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
    let webAcquirer: any WebAcquiring
    let webDocumentBuilder: @Sendable (
        AcquiredWebPage,
        SourceDocumentID
    ) async throws -> StaticWebImportProduct
    let documentIDGenerator: @Sendable () -> SourceDocumentID
    let workspaceSnapshotLoader: @Sendable (
        ImportWorkspace
    ) async throws -> DurableImportSnapshot
    let boundaryHook: ImportRunnerBoundaryHook
    private let retainedImportsLoader: @Sendable () async throws
        -> [DurableImportSnapshot]
    private let importRunner: (
        @Sendable (ImportWorkspace) async throws -> Void
    )?
    private let claimNextRunnable: @Sendable () async throws
        -> DurableQueueClaim?
    private let importWorkspaceLoader: @Sendable (ImportTaskID) async throws
        -> ImportWorkspace?
    private let acceptanceLoader: @Sendable (OriginalSource) async throws
        -> DurableImportAcceptance
    private var bootstrapState: BootstrapState
    private var registry = TaskSnapshotRegistry()
    private var scheduler = ImportScheduler()
    private var activeRunners: [ImportTaskID: Task<Void, Never>] = [:]

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
            -> DurableQueueClaim?)? = nil,
        importWorkspaceLoader: (@Sendable (ImportTaskID) async throws
            -> ImportWorkspace?)? = nil,
        acceptanceLoader: (@Sendable (OriginalSource) async throws
            -> DurableImportAcceptance)? = nil,
        importRunnerBoundaryHook: ImportRunnerBoundaryHook? = nil
    ) {
        let resolvedRetainedImportsLoader = retainedImportsLoader ?? {
            try await library.retainedImports()
        }
        self.library = library
        self.webAcquirer = webAcquirer
        self.webDocumentBuilder = webDocumentBuilder
        self.documentIDGenerator = documentIDGenerator
        self.workspaceSnapshotLoader = workspaceSnapshotLoader
        self.boundaryHook = importRunnerBoundaryHook ?? { _ in }
        self.retainedImportsLoader = resolvedRetainedImportsLoader
        self.importRunner = importRunner
        self.claimNextRunnable = claimNextRunnable ?? {
            try await library.claimNextRunnable()
        }
        self.importWorkspaceLoader = importWorkspaceLoader ?? { taskID in
            try await library.importWorkspace(id: taskID)
        }
        self.acceptanceLoader = acceptanceLoader ?? { source in
            try await library.acceptWithAuthoritativeSnapshots(source)
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
            webAcquirer: DynamicFallbackWebAcquirer()
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
            for snapshot in snapshots
            where snapshot.state == .cancelling {
                await runCancellationCleanup(
                    taskID: snapshot.taskID,
                    expectedRevision: snapshot.revision
                )
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

        let acceptance: DurableImportAcceptance
        do {
            acceptance = try await acceptanceLoader(source)
        } catch {
            throw Self.submissionError(for: error)
        }
        let taskID = acceptance.workspace.taskID
        do {
            _ = try registry.applyBatch(acceptance.snapshots)
        } catch {
            do {
                _ = try registry.reconcileAuthoritative(
                    acceptance.snapshots
                )
            } catch {
                preconditionFailure(
                    "A transactional acceptance batch must reconcile"
                )
            }
        }
        precondition(
            registry.snapshot(for: taskID) != nil,
            "A durably accepted task must exist before handle return"
        )
        requestSchedulerWake()

        return ImportTaskHandle(id: taskID, owner: self)
    }

    public func task(
        id: ImportTaskID
    ) async throws -> ImportTaskHandle? {
        do {
            try await start()
        } catch {
            throw DocumentImportAvailabilityError.localLibraryUnavailable
        }
        guard registry.snapshot(for: id) != nil else {
            return nil
        }
        return ImportTaskHandle(id: id, owner: self)
    }

    public func cancel(taskID: ImportTaskID) async throws {
        do {
            try await start()
        } catch {
            throw DocumentImportAvailabilityError.localLibraryUnavailable
        }
        guard let current = registry.snapshot(for: taskID) else {
            throw ImportTaskControlError.taskNotFound
        }

        let mutation: DurableQueueMutation
        do {
            mutation = try await requestCancellationOnce(
                taskID: taskID,
                expectedRevision: current.revision
            )
        } catch let error as LocalLibraryError {
            throw await cancelControlError(
                for: error,
                currentState: current.state,
                taskID: taskID
            )
        } catch {
            throw ImportTaskControlError.invalidState
        }

        _ = try? registry.applyBatch(
            mutation.queueUpdates + [mutation.primary]
        )
        guard mutation.primary.state == .cancelling else {
            return
        }
        if let runnerTask = activeRunners[taskID] {
            runnerTask.cancel()
        } else {
            await runCancellationCleanup(
                taskID: taskID,
                expectedRevision: mutation.primary.revision
            )
        }
        requestSchedulerWake()
    }

    public func retry(taskID: ImportTaskID) async throws {
        do {
            try await start()
        } catch {
            throw DocumentImportAvailabilityError.localLibraryUnavailable
        }
        guard registry.snapshot(for: taskID) != nil else {
            throw ImportTaskControlError.taskNotFound
        }

        let durable: DurableImportSnapshot
        do {
            durable = try await library.snapshot(taskID: taskID)
        } catch {
            throw DocumentImportAvailabilityError.localLibraryUnavailable
        }

        let disposition: RetryCheckpointDisposition
        switch durable.state {
        case .failed:
            guard Self.isRetryable(durable.failure) else {
                throw ImportTaskControlError.retryNotAllowed
            }
            disposition = Self.retryDisposition(for: durable)
        case .cancelled:
            disposition = .clear
        case .completed:
            throw ImportTaskControlError.retryNotAllowed
        case .queued, .running, .cancelling, .publicationPending:
            throw ImportTaskControlError.invalidState
        case .abandoned, .accepted, .working:
            throw ImportTaskControlError.retryNotAllowed
        }

        let retried: DurableImportSnapshot
        do {
            retried = try await library.retryImport(
                taskID: taskID,
                expectedRevision: durable.revision,
                checkpointDisposition: disposition
            )
        } catch let error as LocalLibraryError {
            throw Self.retryControlError(for: error)
        } catch {
            throw ImportTaskControlError.invalidState
        }
        _ = try? registry.applyBatch([retried])
        requestSchedulerWake()
    }

    /// Requests cancellation, tolerating one stale revision: the in-memory
    /// registry can lag the durable revision while checkpoint writes are in
    /// flight, so refresh from the durable snapshot before reporting failure.
    private func requestCancellationOnce(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) async throws -> DurableQueueMutation {
        do {
            return try await library.requestCancellation(
                taskID: taskID,
                expectedRevision: expectedRevision
            )
        } catch let error as LocalLibraryError {
            guard case .staleRevision = error else {
                throw error
            }
            let durable = try await library.snapshot(taskID: taskID)
            return try await library.requestCancellation(
                taskID: taskID,
                expectedRevision: durable.revision
            )
        }
    }

    private func cancelControlError(
        for error: LocalLibraryError,
        currentState: ImportTaskState,
        taskID: ImportTaskID
    ) async -> ImportTaskControlError {
        switch error {
        case .unavailable:
            return .invalidState
        case .staleRevision,
             .invalidTaskState:
            // The in-memory registry snapshot can lag behind the durable
            // state when publication races with cancellation; classify the
            // terminal case from the durable snapshot before reporting.
            if let durable = try? await library.snapshot(taskID: taskID),
               case .completed = durable.state {
                return .tooLate
            }
            if case .completed = currentState {
                return .tooLate
            }
            return .invalidState
        case .insufficientDiskSpace,
             .checkpointRegression,
             .artifactMissing,
             .artifactOwnershipViolation,
             .publicationFailed,
             .corruptLibrary:
            return .invalidState
        }
    }

    private static func retryControlError(
        for error: LocalLibraryError
    ) -> ImportTaskControlError {
        switch error {
        case .unavailable,
             .staleRevision,
             .invalidTaskState,
             .insufficientDiskSpace,
             .checkpointRegression,
             .artifactMissing,
             .artifactOwnershipViolation,
             .publicationFailed,
             .corruptLibrary:
            return .invalidState
        }
    }

    private static func persistedFailure(
        from envelope: ImportTaskFailureEnvelope?
    ) -> PersistedImportFailure? {
        guard let envelope, envelope.codecVersion == 1 else {
            return nil
        }
        return try? JSONDecoder().decode(
            PersistedImportFailure.self,
            from: envelope.payload
        )
    }

    private static func isRetryable(
        _ envelope: ImportTaskFailureEnvelope?
    ) -> Bool {
        persistedFailure(from: envelope)?.recovery == .retryable
    }

    private static func retryDisposition(
        for durable: DurableImportSnapshot
    ) -> RetryCheckpointDisposition {
        // A failure caused by an invalid checkpoint must never be reused:
        // retaining it would make a user retry fail deterministically.
        if persistedFailure(from: durable.failure)?.code == .checkpointInvalid {
            return .clear
        }
        guard let checkpoint = durable.checkpoint,
              checkpoint.codecVersion == 1,
              durable.checkpointArtifact != nil,
              let ordinal = durable.checkpointOrdinal,
              let stage = WebImportStage(rawValue: ordinal),
              stage != .acquiring
        else {
            return .clear
        }
        return .retainVerified
    }

    private func requestSchedulerWake() {
        guard scheduler.requestWake() else { return }
        let task = Task { await self.runSchedulerLoop() }
        scheduler.install(task)
    }

    private func runSchedulerLoop() async {
        var availabilityRetryDelayMilliseconds: Int64 = 10
        var contentionAttemptCount = 0
        while !Task.isCancelled {
            guard activeRunners.isEmpty else { break }
            guard registry.hasQueuedWork else { break }
            let claim: DurableQueueClaim?
            do {
                claim = try await claimNextRunnable()
                availabilityRetryDelayMilliseconds = 10
                contentionAttemptCount = 0
            } catch DurableQueueClaimError.transientDatabaseContention {
                contentionAttemptCount += 1
                guard contentionAttemptCount < 5 else { break }
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
            let projection: TaskSnapshotRegistry.BatchApplyResult
            do {
                projection = try registry.applyBatch(
                    claim.queueUpdates + [claim.claimed]
                )
                guard projection.changedTaskIDs.contains(
                    claim.claimed.taskID
                ) else {
                    _ = await rollbackClaim(claim)
                    break
                }
            } catch {
                _ = await rollbackClaim(claim)
                break
            }

            let workspace: ImportWorkspace
            do {
                guard let loaded = try await importWorkspaceLoader(
                    claim.claimed.taskID
                ) else {
                    _ = await rollbackClaim(claim)
                    break
                }
                workspace = loaded
            } catch {
                _ = await rollbackClaim(claim)
                break
            }

            guard activeRunners[claim.claimed.taskID] == nil else {
                _ = await rollbackClaim(claim)
                break
            }
            let claimed = claim.claimed
            activeRunners[claimed.taskID] = Task {
                await self.runImport(
                    workspace: workspace,
                    claimed: claimed
                )
                await self.runnerDidFinish(claimed.taskID)
            }
            break
        }
        schedulerLoopDidStop()
    }

    private func runImport(
        workspace: ImportWorkspace,
        claimed: DurableImportSnapshot
    ) async {
        if let importRunner {
            do {
                try await importRunner(workspace)
            } catch is CancellationError {
                await finishRunnerCancellation(workspace: workspace)
            } catch {
                await failTask(workspace: workspace, error: error)
            }
            return
        }
        switch claimed.originalSource {
        case .webpage(let sourceURL):
            await runResumableWebImport(
                workspace: workspace,
                source: claimed.originalSource,
                sourceURL: sourceURL
            )
        case .pdfFile:
            await failTask(
                workspace: workspace,
                error: ImportSubmissionError.unsupportedOriginalSource
            )
        }
    }

    private func runnerDidFinish(_ taskID: ImportTaskID) async {
        activeRunners.removeValue(forKey: taskID)
        await reconcileLeftoverCancellation(taskID: taskID)
        requestSchedulerWake()
    }

    private func reconcileLeftoverCancellation(
        taskID: ImportTaskID
    ) async {
        guard let workspace = try? await importWorkspaceLoader(taskID),
              let durable = try? await workspace.snapshot(),
              durable.state == .cancelling
        else {
            return
        }
        await runCancellationCleanup(
            taskID: taskID,
            expectedRevision: durable.revision
        )
    }

    func finishRunnerCancellation(workspace: ImportWorkspace) async {
        guard let durable = try? await workspace.snapshot(),
              durable.state == .cancelling
        else {
            return
        }
        await runCancellationCleanup(
            taskID: workspace.taskID,
            expectedRevision: durable.revision
        )
    }

    private func runCancellationCleanup(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) async {
        do {
            try await boundaryHook(.duringCancellationCleanup)
        } catch {
            return
        }
        guard let cancelled = try? await library.finishCancellation(
            taskID: taskID,
            expectedRevision: expectedRevision
        ) else {
            return
        }
        _ = try? registry.applyBatch([cancelled])
    }

    private func rollbackClaim(_ claim: DurableQueueClaim) async -> Bool {
        do {
            let rollback = try await library.rollbackClaim(
                taskID: claim.claimed.taskID,
                expectedRevision: claim.claimed.revision,
                previousQueueSequence: claim.previousQueueSequence
            )
            let projection = try registry.applyBatch(
                rollback.queueUpdates + [rollback.primary]
            )
            return projection.changedTaskIDs.contains(
                rollback.primary.taskID
            )
        } catch {
            return false
        }
    }

    private func schedulerLoopDidStop() {
        if scheduler.didBecomeIdle() {
            requestSchedulerWake()
        }
    }

    func failTask(
        workspace: ImportWorkspace,
        error: Error
    ) async {
        guard !(error is ImportTaskRunnerInterruption) else {
            return
        }
        if await persistFailure(workspace: workspace, error: error) {
            return
        }

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

    private func persistFailure(
        workspace: ImportWorkspace,
        error: Error
    ) async -> Bool {
        let failure = Self.classify(error)
        guard let durable = try? await workspace.snapshot(),
              durable.state == .queued || durable.state == .running
        else {
            return false
        }
        guard let payload = try? JSONEncoder().encode(
            PersistedImportFailure(
                code: failure.code,
                recovery: failure.recovery,
                diagnosticID: failure.diagnosticID
            )
        ) else {
            return false
        }
        do {
            let mutation = try await workspace.recordFailure(
                expectedRevision: durable.revision,
                failure: ImportTaskFailureEnvelope(
                    codecVersion: 1,
                    payload: payload
                ),
                retainCheckpoint: failure.recovery == .retryable
            )
            _ = try? registry.applyBatch(
                mutation.queueUpdates + [mutation.primary]
            )
            return true
        } catch {
            return false
        }
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

    func updateSnapshot(
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

    func finishTask(
        taskID: ImportTaskID,
        snapshot: ImportTaskSnapshot
    ) {
        guard let journalSequence = registry.journalSequence(for: taskID) else {
            return
        }
        _ = try? registry.apply(snapshot, journalSequence: journalSequence)
    }

    static func progress(
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

    static func success(
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

    static func classify(_ error: Error) -> ImportFailure {
        if let error = error as? WebImportCheckpointError {
            switch error {
            case .invalidPackage, .cannotWrite:
                return ImportFailure(
                    code: .checkpointInvalid,
                    recovery: .retryable
                )
            }
        }

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
            case .insufficientDiskSpace:
                return ImportFailure(
                    code: .insufficientDiskSpace,
                    recovery: .requiresUserAction
                )
            case .publicationFailed(let retryable):
                return ImportFailure(
                    code: .publicationFailed,
                    recovery: retryable ? .retryable : .requiresUserAction
                )
            case .unavailable,
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
