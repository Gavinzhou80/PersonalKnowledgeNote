import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

private struct PublishedFixture {
    let library: LocalLibrary
    let documentID: SourceDocumentID
    let title: String
}

private func publishFixtureDocument(
    library: LocalLibrary,
    root: URL,
    urlPath: String,
    title: String,
    fingerprint: String,
    assetNames: [String] = []
) async throws -> SourceDocumentID {
    let package = root.appending(path: "WebPackage-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<article>\(title)</article>".utf8).write(
        to: package.appending(path: "index.html")
    )
    if !assetNames.isEmpty {
        let assets = package.appending(path: "assets")
        try FileManager.default.createDirectory(
            at: assets,
            withIntermediateDirectories: true
        )
        for name in assetNames {
            try Data("asset-bytes-\(name)".utf8).write(
                to: assets.appending(path: name)
            )
        }
    }
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://fixture.invalid/\(urlPath)"))
    )
    let content = makeFixtureContent(titled: title)
    let workspace = try await library.accept(source)
    let accepted = try await workspace.snapshot()
    let staged = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: accepted.revision
    )
    try FileManager.default.removeItem(at: package)
    let stagedSnapshot = try await workspace.snapshot()
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint(fingerprint),
        artifact: staged,
        document: content,
        originalSource: source
    )
    let outcome = try await workspace.finish(
        candidate,
        expectedRevision: stagedSnapshot.revision
    )
    #expect(outcome == .published(documentID: content.documentID))
    return content.documentID
}

@Test
func summariesListVisibleDocumentsNewestFirst() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )

    _ = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "first",
        title: "First Article",
        fingerprint: "reading-seam-first"
    )
    let newestID = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "second",
        title: "Second Article",
        fingerprint: "reading-seam-second"
    )

    let summaries = try await library.publishedDocumentSummaries()

    #expect(summaries.count == 2)
    #expect(summaries.first?.documentID == newestID)
    #expect(summaries.first?.title == "Second Article")
    #expect(summaries.last?.title == "First Article")
}

@Test
func summariesExcludeHiddenPublicationReservations() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let visibleID = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "visible",
        title: "Visible Article",
        fingerprint: "reading-seam-visible"
    )

    // A prepared-but-uncommitted publication keeps a hidden document row.
    let hiddenSource = OriginalSource.webpage(
        try #require(URL(string: "https://fixture.invalid/hidden"))
    )
    let hiddenWorkspace = try await library.accept(hiddenSource)
    let hiddenPackage = root.appending(path: "HiddenPackage")
    try FileManager.default.createDirectory(
        at: hiddenPackage,
        withIntermediateDirectories: true
    )
    try Data("<article>Hidden</article>".utf8).write(
        to: hiddenPackage.appending(path: "index.html")
    )
    let hiddenAccepted = try await hiddenWorkspace.snapshot()
    let hiddenStaged = try await hiddenWorkspace.stageArtifact(
        .package(
            hiddenPackage,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: hiddenAccepted.revision
    )
    let hiddenCandidate = PublicationCandidate(
        fingerprint: ContentFingerprint("reading-seam-hidden"),
        artifact: hiddenStaged,
        document: makeFixtureContent(titled: "Hidden Article"),
        originalSource: hiddenSource
    )
    let hiddenSnapshot = try await hiddenWorkspace.snapshot()
    try LocalLibraryTestDriver.prepareHiddenPublication(
        at: root.appending(path: "Library"),
        taskID: hiddenWorkspace.taskID,
        candidate: hiddenCandidate,
        expectedRevision: hiddenSnapshot.revision
    )

    let summaries = try await library.publishedDocumentSummaries()

    #expect(summaries.map(\.documentID) == [visibleID])
}

@Test
func artifactResourceServesIndexAndAssets() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentID = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "assets",
        title: "Asset Article",
        fingerprint: "reading-seam-assets",
        assetNames: ["figure.png"]
    )

    let index = try #require(
        try await library.artifactResource(
            documentID: documentID,
            relativePath: "index.html"
        )
    )
    #expect(
        String(decoding: index.data, as: UTF8.self)
            .contains("<article>Asset Article</article>")
    )
    #expect(index.contentType == "text/html")

    let asset = try #require(
        try await library.artifactResource(
            documentID: documentID,
            relativePath: "assets/figure.png"
        )
    )
    #expect(
        String(decoding: asset.data, as: UTF8.self)
            == "asset-bytes-figure.png"
    )
    #expect(asset.contentType == "image/png")
}

@Test
func artifactResourceReturnsNilForUnknownDocumentAndMissingFile()
    async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentID = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "nil-cases",
        title: "Nil Cases",
        fingerprint: "reading-seam-nil"
    )

    let unknown = try await library.artifactResource(
        documentID: SourceDocumentID(),
        relativePath: "index.html"
    )
    #expect(unknown == nil)

    let missing = try await library.artifactResource(
        documentID: documentID,
        relativePath: "assets/missing.png"
    )
    #expect(missing == nil)
}

@Test
func artifactResourceRejectsPathTraversal() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let documentID = try await publishFixtureDocument(
        library: library,
        root: root,
        urlPath: "traversal",
        title: "Traversal",
        fingerprint: "reading-seam-traversal"
    )

    for hostilePath in [
        "../library.sqlite",
        "assets/../../library.sqlite",
        "/etc/passwd",
        "..\\library.sqlite",
        "assets//../../Staging",
    ] {
        let resource = try await library.artifactResource(
            documentID: documentID,
            relativePath: hostilePath
        )
        #expect(resource == nil, "Accepted hostile path \(hostilePath)")
    }
}
