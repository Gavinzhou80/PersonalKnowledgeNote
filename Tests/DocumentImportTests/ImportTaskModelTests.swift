import Foundation
import KnowledgeCore
import Testing
import DocumentImport

@Test
func importTaskSnapshotCarriesApprovedPublicState() throws {
    let taskID = ImportTaskID()
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    let snapshot = ImportTaskSnapshot(
        id: taskID,
        revision: 3,
        attempt: 1,
        source: .webpage(sourceURL),
        state: .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    #expect(snapshot.id == taskID)
    #expect(snapshot.revision == 3)
    #expect(snapshot.attempt == 1)
    #expect(snapshot.source == .webpage(sourceURL))
    #expect(
        snapshot.state == .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
}

@Test
func terminalSuccessPreservesPublicationOutcome() {
    let documentID = SourceDocumentID()
    let success = ImportSuccess.published(
        documentID: documentID,
        issues: []
    )

    #expect(ImportTerminalState.success(success) == .success(success))
}
