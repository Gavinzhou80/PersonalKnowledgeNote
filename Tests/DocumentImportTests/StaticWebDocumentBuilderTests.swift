import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

@Test
func stableWebIdentityUsesVersionedSemanticInputs() {
    let base = StableWebIdentity.blockID(
        category: .text,
        role: .paragraph,
        ordinal: 2,
        text: "Canonical text"
    )

    #expect(base == StableWebIdentity.blockID(
        category: .text,
        role: .paragraph,
        ordinal: 2,
        text: "Canonical text"
    ))
    #expect(base != StableWebIdentity.blockID(
        category: .code,
        role: .codeBlock(language: nil),
        ordinal: 2,
        text: "Canonical text"
    ))
    #expect(base != StableWebIdentity.blockID(
        category: .text,
        role: .quotation,
        ordinal: 2,
        text: "Canonical text"
    ))
    #expect(base != StableWebIdentity.blockID(
        category: .text,
        role: .paragraph,
        ordinal: 3,
        text: "Canonical text"
    ))
    #expect(base != StableWebIdentity.blockID(
        category: .text,
        role: .paragraph,
        ordinal: 2,
        text: "Different text"
    ))
}

@Test
func richWebDocumentBuilderProducesAuthoritativeGraph() async throws {
    let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
    let image = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
    let server = try await LocalHTTPFixtureServer.start { path in
        if path == "/articles/rich/hero.svg" {
            return .init(headers: ["Content-Type": "image/svg+xml"], body: image)
        }
        return .init(status: 404, headers: ["Content-Type": "text/plain"])
    }
    defer { server.stop() }
    let page = AcquiredWebPage(
        finalURL: server.url("articles/rich/index.html"),
        mimeType: "text/html",
        responseBytes: fixture
    )
    let documentID = SourceDocumentID()

    let product = try await StaticWebDocumentBuilder().build(
        page,
        documentID: documentID
    )
    defer { try? FileManager.default.removeItem(at: product.packageURL) }
    let content = product.document.content

    #expect(content.documentID == documentID)
    #expect(content.importedMetadata.title == "Rich Fixture Article")
    #expect(content.importedMetadata.author == "Ada Example")
    #expect(content.importedMetadata.publishedAt == ISO8601DateFormatter().date(from: "2025-04-03T10:15:30Z"))
    #expect(content.blocks.map(\.role) == [
        .heading(level: 1), .paragraph, .heading(level: 2), .paragraph,
        .listItem, .listItem, .listItem, .quotation,
        .codeBlock(language: "swift"), .image, .caption,
    ])
    #expect(content.blocks.map(\.category) == [
        .text, .text, .text, .text, .text, .text, .text, .text,
        .code, .media, .text,
    ])
    #expect(content.blocks[1].inlineMarkup.count == 5)
    let imageBlock = content.blocks[9]
    let captionBlock = content.blocks[10]
    #expect(imageBlock.media?.artifactRelativePath.hasPrefix("assets/") == true)
    #expect(content.structure.orderedBlockIDs == content.blocks.map(\.id))
    #expect(content.structure.relations == [
        SourceRelation(
            sourceBlockID: captionBlock.id,
            targetBlockID: imageBlock.id,
            kind: .captionForMedia
        ),
    ])
    #expect(content.evidence[imageBlock.id] == .web(locator: "#hero-image"))
    #expect(content.issues.isEmpty)
    #expect(product.issues == content.issues)

    let changedURL = AcquiredWebPage(
        finalURL: server.url("different/path?utm_source=changed"),
        mimeType: "text/html",
        responseBytes: Data(
            String(decoding: fixture, as: UTF8.self)
                .replacingOccurrences(
                    of: "https://example.com/reference?utm_source=fixture&amp;utm_medium=test&amp;keep=yes",
                    with: "https://different.example/path?utm_campaign=other&amp;id=42"
                )
                .utf8
        )
    )
    let alternate = try await StaticWebDocumentBuilder().build(
        changedURL,
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: alternate.packageURL) }
    #expect(alternate.fingerprint == product.fingerprint)
    #expect(alternate.document.content.issues.count == 1)
    #expect(product.document.content.issues.isEmpty)
}

@Test
func duplicateImageURLIssuesReferenceEachFinalImageBlock() async throws {
    let server = try await LocalHTTPFixtureServer.start { _ in
        .init(status: 404, headers: ["Content-Type": "text/plain"])
    }
    defer { server.stop() }
    let html = Data("""
    <html><body><article><h1>Duplicate images</h1><p>Readable body.</p>
    <img src="missing.svg" alt="First"><img src="missing.svg" alt="Second">
    </article></body></html>
    """.utf8)
    let product = try await StaticWebDocumentBuilder().build(
        AcquiredWebPage(
            finalURL: server.url("article/index.html"),
            mimeType: "text/html",
            responseBytes: html
        ),
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: product.packageURL) }
    let imageIDs = product.document.content.blocks
        .filter { $0.role == .image }
        .map(\.id)

    #expect(imageIDs.count == 2)
    #expect(product.issues.map(\.relatedBlockID) == imageIDs.map(Optional.some))
}

@Test
func staticFixtureBuildsDeterministicManagedWebContent() async throws {
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    let page = AcquiredWebPage(
        sourceURL: sourceURL,
        html: try Data(contentsOf: FixtureCatalog.webArticleURL)
    )
    let documentID = SourceDocumentID(try #require(
        UUID(uuidString: "10000000-0000-0000-0000-000000000001")
    ))
    let builder = StaticWebDocumentBuilder()

    let first = try await builder.build(page, documentID: documentID)
    defer { try? FileManager.default.removeItem(at: first.packageURL) }
    let second = try await builder.build(page, documentID: documentID)
    defer { try? FileManager.default.removeItem(at: second.packageURL) }

    let firstContent = first.document.content
    let firstBlockIDs = firstContent.blocks.map(\.id)
    let secondBlockIDs = second.document.content.blocks.map(\.id)
    let expectedBlockIDs = [
        SourceBlockID(try #require(
            UUID(uuidString: "2e76281c-b8ea-1037-decd-5cedb52b146b")
        )),
        SourceBlockID(try #require(
            UUID(uuidString: "681f3b68-bc94-2a86-4b1f-94cc768557d5")
        )),
    ]

    #expect(firstContent.importedMetadata.title == "Fixture Article")
    #expect(firstContent.importedMetadata.author == nil)
    #expect(
        firstContent.blocks.map(\.canonicalText)
            == ["Fixture Article", "Deterministic offline content."]
    )
    #expect(firstContent.structure.orderedBlockIDs == firstBlockIDs)
    #expect(Set(firstContent.evidence.keys) == Set(firstBlockIDs))
    #expect(
        firstContent.evidence[firstBlockIDs[0]]
            == .web(locator: "html > body > article:nth-of-type(1) > h1:nth-of-type(1)")
    )
    #expect(
        firstContent.evidence[firstBlockIDs[1]]
            == .web(locator: "html > body > article:nth-of-type(1) > p:nth-of-type(1)")
    )

    #expect(firstBlockIDs == secondBlockIDs)
    #expect(firstBlockIDs == expectedBlockIDs)
    #expect(first.fingerprint == second.fingerprint)
    #expect(
        first.fingerprint.rawValue
            == "c32d24ad88305e1bf7aa138649ad8906e4f616605ef101f3b5088137676932e9"
    )
    #expect(first.descriptor == second.descriptor)
    #expect(first.document.artifact == first.descriptor)
    let authoritativeDescriptor = try LocalLibrary.describeWebPackage(
        at: first.packageURL
    )
    #expect(first.descriptor == authoritativeDescriptor)

    let alternatePage = AcquiredWebPage(
        sourceURL: try #require(
            URL(string: "https://other.invalid/same-content")
        ),
        html: page.html
    )
    let alternate = try await builder.build(
        alternatePage,
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: alternate.packageURL) }
    #expect(alternate.document.content.blocks.map(\.id) == firstBlockIDs)
    #expect(alternate.fingerprint == first.fingerprint)

    let indexHTML = try String(
        contentsOf: first.packageURL.appending(path: "index.html"),
        encoding: .utf8
    )
    let lowercaseHTML = indexHTML.lowercased()
    #expect(!lowercaseHTML.contains("<script"))
    #expect(!lowercaseHTML.contains("<form"))
    #expect(!lowercaseHTML.contains("http://"))
    #expect(!lowercaseHTML.contains("https://"))
    #expect(indexHTML.contains("Fixture Article"))
    #expect(indexHTML.contains("Deterministic offline content."))

    #expect(first.descriptor.kind == .webPackage)
    #expect(first.descriptor.byteCount > 0)
    #expect(
        first.descriptor.contentHash
            == "747e1df4697c6035a123ece5e7d80d5df1762f91970e2d388d60ca64cdcc64d4"
    )
}

@Test
func commentAndScriptArticleTextDoNotPreemptRealArticle() async throws {
    let html = """
    <!doctype html>
    <html><head><title>Scanner Fixture</title></head><body>
    <!-- <article><h1>Fake Comment</h1></article> -->
    <script>const template = "<article><h1>Fake Script</h1></article>";</script>
    <article>
      <h1>Real Article</h1>
      <p>Real content.</p>
    </article>
    </body></html>
    """
    let page = AcquiredWebPage(
        sourceURL: try #require(
            URL(string: "https://fixture.invalid/scanner")
        ),
        html: Data(html.utf8)
    )

    let product = try await StaticWebDocumentBuilder().build(
        page,
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: product.packageURL) }

    #expect(
        product.document.content.blocks.map(\.canonicalText)
            == ["Real Article", "Real content."]
    )
}

@Test
func nestedArticleDoesNotTruncateOuterArticle() async throws {
    let html = """
    <!doctype html>
    <html><head><title>Nested Fixture</title></head><body>
    <article>
      <h1>Outer Heading</h1>
      <article><h2>Nested Heading</h2></article>
      <p>Trailing paragraph.</p>
    </article>
    </body></html>
    """
    let page = AcquiredWebPage(
        sourceURL: try #require(
            URL(string: "https://fixture.invalid/nested")
        ),
        html: Data(html.utf8)
    )

    let product = try await StaticWebDocumentBuilder().build(
        page,
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: product.packageURL) }

    #expect(
        product.document.content.blocks.map(\.canonicalText)
            == ["Outer Heading", "Nested Heading", "Trailing paragraph."]
    )
}
