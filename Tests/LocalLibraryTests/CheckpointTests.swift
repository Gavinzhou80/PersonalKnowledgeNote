import Foundation
import KnowledgeCore
import TestFixtures
import Testing
@testable import LocalLibrary

@Test
func checkpointSurvivesReopenAndAdvancesRevision() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let envelope = CheckpointEnvelope(
        codecVersion: 1,
        payload: Data("artifact-ready".utf8)
    )

    let accepted = try await checkpointInReleasedScope(
        envelope,
        at: root
    )

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: accepted.taskID)
    )
    let snapshot = try await recovered.snapshot()

    #expect(snapshot.revision == accepted.initialRevision + 1)
    #expect(snapshot.checkpoint == envelope)
    #expect(snapshot.state == .working)
    do {
        _ = try await recovered.checkpoint(
            CheckpointUpdate(
                expectedRevision: snapshot.revision,
                ordinal: 1,
                envelope: envelope
            )
        )
        Issue.record("Expected reopened checkpoint ordinal to be preserved")
    } catch let error as LocalLibraryError {
        #expect(error == .checkpointRegression)
    }
}

@Test
func staleRevisionAndCheckpointRegressionAreRejected() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/revisions")))
    )
    let initial = try await workspace.snapshot()
    let envelope = CheckpointEnvelope(
        codecVersion: 1,
        payload: Data("revision-check".utf8)
    )
    let first = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 2,
            envelope: envelope
        )
    )

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: first.revision,
                ordinal: 1,
                envelope: envelope
            )
        )
        Issue.record("Expected checkpoint ordinal regression to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .checkpointRegression)
    }

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 3,
                envelope: envelope
            )
        )
        Issue.record("Expected stale revision to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .staleRevision(current: first.revision))
    }
}

@Test
func checkpointPayloadLimitAcceptsBoundaryAndRejectsOneByteOver() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/payload-limit")))
    )
    let initial = try await workspace.snapshot()
    let maximumPayload = Data(repeating: 0x41, count: 1_048_576)
    let accepted = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(
                codecVersion: 7,
                payload: maximumPayload
            )
        )
    )

    #expect(accepted.checkpoint?.payload == maximumPayload)

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: accepted.revision,
                ordinal: 2,
                envelope: CheckpointEnvelope(
                    codecVersion: 8,
                    payload: Data(repeating: 0x42, count: 1_048_577)
                )
            )
        )
        Issue.record("Expected oversized checkpoint payload to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .invalidTaskState)
    }
}

@Test
func abandonIsDurableAndIdempotent() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let abandoned = try await abandonInReleasedScope(at: root)

    let reopened = try await LocalLibrary.open(at: root)
    let snapshot = try await reopened.snapshot(taskID: abandoned.taskID)
    #expect(snapshot.state == .abandoned)
    #expect(snapshot.revision == abandoned.initialRevision + 1)

    let reopenedWorkspace = ImportWorkspace(
        taskID: abandoned.taskID,
        library: reopened
    )
    try await reopenedWorkspace.abandon(
        expectedRevision: abandoned.initialRevision
    )
    let idempotentSnapshot = try await reopenedWorkspace.snapshot()

    #expect(idempotentSnapshot.state == .abandoned)
    #expect(idempotentSnapshot.revision == snapshot.revision)
}

@Test
func abandonRejectsStaleRevision() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/abandon-stale")))
    )
    let initial = try await workspace.snapshot()
    let checkpointed = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("working".utf8)
            )
        )
    )

    do {
        try await workspace.abandon(expectedRevision: initial.revision)
        Issue.record("Expected stale abandon revision to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .staleRevision(current: checkpointed.revision))
    }
}

@Test
func checkpointRejectsAbandonedTask() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/checkpoint-abandoned")))
    )
    let initial = try await workspace.snapshot()
    try await workspace.abandon(expectedRevision: initial.revision)
    let abandoned = try await workspace.snapshot()

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: abandoned.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(
                    codecVersion: 1,
                    payload: Data("too-late".utf8)
                )
            )
        )
        Issue.record("Expected abandoned task checkpoint to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .invalidTaskState)
    }
}

@Test
func abandonRemovesStagedWebAndPDFArtifacts() async throws {
    try await verifyAbandonRemovesStagedWebArtifact()
    try await verifyAbandonRemovesStagedPDFArtifact()
}

@Test
func reopeningCleansArtifactsFromCommittedAbandon() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let staged = try await stageWebArtifactInReleasedScope(at: root)
    let database = try LibraryDatabase(
        url: root.appending(path: "Library/library.sqlite")
    )

    _ = try database.abandon(
        taskID: staged.taskID,
        expectedRevision: staged.revision
    )

    let reopened = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let workspace = ImportWorkspace(
        taskID: staged.taskID,
        library: reopened
    )
    let snapshot = try await workspace.snapshot()

    #expect(snapshot.state == .abandoned)
    #expect(snapshot.stagedArtifact == staged.artifact)
    #expect(try await workspace.stagedArtifactCount() == 0)
    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.verifyManagedArtifact(staged.artifact)
    }
}

private struct CheckpointAcceptance: Sendable {
    let taskID: ImportTaskID
    let initialRevision: UInt64
}

private struct AbandonedAcceptance: Sendable {
    let taskID: ImportTaskID
    let initialRevision: UInt64
}

private struct StagedAcceptance: Sendable {
    let taskID: ImportTaskID
    let revision: UInt64
    let artifact: StagedArtifact
}

@inline(never)
private func checkpointInReleasedScope(
    _ envelope: CheckpointEnvelope,
    at root: URL
) async throws -> CheckpointAcceptance {
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/checkpoint")))
    )
    let initial = try await workspace.snapshot()
    let updated = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 1,
            envelope: envelope
        )
    )

    #expect(updated.revision == initial.revision + 1)

    return CheckpointAcceptance(
        taskID: workspace.taskID,
        initialRevision: initial.revision
    )
}

@inline(never)
private func abandonInReleasedScope(
    at root: URL
) async throws -> AbandonedAcceptance {
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/abandon")))
    )
    let initial = try await workspace.snapshot()

    try await workspace.abandon(expectedRevision: initial.revision)

    return AbandonedAcceptance(
        taskID: workspace.taskID,
        initialRevision: initial.revision
    )
}

private func verifyAbandonRemovesStagedWebArtifact() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "WebPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("web artifact".utf8).write(
        to: package.appending(path: "index.html")
    )
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/abandon-web")))
    )
    let initial = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "caller-supplied"
            )
        ),
        expectedRevision: initial.revision
    )

    try await assertAbandonRemovesPhysicalArtifact(
        workspace: workspace,
        artifact: artifact
    )
}

private func verifyAbandonRemovesStagedPDFArtifact() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let externalPDF = temporaryRoot.appending(path: "external.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )
    let workspace = try await library.accept(.pdfFile(externalPDF))
    let artifact = try #require(
        try await workspace.snapshot().stagedArtifact
    )

    try await assertAbandonRemovesPhysicalArtifact(
        workspace: workspace,
        artifact: artifact
    )
}

private func assertAbandonRemovesPhysicalArtifact(
    workspace: ImportWorkspace,
    artifact: StagedArtifact
) async throws {
    let beforeAbandon = try await workspace.snapshot()
    #expect(try await workspace.stagedArtifactCount() == 1)

    try await workspace.abandon(
        expectedRevision: beforeAbandon.revision
    )

    let abandoned = try await workspace.snapshot()
    #expect(abandoned.state == .abandoned)
    #expect(abandoned.stagedArtifact == artifact)
    #expect(try await workspace.stagedArtifactCount() == 0)
    do {
        _ = try await workspace.verifyManagedArtifact(artifact)
        Issue.record("Expected abandoned staged artifact to be missing")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactMissing)
    }
}

@inline(never)
private func stageWebArtifactInReleasedScope(
    at root: URL
) async throws -> StagedAcceptance {
    let package = root.appending(path: "CleanupPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("startup cleanup".utf8).write(
        to: package.appending(path: "index.html")
    )
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/startup-cleanup")))
    )
    let initial = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "caller-supplied"
            )
        ),
        expectedRevision: initial.revision
    )
    let staged = try await workspace.snapshot()
    #expect(try await workspace.stagedArtifactCount() == 1)

    return StagedAcceptance(
        taskID: workspace.taskID,
        revision: staged.revision,
        artifact: artifact
    )
}
