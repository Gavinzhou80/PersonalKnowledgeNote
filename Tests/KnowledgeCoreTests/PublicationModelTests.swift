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

@Test
func decodingRejectsEmptyContentFingerprint() throws {
    let data = try JSONEncoder().encode(
        UncheckedContentFingerprint(rawValue: "")
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ContentFingerprint.self, from: data)
    }
}

@Test
func decodingRejectsZeroByteArtifact() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: 0,
            contentHash: "hash"
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceArtifactDescriptor.self, from: data)
    }
}

@Test
func decodingRejectsArtifactWithEmptyContentHash() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceArtifactDescriptor(
            kind: .pdf,
            byteCount: 1,
            contentHash: ""
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceArtifactDescriptor.self, from: data)
    }
}

@Test
func decodingRejectsBlockWithEmptyCanonicalText() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceBlock(
            id: SourceBlockID(),
            canonicalText: ""
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceBlock.self, from: data)
    }
}

@Test
func decodingRejectsDocumentGraphWithoutEvidenceCoverage() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [block],
            structure: SourceStructure(orderedBlockIDs: [block.id]),
            evidence: [:]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

@Test
func decodingRejectsDuplicateBlockIDs() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [block, block],
            structure: SourceStructure(orderedBlockIDs: [block.id]),
            evidence: [block.id: .web(locator: "article > p")]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

@Test
func decodingRejectsDuplicateOrderedBlockIDs() throws {
    let first = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "First block"
    )
    let second = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Second block"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [first, second],
            structure: SourceStructure(
                orderedBlockIDs: [first.id, first.id]
            ),
            evidence: [
                first.id: .web(locator: "article > p:first-of-type"),
                second.id: .web(locator: "article > p:last-of-type")
            ]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

private struct UncheckedContentFingerprint: Encodable {
    let rawValue: String
}

private struct UncheckedSourceArtifactDescriptor: Encodable {
    let kind: SourceArtifactKind
    let byteCount: UInt64
    let contentHash: String
}

private struct UncheckedSourceBlock: Encodable {
    let id: SourceBlockID
    let canonicalText: String
}

private struct UncheckedSourceDocumentContent: Encodable {
    let documentID: SourceDocumentID
    let importedMetadata: ImportedDocumentMetadata
    let blocks: [SourceBlock]
    let structure: SourceStructure
    let evidence: [SourceBlockID: SourceEvidence]
}
