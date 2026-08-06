import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

@Test
func staticFixtureBuildsDeterministicManagedWebContent() throws {
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

    let first = try builder.build(page, documentID: documentID)
    defer { try? FileManager.default.removeItem(at: first.packageURL) }
    let second = try builder.build(page, documentID: documentID)
    defer { try? FileManager.default.removeItem(at: second.packageURL) }

    let firstContent = first.document.content
    let firstBlockIDs = firstContent.blocks.map(\.id)
    let secondBlockIDs = second.document.content.blocks.map(\.id)
    let expectedBlockIDs = [
        SourceBlockID(try #require(
            UUID(uuidString: "d3b501a8-7190-5456-0179-7fc7ed5631c9")
        )),
        SourceBlockID(try #require(
            UUID(uuidString: "0ac1613a-4e71-300b-c635-7731932ff4f7")
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
            == .web(locator: "article > h1:nth-of-type(1)")
    )
    #expect(
        firstContent.evidence[firstBlockIDs[1]]
            == .web(locator: "article > p:nth-of-type(1)")
    )

    #expect(firstBlockIDs == secondBlockIDs)
    #expect(firstBlockIDs == expectedBlockIDs)
    #expect(first.fingerprint == second.fingerprint)
    #expect(
        first.fingerprint.rawValue
            == "fde62afd563a9f9cebed8bd15029dc235cb16fe9845e5f6f23e6c2ed1a9a44ce"
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
    let alternate = try builder.build(
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
    #expect(!lowercaseHTML.contains("script"))
    #expect(!lowercaseHTML.contains("form"))
    #expect(!lowercaseHTML.contains("http://"))
    #expect(!lowercaseHTML.contains("https://"))
    #expect(indexHTML.contains("Fixture Article"))
    #expect(indexHTML.contains("Deterministic offline content."))

    #expect(first.descriptor.kind == .webPackage)
    #expect(first.descriptor.byteCount > 0)
    #expect(
        first.descriptor.contentHash
            == "70a0a521c9aca0b27099f0393f0b9bdf8b297d3ab7e44641487fdc218b33630e"
    )
}

@Test
func commentAndScriptArticleTextDoNotPreemptRealArticle() throws {
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

    let product = try StaticWebDocumentBuilder().build(
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
func nestedArticleDoesNotTruncateOuterArticle() throws {
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

    let product = try StaticWebDocumentBuilder().build(
        page,
        documentID: SourceDocumentID()
    )
    defer { try? FileManager.default.removeItem(at: product.packageURL) }

    #expect(
        product.document.content.blocks.map(\.canonicalText)
            == ["Outer Heading", "Trailing paragraph."]
    )
}
