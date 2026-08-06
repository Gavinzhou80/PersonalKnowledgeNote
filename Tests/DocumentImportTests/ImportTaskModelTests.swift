import Foundation
import KnowledgeCore
import Testing
import DocumentImport

private func requireHashableSendable<T: Hashable & Sendable>(_: T.Type) {}

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
func importSubmissionErrorIsHashableAndSendable() {
    requireHashableSendable(ImportSubmissionError.self)
}

@Test
func terminalSuccessPreservesPublicationOutcome() {
    let documentID = SourceDocumentID()
    let relatedBlockID = SourceBlockID()
    let issue = KnowledgeCore.ImportIssue(
        code: .optionalWebImageUnavailable,
        relatedBlockID: relatedBlockID
    )
    let success = ImportSuccess.published(
        documentID: documentID,
        issues: [issue]
    )

    switch ImportTerminalState.success(success) {
    case .success(.published(let actualID, let issues)):
        #expect(actualID == documentID)
        #expect(issues == [issue])
    default:
        Issue.record("Expected published success terminal state")
    }
}
