import Foundation
import KnowledgeCore
import LocalLibrary

public actor DocumentImport {
    private struct TaskRecord {
        var snapshot: ImportTaskSnapshot
        let sequence: UInt64
        var terminal: ImportTerminalState?
        var observers: [
            UUID: AsyncStream<ImportTaskSnapshot>.Continuation
        ] = [:]
        var waiters: [
            CheckedContinuation<ImportTerminalState, Never>
        ] = []
    }

    private struct ListObserver {
        let query: ImportTaskQuery
        let continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    }

    private let library: LocalLibrary
    private let webAcquirer: any WebAcquiring
    private let documentIDGenerator: @Sendable () -> SourceDocumentID
    private let workspaceSnapshotLoader: @Sendable (
        ImportWorkspace
    ) async throws -> DurableImportSnapshot
    private var records: [ImportTaskID: TaskRecord] = [:]
    private var listObservers: [UUID: ListObserver] = [:]
    private var nextSequence: UInt64 = 0

    init(
        library: LocalLibrary,
        webAcquirer: any WebAcquiring,
        documentIDGenerator: @escaping @Sendable () -> SourceDocumentID = {
            SourceDocumentID()
        },
        workspaceSnapshotLoader: @escaping @Sendable (
            ImportWorkspace
        ) async throws -> DurableImportSnapshot = { workspace in
            try await workspace.snapshot()
        }
    ) {
        self.library = library
        self.webAcquirer = webAcquirer
        self.documentIDGenerator = documentIDGenerator
        self.workspaceSnapshotLoader = workspaceSnapshotLoader
    }

    public nonisolated func observeTasks(
        _ query: ImportTaskQuery = .unfinished
    ) -> AsyncStream<[ImportTaskSnapshot]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let observerID = UUID()
            Task {
                await self.registerListObserver(
                    id: observerID,
                    query: query,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeListObserver(id: observerID)
                }
            }
        }
    }

    nonisolated func updates(
        for taskID: ImportTaskID
    ) -> AsyncStream<ImportTaskSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let observerID = UUID()
            Task {
                await self.registerTaskObserver(
                    id: observerID,
                    taskID: taskID,
                    continuation: continuation
                )
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeTaskObserver(
                        id: observerID,
                        taskID: taskID
                    )
                }
            }
        }
    }

    func value(for taskID: ImportTaskID) async -> ImportTerminalState {
        guard var record = records[taskID] else {
            return .failure(Self.privacySafeFailure())
        }
        if let terminal = record.terminal {
            return terminal
        }
        return await withCheckedContinuation { continuation in
            record.waiters.append(continuation)
            records[taskID] = record
        }
    }

    public func submit(
        _ source: OriginalSource
    ) async throws -> ImportTaskHandle {
        let sourceURL: URL
        switch source {
        case .webpage(let url):
            guard Self.isValidWebURL(url) else {
                throw ImportSubmissionError.invalidWebURL
            }
            sourceURL = url
        case .pdfFile:
            throw ImportSubmissionError.unsupportedOriginalSource
        }

        let workspace: ImportWorkspace
        do {
            workspace = try await library.accept(source)
        } catch {
            throw Self.submissionError(for: error)
        }

        let durable: DurableImportSnapshot
        do {
            durable = try await workspaceSnapshotLoader(workspace)
        } catch {
            try? await workspace.abandon(expectedRevision: 0)
            throw Self.submissionError(for: error)
        }

        let taskID = workspace.taskID
        let snapshot = ImportTaskSnapshot(
            id: taskID,
            revision: durable.revision,
            attempt: durable.attempt,
            source: .webpage(sourceURL),
            state: .queued(position: 0)
        )
        records[taskID] = TaskRecord(
            snapshot: snapshot,
            sequence: nextSequence,
            terminal: nil
        )
        nextSequence += 1
        notifyListObservers()

        Task {
            await self.runWebImport(
                workspace: workspace,
                source: source,
                sourceURL: sourceURL
            )
        }

        return ImportTaskHandle(id: taskID, owner: self)
    }

    private func runWebImport(
        workspace: ImportWorkspace,
        source: OriginalSource,
        sourceURL: URL
    ) async {
        var packageURL: URL?
        defer {
            if let packageURL {
                try? FileManager.default.removeItem(at: packageURL)
            }
        }

        do {
            let accepted = try await workspace.snapshot()
            let acquiring = try await workspace.checkpoint(
                CheckpointUpdate(
                    expectedRevision: accepted.revision,
                    ordinal: 1,
                    envelope: Self.checkpoint(
                        "acquiringOriginalSource"
                    )
                )
            )
            updateSnapshot(
                taskID: workspace.taskID,
                revision: acquiring.revision,
                state: .running(Self.progress(.acquiringOriginalSource))
            )

            let page = try await webAcquirer.acquire(sourceURL)
            let constructing = try await workspace.checkpoint(
                CheckpointUpdate(
                    expectedRevision: acquiring.revision,
                    ordinal: 2,
                    envelope: Self.checkpoint(
                        "constructingSourceDocument"
                    )
                )
            )
            updateSnapshot(
                taskID: workspace.taskID,
                revision: constructing.revision,
                state: .running(
                    Self.progress(.constructingSourceDocument)
                )
            )

            let product = try StaticWebDocumentBuilder().build(
                page,
                documentID: documentIDGenerator()
            )
            packageURL = product.packageURL
            let artifact = try await workspace.stageArtifact(
                .package(
                    product.packageURL,
                    descriptor: product.descriptor
                ),
                expectedRevision: constructing.revision
            )
            let staged = try await workspace.snapshot()
            let publishing = try await workspace.checkpoint(
                CheckpointUpdate(
                    expectedRevision: staged.revision,
                    ordinal: 3,
                    envelope: Self.checkpoint("publishing")
                )
            )
            updateSnapshot(
                taskID: workspace.taskID,
                revision: publishing.revision,
                state: .running(Self.progress(.publishing))
            )

            let outcome = try await workspace.finish(
                PublicationCandidate(
                    fingerprint: product.fingerprint,
                    artifact: artifact,
                    document: product.document.content,
                    originalSource: source
                ),
                expectedRevision: publishing.revision
            )
            let success = Self.success(for: outcome)
            let completed = try? await workspaceSnapshotLoader(workspace)
            finishTask(
                taskID: workspace.taskID,
                snapshot: ImportTaskSnapshot(
                    id: workspace.taskID,
                    revision: completed?.revision
                        ?? Self.completionRevision(
                            after: publishing.revision,
                            outcome: outcome
                        ),
                    attempt: completed?.attempt ?? publishing.attempt,
                    source: .webpage(sourceURL),
                    state: .completed(success)
                ),
                terminal: .success(success)
            )
        } catch {
            await failTask(workspace: workspace)
        }
    }

    private func failTask(workspace: ImportWorkspace) async {
        var failureRevision = (records[workspace.taskID]?.snapshot.revision ?? 0)
            + 1

        if let durable = try? await workspace.snapshot() {
            failureRevision = max(failureRevision, durable.revision)
            if durable.state != .completed && durable.state != .abandoned {
                try? await workspace.abandon(
                    expectedRevision: durable.revision
                )
                if let abandoned = try? await workspace.snapshot() {
                    failureRevision = max(
                        failureRevision,
                        abandoned.revision
                    )
                }
            }
        }

        guard let record = records[workspace.taskID] else {
            return
        }
        let failure = Self.privacySafeFailure()
        finishTask(
            taskID: workspace.taskID,
            snapshot: ImportTaskSnapshot(
                id: record.snapshot.id,
                revision: max(
                    failureRevision,
                    record.snapshot.revision + 1
                ),
                attempt: record.snapshot.attempt,
                source: record.snapshot.source,
                state: .failed(failure)
            ),
            terminal: .failure(failure)
        )
    }

    private func registerListObserver(
        id: UUID,
        query: ImportTaskQuery,
        continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    ) {
        let result = continuation.yield(snapshots(matching: query))
        if case .terminated = result {
            return
        }
        listObservers[id] = ListObserver(
            query: query,
            continuation: continuation
        )
    }

    private func removeListObserver(id: UUID) {
        listObservers.removeValue(forKey: id)
    }

    private func registerTaskObserver(
        id: UUID,
        taskID: ImportTaskID,
        continuation: AsyncStream<ImportTaskSnapshot>.Continuation
    ) {
        guard var record = records[taskID] else {
            continuation.finish()
            return
        }
        let result = continuation.yield(record.snapshot)
        if case .terminated = result {
            return
        }
        if record.terminal != nil {
            continuation.finish()
            return
        }
        record.observers[id] = continuation
        records[taskID] = record
    }

    private func removeTaskObserver(id: UUID, taskID: ImportTaskID) {
        guard var record = records[taskID] else {
            return
        }
        record.observers.removeValue(forKey: id)
        records[taskID] = record
    }

    private func updateSnapshot(
        taskID: ImportTaskID,
        revision: UInt64,
        state: ImportTaskState
    ) {
        guard var record = records[taskID] else {
            return
        }
        record.snapshot = ImportTaskSnapshot(
            id: record.snapshot.id,
            revision: revision,
            attempt: record.snapshot.attempt,
            source: record.snapshot.source,
            state: state
        )
        let snapshot = record.snapshot
        let observers = Array(record.observers.values)
        records[taskID] = record
        for observer in observers {
            observer.yield(snapshot)
        }
        notifyListObservers()
    }

    private func finishTask(
        taskID: ImportTaskID,
        snapshot: ImportTaskSnapshot,
        terminal: ImportTerminalState
    ) {
        guard var record = records[taskID] else {
            return
        }
        record.snapshot = snapshot
        record.terminal = terminal
        let observers = Array(record.observers.values)
        let waiters = record.waiters
        record.observers.removeAll()
        record.waiters.removeAll()
        records[taskID] = record

        for observer in observers {
            observer.yield(snapshot)
            observer.finish()
        }
        for waiter in waiters {
            waiter.resume(returning: terminal)
        }
        notifyListObservers()
    }

    private func notifyListObservers() {
        for observer in listObservers.values {
            observer.continuation.yield(
                snapshots(matching: observer.query)
            )
        }
    }

    private func snapshots(
        matching query: ImportTaskQuery
    ) -> [ImportTaskSnapshot] {
        records.values
            .filter { Self.matches($0.snapshot.state, query: query) }
            .sorted { $0.sequence < $1.sequence }
            .map(\.snapshot)
    }

    private static func matches(
        _ state: ImportTaskState,
        query: ImportTaskQuery
    ) -> Bool {
        switch query {
        case .all:
            return true
        case .active:
            switch state {
            case .queued, .running:
                return true
            case .failed, .completed:
                return false
            }
        case .unfinished:
            switch state {
            case .queued, .running, .failed:
                return true
            case .completed:
                return false
            }
        }
    }

    private static func progress(
        _ activity: ImportActivity
    ) -> ImportProgress {
        ImportProgress(
            activity: activity,
            completedUnitCount: 0,
            totalUnitCount: nil
        )
    }

    private static func checkpoint(
        _ stage: String
    ) -> CheckpointEnvelope {
        CheckpointEnvelope(
            codecVersion: 1,
            payload: Data("document-import-t03:\(stage)".utf8)
        )
    }

    private static func completionRevision(
        after publishingRevision: UInt64,
        outcome: PublicationOutcome
    ) -> UInt64 {
        let increment: UInt64
        switch outcome {
        case .published:
            increment = 2
        case .alreadyImported:
            increment = 1
        }
        let (revision, overflow) = publishingRevision
            .addingReportingOverflow(increment)
        precondition(
            !overflow,
            "A successful Local Library finish must have completed its durable revision increments"
        )
        return revision
    }

    private static func success(
        for outcome: PublicationOutcome
    ) -> ImportSuccess {
        switch outcome {
        case .published(let documentID):
            return .published(documentID: documentID, issues: [])
        case .alreadyImported(
            let documentID,
            let location,
            let provenanceAdded
        ):
            return .alreadyImported(
                documentID: documentID,
                location: location,
                provenanceAdded: provenanceAdded
            )
        }
    }

    private static func isValidWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }

    private static func submissionError(
        for error: Error
    ) -> ImportSubmissionError {
        guard let error = error as? LocalLibraryError else {
            return .cannotPersistImportTask
        }
        switch error {
        case .insufficientDiskSpace:
            return .insufficientDiskSpace
        case .unavailable, .corruptLibrary:
            return .localLibraryUnavailable
        case .staleRevision,
             .invalidTaskState,
             .checkpointRegression,
             .artifactMissing,
             .artifactOwnershipViolation,
             .publicationFailed:
            return .cannotPersistImportTask
        }
    }

    private static func privacySafeFailure() -> ImportFailure {
        ImportFailure(
            code: .localLibraryUnavailable,
            recovery: .requiresUserAction
        )
    }
}
