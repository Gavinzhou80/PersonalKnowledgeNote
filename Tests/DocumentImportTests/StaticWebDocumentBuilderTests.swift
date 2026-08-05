import Foundation
import KnowledgeCore
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
    #expect(first.fingerprint == second.fingerprint)
    #expect(first.descriptor == second.descriptor)
    #expect(first.document.artifact == first.descriptor)

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
    #expect(!first.descriptor.contentHash.isEmpty)
}
