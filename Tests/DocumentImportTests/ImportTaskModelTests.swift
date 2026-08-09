import Foundation
import struct KnowledgeCore.ImportIssue
import struct KnowledgeCore.ImportTaskID
import struct KnowledgeCore.SourceBlockID
import struct KnowledgeCore.SourceDocumentID
import Testing
@testable import DocumentImport
import typealias DocumentImport.ImportIssue

private func requireHashableSendable<T: Hashable & Sendable>(_: T.Type) {}
private typealias PublicImportTaskState = ImportTaskState

@Test
func taskControlModelsAreStableAndSendable() {
    let failure = ImportFailure(
        code: .networkUnavailable,
        recovery: .retryable,
        diagnosticID: UUID(
            uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"
        )!
    )

    requireHashableSendable(PublicImportTaskState.self)
    requireHashableSendable(ImportTerminalState.self)
    requireHashableSendable(ImportTaskControlError.self)
    requireHashableSendable(DocumentImportAvailabilityError.self)
    #expect(
        PublicImportTaskState.cancelling
            != PublicImportTaskState.cancelled
    )
    #expect(ImportTerminalState.cancelled != .failure(failure))
    #expect(ImportTaskControlError.tooLate != .retryNotAllowed)
    #expect(
        DocumentImportAvailabilityError.localLibraryUnavailable
            == .localLibraryUnavailable
    )
}

@Test
func importFailureCodeAndRecoveryRoundTripThroughCodable() throws {
    let codes: [ImportFailure.Code] = [
        .networkUnavailable,
        .checkpointInvalid,
        .publicationFailed,
    ]
    let recoveries: [ImportFailure.Recovery] = [
        .retryable,
        .requiresNewOriginalSource,
        .requiresUserAction,
        .unsupported,
    ]

    for code in codes {
        let data = try JSONEncoder().encode(code)
        #expect(try JSONDecoder().decode(
            ImportFailure.Code.self,
            from: data
        ) == code)
    }
    for recovery in recoveries {
        let data = try JSONEncoder().encode(recovery)
        #expect(try JSONDecoder().decode(
            ImportFailure.Recovery.self,
            from: data
        ) == recovery)
    }
}

@Test
func cancellingAndCancelledStatesMatchTaskQueries() {
    #expect(DocumentImport.matches(.cancelling, query: .active))
    #expect(!DocumentImport.matches(.cancelled, query: .active))
    #expect(DocumentImport.matches(.cancelling, query: .unfinished))
    #expect(DocumentImport.matches(.cancelled, query: .unfinished))
    #expect(DocumentImport.matches(.cancelling, query: .all))
    #expect(DocumentImport.matches(.cancelled, query: .all))
}

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
        issues: [issue],
        facts: nil
    )

    switch ImportTerminalState.success(success) {
    case .success(.published(let actualID, let issues, _)):
        #expect(actualID == documentID)
        #expect(issues == [issue])
    default:
        Issue.record("Expected published success terminal state")
    }
}

@Test
func deprecatedImportIssueNamesRemainSourceCompatible() {
    let oldIssue: ImportIssue = ImportIssue(
        code: .optionalResourceUnavailable
    )
    let newIssue = KnowledgeCore.ImportIssue(
        code: .optionalWebImageUnavailable
    )

    #expect(oldIssue == newIssue)
    #expect(
        KnowledgeCore.ImportIssue.Code.optionalResourceUnavailable
            == .optionalWebImageUnavailable
    )
}
