import Foundation
import GRDB
import KnowledgeCore
import LocalLibrary
import SwiftSoup
import TestFixtures
import Testing
@testable import DocumentImport

@Suite(.serialized)
struct RealStaticWebImportIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func publicImportPublishesAnAuthoritativeOfflineWebPackage() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let libraryRoot = root.appending(path: "Library")
        let library = try await LocalLibrary.open(at: libraryRoot)
        let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
        let hero = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
        let publicationGate = AsyncTestGate()
        let server = try await LocalHTTPFixtureServer.start { path in
            switch path {
            case "/articles/rich/index.html?utm_source=integration":
                return .init(
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: fixture,
                    delay: .milliseconds(100)
                )
            case "/articles/rich/hero.svg":
                return .init(
                    headers: ["Content-Type": "image/svg+xml"],
                    body: hero,
                    beforeSend: { await publicationGate.waitForRelease() }
                )
            default:
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
        }
        defer { server.stop() }
        let sourceURL = server.url("articles/rich/index.html?utm_source=integration")
        let documentImport = DocumentImport(library: library)

        let handle = try await documentImport.submit(.webpage(sourceURL))
        let workspace = try #require(try await library.importWorkspace(id: handle.id))
        #expect((try await workspace.snapshot()).state != .completed)

        var updates = handle.updates().makeAsyncIterator()
        var snapshots: [ImportTaskSnapshot] = []
        var checkedAtomicVisibility = false
        while let snapshot = await updates.next() {
            snapshots.append(snapshot)
            if case .running(let progress) = snapshot.state,
               progress.activity == .constructingSourceDocument {
                await publicationGate.waitUntilBlocked()
                checkedAtomicVisibility = true
                #expect(try visibleSourceDocumentCount(at: libraryRoot) == 0)
                #expect(try sourceDocumentCount(at: libraryRoot) == 0)
                await publicationGate.release()
            }
        }
        #expect(checkedAtomicVisibility)

        let terminal = await handle.value()
        let documentID = try #require(publishedDocumentID(terminal))
        #expect(terminal == .success(.published(documentID: documentID, issues: [])))
        #expect(snapshots.compactMap(\.activity) == [
            .acquiringOriginalSource,
            .constructingSourceDocument,
            .publishing,
        ])
        #expect(snapshots.last?.state == .completed(
            .published(documentID: documentID, issues: [])
        ))

        let located = try #require(try await library.sourceDocument(id: documentID))
        let content = located.document.content
        #expect(located.location == .library)
        #expect(located.document.artifact.kind == .webPackage)
        #expect(content.importedMetadata == ImportedDocumentMetadata(
            title: "Rich Fixture Article",
            author: "Ada Example",
            publishedAt: ISO8601DateFormatter().date(from: "2025-04-03T10:15:30Z")
        ))
        let expectedRoles: [SourceBlockRole] = [
            .heading(level: 1), .paragraph, .heading(level: 2), .paragraph,
            .listItem, .listItem, .listItem, .quotation,
            .codeBlock(language: "swift"), .image, .caption,
        ]
        let expectedCategories: [SourceBlockCategory] = [
            .text, .text, .text, .text, .text, .text, .text, .text,
            .code, .media, .text,
        ]
        let expectedTexts = [
            "Rich Fixture Article",
            "A careful article with strong evidence, a useful link, Example Journal, and inline().",
            "Details", "Second paragraph.", "First unordered item", "Second unordered item",
            "First ordered item", "Quoted insight.",
            "let greeting = \"hello\"\nprint(greeting)", "Abstract fixture hero", "The fixture hero image.",
        ]
        let expectedIntroMarkup = [
            InlineMarkup(range: .init(utf16Offset: 2, utf16Length: 7), kind: .emphasis),
            InlineMarkup(range: .init(utf16Offset: 23, utf16Length: 15), kind: .strong),
            InlineMarkup(
                range: .init(utf16Offset: 42, utf16Length: 11),
                kind: .link(URL(string: "https://example.com/reference?keep=yes")!)
            ),
            InlineMarkup(range: .init(utf16Offset: 55, utf16Length: 15), kind: .citation(nil)),
            InlineMarkup(range: .init(utf16Offset: 76, utf16Length: 8), kind: .inlineCode),
        ]
        #expect(content.blocks.map(\.role) == expectedRoles)
        #expect(content.blocks.map(\.category) == expectedCategories)
        #expect(content.blocks.map(\.canonicalText) == expectedTexts)
        #expect(content.blocks[1].inlineMarkup == expectedIntroMarkup)
        #expect(content.blocks.enumerated().allSatisfy { index, block in
            index == 1 || block.inlineMarkup.isEmpty
        })
        #expect(content.blocks[1].inlineMarkup.map(\.kind) == [
            .emphasis, .strong,
            .link(URL(string: "https://example.com/reference?keep=yes")!),
            .citation(nil), .inlineCode,
        ])
        let intro = content.blocks[1]
        let introText = intro.canonicalText as NSString
        #expect(intro.inlineMarkup.map {
            introText.substring(with: NSRange(
                location: $0.range.utf16Offset,
                length: $0.range.utf16Length
            ))
        } == [
            "careful", "strong evidence", "useful link", "Example Journal", "inline()",
        ])
        #expect(content.structure.orderedBlockIDs == content.blocks.map(\.id))
        let image = content.blocks[9]
        let caption = content.blocks[10]
        let expectedMedia = SourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/c2da3444ef14dd83bddcc9c4fd826d70e0e8d457ee727dc54d5400e06f170a3b.svg",
            mimeType: "image/svg+xml",
            altText: "Abstract fixture hero",
            pixelWidth: nil,
            pixelHeight: nil
        )
        let expectedIDs = zip(zip(expectedCategories, expectedRoles), expectedTexts)
            .enumerated().map { index, value in
                StableWebIdentity.blockID(
                    category: value.0.0,
                    role: value.0.1,
                    ordinal: index + 1,
                    text: value.1
                )
            }
        let expectedBlocks = expectedTexts.indices.map { index in
            SourceBlock(
                id: expectedIDs[index],
                canonicalText: expectedTexts[index],
                category: expectedCategories[index],
                role: expectedRoles[index],
                inlineMarkup: index == 1 ? expectedIntroMarkup : [],
                media: index == 9 ? expectedMedia : nil
            )
        }
        #expect(content.blocks == expectedBlocks)
        #expect(image.media == expectedMedia)
        #expect(content.blocks.enumerated().allSatisfy { index, block in
            index == 9 || block.media == nil
        })
        #expect(content.structure.relations == [
            SourceRelation(
                sourceBlockID: caption.id,
                targetBlockID: image.id,
                kind: .captionForMedia
            ),
        ])
        let expectedLocators = [
            "#headline", "#intro", "#story > h2:nth-of-type(1)",
            "#story > p:nth-of-type(2)",
            "#story > ul:nth-of-type(1) > li:nth-of-type(1)",
            "#story > ul:nth-of-type(1) > li:nth-of-type(2)",
            "#story > ol:nth-of-type(1) > li:nth-of-type(1)",
            "#quote", "#sample", "#hero-image", "#hero-caption",
        ]
        #expect(content.blocks.map { content.evidence[$0.id] } == expectedLocators.map {
            Optional(SourceEvidence.web(locator: $0))
        })
        #expect(content.issues.isEmpty)

        let packageURL = libraryRoot.appending(path: "Artifacts/\(documentID.rawValue.uuidString)/payload")
        let indexURL = packageURL.appending(path: "index.html")
        let assetURL = try #require(image.media).artifactRelativePath
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appending(path: assetURL).path))
        let authoritativeDescriptor = try LocalLibrary.describeWebPackage(at: packageURL)
        #expect(located.document.artifact == authoritativeDescriptor)
        #expect(authoritativeDescriptor == SourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: 1_408,
            contentHash: "870094b76c9ddabec70ff1cecbcda506c8398fad9c05d4262aa69d695eb522bf"
        ))
        #expect(try FileManager.default.contentsOfDirectory(
            at: packageURL,
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent).sorted() == ["assets", "index.html"])
        #expect(try FileManager.default.contentsOfDirectory(
            at: packageURL.appending(path: "assets"),
            includingPropertiesForKeys: nil
        ).map(\.lastPathComponent) == [
            "c2da3444ef14dd83bddcc9c4fd826d70e0e8d457ee727dc54d5400e06f170a3b.svg",
        ])
        server.stop()
        let offlineHTML = try Data(contentsOf: indexURL)
        let offlineDocument = try SwiftSoup.parse(String(decoding: offlineHTML, as: UTF8.self))
        try assertOfflineClosure(
            document: offlineDocument,
            packageURL: packageURL,
            expectedImagePath: expectedMedia.artifactRelativePath
        )
    }

    @Test(.timeLimit(.minutes(1)))
    func missingOptionalImagePublishesWithTheExactPersistentIssue() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
        let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
        let server = try await LocalHTTPFixtureServer.start { path in
            if path == "/missing/index.html" {
                return .init(headers: ["Content-Type": "text/html"], body: fixture)
            }
            return .init(status: 404, headers: ["Content-Type": "text/plain"])
        }
        defer { server.stop() }

        let handle = try await DocumentImport(library: library).submit(
            .webpage(server.url("missing/index.html"))
        )
        let terminal = await handle.value()
        let documentID = try #require(publishedDocumentID(terminal))
        let located = try #require(try await library.sourceDocument(id: documentID))
        let image = try #require(located.document.content.blocks.first { $0.role == .image })
        let expected = [KnowledgeCore.ImportIssue(
            code: .optionalWebImageUnavailable,
            relatedBlockID: image.id
        )]

        #expect(located.document.content.issues == expected)
        #expect(terminal == .success(.published(documentID: documentID, issues: expected)))
    }

    @Test(.timeLimit(.minutes(1)))
    func canonicalDuplicateAddsProvenanceWithoutReplacingTheFirstPublication() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let libraryRoot = root.appending(path: "Library")
        let library = try await LocalLibrary.open(at: libraryRoot)
        let fixture = String(decoding: try Data(contentsOf: FixtureCatalog.richArticleURL), as: UTF8.self)
        let hero = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
        let alternate = fixture
            .replacingOccurrences(of: "Navigation noise", with: "Changed navigation chrome")
            .replacingOccurrences(of: "Advertisement noise", with: "Changed advertisement chrome")
            .replacingOccurrences(
                of: "https://example.com/reference?utm_source=fixture&amp;utm_medium=test&amp;keep=yes",
                with: "https://elsewhere.example/reference?utm_campaign=duplicate&amp;keep=yes"
            )
        let server = try await LocalHTTPFixtureServer.start { path in
            switch path {
            case "/first/index.html":
                return .init(headers: ["Content-Type": "text/html"], body: Data(fixture.utf8))
            case "/first/hero.svg":
                return .init(headers: ["Content-Type": "image/svg+xml"], body: hero)
            case "/second/article.html?utm_source=duplicate&utm_campaign=changed":
                return .init(headers: ["Content-Type": "text/html"], body: Data(alternate.utf8))
            default:
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
        }
        defer { server.stop() }
        let importer = DocumentImport(library: library)

        let firstTerminal = try await importer.submit(
            .webpage(server.url("first/index.html"))
        ).value()
        let firstID = try #require(publishedDocumentID(firstTerminal))
        let first = try #require(try await library.sourceDocument(id: firstID)).document
        let firstPackage = libraryRoot.appending(path: "Artifacts/\(firstID.rawValue.uuidString)/payload")
        let firstIndex = try Data(contentsOf: firstPackage.appending(path: "index.html"))

        let secondURL = server.url("second/article.html?utm_source=duplicate&utm_campaign=changed")
        let secondTerminal = try await importer.submit(.webpage(secondURL)).value()

        #expect(secondTerminal == .success(.alreadyImported(
            documentID: firstID,
            location: .library,
            provenanceAdded: true
        )))
        let preserved = try #require(try await library.sourceDocument(id: firstID)).document
        #expect(preserved == first)
        #expect(try Data(contentsOf: firstPackage.appending(path: "index.html")) == firstIndex)
        #expect(try FileManager.default.contentsOfDirectory(
            at: libraryRoot.appending(path: "Artifacts"),
            includingPropertiesForKeys: nil
        ).count == 1)

        let reopened = try await LocalLibrary.open(at: libraryRoot)
        let repeatedTerminal = try await DocumentImport(library: reopened)
            .submit(.webpage(secondURL)).value()
        #expect(repeatedTerminal == .success(.alreadyImported(
            documentID: firstID,
            location: .library,
            provenanceAdded: false
        )))
        #expect(try #require(try await reopened.sourceDocument(id: firstID)).document == first)
        #expect(try sourceDocumentCount(at: libraryRoot) == 1)
        #expect(try visibleSourceDocumentCount(at: libraryRoot) == 1)
        #expect(try Data(contentsOf: firstPackage.appending(path: "index.html")) == firstIndex)
    }
}

private extension ImportTaskSnapshot {
    var activity: ImportActivity? {
        guard case .running(let progress) = state else { return nil }
        return progress.activity
    }
}

private func publishedDocumentID(_ terminal: ImportTerminalState) -> SourceDocumentID? {
    guard case .success(.published(let documentID, _)) = terminal else { return nil }
    return documentID
}

private actor AsyncTestGate {
    private var blocked = false
    private var released = false
    private var blockedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func waitForRelease() async {
        blocked = true
        let waiters = blockedWaiters
        blockedWaiters.removeAll()
        waiters.forEach { $0.resume() }
        guard !released else { return }
        await withCheckedContinuation { releaseWaiters.append($0) }
    }

    func waitUntilBlocked() async {
        guard !blocked else { return }
        await withCheckedContinuation { blockedWaiters.append($0) }
    }

    func release() {
        released = true
        let waiters = releaseWaiters
        releaseWaiters.removeAll()
        waiters.forEach { $0.resume() }
    }
}

private func sourceDocumentCount(at libraryRoot: URL) throws -> Int {
    try DatabaseQueue(path: libraryRoot.appending(path: "library.sqlite").path)
        .read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM source_documents") ?? 0
        }
}

private func visibleSourceDocumentCount(at libraryRoot: URL) throws -> Int {
    try DatabaseQueue(path: libraryRoot.appending(path: "library.sqlite").path)
        .read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM source_documents WHERE visibility = ?",
                arguments: ["visible"]
            ) ?? 0
        }
}

private func assertOfflineClosure(
    document: SwiftSoup.Document,
    packageURL: URL,
    expectedImagePath: String
) throws {
    let imageSources = try document.select("img[src]").array().map {
        try $0.attr("src")
    }
    #expect(imageSources == [expectedImagePath])

    let loadableAttributes: [(String, String)] = [
        ("img[src]", "src"), ("img[srcset]", "srcset"),
        ("source[src]", "src"), ("source[srcset]", "srcset"),
        ("link[rel=stylesheet][href]", "href"),
        ("link[rel=preload][href]", "href"),
        ("link[rel=icon][href]", "href"),
        ("script[src]", "src"), ("iframe[src]", "src"),
        ("object[data]", "data"), ("embed[src]", "src"),
        ("video[src]", "src"), ("video[poster]", "poster"),
        ("audio[src]", "src"),
        ("svg image[href]", "href"), ("svg image[xlink\\:href]", "xlink:href"),
        ("svg use[href]", "href"), ("svg use[xlink\\:href]", "xlink:href"),
    ]
    for (selector, attribute) in loadableAttributes {
        for element in try document.select(selector).array() {
            let raw = try element.attr(attribute)
            let references = attribute == "srcset"
                ? raw.split(separator: ",").compactMap {
                    $0.split(whereSeparator: \.isWhitespace).first.map(String.init)
                }
                : [raw]
            for reference in references {
                try assertLocalPackageReference(reference, packageURL: packageURL)
            }
        }
    }

    for meta in try document.select("meta[http-equiv=refresh]").array() {
        let content = try meta.attr("content").lowercased()
        #expect(!content.contains("url="))
    }
    for styled in try document.select("[style], style").array() {
        let css = styled.tagName() == "style" ? try styled.html() : try styled.attr("style")
        #expect(!css.lowercased().contains("url("))
        #expect(!css.lowercased().contains("@import"))
    }
}

private func assertLocalPackageReference(
    _ rawReference: String,
    packageURL: URL
) throws {
    let reference = rawReference.trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(!reference.isEmpty)
    #expect(!reference.hasPrefix("//"))
    let lowered = reference.lowercased()
    #expect(!lowered.hasPrefix("http:"))
    #expect(!lowered.hasPrefix("https:"))
    #expect(!lowered.hasPrefix("javascript:"))
    #expect(!lowered.hasPrefix("data:"))
    #expect(!lowered.hasPrefix("file:"))

    let path = reference.split(separator: "#", maxSplits: 1).first?
        .split(separator: "?", maxSplits: 1).first.map(String.init) ?? reference
    let decoded = path.removingPercentEncoding ?? path
    #expect(!decoded.hasPrefix("/"))
    #expect(!decoded.split(separator: "/").contains(".."))
    #expect(FileManager.default.fileExists(atPath: packageURL.appending(path: decoded).path))
}
