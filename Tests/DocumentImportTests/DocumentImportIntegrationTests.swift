import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

private struct FixedPageWebAcquirer: WebAcquiring {
    let page: AcquiredWebPage

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        page
    }
}

@Test(.timeLimit(.minutes(1)))
func invalidWebURLFailsBeforeDurableAcceptance() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer()
    )
    do {
        _ = try await documentImport.submit(
            .webpage(URL(string: "relative/path")!)
        )
        Issue.record("Expected invalid web URL submission failure")
    } catch let error as ImportSubmissionError {
        #expect(error == .invalidWebURL)
    }

    #expect(try await library.recoverableImports().isEmpty)
}

@Test(.timeLimit(.minutes(1)))
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
    var taskLists = documentImport.observeTasks(.all)
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
    let durableAcquiring = try await workspace.snapshot()
    #expect(durableAcquiring.revision == acquiring.revision)
    #expect(durableAcquiring.state == .working)

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
    #expect(await handleUpdates.next() == constructing)

    let publishingList = try #require(await taskLists.next())
    let publishing = try #require(publishingList.first)
    #expect(
        publishing.state == .running(ImportProgress(
            activity: .publishing,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    #expect(await handleUpdates.next() == publishing)

    let completedList = try #require(await taskLists.next())
    let completed = try #require(completedList.first)
    let expectedSuccess = ImportSuccess.published(
        documentID: fixedDocumentID,
        issues: []
    )
    #expect(completed.state == .completed(expectedSuccess))
    #expect(await handleUpdates.next() == completed)
    #expect(await handleUpdates.next() == nil)
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
    let durableCompleted = try await workspace.snapshot()
    #expect(durableCompleted.revision == completed.revision)
    #expect(durableCompleted.state == .completed)

    let located = try #require(
        try await library.sourceDocument(id: fixedDocumentID)
    )
    let headingID = SourceBlockID(try #require(
        UUID(uuidString: "2e76281c-b8ea-1037-decd-5cedb52b146b")
    ))
    let paragraphID = SourceBlockID(try #require(
        UUID(uuidString: "681f3b68-bc94-2a86-4b1f-94cc768557d5")
    ))
    let expectedContent = SourceDocumentContent(
        documentID: fixedDocumentID,
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture Article",
            author: nil
        ),
        blocks: [
            SourceBlock(
                id: headingID,
                canonicalText: "Fixture Article",
                category: .text,
                role: .heading(level: 1)
            ),
            SourceBlock(
                id: paragraphID,
                canonicalText: "Deterministic offline content."
            ),
        ],
        structure: SourceStructure(
            orderedBlockIDs: [headingID, paragraphID]
        ),
        evidence: [
            headingID: .web(
                locator: "html > body > article:nth-of-type(1) > h1:nth-of-type(1)"
            ),
            paragraphID: .web(
                locator: "html > body > article:nth-of-type(1) > p:nth-of-type(1)"
            ),
        ]
    )

    #expect(located.location == .library)
    #expect(located.document.artifact.kind == .webPackage)
    #expect(located.document.content == expectedContent)
}

@Test(.timeLimit(.minutes(1)))
func publishedSuccessMatchesPersistentIssues() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
    let server = try await LocalHTTPFixtureServer.start { _ in
        .init(status: 404, headers: ["Content-Type": "text/plain"])
    }
    defer { server.stop() }
    let page = AcquiredWebPage(
        finalURL: server.url("articles/rich/index.html"),
        mimeType: "text/html",
        responseBytes: fixture
    )
    let fixedDocumentID = SourceDocumentID()
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: FixedPageWebAcquirer(page: page),
        documentIDGenerator: { fixedDocumentID }
    )

    let handle = try await documentImport.submit(.webpage(page.finalURL))
    let terminal = await handle.value()
    let located = try #require(
        try await library.sourceDocument(id: fixedDocumentID)
    )
    let persistedIssues = located.document.content.issues
    let imageBlock = try #require(
        located.document.content.blocks.first { $0.role == .image }
    )

    #expect(persistedIssues == [
        .init(
            code: .optionalWebImageUnavailable,
            relatedBlockID: imageBlock.id
        ),
    ])
    #expect(terminal == .success(.published(
        documentID: fixedDocumentID,
        issues: persistedIssues
    )))
}

@Test(.timeLimit(.minutes(1)))
func genericPostAcceptanceFailureFinishesAndAbandonsTask() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer()
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/failure")
    )

    let handle = try await documentImport.submit(.webpage(sourceURL))
    var updates = handle.updates().makeAsyncIterator()
    let terminal = await handle.value()
    var finalSnapshot: ImportTaskSnapshot?
    while let snapshot = await updates.next() {
        finalSnapshot = snapshot
    }

    guard case .failure(let failure) = terminal else {
        Issue.record("Expected generic post-acceptance failure")
        return
    }
    #expect(failure.code == .localLibraryUnavailable)
    #expect(failure.recovery == .requiresUserAction)
    #expect(finalSnapshot?.state == .failed(failure))
    #expect(
        try await library.importWorkspace(id: handle.id) == nil
    )
}

@Test(.timeLimit(.minutes(1)))
func acquisitionFailureIsTerminalTaskDataAfterAcceptance() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: ThrowingFixtureWebAcquirer()
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/network-unavailable")
    )

    let handle = try await documentImport.submit(.webpage(sourceURL))
    var updates = handle.updates().makeAsyncIterator()
    let terminal = await handle.value()
    var finalSnapshot: ImportTaskSnapshot?
    while let snapshot = await updates.next() {
        finalSnapshot = snapshot
    }

    guard case .failure(let failure) = terminal else {
        Issue.record("Expected acquisition failure after acceptance")
        return
    }
    #expect(failure.code == .networkUnavailable)
    #expect(failure.recovery == .retryable)
    #expect(finalSnapshot?.state == .failed(failure))
    #expect(
        try await library.importWorkspace(id: handle.id) == nil
    )
}

@Test(.timeLimit(.minutes(1)))
func immediatelyDiscardedObservationStreamsDoNotBlockImport() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let acquirer = try GatedFixtureWebAcquirer()
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: acquirer
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/discarded-observers")
    )

    for _ in 0..<128 {
        _ = documentImport.observeTasks(.all)
    }
    let handle = try await documentImport.submit(.webpage(sourceURL))
    await acquirer.waitUntilStarted()
    for _ in 0..<128 {
        _ = handle.updates()
    }

    async let terminal = handle.value()
    await acquirer.release()

    guard case .success(.published) = await terminal else {
        Issue.record("Expected discarded streams not to cancel import")
        return
    }
}

@Test(.timeLimit(.minutes(1)))
func completedSnapshotFailureStillPublishesSuccessfulTerminal() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let acquirer = try GatedFixtureWebAcquirer()
    let snapshotLoader = SelectiveWorkspaceSnapshotLoader(
        failingCalls: [2]
    )
    let fixedDocumentID = SourceDocumentID(try #require(
        UUID(uuidString: "20000000-0000-0000-0000-000000000002")
    ))
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: acquirer,
        documentIDGenerator: { fixedDocumentID },
        workspaceSnapshotLoader: { workspace in
            try await snapshotLoader.load(workspace)
        }
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/completed-snapshot-failure")
    )

    let handle = try await documentImport.submit(.webpage(sourceURL))
    await acquirer.waitUntilStarted()
    var updates = handle.updates().makeAsyncIterator()
    let acquiring = try #require(await updates.next())
    #expect(
        acquiring.state == .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    async let terminal = handle.value()
    await acquirer.release()

    _ = try #require(await updates.next())
    let publishing = try #require(await updates.next())
    let completed = try #require(await updates.next())
    let expectedSuccess = ImportSuccess.published(
        documentID: fixedDocumentID,
        issues: []
    )
    #expect(
        publishing.state == .running(ImportProgress(
            activity: .publishing,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    let workspace = try #require(
        try await library.importWorkspace(id: handle.id)
    )
    let durableCompleted = try await workspace.snapshot()
    #expect(durableCompleted.state == .completed)
    #expect(completed.revision == durableCompleted.revision)
    #expect(completed.attempt == publishing.attempt)
    #expect(completed.state == .completed(expectedSuccess))
    #expect(await updates.next() == nil)
    #expect(await terminal == .success(expectedSuccess))
    #expect(
        try await library.sourceDocument(id: fixedDocumentID) != nil
    )
}

@Test(.timeLimit(.minutes(1)))
func initialSnapshotFailureAbandonsAcceptedTask() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let snapshotLoader = SelectiveWorkspaceSnapshotLoader(
        failingCalls: [1]
    )
    let documentImport = DocumentImport(
        library: library,
        webAcquirer: ThrowingWebAcquirer(),
        workspaceSnapshotLoader: { workspace in
            try await snapshotLoader.load(workspace)
        }
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/initial-snapshot-failure")
    )

    do {
        _ = try await documentImport.submit(.webpage(sourceURL))
        Issue.record("Expected initial snapshot failure")
    } catch let error as ImportSubmissionError {
        #expect(error == .cannotPersistImportTask)
    }

    #expect(try await library.recoverableImports().isEmpty)
}
