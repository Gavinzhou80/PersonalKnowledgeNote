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
            sourceURL: page.finalURL,
            textEncodingName: page.textEncodingName
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
            let identifiedBlocks = article.blocks.enumerated().map {
                index, block in
                (
                    block: block,
                    id: StableWebIdentity.blockID(
                        category: block.category,
                        role: block.role,
                        ordinal: index + 1,
                        text: block.canonicalText
                    )
                )
            }
            let authoritativeBlocks = identifiedBlocks.filter { identified in
                let block = identified.block
                guard block.role == .image else { return true }
                if !block.canonicalText.isEmpty { return true }
                guard let imageKey = block.imageKey else { return false }
                return localized.mediaByCandidateKey[imageKey] != nil
            }
            let identities = authoritativeBlocks.map(\.id)
            let imageBlockIDs = Dictionary(uniqueKeysWithValues:
                authoritativeBlocks.compactMap { identified in
                    identified.block.imageKey.map { ($0, identified.id) }
                }
            )
            stageObserver(.buildRelations)
            let relations = authoritativeBlocks.compactMap {
                identified -> SourceRelation? in
                guard let targetKey = identified.block.relationTargetKey,
                      let imageID = imageBlockIDs[targetKey]
                else { return nil }
                return SourceRelation(
                    sourceBlockID: identified.id,
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
            let blocks = authoritativeBlocks.map { identified in
                let extracted = identified.block
                return SourceBlock(
                    id: identified.id,
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
                authoritativeBlocks.map {
                    ($0.id, SourceEvidence.web(locator: $0.block.evidenceLocator))
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
                blocks: authoritativeBlocks.map {
                    ($0.block.category, $0.block.role, $0.block.canonicalText)
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
