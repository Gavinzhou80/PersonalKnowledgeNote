import Foundation
import KnowledgeCore

public actor ImportWorkspace {
    public nonisolated let taskID: ImportTaskID
    private let library: LocalLibrary

    package init(taskID: ImportTaskID, library: LocalLibrary) {
        self.taskID = taskID
        self.library = library
    }

    public func snapshot() async throws -> DurableImportSnapshot {
        try await library.snapshot(taskID: taskID)
    }

    public func stageArtifact(
        _ input: SourceArtifactInput,
        expectedRevision: UInt64
    ) async throws -> StagedArtifact {
        try await library.stageArtifact(
            input,
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    public func checkpoint(
        _ update: CheckpointUpdate
    ) async throws -> DurableImportSnapshot {
        try await library.checkpoint(taskID: taskID, update: update)
    }

    package func replaceCheckpointArtifact(
        packageURL: URL,
        update: CheckpointUpdate
    ) async throws -> CheckpointArtifactReplacement {
        try await library.replaceCheckpointArtifact(
            packageURL: packageURL,
            taskID: taskID,
            update: update
        )
    }

    package func loadCheckpointArtifact(
        _ artifact: ManagedCheckpointArtifact
    ) async throws -> VerifiedCheckpointPackage {
        try await library.loadCheckpointArtifact(
            artifact,
            taskID: taskID
        )
    }

    package func removeCheckpointArtifact(
        expectedRevision: UInt64
    ) async throws -> DurableImportSnapshot {
        try await library.removeCheckpointArtifact(
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    public func finish(
        _ candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) async throws -> PublicationOutcome {
        try await library.finish(
            taskID: taskID,
            candidate: candidate,
            expectedRevision: expectedRevision
        )
    }

    public func abandon(expectedRevision: UInt64) async throws {
        try await library.abandon(
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    package func recordFailure(
        expectedRevision: UInt64,
        failure: ImportTaskFailureEnvelope,
        retainCheckpoint: Bool
    ) async throws -> DurableQueueMutation {
        try await library.recordFailure(
            taskID: taskID,
            expectedRevision: expectedRevision,
            failure: failure,
            retainCheckpoint: retainCheckpoint
        )
    }

    package func finishCancellation(
        expectedRevision: UInt64
    ) async throws -> DurableImportSnapshot {
        try await library.finishCancellation(
            taskID: taskID,
            expectedRevision: expectedRevision
        )
    }

    package func verifyManagedArtifact(
        _ artifact: StagedArtifact
    ) async throws -> SourceArtifactDescriptor {
        try await library.verifyManagedArtifact(
            artifact,
            taskID: taskID
        )
    }

    package func stagedArtifactCount() async throws -> Int {
        try await library.stagedArtifactCount(taskID: taskID)
    }

    package func checkpointArtifactCount() async throws -> Int {
        try await library.checkpointArtifactCount(taskID: taskID)
    }
}
