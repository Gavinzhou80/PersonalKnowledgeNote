import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

@Test(.timeLimit(.minutes(1)))
func schedulerRunsOneHeavyTaskInDurableFIFOOrder() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let first = try await harness.importer.submit(.webpage(harness.url("/1")))
    let second = try await harness.importer.submit(.webpage(harness.url("/2")))
    let third = try await harness.importer.submit(.webpage(harness.url("/3")))

    try await harness.runner.waitUntilStarted(first.id)
    #expect(await harness.runner.maximumConcurrentRuns == 1)
    #expect(await harness.runner.startedIDs == [first.id])
    #expect(try await currentQueuedPosition(second) == 1)
    #expect(try await currentQueuedPosition(third) == 2)

    await harness.runner.release(first.id)
    try await harness.runner.waitUntilStarted(second.id)
    #expect(await harness.runner.startedIDs == [first.id, second.id])
    #expect(await harness.runner.maximumConcurrentRuns == 1)

    await harness.runner.release(second.id)
    try await harness.runner.waitUntilStarted(third.id)
    await harness.runner.release(third.id)
}

@Test(.timeLimit(.minutes(1)))
func submitWhileRunnerIsBlockedDoesNotLoseSchedulerWake() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let claims = CountingClaimProbe(library: library)
    let runner = DeterministicRunnerGate()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    let first = try await importer.submit(
        .webpage(URL(string: "https://fixture.invalid/lost-wake-first")!)
    )
    try await runner.waitUntilStarted(first.id)
    #expect(await claims.callCount == 1)

    let second = try await importer.submit(
        .webpage(URL(string: "https://fixture.invalid/lost-wake-second")!)
    )
    #expect(await claims.callCount == 1)
    #expect(await runner.maximumConcurrentRuns == 1)

    await runner.release(first.id)
    try await runner.waitUntilStarted(second.id)
    #expect(await claims.callCount == 2)
    #expect(await runner.startedIDs == [first.id, second.id])
    #expect(await runner.maximumConcurrentRuns == 1)
    await runner.release(second.id)
}

@Test(.timeLimit(.minutes(1)))
func claimingHeadRevisesWaitingPositionsButTailSubmitDoesNot() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let first = try await harness.importer.submit(.webpage(harness.url("/1")))
    let second = try await harness.importer.submit(.webpage(harness.url("/2")))
    try await harness.runner.waitUntilStarted(first.id)
    let secondBeforeTail = try await latestSnapshot(second)
    #expect(secondBeforeTail.state == .queued(position: 1))

    let third = try await harness.importer.submit(.webpage(harness.url("/3")))
    let thirdBeforeShift = try await latestSnapshot(third)
    let secondAfterTail = try await latestSnapshot(second)
    #expect(secondAfterTail == secondBeforeTail)
    #expect(try await currentQueuedPosition(third) == 2)

    await harness.runner.release(first.id)
    try await harness.runner.waitUntilStarted(second.id)
    let thirdShifted = try await latestSnapshot(third)
    #expect(thirdShifted.state == .queued(position: 1))
    #expect(thirdShifted.revision > thirdBeforeShift.revision)

    await harness.runner.release(second.id)
    try await harness.runner.waitUntilStarted(third.id)
    await harness.runner.release(third.id)
}

@Test(.timeLimit(.minutes(1)))
func bootstrapRunsPreacceptedTasksBeforeImmediateSubmission() async throws {
    let firstURL = URL(string: "https://fixture.invalid/preaccepted-1")!
    let secondURL = URL(string: "https://fixture.invalid/preaccepted-2")!
    let harness = try await DurableQueueHarness.make(
        preacceptedURLs: [firstURL, secondURL]
    )
    defer { removeTemporaryDocumentImportRoot(harness.root) }

    let retained = try await harness.library.retainedImports()
    let submitted = try await harness.importer.submit(
        .webpage(harness.url("/submitted"))
    )
    let firstID = try #require(retained.first?.taskID)
    let secondID = try #require(retained.dropFirst().first?.taskID)

    try await harness.runner.waitUntilStarted(firstID)
    #expect(await harness.runner.startedIDs == [firstID])
    await harness.runner.release(firstID)
    try await harness.runner.waitUntilStarted(secondID)
    await harness.runner.release(secondID)
    try await harness.runner.waitUntilStarted(submitted.id)
    await harness.runner.release(submitted.id)
}

@Test(.timeLimit(.minutes(1)))
func simultaneousSubmissionsCoalesceWakesWithoutDuplicateClaims() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }

    let handles = try await withThrowingTaskGroup(
        of: ImportTaskHandle.self,
        returning: [ImportTaskHandle].self
    ) { group in
        for index in 0..<12 {
            group.addTask {
                try await harness.importer.submit(
                    .webpage(harness.url("/stress-\(index)"))
                )
            }
        }
        var result: [ImportTaskHandle] = []
        for try await handle in group { result.append(handle) }
        return result
    }
    #expect(handles.count == 12)
    let durableOrder = try await harness.library.retainedImports().map(\.taskID)

    for taskID in durableOrder {
        try await harness.runner.waitUntilStarted(taskID)
        #expect(await harness.runner.maximumConcurrentRuns == 1)
        await harness.runner.release(taskID)
    }
    #expect(await harness.runner.startedIDs == durableOrder)
    #expect(Set(await harness.runner.startedIDs).count == durableOrder.count)
}

@Test(.timeLimit(.minutes(1)))
func transientClaimFailureRetriesWithoutAnotherWakeOrDuplicateRunner() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/transient-claim")!)
    )
    let runner = DeterministicRunnerGate()
    let claims = TransientClaimProbe(library: library)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    try await importer.start()
    try await runner.waitUntilStarted(workspace.taskID)
    #expect(await claims.callCount == 2)
    #expect(await runner.startedIDs == [workspace.taskID])
    #expect(await runner.maximumConcurrentRuns == 1)
    await runner.release(workspace.taskID)
}

@Test(.timeLimit(.minutes(1)))
func unclassifiedClaimUnavailableHaltsInsteadOfSpinning() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    _ = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/nontransient-claim")!)
    )
    let claims = NonTransientClaimProbe()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { _ in },
        claimNextRunnable: { try await claims.claim() }
    )

    try await importer.start()
    try await claims.waitUntilCalled()
    try await claims.verifyCallCountRemains(1, for: .milliseconds(300))
    #expect(await claims.callCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func persistentContentionExhaustsAndLaterSubmitStartsFreshRetryGeneration() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let first = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/contention-first")!)
    )
    let claims = PersistentContentionClaimProbe(library: library)
    let runner = DeterministicRunnerGate()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    try await importer.start()
    try await claims.waitForCallCount(5)
    try await claims.verifyCallCountRemains(5, for: .milliseconds(300))
    #expect(await runner.startedIDs.isEmpty)

    await claims.allowClaims()
    let second = try await importer.submit(
        .webpage(URL(string: "https://fixture.invalid/contention-second")!)
    )
    try await runner.waitUntilStarted(first.taskID)
    #expect(await claims.callCount == 6)
    #expect(await runner.maximumConcurrentRuns == 1)
    await runner.release(first.taskID)
    try await runner.waitUntilStarted(second.id)
    await runner.release(second.id)
}

@Test(.timeLimit(.minutes(1)))
func removedLibraryRootDoesNotLeaveAClaimRetryLoop() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/root-removal")!)
    )
    let runner = DeterministicRunnerGate()
    let claims = RootRemovalClaimProbe(library: library)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    try await importer.start()
    try await runner.waitUntilStarted(workspace.taskID)
    await runner.release(workspace.taskID)
    try await runner.waitUntilStopped(workspace.taskID)
    removeTemporaryDocumentImportRoot(root)
    await claims.releaseSecondClaim()
    try await claims.verifyCallCountRemains(1, for: .milliseconds(300))
    #expect(await claims.callCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func emptyPostRunSchedulerDoesNotCompeteWithReopenedAcceptance() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let firstLibrary = try await LocalLibrary.open(at: libraryRoot)
    let secondLibrary = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await firstLibrary.accept(
        .webpage(URL(string: "https://fixture.invalid/first-owner")!)
    )
    let runner = DeterministicRunnerGate()
    let claims = RootRemovalClaimProbe(library: firstLibrary)
    let importer = DocumentImport(
        library: firstLibrary,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    try await importer.start()
    try await runner.waitUntilStarted(workspace.taskID)
    await runner.release(workspace.taskID)
    try await runner.waitUntilStopped(workspace.taskID)
    let second = try await secondLibrary.accept(
        .webpage(URL(string: "https://fixture.invalid/second-owner")!)
    )
    await claims.releaseSecondClaim()
    try await claims.verifyCallCountRemains(1, for: .milliseconds(300))
    #expect(try await second.snapshot().state == .queued)
}

@Test(.timeLimit(.minutes(1)))
func droppedAndRecreatedStreamsDoNotOwnRunnerAndStartAuthoritatively() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let first = try await harness.importer.submit(.webpage(harness.url("/stream-1")))
    let second = try await harness.importer.submit(.webpage(harness.url("/stream-2")))
    try await harness.runner.waitUntilStarted(first.id)

    do {
        var iterator = harness.importer.observeTasks(.all).makeAsyncIterator()
        let snapshots = try #require(await iterator.next())
        #expect(snapshots.map(\.id) == [first.id, second.id])
    }
    #expect(await harness.runner.isStillRunning(first.id))
    var recreated = harness.importer.observeTasks(.all).makeAsyncIterator()
    let authoritative = try #require(await recreated.next())
    #expect(authoritative.map(\.id) == [first.id, second.id])

    _ = first.updates()
    await harness.runner.release(first.id)
    try await harness.runner.waitUntilStarted(second.id)
    await harness.runner.release(second.id)
}

@Test(.timeLimit(.minutes(1)))
func startIsEagerConcurrentAndIdempotent() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let probe = BootstrapLoadProbe(library: library)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await probe.load() },
        importRunner: { _ in }
    )

    try await probe.waitForCallCount(1)
    async let first: Void = importer.start()
    async let second: Void = importer.start()
    _ = try await (first, second)
    try await importer.start()
    #expect(await probe.callCount == 1)
}

@Test(.timeLimit(.minutes(1)))
func failedBootstrapCanRetryWithoutAcceptingOnImplicitSubmit() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let probe = BootstrapLoadProbe(library: library, failures: 1)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await probe.load() },
        importRunner: { _ in }
    )

    do {
        _ = try await importer.submit(
            .webpage(URL(string: "https://fixture.invalid/rejected")!)
        )
        Issue.record("Expected implicit bootstrap failure")
    } catch let error as ImportSubmissionError {
        #expect(error == .localLibraryUnavailable)
    }
    #expect(try await library.retainedImports().isEmpty)

    try await importer.start()
    try await importer.start()
    #expect(await probe.callCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func explicitStartMapsFailureAndRetriesTheSameScheduler() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let probe = BootstrapLoadProbe(library: library, failures: 1)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await probe.load() },
        importRunner: { _ in }
    )

    do {
        try await importer.start()
        Issue.record("Expected availability failure")
    } catch let error as DocumentImportAvailabilityError {
        #expect(error == .localLibraryUnavailable)
    }
    try await importer.start()
    try await importer.start()
    #expect(await probe.callCount == 2)
}

@Test(.timeLimit(.minutes(1)))
func observationBeforeBootstrapWaitsForAuthoritativeHydration() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let accepted = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/retained")!)
    )
    let loader = SuspendedBootstrapLoader(library: library)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await loader.load() },
        importRunner: { _ in }
    )
    let probe = TaskListEmissionProbe()
    let stream = importer.observeTasks(.all)
    let observation = Task {
        for await snapshots in stream {
            await probe.record(snapshots)
        }
    }

    try await Task.sleep(for: .milliseconds(25))
    #expect(await probe.emissions.isEmpty)
    await loader.release()
    try await probe.waitForEmissionCount(1)
    let first = try #require(await probe.emissions.first)
    #expect(first.map(\.id) == [accepted.taskID])
    observation.cancel()
}

@Test(.timeLimit(.minutes(1)))
func observerSurvivesFailedBootstrapAndReceivesRetryHydration() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let accepted = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/bootstrap-retry")!)
    )
    let bootstrap = BootstrapLoadProbe(library: library, failures: 1)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await bootstrap.load() },
        importRunner: { _ in },
        claimNextRunnable: { throw LocalLibraryError.unavailable }
    )
    let emissions = TaskListEmissionProbe()
    let stream = importer.observeTasks(.all)
    let observation = Task {
        for await snapshots in stream {
            await emissions.record(snapshots)
        }
    }

    do {
        try await importer.start()
        Issue.record("Expected first bootstrap generation to fail")
    } catch let error as DocumentImportAvailabilityError {
        #expect(error == .localLibraryUnavailable)
    }
    try await emissions.verifyEmissionCountRemains(0, for: .milliseconds(50))

    try await importer.start()
    try await emissions.waitForEmissionCount(1)
    let first = try #require(await emissions.emissions.first)
    #expect(first.map(\.id) == [accepted.taskID])
    #expect(!first.isEmpty)
    observation.cancel()
}

@Test(.timeLimit(.minutes(1)))
func concurrentStartsShareOneSuspendedBootstrapGeneration() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/concurrent-start")!)
    )
    let loader = SuspendedBootstrapLoader(library: library)
    let claims = CountingClaimProbe(library: library)
    let runner = DeterministicRunnerGate()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await loader.load() },
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { try await claims.claim() }
    )

    try await loader.waitUntilCalled()
    async let first: Void = importer.start()
    async let second: Void = importer.start()
    async let third: Void = importer.start()
    await loader.release()
    _ = try await (first, second, third)

    try await runner.waitUntilStarted(workspace.taskID)
    #expect(await loader.callCount == 1)
    #expect(await claims.callCount == 1)
    #expect(await runner.startedIDs == [workspace.taskID])
    await runner.release(workspace.taskID)
}

@Test(.timeLimit(.minutes(1)))
func recreatedCompletedHistoryPreservesOutcomeIssuesAndSourceSummary() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let firstPDF = root.appending(path: "first.pdf")
    let secondPDF = root.appending(path: "second.pdf")
    try FileManager.default.copyItem(at: FixtureCatalog.minimalPDFURL, to: firstPDF)
    try FileManager.default.copyItem(at: FixtureCatalog.minimalPDFURL, to: secondPDF)

    let block = SourceBlock(id: SourceBlockID(), canonicalText: "Recovered")
    let issue = KnowledgeCore.ImportIssue(
        code: .optionalWebImageUnavailable,
        relatedBlockID: block.id
    )
    let firstDocumentID = SourceDocumentID()
    let firstContent = SourceDocumentContent(
        documentID: firstDocumentID,
        importedMetadata: ImportedDocumentMetadata(title: "Recovered", author: nil),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [block.id: .web(locator: "article > p")],
        issues: [issue]
    )
    let first = try await library.accept(.pdfFile(firstPDF))
    let firstAccepted = try await first.snapshot()
    let firstOutcome = try await first.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("recovered-completed-history"),
            artifact: try #require(firstAccepted.stagedArtifact),
            document: firstContent,
            originalSource: .pdfFile(firstPDF)
        ),
        expectedRevision: firstAccepted.revision
    )
    #expect(firstOutcome == .published(documentID: firstDocumentID))

    let second = try await library.accept(.pdfFile(secondPDF))
    let secondAccepted = try await second.snapshot()
    let secondOutcome = try await second.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("recovered-completed-history"),
            artifact: try #require(secondAccepted.stagedArtifact),
            document: SourceDocumentContent(
                documentID: SourceDocumentID(),
                importedMetadata: firstContent.importedMetadata,
                blocks: firstContent.blocks,
                structure: firstContent.structure,
                evidence: firstContent.evidence,
                issues: []
            ),
            originalSource: .pdfFile(secondPDF)
        ),
        expectedRevision: secondAccepted.revision
    )

    let recreatedLibrary = try await LocalLibrary.open(at: libraryRoot)
    let importer = DocumentImport(
        library: recreatedLibrary,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { _ in }
    )
    var iterator = importer.observeTasks(.all).makeAsyncIterator()
    let history = try #require(await iterator.next())
    #expect(history.map(\.source) == [
        .pdfFile(name: "first.pdf"),
        .pdfFile(name: "second.pdf"),
    ])
    #expect(history[0].state == .completed(.published(
        documentID: firstDocumentID,
        issues: [issue]
    )))
    guard case .alreadyImported(
        let duplicateID,
        let location,
        let provenanceAdded
    ) = secondOutcome else {
        Issue.record("Expected durable duplicate outcome")
        return
    }
    #expect(history[1].state == .completed(.alreadyImported(
        documentID: duplicateID,
        location: location,
        provenanceAdded: provenanceAdded
    )))
}

@Test
func snapshotRegistryRejectsConflictingSameRevisionAndIgnoresStaleUpdates() throws {
    let taskID = ImportTaskID()
    let source = OriginalSourceSummary.webpage(
        URL(string: "https://fixture.invalid/registry")!
    )
    let initial = ImportTaskSnapshot(
        id: taskID,
        revision: 4,
        attempt: 1,
        source: source,
        state: .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([])
    let durable = DurableImportSnapshot(
        taskID: taskID,
        journalSequence: 9,
        originalSource: .webpage(URL(string: "https://fixture.invalid/registry")!),
        queueSequence: nil,
        attempt: 1,
        revision: 4,
        state: .running,
        failure: nil,
        checkpoint: nil,
        checkpointArtifact: nil,
        stagedArtifact: nil,
        outcome: nil
    )
    _ = try registry.apply([durable])
    #expect(try registry.apply(initial, journalSequence: 9) == false)

    let stale = ImportTaskSnapshot(
        id: taskID,
        revision: 3,
        attempt: 1,
        source: source,
        state: .queued(position: 1)
    )
    #expect(try registry.apply(stale, journalSequence: 9) == false)

    let conflict = ImportTaskSnapshot(
        id: taskID,
        revision: 4,
        attempt: 1,
        source: source,
        state: .cancelling
    )
    #expect(throws: TaskSnapshotRegistry.RegistryError.self) {
        try registry.apply(conflict, journalSequence: 9)
    }
}

@Test
func staleBatchItemCannotInfluenceAcceptedQueuePositions() throws {
    let first = ImportTaskID()
    let second = ImportTaskID()
    let third = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(first, journal: 1, queue: 1, revision: 2),
        durableSnapshot(second, journal: 2, queue: 2, revision: 1),
        durableSnapshot(third, journal: 3, queue: 3, revision: 1),
    ])

    _ = try registry.apply([
        durableSnapshot(first, journal: 1, queue: 100, revision: 1),
        durableSnapshot(
            second,
            journal: 2,
            queue: nil,
            revision: 2,
            state: .running
        ),
        durableSnapshot(third, journal: 3, queue: 3, revision: 2),
    ])

    #expect(registry.snapshot(for: first)?.state == .queued(position: 1))
    #expect(registry.snapshot(for: second)?.state == .running(ImportProgress(
        activity: .acquiringOriginalSource,
        completedUnitCount: 0,
        totalUnitCount: nil
    )))
    #expect(registry.snapshot(for: third)?.state == .queued(position: 2))
}

@Test(.timeLimit(.minutes(1)))
func conflictingLaterBatchItemRollsBackEarlierUpdateAndEmitsNothing() async throws {
    let first = ImportTaskID()
    let second = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(first, journal: 1, queue: 1, revision: 1),
        durableSnapshot(second, journal: 2, queue: 2, revision: 1),
    ])
    let before = registry.snapshots(matching: .all)
    let taskProbe = TaskSnapshotEmissionProbe()
    let listProbe = TaskListEmissionProbe()
    let taskPair = AsyncStream<ImportTaskSnapshot>.makeStream()
    let listPair = AsyncStream<[ImportTaskSnapshot]>.makeStream()
    registry.registerTaskObserver(
        id: UUID(),
        taskID: first,
        continuation: taskPair.continuation
    )
    registry.registerListObserver(
        id: UUID(),
        query: .all,
        continuation: listPair.continuation
    )
    let taskObservation = Task {
        for await snapshot in taskPair.stream { await taskProbe.record(snapshot) }
    }
    let listObservation = Task {
        for await snapshots in listPair.stream { await listProbe.record(snapshots) }
    }
    try await taskProbe.waitForEmissionCount(1)
    try await listProbe.waitForEmissionCount(1)

    #expect(throws: TaskSnapshotRegistry.RegistryError.self) {
        try registry.apply([
            durableSnapshot(
                first,
                journal: 1,
                queue: nil,
                revision: 2,
                state: .running
            ),
            durableSnapshot(
                second,
                journal: 2,
                queue: nil,
                revision: 1,
                state: .running
            ),
        ])
    }

    #expect(registry.snapshots(matching: .all) == before)
    try await taskProbe.verifyEmissionCountRemains(1, for: .milliseconds(50))
    try await listProbe.verifyEmissionCountRemains(1, for: .milliseconds(50))
    taskObservation.cancel()
    listObservation.cancel()
}

@Test
func unorderedNewSnapshotsDerivePositionsAfterStaleFiltering() throws {
    let first = ImportTaskID()
    let second = ImportTaskID()
    let third = ImportTaskID()
    let fourth = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(first, journal: 1, queue: 1, revision: 2),
    ])

    _ = try registry.apply([
        durableSnapshot(fourth, journal: 4, queue: 4, revision: 0),
        durableSnapshot(first, journal: 1, queue: 5, revision: 1),
        durableSnapshot(third, journal: 3, queue: 3, revision: 0),
        durableSnapshot(second, journal: 2, queue: 2, revision: 0),
    ])

    #expect(registry.snapshots(matching: .all).map { snapshot in
        switch snapshot.state {
        case .queued(let position): return (snapshot.id, position)
        default: return (snapshot.id, 0)
        }
    }.map { "\($0.0.rawValue.uuidString):\($0.1)" } == [
        "\(first.rawValue.uuidString):1",
        "\(second.rawValue.uuidString):2",
        "\(third.rawValue.uuidString):3",
        "\(fourth.rawValue.uuidString):4",
    ])
}

@Test
func taskQueriesUseExactStateBucketsAndStableOrdering() throws {
    let cancelling = ImportTaskID()
    let running = ImportTaskID()
    let firstQueued = ImportTaskID()
    let secondQueued = ImportTaskID()
    let failed = ImportTaskID()
    let cancelled = ImportTaskID()
    let completed = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(
            completed,
            journal: 7,
            queue: nil,
            revision: 1,
            state: .completed,
            outcome: .published(documentID: SourceDocumentID()),
            publicationIssues: []
        ),
        durableSnapshot(
            secondQueued,
            journal: 6,
            queue: 20,
            revision: 1
        ),
        durableSnapshot(
            cancelling,
            journal: 2,
            queue: nil,
            revision: 1,
            state: .cancelling
        ),
        durableSnapshot(
            cancelled,
            journal: 4,
            queue: nil,
            revision: 1,
            state: .cancelled
        ),
        durableSnapshot(
            firstQueued,
            journal: 1,
            queue: 10,
            revision: 1
        ),
        durableSnapshot(
            running,
            journal: 5,
            queue: nil,
            revision: 1,
            state: .running
        ),
        durableSnapshot(
            failed,
            journal: 3,
            queue: nil,
            revision: 1,
            state: .failed
        ),
    ])

    let active = [cancelling, running, firstQueued, secondQueued]
    #expect(registry.snapshots(matching: .active).map(\.id) == active)
    #expect(registry.snapshots(matching: .unfinished).map(\.id) ==
        active + [failed, cancelled]
    )
    #expect(registry.snapshots(matching: .all).map(\.id) ==
        active + [failed, cancelled, completed]
    )
}

@Test(.timeLimit(.minutes(1)))
func authoritativeReconciliationRepairsSameRevisionProjectionAtomically() async throws {
    let first = ImportTaskID()
    let second = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(first, journal: 1, queue: 1, revision: 1),
        durableSnapshot(second, journal: 2, queue: 2, revision: 1),
    ])
    let taskProbe = TaskSnapshotEmissionProbe()
    let listProbe = TaskListEmissionProbe()
    let taskPair = AsyncStream<ImportTaskSnapshot>.makeStream()
    let listPair = AsyncStream<[ImportTaskSnapshot]>.makeStream()
    registry.registerTaskObserver(
        id: UUID(),
        taskID: first,
        continuation: taskPair.continuation
    )
    registry.registerListObserver(
        id: UUID(),
        query: .all,
        continuation: listPair.continuation
    )
    let taskObservation = Task {
        for await snapshot in taskPair.stream { await taskProbe.record(snapshot) }
    }
    let listObservation = Task {
        for await snapshots in listPair.stream { await listProbe.record(snapshots) }
    }
    try await taskProbe.waitForEmissionCount(1)
    try await listProbe.waitForEmissionCount(1)

    let result = try registry.reconcileAuthoritative([
        durableSnapshot(
            first,
            journal: 1,
            queue: nil,
            revision: 1,
            state: .running
        ),
        durableSnapshot(second, journal: 2, queue: 2, revision: 1),
    ])

    #expect(result.changedTaskIDs == [first, second])
    try await taskProbe.waitForEmissionCount(2)
    try await listProbe.waitForEmissionCount(2)
    #expect(await taskProbe.emissions.last?.state == .running(ImportProgress(
        activity: .acquiringOriginalSource,
        completedUnitCount: 0,
        totalUnitCount: nil
    )))
    let corrected = try #require(await listProbe.emissions.last)
    #expect(corrected.map(\.id) == [first, second])
    #expect(corrected.map(\.state) == [
        .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        )),
        .queued(position: 1),
    ])
    try await taskProbe.verifyEmissionCountRemains(2, for: .milliseconds(50))
    try await listProbe.verifyEmissionCountRemains(2, for: .milliseconds(50))
    taskObservation.cancel()
    listObservation.cancel()
}

@Test
func authoritativeReconciliationPreservesStrictlyNewerProjection() throws {
    let taskID = ImportTaskID()
    var registry = TaskSnapshotRegistry()
    try registry.hydrate([
        durableSnapshot(
            taskID,
            journal: 1,
            queue: nil,
            revision: 3,
            state: .running,
            attempt: 2
        ),
    ])

    let result = try registry.reconcileAuthoritative([
        durableSnapshot(
            taskID,
            journal: 1,
            queue: 1,
            revision: 99,
            attempt: 1
        ),
    ])

    #expect(result.changedTaskIDs.isEmpty)
    #expect(registry.snapshot(for: taskID)?.attempt == 2)
    #expect(registry.snapshot(for: taskID)?.revision == 3)
    #expect(registry.snapshot(for: taskID)?.state == .running(ImportProgress(
        activity: .acquiringOriginalSource,
        completedUnitCount: 0,
        totalUnitCount: nil
    )))
}

@Test(.timeLimit(.minutes(1)))
func staleClaimProjectionNeverLaunchesRunner() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/stale-claim")!)
    )
    let accepted = try await workspace.snapshot()
    let staleClaim = DurableQueueClaim(
        claimed: durableSnapshot(
            workspace.taskID,
            journal: accepted.journalSequence,
            queue: nil,
            revision: accepted.revision,
            state: .running
        ),
        queueUpdates: [],
        previousQueueSequence: try #require(accepted.queueSequence)
    )
    let claims = OneShotClaimProbe(staleClaim)
    let runner = DeterministicRunnerGate()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        claimNextRunnable: { await claims.claim() }
    )

    try await importer.start()
    try await claims.waitUntilCalled()
    try await Task.sleep(for: .milliseconds(25))
    #expect(await runner.startedIDs.isEmpty)
    #expect(try await workspace.snapshot().state == .queued)
}

enum WorkspaceLookupFailureCase: CaseIterable, Sendable {
    case nilResult
    case thrownError
}

@Test(.timeLimit(.minutes(1)), arguments: WorkspaceLookupFailureCase.allCases)
func workspaceLookupFailureRollsBackClaimBeforeRunnerLaunch(
    failureCase: WorkspaceLookupFailureCase
) async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let first = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/workspace-1")!)
    )
    let second = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/workspace-2")!)
    )
    let runner = DeterministicRunnerGate()
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { try await runner.run($0) },
        importWorkspaceLoader: { _ in
            switch failureCase {
            case .nilResult:
                return nil
            case .thrownError:
                throw DurableQueueTestError.injectedBootstrapFailure
            }
        }
    )

    try await importer.start()
    let rolledBack = try await waitUntilDurableState(
        .queued,
        taskID: first.taskID,
        library: library,
        minimumRevision: 2
    )
    #expect(rolledBack.queueSequence == 1)
    #expect(rolledBack.revision == 2)
    #expect(await runner.startedIDs.isEmpty)
    let retained = try await library.retainedImports()
    #expect(retained.map(\.taskID) == [first.taskID, second.taskID])
    #expect(retained.map(\.revision) == [2, 2])
}

@Test(.timeLimit(.minutes(1)))
func concurrentSubmitReturnInversionStillPublishesCompleteDurableFIFO() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let acceptances = ControlledAcceptanceProbe(library: library)
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        importRunner: { _ in },
        claimNextRunnable: { throw LocalLibraryError.unavailable },
        acceptanceLoader: { try await acceptances.accept($0) }
    )
    var lists = importer.observeTasks(.all).makeAsyncIterator()
    #expect(try #require(await lists.next()).isEmpty)

    async let firstHandle = importer.submit(
        .webpage(URL(string: "https://fixture.invalid/inverted-first")!)
    )
    try await acceptances.waitUntilFirstCommitted()
    let secondHandle = try await importer.submit(
        .webpage(URL(string: "https://fixture.invalid/inverted-second")!)
    )
    let committed = await acceptances.committedTaskIDs
    #expect(committed.count == 2)
    let authoritative = try #require(await lists.next())
    #expect(authoritative.map(\.id) == committed)
    #expect(authoritative.map(\.state) == [
        .queued(position: 1),
        .queued(position: 2),
    ])
    #expect(secondHandle.id == committed[1])
    #expect(try await latestSnapshot(secondHandle).state == .queued(position: 2))

    await acceptances.releaseFirst()
    let first = try await firstHandle
    #expect(first.id == committed[0])
    #expect(try await latestSnapshot(first).state == .queued(position: 1))
    #expect(try await library.retainedImports().map(\.taskID) == committed)
}

@Test(.timeLimit(.minutes(1)))
func postAcceptConflictUsesTransactionalBatchWithoutReload() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/transactional-batch")!)
    )
    let accepted = try #require(try await library.retainedImports().first)
    let conflicting = durableSnapshot(
        workspace.taskID,
        journal: accepted.journalSequence,
        queue: nil,
        revision: accepted.revision,
        state: .running
    )
    let retained = SelectiveRetainedImportsLoader(
        library: library,
        failingCalls: [2],
        successfulSnapshots: [conflicting]
    )
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        retainedImportsLoader: { try await retained.load() },
        importRunner: { _ in },
        claimNextRunnable: { throw LocalLibraryError.unavailable },
        acceptanceLoader: { _ in
            return DurableImportAcceptance(
                workspace: workspace,
                snapshots: [accepted]
            )
        }
    )
    try await importer.start()
    let taskProbe = TaskSnapshotEmissionProbe()
    let listProbe = TaskListEmissionProbe()
    let taskObservation = Task {
        for await snapshot in importer.updates(for: workspace.taskID) {
            await taskProbe.record(snapshot)
        }
    }
    let listObservation = Task {
        for await snapshots in importer.observeTasks(.all) {
            await listProbe.record(snapshots)
        }
    }
    try await taskProbe.waitForEmissionCount(1)
    try await listProbe.waitForEmissionCount(1)
    #expect(await taskProbe.emissions.first?.state == .running(ImportProgress(
        activity: .acquiringOriginalSource,
        completedUnitCount: 0,
        totalUnitCount: nil
    )))

    let handle = try await importer.submit(
        .webpage(URL(string: "https://fixture.invalid/transactional-batch")!)
    )
    #expect(handle.id == workspace.taskID)
    #expect(try await latestSnapshot(handle).state == .queued(position: 1))
    try await taskProbe.waitForEmissionCount(2)
    try await listProbe.waitForEmissionCount(2)
    #expect(await taskProbe.emissions.last?.state == .queued(position: 1))
    #expect(await listProbe.emissions.last?.map(\.state) == [
        .queued(position: 1),
    ])
    try await taskProbe.verifyEmissionCountRemains(2, for: .milliseconds(50))
    try await listProbe.verifyEmissionCountRemains(2, for: .milliseconds(50))
    #expect(await retained.callCount == 1)
    #expect(try await library.retainedImports().count == 1)
    taskObservation.cancel()
    listObservation.cancel()
}

private func durableSnapshot(
    _ taskID: ImportTaskID,
    journal: UInt64,
    queue: UInt64?,
    revision: UInt64,
    state: KnowledgeCore.ImportTaskState = .queued,
    attempt: UInt = 1,
    outcome: PublicationOutcome? = nil,
    publicationIssues: [KnowledgeCore.ImportIssue]? = nil
) -> DurableImportSnapshot {
    DurableImportSnapshot(
        taskID: taskID,
        journalSequence: journal,
        originalSource: .webpage(
            URL(string: "https://fixture.invalid/\(journal)")!
        ),
        queueSequence: queue,
        attempt: attempt,
        revision: revision,
        state: state,
        failure: nil,
        checkpoint: nil,
        checkpointArtifact: nil,
        stagedArtifact: nil,
        outcome: outcome,
        publicationIssues: publicationIssues
    )
}
