import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func acceptedImportSurvivesLibraryReopen() async throws {
    let root = try makeTemporaryLibraryRoot()
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/article"))
    )

    let taskID = try await {
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(source)
        let snapshot = try await workspace.snapshot()

        #expect(snapshot.state == .accepted)
        #expect(snapshot.revision == 0)
        return workspace.taskID
    }()

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: taskID)
    )
    let snapshot = try await recovered.snapshot()

    #expect(snapshot.taskID == taskID)
    #expect(snapshot.state == .accepted)
}
