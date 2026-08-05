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
        precondition(
            (try? Self.validate(canonicalText)) != nil,
            "SourceBlock canonicalText must not be empty"
        )
        self.id = id
        self.canonicalText = canonicalText
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(SourceBlockID.self, forKey: .id)
        let canonicalText = try container.decode(
            String.self,
            forKey: .canonicalText
        )

        do {
            try Self.validate(canonicalText)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceBlock canonicalText must not be empty",
                    underlyingError: error
                )
            )
        }

        self.id = id
        self.canonicalText = canonicalText
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalText
    }

    private enum ValidationError: Error {
        case emptyCanonicalText
    }

    private static func validate(_ canonicalText: String) throws {
        guard !canonicalText.isEmpty else {
            throw ValidationError.emptyCanonicalText
        }
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
        precondition(
            (try? Self.validate(
                blocks: blocks,
                structure: structure,
                evidence: evidence
            )) != nil,
            "SourceDocumentContent requires unique block IDs with exact structure and evidence coverage"
        )
        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let documentID = try container.decode(
            SourceDocumentID.self,
            forKey: .documentID
        )
        let importedMetadata = try container.decode(
            ImportedDocumentMetadata.self,
            forKey: .importedMetadata
        )
        let blocks = try container.decode(
            [SourceBlock].self,
            forKey: .blocks
        )
        let structure = try container.decode(
            SourceStructure.self,
            forKey: .structure
        )
        let evidence = try container.decode(
            [SourceBlockID: SourceEvidence].self,
            forKey: .evidence
        )

        do {
            try Self.validate(
                blocks: blocks,
                structure: structure,
                evidence: evidence
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceDocumentContent requires unique block IDs with exact structure and evidence coverage",
                    underlyingError: error
                )
            )
        }

        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
    }

    private enum CodingKeys: String, CodingKey {
        case documentID
        case importedMetadata
        case blocks
        case structure
        case evidence
    }

    private enum ValidationError: Error {
        case emptyBlocks
        case duplicateBlockIDs
        case duplicateOrderedBlockIDs
        case structureCountMismatch
        case evidenceCountMismatch
        case structureCoverageMismatch
        case evidenceCoverageMismatch
    }

    private static func validate(
        blocks: [SourceBlock],
        structure: SourceStructure,
        evidence: [SourceBlockID: SourceEvidence]
    ) throws {
        guard !blocks.isEmpty else {
            throw ValidationError.emptyBlocks
        }

        let blockIDs = blocks.map(\.id)
        let orderedBlockIDs = structure.orderedBlockIDs
        let blockIDSet = Set(blockIDs)
        let orderedBlockIDSet = Set(orderedBlockIDs)
        let evidenceBlockIDSet = Set(evidence.keys)

        guard blockIDSet.count == blockIDs.count else {
            throw ValidationError.duplicateBlockIDs
        }
        guard orderedBlockIDSet.count == orderedBlockIDs.count else {
            throw ValidationError.duplicateOrderedBlockIDs
        }
        guard blockIDs.count == orderedBlockIDs.count else {
            throw ValidationError.structureCountMismatch
        }
        guard blockIDs.count == evidence.count else {
            throw ValidationError.evidenceCountMismatch
        }
        guard blockIDSet == orderedBlockIDSet else {
            throw ValidationError.structureCoverageMismatch
        }
        guard blockIDSet == evidenceBlockIDSet else {
            throw ValidationError.evidenceCoverageMismatch
        }
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
