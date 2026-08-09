import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

@Test(arguments: T05CrashPoint.allCases)
func restartRecoversEachDurableImportBoundary(
    _ point: T05CrashPoint
) async throws {
    let harness = try await RecoveryHarness.make(crashPoint: point)
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let taskID = try await harness.runUntilInjectedTermination()

    let reopened = try await harness.reopen()
    let handle = try #require(
        try await reopened.importer.task(id: taskID)
    )
    let terminal = await handle.value()

    #expect(terminal.isExpectedFor(point))
    #expect(reopened.visibleDocumentCount <= 1)
    #expect(try await reopened.checkpointArtifactCount(taskID) == 0)
    #expect(reopened.unownedStagingCount == 0)
}

@Test
func twoImportersCannotRunTheSameDurableTask() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let accepted = try await library.accept(
        .webpage(URL(string: "https://fixture.invalid/exclusive")!)
    )
    let taskID = accepted.taskID
    let gate = DeterministicRunnerGate()

    func makeImporter() -> DocumentImport {
        DocumentImport(
            library: library,
            webAcquirer: ThrowingWebAcquirer(),
            importRunner: { workspace in
                try await gate.run(workspace)
            }
        )
    }
    let first = makeImporter()
    let second = makeImporter()
    try await first.start()
    try await second.start()

    try await gate.waitUntilStarted(taskID)
    #expect(await gate.maximumConcurrentRuns == 1)
    await gate.release(taskID)
    try await gate.waitUntilStopped(taskID)

    try await Task.sleep(for: .milliseconds(50))
    #expect(await gate.startedIDs == [taskID])
    #expect(await gate.maximumConcurrentRuns == 1)
}

@Test
func restartAfterAcquisitionReusesPersistedPageWithoutNetwork() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterAcquiredCheckpoint
    )
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.firstImporter.submit(
        .webpage(harness.articleURL)
    )
    try await harness.crashInjector.waitForInjectedTermination()
    #expect(await harness.acquirer.callCount == 1)

    let reopened = try await harness.reopenImporter(
        acquirer: .failingIfCalled
    )
    let recovered = try #require(try await reopened.task(id: handle.id))
    #expect(await recovered.value().isSuccess)
    #expect(await harness.acquirer.callCount == 1)
}

@Test
func restartAfterPreparedCheckpointPublishesWithoutRebuilding() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterPreparedCheckpoint
    )
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.firstImporter.submit(
        .webpage(harness.articleURL)
    )
    try await harness.crashInjector.waitForInjectedTermination()
    #expect(await harness.builder.callCount == 1)

    let reopened = try await harness.reopenImporter(
        builder: .failingIfCalled
    )
    let recovered = try #require(try await reopened.task(id: handle.id))
    #expect(await recovered.value().isSuccess)
    #expect(await harness.builder.callCount == 1)
}

@Test
func restartAfterAcceptanceCompletesFromScratch() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterAcceptance
    )
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.firstImporter.submit(
        .webpage(harness.articleURL)
    )
    try await harness.crashInjector.waitForInjectedTermination()
    #expect(await harness.acquirer.callCount == 0)

    let reopened = try await harness.reopenImporter()
    let recovered = try #require(try await reopened.task(id: handle.id))
    #expect(await recovered.value().isSuccess)
    #expect(await harness.acquirer.callCount == 0)
}

@Test
func restartWithCorruptAcquiredCheckpointFailsRetryably() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterAcquiredCheckpoint
    )
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.firstImporter.submit(
        .webpage(harness.articleURL)
    )
    try await harness.crashInjector.waitForInjectedTermination()

    try corruptManagedCheckpointPayload(under: harness.root)

    let reopened = try await harness.reopenImporter()
    let recovered = try #require(try await reopened.task(id: handle.id))
    let terminal = await recovered.value()
    guard case .failure(let failure) = terminal else {
        Issue.record("Expected retryable failure, got \(terminal)")
        return
    }
    #expect(failure.code == .checkpointInvalid)
    #expect(failure.recovery == .retryable)
}
