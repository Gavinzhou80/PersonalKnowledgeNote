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

    public func abandon(expectedRevision: UInt64) async throws {
        try await library.abandon(
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
}
