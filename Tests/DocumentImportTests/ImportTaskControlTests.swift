import Foundation
import KnowledgeCore
import LocalLibrary
import Testing
@testable import DocumentImport

private struct AccessDeniedWebAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        throw WebAcquisitionError.accessDenied
    }
}

@Test
func cancelQueuedTaskTerminatesCancelled() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let blocker = try await harness.importer.submit(
        .webpage(harness.url("/blocker"))
    )
    try await harness.runner.waitUntilStarted(blocker.id)
    let queued = try await harness.importer.submit(
        .webpage(harness.url("/queued"))
    )
    #expect(try await currentQueuedPosition(queued) == 1)

    try await queued.cancel()

    #expect(await queued.value() == .cancelled)
    _ = try await waitUntilDurableState(
        .cancelled,
        taskID: queued.id,
        library: harness.library
    )
    #expect(await harness.runner.isStillRunning(blocker.id))
}

@Test
func cancelRunningTaskStopsRunnerAndTerminatesCancelled() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.importer.submit(
        .webpage(harness.url("/running"))
    )
    try await harness.runner.waitUntilStarted(handle.id)

    try await handle.cancel()

    #expect(await handle.value() == .cancelled)
    try await harness.runner.waitUntilStopped(handle.id)
    _ = try await waitUntilDurableState(
        .cancelled,
        taskID: handle.id,
        library: harness.library
    )
}

@Test
func repeatedCancellationDoesNotAdvanceRevision() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let blocker = try await harness.importer.submit(
        .webpage(harness.url("/blocker"))
    )
    try await harness.runner.waitUntilStarted(blocker.id)
    let handle = try await harness.importer.submit(
        .webpage(harness.url("/repeat-cancel"))
    )

    try await handle.cancel()
    _ = try await waitUntilDurableState(
        .cancelled,
        taskID: handle.id,
        library: harness.library
    )
    let firstCancellation = try await waitUntilDurableState(
        .cancelled,
        taskID: handle.id,
        library: harness.library
    )

    try await handle.cancel()

    let retained = try await harness.library.retainedImports()
    let durable = try #require(
        retained.first { $0.taskID == handle.id }
    )
    #expect(durable.state == .cancelled)
    #expect(durable.revision == firstCancellation.revision)
}

@Test
func cancelCompletedTaskThrowsTooLate() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: try CountingWebAcquirer()
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/completed-too-late")
    )
    let handle = try await documentImport.submit(.webpage(sourceURL))
    #expect(await handle.value().isSuccess)

    await #expect(throws: ImportTaskControlError.tooLate) {
        try await handle.cancel()
    }
}

@Test
func retryEntersQueueTailBehindEarlierRetriedWork() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let failedFirst = try await harness.submitRetryableFailure()
    let failedSecond = try await harness.submitRetryableFailure()
    let waiting = try await harness.importer.submit(
        .webpage(harness.url("/waiting"))
    )

    _ = try await waitUntilDurableState(
        .failed,
        taskID: failedFirst.id,
        library: harness.library
    )
    _ = try await waitUntilDurableState(
        .failed,
        taskID: failedSecond.id,
        library: harness.library
    )
    try await harness.runner.waitUntilStarted(waiting.id)

    try await failedFirst.retry()
    try await failedSecond.retry()

    let firstRetried = try await latestSnapshot(failedFirst)
    let secondRetried = try await latestSnapshot(failedSecond)
    #expect(firstRetried.id == failedFirst.id)
    #expect(firstRetried.attempt == 2)
    #expect(firstRetried.state == .queued(position: 1))
    #expect(secondRetried.id == failedSecond.id)
    #expect(secondRetried.attempt == 2)
    #expect(secondRetried.state == .queued(position: 2))
}

@Test
func valueWaiterRemainsBoundToAttemptThatRegisteredIt() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }
    let handle = try await harness.submitRetryableFailure(
        blockTerminalDelivery: true
    )
    let firstAttempt = Task { await handle.value() }
    await harness.releaseFailure()
    #expect(await firstAttempt.value.isRetryableFailure)

    try await handle.retry()

    let secondAttempt = await handle.value()
    #expect(secondAttempt.isRetryableFailure)
    let firstTerminal = await firstAttempt.value
    #expect(secondAttempt != firstTerminal)
    let retried = try await waitUntilDurableState(
        .failed,
        taskID: handle.id,
        library: harness.library,
        minimumRevision: 0
    )
    #expect(retried.attempt == 2)
}

@Test
func retryNonRetryableFailureThrowsRetryNotAllowed() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: AccessDeniedWebAcquirer()
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/access-denied")
    )
    let handle = try await documentImport.submit(.webpage(sourceURL))
    guard case .failure(let failure) = await handle.value() else {
        Issue.record("Expected access-denied failure")
        return
    }
    #expect(failure.recovery == .requiresUserAction)

    await #expect(throws: ImportTaskControlError.retryNotAllowed) {
        try await handle.retry()
    }
}

@Test
func taskLookupReturnsNilForUnknownID() async throws {
    let harness = try await DurableQueueHarness.make()
    defer { removeTemporaryDocumentImportRoot(harness.root) }

    let missing = try await harness.importer.task(id: ImportTaskID())
    #expect(missing == nil)
}
