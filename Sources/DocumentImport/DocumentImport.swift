import Foundation
import KnowledgeCore
import LocalLibrary

public actor DocumentImport {
    private enum BootstrapState {
        case idle
        case running(
            generation: UUID,
            task: Task<[DurableImportSnapshot], Error>
        )
        case ready
    }

    private let library: LocalLibrary
    private let webAcquirer: any WebAcquiring
    private let webDocumentBuilder: @Sendable (
        AcquiredWebPage,
        SourceDocumentID
    ) async throws -> StaticWebImportProduct
    private let documentIDGenerator: @Sendable () -> SourceDocumentID
    private let workspaceSnapshotLoader: @Sendable (
        ImportWorkspace
    ) async throws -> DurableImportSnapshot
    private let retainedImportsLoader: @Sendable () async throws
        -> [DurableImportSnapshot]
    private let importRunner: (
        @Sendable (ImportWorkspace) async throws -> Void
    )?
    private let claimNextRunnable: @Sendable () async throws
        -> DurableQueueClaim?
    private var bootstrapState: BootstrapState
    private var registry = TaskSnapshotRegistry()
    private var scheduler = ImportScheduler()

    init(
        library: LocalLibrary,
        webAcquirer: any WebAcquiring,
        webDocumentBuilder: @escaping @Sendable (
            AcquiredWebPage,
            SourceDocumentID
        ) async throws -> StaticWebImportProduct = { page, documentID in
            try await StaticWebDocumentBuilder().build(
                page,
                documentID: documentID
            )
        },
        documentIDGenerator: @escaping @Sendable () -> SourceDocumentID = {
            SourceDocumentID()
        },
        workspaceSnapshotLoader: @escaping @Sendable (
            ImportWorkspace
        ) async throws -> DurableImportSnapshot = { workspace in
            try await workspace.snapshot()
        },
        retainedImportsLoader: (@Sendable () async throws
            -> [DurableImportSnapshot])? = nil,
        importRunner: (@Sendable (ImportWorkspace) async throws -> Void)? = nil,
        claimNextRunnable: (@Sendable () async throws
            -> DurableQueueClaim?)? = nil
    ) {
        let resolvedRetainedImportsLoader = retainedImportsLoader ?? {
            try await library.retainedImports()
        }
        self.library = library
        self.webAcquirer = webAcquirer
        self.webDocumentBuilder = webDocumentBuilder
        self.documentIDGenerator = documentIDGenerator
        self.workspaceSnapshotLoader = workspaceSnapshotLoader
        self.retainedImportsLoader = resolvedRetainedImportsLoader
        self.importRunner = importRunner
        self.claimNextRunnable = claimNextRunnable ?? {
            try await library.claimNextRunnable()
        }
        let generation = UUID()
        bootstrapState = .running(
            generation: generation,
            task: Task {
                try await resolvedRetainedImportsLoader()
            }
        )
    }

    public init(library: LocalLibrary) {
        self.init(
            library: library,
            webAcquirer: URLSessionStaticWebAcquirer()
        )
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
                try? await self.start()
            }
            continuation.onTermination = { _ in
                Task {
                    await self.removeListObserver(id: observerID)
                }
            }
        }
    }

    public func start() async throws {
        let generation: UUID
        let task: Task<[DurableImportSnapshot], Error>
        switch bootstrapState {
        case .ready:
            return
        case .running(let currentGeneration, let currentTask):
            generation = currentGeneration
            task = currentTask
        case .idle:
            generation = UUID()
            let loader = retainedImportsLoader
            task = Task { try await loader() }
            bootstrapState = .running(
                generation: generation,
                task: task
            )
        }

        let snapshots: [DurableImportSnapshot]
        do {
            snapshots = try await task.value
        } catch {
            if case .running(let currentGeneration, _) = bootstrapState,
               currentGeneration == generation {
                bootstrapState = .idle
            }
            throw DocumentImportAvailabilityError.localLibraryUnavailable
        }

        switch bootstrapState {
        case .ready:
            return
        case .running(let currentGeneration, _)
            where currentGeneration == generation:
            do {
                try registry.hydrate(snapshots)
            } catch {
                bootstrapState = .idle
                throw DocumentImportAvailabilityError.localLibraryUnavailable
            }
            bootstrapState = .ready
            requestSchedulerWake()
        case .idle, .running:
            throw DocumentImportAvailabilityError.localLibraryUnavailable
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
                try? await self.start()
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
        do {
            try await start()
        } catch {
            return .failure(Self.privacySafeFailure())
        }
        if let terminal = registry.terminalValue(for: taskID) {
            return terminal
        }
        return await withCheckedContinuation { continuation in
            registry.registerWaiter(
                taskID: taskID,
                continuation: continuation
            )
        }
    }

    public func submit(
        _ source: OriginalSource
    ) async throws -> ImportTaskHandle {
        do {
            try await start()
        } catch {
            throw ImportSubmissionError.localLibraryUnavailable
        }

        switch source {
        case .webpage(let url):
            guard Self.isValidWebURL(url) else {
                throw ImportSubmissionError.invalidWebURL
            }
        case .pdfFile:
            throw ImportSubmissionError.unsupportedOriginalSource
        }

        let workspace: ImportWorkspace
        do {
            workspace = try await library.accept(source)
        } catch {
            throw Self.submissionError(for: error)
        }

        let durable: DurableImportSnapshot?
        do {
            durable = try await workspaceSnapshotLoader(workspace)
        } catch {
            durable = nil
        }

        let taskID = workspace.taskID
        if let durable {
            _ = try? registry.apply([durable])
        } else if let retained = try? await library.retainedImports() {
            _ = try? registry.apply(retained)
        }
        requestSchedulerWake()

        return ImportTaskHandle(id: taskID, owner: self)
    }

    private func requestSchedulerWake() {
        guard scheduler.requestWake() else { return }
        let task = Task { await self.runSchedulerLoop() }
        scheduler.install(task)
    }

    private func runSchedulerLoop() async {
        var availabilityRetryDelayMilliseconds: Int64 = 10
        while !Task.isCancelled {
            guard registry.hasQueuedWork else { break }
            let claim: DurableQueueClaim?
            do {
                claim = try await claimNextRunnable()
                availabilityRetryDelayMilliseconds = 10
            } catch DurableQueueClaimError.transientDatabaseContention {
                do {
                    try await Task.sleep(
                        for: .milliseconds(
                            availabilityRetryDelayMilliseconds
                        )
                    )
                } catch {
                    break
                }
                availabilityRetryDelayMilliseconds = min(
                    availabilityRetryDelayMilliseconds * 2,
                    250
                )
                continue
            } catch {
                break
            }
            guard let claim else { break }
            _ = try? registry.apply(claim.queueUpdates + [claim.claimed])
            guard let workspace = try? await library.importWorkspace(
                id: claim.claimed.taskID
            ) else {
                continue
            }

            if let importRunner {
                do {
                    try await importRunner(workspace)
                } catch {
                    await failTask(workspace: workspace, error: error)
                }
            } else {
                switch claim.claimed.originalSource {
                case .webpage(let sourceURL):
                    await runWebImport(
                        workspace: workspace,
                        source: claim.claimed.originalSource,
                        sourceURL: sourceURL
                    )
                case .pdfFile:
                    await failTask(
                        workspace: workspace,
                        error: ImportSubmissionError.unsupportedOriginalSource
                    )
                }
            }
        }
        schedulerLoopDidStop()
    }

    private func schedulerLoopDidStop() {
        if scheduler.didBecomeIdle() {
            requestSchedulerWake()
        }
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

            let product = try await webDocumentBuilder(
                page,
                documentIDGenerator()
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
            let success = Self.success(
                for: outcome,
                publishedIssues: product.issues
            )
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
                )
            )
        } catch {
            await failTask(workspace: workspace, error: error)
        }
    }

    private func failTask(
        workspace: ImportWorkspace,
        error: Error
    ) async {
        var failureRevision = (
            registry.snapshot(for: workspace.taskID)?.revision ?? 0
        ) + 1

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

        guard let current = registry.snapshot(for: workspace.taskID),
              let journalSequence = registry.journalSequence(
                for: workspace.taskID
              ) else {
            return
        }
        let failure = Self.classify(error)
        _ = try? registry.apply(
            ImportTaskSnapshot(
                id: current.id,
                revision: max(failureRevision, current.revision + 1),
                attempt: current.attempt,
                source: current.source,
                state: .failed(failure)
            ),
            journalSequence: journalSequence
        )
    }

    private func registerListObserver(
        id: UUID,
        query: ImportTaskQuery,
        continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    ) {
        registry.registerListObserver(
            id: id,
            query: query,
            continuation: continuation
        )
    }

    private func removeListObserver(id: UUID) {
        registry.removeListObserver(id: id)
    }

    private func registerTaskObserver(
        id: UUID,
        taskID: ImportTaskID,
        continuation: AsyncStream<ImportTaskSnapshot>.Continuation
    ) {
        registry.registerTaskObserver(
            id: id,
            taskID: taskID,
            continuation: continuation
        )
    }

    private func removeTaskObserver(id: UUID, taskID: ImportTaskID) {
        registry.removeTaskObserver(id: id, taskID: taskID)
    }

    private func updateSnapshot(
        taskID: ImportTaskID,
        revision: UInt64,
        state: ImportTaskState
    ) {
        guard let current = registry.snapshot(for: taskID),
              let journalSequence = registry.journalSequence(for: taskID) else {
            return
        }
        _ = try? registry.apply(
            ImportTaskSnapshot(
                id: current.id,
                revision: revision,
                attempt: current.attempt,
                source: current.source,
                state: state
            ),
            journalSequence: journalSequence
        )
    }

    private func finishTask(
        taskID: ImportTaskID,
        snapshot: ImportTaskSnapshot
    ) {
        guard let journalSequence = registry.journalSequence(for: taskID) else {
            return
        }
        _ = try? registry.apply(snapshot, journalSequence: journalSequence)
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

    static func matches(
        _ state: ImportTaskState,
        query: ImportTaskQuery
    ) -> Bool {
        TaskSnapshotRegistry.matches(state, query: query)
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
        for outcome: PublicationOutcome,
        publishedIssues: [KnowledgeCore.ImportIssue]
    ) -> ImportSuccess {
        switch outcome {
        case .published(let documentID):
            return .published(
                documentID: documentID,
                issues: publishedIssues
            )
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

    private static func classify(_ error: Error) -> ImportFailure {
        if let error = error as? WebAcquisitionError {
            switch error {
            case .networkUnavailable:
                return ImportFailure(
                    code: .networkUnavailable,
                    recovery: .retryable
                )
            case .requestTimedOut:
                return ImportFailure(
                    code: .requestTimedOut,
                    recovery: .retryable
                )
            case .accessDenied:
                return ImportFailure(
                    code: .accessDenied,
                    recovery: .requiresUserAction
                )
            case .invalidHTTPResponse:
                return ImportFailure(
                    code: .invalidHTTPResponse,
                    recovery: .retryable
                )
            case .unsupportedContentType:
                return ImportFailure(
                    code: .unsupportedContentType,
                    recovery: .unsupported
                )
            case .responseTooLarge:
                return ImportFailure(
                    code: .responseTooLarge,
                    recovery: .unsupported
                )
            }
        }

        if let error = error as? StaticWebBuildError {
            switch error {
            case .missingArticle, .noReadableBlocks:
                return ImportFailure(
                    code: .webpageHasNoReadableArticle,
                    recovery: .unsupported
                )
            case .unreadableHTML, .cannotWritePackage:
                return ImportFailure(
                    code: .artifactConstructionFailed,
                    recovery: .retryable
                )
            }
        }

        if let error = error as? LocalLibraryError {
            switch error {
            case .publicationFailed(let retryable):
                return ImportFailure(
                    code: .publicationFailed,
                    recovery: retryable ? .retryable : .requiresUserAction
                )
            case .unavailable,
                 .insufficientDiskSpace,
                 .staleRevision,
                 .invalidTaskState,
                 .checkpointRegression,
                 .artifactMissing,
                 .artifactOwnershipViolation,
                 .corruptLibrary:
                return privacySafeFailure()
            }
        }

        return privacySafeFailure()
    }

    private static func privacySafeFailure() -> ImportFailure {
        ImportFailure(
            code: .localLibraryUnavailable,
            recovery: .requiresUserAction
        )
    }
}
