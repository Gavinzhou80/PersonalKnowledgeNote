import Foundation
import KnowledgeCore
import Testing

@Test
func identifiersRoundTripThroughCodable() throws {
    let original = ImportTaskID()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ImportTaskID.self, from: data)

    #expect(decoded == original)
}

@Test
func identicalTextAtDifferentPositionsKeepsDistinctBlockIdentity() {
    let first = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )
    let second = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )

    #expect(first.id != second.id)
    #expect(first.canonicalText == second.canonicalText)
}

@Test
func sourceDocumentContentIsReadableAndLocatable() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let content = SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [
            block.id: .web(locator: "article > p:nth-of-type(1)")
        ]
    )

    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: data
    )

    #expect(decoded == content)
}
