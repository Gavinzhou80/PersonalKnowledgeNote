import Foundation
import KnowledgeCore
import LocalLibrary

enum StaticWebBuildError: Error, Equatable, Sendable {
    case unreadableHTML
    case missingArticle
    case noReadableBlocks
    case cannotWritePackage
}

enum StaticWebBuildStage: Equatable, Sendable {
    case extract
    case localize
    case assignIdentities
    case buildRelations
    case render
    case describePackage
    case validateContent
}

struct StaticWebImportProduct: Sendable {
    let packageURL: URL
    let descriptor: SourceArtifactDescriptor
    let fingerprint: ContentFingerprint
    let document: SourceDocument
    var issues: [KnowledgeCore.ImportIssue] { document.content.issues }
}

struct StaticWebDocumentBuilder: Sendable {
    private let extractor: StaticArticleExtractor
    private let localizer: WebResourceLocalizer
    private let renderer: WebArtifactRenderer
    private let stageObserver: @Sendable (StaticWebBuildStage) -> Void

    init(
        extractor: StaticArticleExtractor = StaticArticleExtractor(),
        localizer: WebResourceLocalizer = WebResourceLocalizer(),
        renderer: WebArtifactRenderer = WebArtifactRenderer(),
        stageObserver: @escaping @Sendable (StaticWebBuildStage) -> Void = { _ in }
    ) {
        self.extractor = extractor
        self.localizer = localizer
        self.renderer = renderer
        self.stageObserver = stageObserver
    }

    func build(
        _ page: AcquiredWebPage,
        documentID: SourceDocumentID
    ) async throws -> StaticWebImportProduct {
        try Task.checkCancellation()
        stageObserver(.extract)
        let article = try extractor.extract(
            html: page.responseBytes,
            sourceURL: page.finalURL
        )
        let packageURL = try makePackage()
        do {
            stageObserver(.localize)
            let localized = try await localizer.localize(
                article.imageCandidates,
                into: packageURL
            )
            try Task.checkCancellation()
            stageObserver(.assignIdentities)
            let identities = article.blocks.enumerated().map { index, block in
                StableWebIdentity.blockID(
                    category: block.category,
                    role: block.role,
                    ordinal: index + 1,
                    text: block.canonicalText
                )
            }
            let imageBlockIDs = Dictionary(uniqueKeysWithValues:
                zip(article.blocks, identities).compactMap { block, id in
                    block.imageKey.map { ($0, id) }
                }
            )
            stageObserver(.buildRelations)
            let relations = zip(article.blocks, identities).compactMap {
                extracted, captionID -> SourceRelation? in
                guard let targetKey = extracted.relationTargetKey,
                      let imageID = imageBlockIDs[targetKey]
                else { return nil }
                return SourceRelation(
                    sourceBlockID: captionID,
                    targetBlockID: imageID,
                    kind: .captionForMedia
                )
            }
            stageObserver(.render)
            try renderer.render(
                article,
                localizedMedia: localized.mediaByCandidateKey,
                into: packageURL
            )
            stageObserver(.describePackage)
            let descriptor = try LocalLibrary.describeWebPackage(at: packageURL)
            stageObserver(.validateContent)
            let blocks = zip(article.blocks, identities).map { extracted, id in
                SourceBlock(
                    id: id,
                    canonicalText: extracted.canonicalText,
                    category: extracted.category,
                    role: extracted.role,
                    inlineMarkup: extracted.inlineMarkup,
                    media: extracted.imageKey.flatMap {
                        localized.mediaByCandidateKey[$0]
                    }
                )
            }
            let evidence = Dictionary(uniqueKeysWithValues:
                zip(article.blocks, identities).map {
                    ($1, SourceEvidence.web(locator: $0.evidenceLocator))
                }
            )
            let issues = localized.issues.map { issue in
                KnowledgeCore.ImportIssue(
                    code: issue.code,
                    relatedBlockID: imageBlockIDs[issue.candidateKey]
                )
            }
            let content = SourceDocumentContent(
                documentID: documentID,
                importedMetadata: article.metadata,
                blocks: blocks,
                structure: SourceStructure(
                    orderedBlockIDs: identities,
                    relations: relations
                ),
                evidence: evidence,
                issues: issues
            )
            let fingerprint = StableWebIdentity.fingerprint(
                blocks: article.blocks.map {
                    ($0.category, $0.role, $0.canonicalText)
                }
            )
            return StaticWebImportProduct(
                packageURL: packageURL,
                descriptor: descriptor,
                fingerprint: fingerprint,
                document: SourceDocument(content: content, artifact: descriptor)
            )
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    private func makePackage() throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appending(path: "StaticWebPackage-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: packageURL,
                withIntermediateDirectories: false
            )
            return packageURL
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw StaticWebBuildError.cannotWritePackage
        }
    }
}
