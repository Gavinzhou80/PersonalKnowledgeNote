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
}
