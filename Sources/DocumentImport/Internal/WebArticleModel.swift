import Foundation
import KnowledgeCore

struct ExtractedWebArticle: Sendable {
    let metadata: ImportedDocumentMetadata
    let blocks: [ExtractedWebBlock]
    let rootSelector: String
    let imageCandidates: [WebImageCandidate]
}

struct ExtractedWebBlock: Sendable {
    let category: SourceBlockCategory
    let role: SourceBlockRole
    let canonicalText: String
    let inlineMarkup: [InlineMarkup]
    let evidenceLocator: String
    let imageKey: String?
    let relationTargetKey: String?
}

struct WebImageCandidate: Sendable {
    let stableKey: String
    let resolvedURL: URL
    let altText: String?
    let evidenceLocator: String
}
