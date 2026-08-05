import Foundation
import KnowledgeCore
import LocalLibrary
import Testing
@testable import DocumentImport

@Test
func importsStaticWebFixtureThroughPublicTaskInterface() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let acquirer = try GatedFixtureWebAcquirer()
    let fixedDocumentID = SourceDocumentID(try #require(
        UUID(uuidString: "20000000-0000-0000-0000-000000000001")
    ))
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: acquirer,
        documentIDGenerator: { fixedDocumentID }
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    var taskLists = documentImport.observeTasks(query: .all)
        .makeAsyncIterator()

    let initiallyVisible = try #require(await taskLists.next())
    #expect(initiallyVisible.isEmpty)

    let handle = try await documentImport.submit(.webpage(sourceURL))

    let queuedList = try #require(await taskLists.next())
    let queued = try #require(queuedList.first)
    #expect(queuedList.count == 1)
    #expect(queued.id == handle.id)
    #expect(queued.source == .webpage(sourceURL))
    #expect(queued.state == .queued(position: 0))

    let workspace = try #require(
        try await library.importWorkspace(id: handle.id)
    )
    let durableAtReturn = try await workspace.snapshot()
    #expect(durableAtReturn.attempt == 1)
    #expect(durableAtReturn.state != .completed)
    #expect(durableAtReturn.state != .abandoned)

    await acquirer.waitUntilStarted()
    #expect(
        try await library.sourceDocument(id: fixedDocumentID) == nil
    )

    let acquiringList = try #require(await taskLists.next())
    let acquiring = try #require(acquiringList.first)
    #expect(acquiringList.count == 1)
    #expect(
        acquiring.state == .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    var handleUpdates = handle.updates().makeAsyncIterator()
    let authoritative = try #require(await handleUpdates.next())
    #expect(authoritative == acquiring)

    async let terminal = handle.value()
    await acquirer.release()

    let constructingList = try #require(await taskLists.next())
    let constructing = try #require(constructingList.first)
    #expect(
        constructing.state == .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    let publishingList = try #require(await taskLists.next())
    let publishing = try #require(publishingList.first)
    #expect(
        publishing.state == .running(ImportProgress(
            activity: .publishing,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    let completedList = try #require(await taskLists.next())
    let completed = try #require(completedList.first)
    let expectedSuccess = ImportSuccess.published(
        documentID: fixedDocumentID,
        issues: []
    )
    #expect(completed.state == .completed(expectedSuccess))
    #expect(
        [queued, acquiring, constructing, publishing, completed]
            .map(\.revision) ==
            [queued, acquiring, constructing, publishing, completed]
            .map(\.revision)
            .sorted()
    )
    #expect(queued.revision < acquiring.revision)
    #expect(acquiring.revision < constructing.revision)
    #expect(constructing.revision < publishing.revision)
    #expect(publishing.revision < completed.revision)
    #expect(await terminal == .success(expectedSuccess))

    let located = try #require(
        try await library.sourceDocument(id: fixedDocumentID)
    )
    let content = located.document.content
    let blockIDs = content.blocks.map(\.id)
    #expect(located.location == .library)
    #expect(located.document.artifact.kind == .webPackage)
    #expect(content.documentID == fixedDocumentID)
    #expect(content.importedMetadata.title == "Fixture Article")
    #expect(content.importedMetadata.author == nil)
    #expect(
        content.blocks.map(\.canonicalText)
            == ["Fixture Article", "Deterministic offline content."]
    )
    #expect(content.structure.orderedBlockIDs == blockIDs)
    #expect(Set(content.evidence.keys) == Set(blockIDs))
    #expect(
        content.evidence[blockIDs[0]]
            == .web(locator: "article > h1:nth-of-type(1)")
    )
    #expect(
        content.evidence[blockIDs[1]]
            == .web(locator: "article > p:nth-of-type(1)")
    )
}
