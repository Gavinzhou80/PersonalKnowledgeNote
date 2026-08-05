import Foundation

public struct ImportedDocumentMetadata:
    Hashable,
    Codable,
    Sendable
{
    public let title: String
    public let author: String?

    public init(title: String, author: String?) {
        self.title = title
        self.author = author
    }
}

public struct SourceBlock: Hashable, Codable, Sendable {
    public let id: SourceBlockID
    public let canonicalText: String

    public init(id: SourceBlockID, canonicalText: String) {
        precondition(!canonicalText.isEmpty)
        self.id = id
        self.canonicalText = canonicalText
    }
}

public struct SourceStructure: Hashable, Codable, Sendable {
    public let orderedBlockIDs: [SourceBlockID]

    public init(orderedBlockIDs: [SourceBlockID]) {
        self.orderedBlockIDs = orderedBlockIDs
    }
}

public struct SourceRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum SourceEvidence: Hashable, Codable, Sendable {
    case web(locator: String)
    case pdf(page: Int, region: SourceRect)
}

public struct SourceDocumentContent:
    Hashable,
    Codable,
    Sendable
{
    public let documentID: SourceDocumentID
    public let importedMetadata: ImportedDocumentMetadata
    public let blocks: [SourceBlock]
    public let structure: SourceStructure
    public let evidence: [SourceBlockID: SourceEvidence]

    public init(
        documentID: SourceDocumentID,
        importedMetadata: ImportedDocumentMetadata,
        blocks: [SourceBlock],
        structure: SourceStructure,
        evidence: [SourceBlockID: SourceEvidence]
    ) {
        precondition(!blocks.isEmpty)
        precondition(Set(blocks.map(\.id)) == Set(structure.orderedBlockIDs))
        precondition(Set(blocks.map(\.id)) == Set(evidence.keys))
        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
    }
}

public struct SourceDocument: Hashable, Codable, Sendable {
    public let content: SourceDocumentContent
    public let artifact: SourceArtifactDescriptor

    public init(
        content: SourceDocumentContent,
        artifact: SourceArtifactDescriptor
    ) {
        self.content = content
        self.artifact = artifact
    }
}
