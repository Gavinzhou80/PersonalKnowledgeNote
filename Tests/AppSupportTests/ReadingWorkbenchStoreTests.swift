import AppSupport
import Foundation
import KnowledgeCore
import LocalLibrary
import Testing

private actor InMemoryReadingLibrary: ReadingLibraryPort {
    private var summariesToReturn: [SourceDocumentSummary] = []
    private var documentsByID: [SourceDocumentID: LocatedSourceDocument]
        = [:]
    private(set) var submittedSources: [OriginalSource] = []

    func setSummaries(_ summaries: [SourceDocumentSummary]) {
        summariesToReturn = summaries
    }

    func setDocument(_ document: LocatedSourceDocument) {
        documentsByID[document.document.content.documentID] = document
    }

    func publishedDocumentSummaries() async throws
        -> [SourceDocumentSummary]
    {
        summariesToReturn
    }

    func sourceDocument(
        id: SourceDocumentID
    ) async throws -> LocatedSourceDocument? {
        documentsByID[id]
    }

    func artifactResource(
        documentID: SourceDocumentID,
        relativePath: String
    ) async throws -> ArtifactResource? {
        nil
    }

    func submitImport(_ source: OriginalSource) async throws {
        submittedSources.append(source)
    }
}

private func makeOutlineFixtureContent() -> SourceDocumentContent {
    let chapter = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Chapter",
        role: .heading(level: 1)
    )
    let intro = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Intro paragraph"
    )
    let section = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Section",
        role: .heading(level: 2)
    )
    let body = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Body paragraph"
    )
    let appendix = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Appendix",
        role: .heading(level: 1)
    )
    return SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Outline Fixture",
            author: nil
        ),
        blocks: [chapter, intro, section, body, appendix],
        structure: SourceStructure(
            orderedBlockIDs: [
                chapter.id,
                intro.id,
                section.id,
                body.id,
                appendix.id,
            ]
        ),
        evidence: [
            chapter.id: .web(locator: "h1"),
            intro.id: .web(locator: "p"),
            section.id: .web(locator: "h2"),
            body.id: .web(locator: "p"),
            appendix.id: .web(locator: "h1"),
        ]
    )
}

private func makePlainFixtureContent() -> SourceDocumentContent {
    let body = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Plain paragraph"
    )
    return SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Plain Fixture",
            author: nil
        ),
        blocks: [body],
        structure: SourceStructure(orderedBlockIDs: [body.id]),
        evidence: [body.id: .web(locator: "p")]
    )
}

private func makeLocatedDocument(
    content: SourceDocumentContent
) -> LocatedSourceDocument {
    LocatedSourceDocument(
        document: SourceDocument(
            content: content,
            artifact: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        location: .library
    )
}

@MainActor
@Test
func storeLoadsPublishedSummariesNewestFirst() async throws {
    let library = InMemoryReadingLibrary()
    let newest = SourceDocumentSummary(
        documentID: SourceDocumentID(),
        title: "Newest Article"
    )
    let oldest = SourceDocumentSummary(
        documentID: SourceDocumentID(),
        title: "Oldest Article"
    )
    await library.setSummaries([newest, oldest])
    let store = ReadingWorkbenchStore(library: library)

    await store.loadDocumentList()

    #expect(store.summaries.map(\.title) == [
        "Newest Article",
        "Oldest Article",
    ])
    #expect(store.summaries.first?.documentID == newest.documentID)
}

@MainActor
@Test
func selectingDocumentProjectsOutlineInReadingOrder() async throws {
    let library = InMemoryReadingLibrary()
    let content = makeOutlineFixtureContent()
    await library.setDocument(makeLocatedDocument(content: content))
    let store = ReadingWorkbenchStore(library: library)

    await store.select(content.documentID)

    #expect(store.selectedDocumentID == content.documentID)
    #expect(store.outline == [
        ReadingOutlineNode(blockIndex: 0, level: 1, text: "Chapter"),
        ReadingOutlineNode(blockIndex: 2, level: 2, text: "Section"),
        ReadingOutlineNode(blockIndex: 4, level: 1, text: "Appendix"),
    ])
}

@MainActor
@Test
func selectingDocumentWithoutHeadingsYieldsEmptyOutline() async throws {
    let library = InMemoryReadingLibrary()
    let content = makePlainFixtureContent()
    await library.setDocument(makeLocatedDocument(content: content))
    let store = ReadingWorkbenchStore(library: library)

    await store.select(content.documentID)

    #expect(store.selectedDocumentID == content.documentID)
    #expect(store.outline.isEmpty)
}

@MainActor
@Test
func artifactLoadURLUsesReadingSchemeForSelection() async throws {
    let library = InMemoryReadingLibrary()
    let content = makePlainFixtureContent()
    await library.setDocument(makeLocatedDocument(content: content))
    let store = ReadingWorkbenchStore(library: library)

    #expect(store.artifactLoadURL == nil)
    await store.select(content.documentID)

    #expect(
        store.artifactLoadURL?.absoluteString
            == "pkn-reading://document/\(content.documentID.rawValue.uuidString)/index.html"
    )
}

@MainActor
@Test
func submitImportForwardsValidURLToLibraryPort() async throws {
    let library = InMemoryReadingLibrary()
    let store = ReadingWorkbenchStore(library: library)
    let url = try #require(URL(string: "https://example.com/article"))

    await store.submitImport(rawURL: "https://example.com/article")

    #expect(store.importState == .submitted)
    let submitted = await library.submittedSources
    #expect(submitted == [.webpage(url)])
}

@MainActor
@Test
func submitImportRejectsUnparsableInputWithTypedState() async throws {
    let library = InMemoryReadingLibrary()
    let store = ReadingWorkbenchStore(library: library)

    for raw in ["not a url", "", "ftp://example.com/file"] {
        await store.submitImport(rawURL: raw)
        #expect(store.importState == .invalidURL, "Rejected \(raw)")
    }
    let submitted = await library.submittedSources
    #expect(submitted.isEmpty)
}

@MainActor
@Test
func publicationCompletionRefreshesSummaryList() async throws {
    let library = InMemoryReadingLibrary()
    let first = SourceDocumentSummary(
        documentID: SourceDocumentID(),
        title: "First Article"
    )
    await library.setSummaries([first])
    let store = ReadingWorkbenchStore(library: library)
    await store.loadDocumentList()
    #expect(store.summaries.count == 1)

    // A new publication lands; the reading list refreshes on reload.
    let second = SourceDocumentSummary(
        documentID: SourceDocumentID(),
        title: "Second Article"
    )
    await library.setSummaries([second, first])

    await store.loadDocumentList()

    #expect(store.summaries.map(\.title) == [
        "Second Article",
        "First Article",
    ])
}
