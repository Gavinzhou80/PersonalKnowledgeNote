import AppSupport
import DocumentImport
import Foundation
import Testing

private typealias PublicImportTaskState = ImportTaskState

@Test
func emptyImportCenterExplainsThatNoImportsExist() {
    let presentation = ImportCenterPresentation.empty

    #expect(presentation.title == "Import Center")
    #expect(presentation.message == "No imports yet")
    #expect(presentation.systemImage == "tray")
}

@Test
func taskSnapshotMapsWithoutWorkflowKnowledge() {
    let cases: [(
        state: PublicImportTaskState,
        message: String,
        systemImage: String
    )] = [
        (
            .queued(position: 1),
            "Waiting to import",
            "clock"
        ),
        (
            .running(
                ImportProgress(
                    activity: .acquiringOriginalSource,
                    completedUnitCount: 0,
                    totalUnitCount: nil
                )
            ),
            "Acquiring webpage",
            "arrow.down.doc"
        ),
        (
            .running(
                ImportProgress(
                    activity: .constructingSourceDocument,
                    completedUnitCount: 0,
                    totalUnitCount: nil
                )
            ),
            "Building source document",
            "doc.text"
        ),
        (
            .running(
                ImportProgress(
                    activity: .publishing,
                    completedUnitCount: 0,
                    totalUnitCount: nil
                )
            ),
            "Publishing source document",
            "tray.and.arrow.down"
        ),
        (
            .failed(
                ImportFailure(
                    code: .networkUnavailable,
                    recovery: .retryable
                )
            ),
            "Import failed",
            "exclamationmark.triangle"
        ),
        (
            .completed(
                .published(
                    documentID: .init(),
                    issues: []
                )
            ),
            "Import completed",
            "checkmark.circle"
        ),
        (
            .completed(
                .alreadyImported(
                    documentID: .init(),
                    location: .library,
                    provenanceAdded: false
                )
            ),
            "Already imported",
            "checkmark.circle"
        ),
    ]

    for testCase in cases {
        let snapshot = ImportTaskSnapshot(
            id: .init(),
            revision: 1,
            attempt: 1,
            source: .webpage(
                URL(string: "https://example.com/article")!
            ),
            state: testCase.state
        )

        let presentation = ImportCenterPresentation.task(snapshot)

        #expect(presentation.title == "Import Center")
        #expect(presentation.message == testCase.message)
        #expect(presentation.systemImage == testCase.systemImage)
    }
}
