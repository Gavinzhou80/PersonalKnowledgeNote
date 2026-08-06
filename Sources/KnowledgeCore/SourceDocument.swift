import Foundation

public struct ImportedDocumentMetadata:
    Hashable,
    Codable,
    Sendable
{
    public let title: String
    public let author: String?
    public let publishedAt: Date?

    public init(
        title: String,
        author: String?,
        publishedAt: Date? = nil
    ) {
        self.title = title
        self.author = author
        self.publishedAt = publishedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.title = try container.decode(String.self, forKey: .title)
        self.author = try container.decodeIfPresent(String.self, forKey: .author)
        self.publishedAt = try container.decodeIfPresent(
            Date.self,
            forKey: .publishedAt
        )
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case author
        case publishedAt
    }
}

public struct SourceBlock: Hashable, Codable, Sendable {
    public let id: SourceBlockID
    public let canonicalText: String
    public let category: SourceBlockCategory
    public let role: SourceBlockRole
    public let inlineMarkup: [InlineMarkup]
    public let media: SourceMediaReference?

    public init(
        id: SourceBlockID,
        canonicalText: String,
        category: SourceBlockCategory = .text,
        role: SourceBlockRole = .paragraph,
        inlineMarkup: [InlineMarkup] = [],
        media: SourceMediaReference? = nil
    ) {
        precondition(
            (try? Self.validate(
                canonicalText: canonicalText,
                category: category,
                role: role,
                inlineMarkup: inlineMarkup,
                media: media
            )) != nil,
            "SourceBlock contains invalid semantic content"
        )
        self.id = id
        self.canonicalText = canonicalText
        self.category = category
        self.role = role
        self.inlineMarkup = inlineMarkup
        self.media = media
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let id = try container.decode(SourceBlockID.self, forKey: .id)
        let canonicalText = try container.decode(
            String.self,
            forKey: .canonicalText
        )
        let category = try container.decodeIfPresent(
            SourceBlockCategory.self,
            forKey: .category
        ) ?? .text
        let role = try container.decodeIfPresent(
            SourceBlockRole.self,
            forKey: .role
        ) ?? .paragraph
        let inlineMarkup = try container.decodeIfPresent(
            [InlineMarkup].self,
            forKey: .inlineMarkup
        ) ?? []
        let media = try container.decodeIfPresent(
            SourceMediaReference.self,
            forKey: .media
        )

        do {
            try Self.validate(
                canonicalText: canonicalText,
                category: category,
                role: role,
                inlineMarkup: inlineMarkup,
                media: media
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceBlock contains invalid semantic content",
                    underlyingError: error
                )
            )
        }

        self.id = id
        self.canonicalText = canonicalText
        self.category = category
        self.role = role
        self.inlineMarkup = inlineMarkup
        self.media = media
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case canonicalText
        case category
        case role
        case inlineMarkup
        case media
    }

    private enum ValidationError: Error {
        case emptyCanonicalText
        case invalidCategoryRole
        case invalidHeadingLevel
        case invalidMediaAssociation
        case invalidMarkupRange
        case unsafeMarkupURL
        case crossingMarkupRanges
    }

    private static func validate(
        canonicalText: String,
        category: SourceBlockCategory,
        role: SourceBlockRole,
        inlineMarkup: [InlineMarkup],
        media: SourceMediaReference?
    ) throws {
        guard !canonicalText.isEmpty else {
            throw ValidationError.emptyCanonicalText
        }

        switch (category, role) {
        case (.text, .heading(let level)):
            guard (1...6).contains(level) else {
                throw ValidationError.invalidHeadingLevel
            }
        case (.text, .paragraph),
             (.text, .listItem),
             (.text, .quotation),
             (.text, .caption),
             (.code, .codeBlock),
             (.media, .image):
            break
        default:
            throw ValidationError.invalidCategoryRole
        }

        switch category {
        case .media:
            guard media != nil else {
                throw ValidationError.invalidMediaAssociation
            }
        case .text, .code:
            guard media == nil else {
                throw ValidationError.invalidMediaAssociation
            }
        }

        let textLength = canonicalText.utf16.count
        for markup in inlineMarkup {
            let (rangeEnd, overflow) = markup.range.utf16Offset.addingReportingOverflow(
                markup.range.utf16Length
            )
            guard !overflow, rangeEnd <= textLength else {
                throw ValidationError.invalidMarkupRange
            }
            let utf16 = canonicalText.utf16
            let startUTF16Index = utf16.index(
                utf16.startIndex,
                offsetBy: markup.range.utf16Offset
            )
            let endUTF16Index = utf16.index(
                utf16.startIndex,
                offsetBy: rangeEnd
            )
            guard String.Index(startUTF16Index, within: canonicalText) != nil,
                  String.Index(endUTF16Index, within: canonicalText) != nil else {
                throw ValidationError.invalidMarkupRange
            }
            switch markup.kind {
            case .link(let url):
                guard isSafeInlineURL(url) else {
                    throw ValidationError.unsafeMarkupURL
                }
            case .citation(let url):
                guard url.map(isSafeInlineURL) ?? true else {
                    throw ValidationError.unsafeMarkupURL
                }
            case .emphasis, .strong, .inlineCode:
                break
            }
        }

        for firstIndex in inlineMarkup.indices {
            for secondIndex in inlineMarkup.index(after: firstIndex)..<inlineMarkup.endIndex {
                let first = inlineMarkup[firstIndex].range
                let second = inlineMarkup[secondIndex].range
                let firstEnd = first.utf16Offset + first.utf16Length
                let secondEnd = second.utf16Offset + second.utf16Length
                let crosses = (
                    first.utf16Offset < second.utf16Offset
                        && second.utf16Offset < firstEnd
                        && firstEnd < secondEnd
                ) || (
                    second.utf16Offset < first.utf16Offset
                        && first.utf16Offset < secondEnd
                        && secondEnd < firstEnd
                )
                guard !crosses else {
                    throw ValidationError.crossingMarkupRanges
                }
            }
        }
    }

    private static func isSafeInlineURL(_ url: URL) -> Bool {
        guard
            let scheme = url.scheme?.lowercased(),
            let host = url.host,
            !host.isEmpty
        else {
            return false
        }
        return scheme == "http" || scheme == "https"
    }
}

public struct SourceStructure: Hashable, Codable, Sendable {
    public let orderedBlockIDs: [SourceBlockID]
    public let relations: [SourceRelation]

    public init(
        orderedBlockIDs: [SourceBlockID],
        relations: [SourceRelation] = []
    ) {
        self.orderedBlockIDs = orderedBlockIDs
        self.relations = relations
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.orderedBlockIDs = try container.decode(
            [SourceBlockID].self,
            forKey: .orderedBlockIDs
        )
        self.relations = try container.decodeIfPresent(
            [SourceRelation].self,
            forKey: .relations
        ) ?? []
    }

    private enum CodingKeys: String, CodingKey {
        case orderedBlockIDs
        case relations
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
    public let issues: [ImportIssue]

    public init(
        documentID: SourceDocumentID,
        importedMetadata: ImportedDocumentMetadata,
        blocks: [SourceBlock],
        structure: SourceStructure,
        evidence: [SourceBlockID: SourceEvidence],
        issues: [ImportIssue] = []
    ) {
        precondition(
            (try? Self.validate(
                blocks: blocks,
                structure: structure,
                evidence: evidence,
                issues: issues
            )) != nil,
            "SourceDocumentContent contains an invalid document graph"
        )
        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
        self.issues = issues
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
        let issues = try container.decodeIfPresent(
            [ImportIssue].self,
            forKey: .issues
        ) ?? []

        do {
            try Self.validate(
                blocks: blocks,
                structure: structure,
                evidence: evidence,
                issues: issues
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceDocumentContent contains an invalid document graph",
                    underlyingError: error
                )
            )
        }

        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
        self.issues = issues
    }

    private enum CodingKeys: String, CodingKey {
        case documentID
        case importedMetadata
        case blocks
        case structure
        case evidence
        case issues
    }

    private enum ValidationError: Error {
        case emptyBlocks
        case duplicateBlockIDs
        case duplicateOrderedBlockIDs
        case structureCountMismatch
        case evidenceCountMismatch
        case structureCoverageMismatch
        case evidenceCoverageMismatch
        case relationEndpointMissing
        case invalidRelationSemantics
        case duplicateRelations
        case issueBlockMissing
    }

    private static func validate(
        blocks: [SourceBlock],
        structure: SourceStructure,
        evidence: [SourceBlockID: SourceEvidence],
        issues: [ImportIssue]
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
        guard Set(structure.relations).count == structure.relations.count else {
            throw ValidationError.duplicateRelations
        }
        guard structure.relations.allSatisfy({ relation in
            blockIDSet.contains(relation.sourceBlockID)
                && blockIDSet.contains(relation.targetBlockID)
        }) else {
            throw ValidationError.relationEndpointMissing
        }
        let blocksByID = Dictionary(uniqueKeysWithValues: blocks.map { ($0.id, $0) })
        guard structure.relations.allSatisfy({ relation in
            guard relation.sourceBlockID != relation.targetBlockID,
                  let source = blocksByID[relation.sourceBlockID],
                  let target = blocksByID[relation.targetBlockID]
            else {
                return false
            }

            switch relation.kind {
            case .captionForMedia:
                return source.category == .text
                    && source.role == .caption
                    && target.category == .media
                    && target.role == .image
            }
        }) else {
            throw ValidationError.invalidRelationSemantics
        }
        guard issues.allSatisfy({ issue in
            issue.relatedBlockID.map(blockIDSet.contains) ?? true
        }) else {
            throw ValidationError.issueBlockMissing
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
