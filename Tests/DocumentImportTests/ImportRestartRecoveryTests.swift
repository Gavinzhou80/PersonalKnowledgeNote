import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

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
