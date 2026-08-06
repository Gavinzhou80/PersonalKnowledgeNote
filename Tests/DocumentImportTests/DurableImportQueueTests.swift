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
