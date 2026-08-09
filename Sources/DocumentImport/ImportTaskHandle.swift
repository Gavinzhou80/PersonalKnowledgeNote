import Foundation
import KnowledgeCore

public struct ImportTaskHandle: Sendable {
    public let id: ImportTaskID
    private let owner: DocumentImport

    init(id: ImportTaskID, owner: DocumentImport) {
        self.id = id
        self.owner = owner
    }

    public func updates() -> AsyncStream<ImportTaskSnapshot> {
        owner.updates(for: id)
    }

    public func value() async -> ImportTerminalState {
        await owner.value(for: id)
    }

    public func cancel() async throws {
        try await owner.cancel(taskID: id)
    }

    public func retry() async throws {
        try await owner.retry(taskID: id)
    }
}
