import Foundation
import KnowledgeCore

enum StaticWebBuildError: Error, Equatable, Sendable {
    case unreadableHTML
    case missingArticle
    case noReadableBlocks
    case cannotWritePackage
}

struct StaticWebImportProduct: Sendable {
    let packageURL: URL
    let descriptor: SourceArtifactDescriptor
    let fingerprint: ContentFingerprint
    let document: SourceDocument
}

struct StaticWebDocumentBuilder: Sendable {
    func build(
        _ page: AcquiredWebPage,
        documentID: SourceDocumentID
    ) throws -> StaticWebImportProduct {
        guard let rawHTML = String(data: page.html, encoding: .utf8) else {
            throw StaticWebBuildError.unreadableHTML
        }
        let xmlDocument = try parseHTML(page.html)
        let article = try articleElement(from: rawHTML)

        let extractedBlocks = extractBlocks(from: article)
        guard !extractedBlocks.isEmpty else {
            throw StaticWebBuildError.noReadableBlocks
        }

        let title = try documentTitle(
            from: xmlDocument,
            fallback: extractedBlocks[0].text
        )
        let blocks = extractedBlocks.enumerated().map { index, extracted in
            SourceBlock(
                id: StableWebIdentity.blockID(
                    role: extracted.role,
                    ordinal: index + 1,
                    text: extracted.text
                ),
                canonicalText: extracted.text
            )
        }
        let blockIDs = blocks.map(\.id)
        let evidence = Dictionary(uniqueKeysWithValues: zip(
            blockIDs,
            extractedBlocks.map { SourceEvidence.web(locator: $0.locator) }
        ))
        let fingerprint = StableWebIdentity.fingerprint(
            blocks: extractedBlocks.map { ($0.role, $0.text) }
        )
        let packageContents = renderHTML(
            title: title,
            blocks: extractedBlocks
        )
        let descriptor = StableWebIdentity.packageDescriptor(
            relativePath: "index.html",
            contents: packageContents
        )
        let content = SourceDocumentContent(
            documentID: documentID,
            importedMetadata: ImportedDocumentMetadata(
                title: title,
                author: nil
            ),
            blocks: blocks,
            structure: SourceStructure(orderedBlockIDs: blockIDs),
            evidence: evidence
        )
        let document = SourceDocument(
            content: content,
            artifact: descriptor
        )
        let packageURL = try writePackage(contents: packageContents)

        return StaticWebImportProduct(
            packageURL: packageURL,
            descriptor: descriptor,
            fingerprint: fingerprint,
            document: document
        )
    }

    private func parseHTML(_ data: Data) throws -> XMLDocument {
        do {
            return try XMLDocument(data: data, options: .documentTidyHTML)
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }
    }

    private func articleElement(from rawHTML: String) throws -> XMLElement {
        guard let openingTag = rawHTML.range(
            of: #"<article\b[^>]*>"#,
            options: [.regularExpression, .caseInsensitive]
        ),
        let closingTag = rawHTML[openingTag.upperBound...].range(
            of: #"</article\s*>"#,
            options: [.regularExpression, .caseInsensitive]
        ) else {
            throw StaticWebBuildError.missingArticle
        }

        let innerHTML = rawHTML[openingTag.upperBound..<closingTag.lowerBound]
        let marker = "document-import-article"
        let wrappedHTML = """
        <html><body><div id="\(marker)">\(innerHTML)</div></body></html>
        """
        let articleDocument = try parseHTML(Data(wrappedHTML.utf8))
        do {
            guard let article = try articleDocument.nodes(
                forXPath: "//*[@id='\(marker)']"
            ).first as? XMLElement else {
                throw StaticWebBuildError.missingArticle
            }
            return article
        } catch let error as StaticWebBuildError {
            throw error
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }
    }

    private func extractBlocks(from article: XMLElement) -> [ExtractedBlock] {
        var tagOrdinals: [String: Int] = [:]
        var blocks: [ExtractedBlock] = []

        for case let element as XMLElement in article.children ?? [] {
            guard let rawName = element.name else {
                continue
            }
            let tag = rawName.lowercased()
            let tagOrdinal = tagOrdinals[tag, default: 0] + 1
            tagOrdinals[tag] = tagOrdinal

            let role: String
            if tag == "p" {
                role = "paragraph"
            } else if let level = headingLevel(for: tag) {
                role = "heading-\(level)"
            } else {
                continue
            }

            let text = normalized(element.stringValue ?? "")
            guard !text.isEmpty else {
                continue
            }
            blocks.append(ExtractedBlock(
                tag: tag,
                role: role,
                text: text,
                locator: "article > \(tag):nth-of-type(\(tagOrdinal))"
            ))
        }

        return blocks
    }

    private func documentTitle(
        from document: XMLDocument,
        fallback: String
    ) throws -> String {
        let titleNodes: [XMLNode]
        do {
            titleNodes = try document.nodes(forXPath: "//title")
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }
        let title = normalized(titleNodes.first?.stringValue ?? "")
        return title.isEmpty ? fallback : title
    }

    private func headingLevel(for tag: String) -> Int? {
        guard tag.count == 2,
              tag.first == "h",
              let level = tag.last?.wholeNumberValue,
              (1...6).contains(level)
        else {
            return nil
        }
        return level
    }

    private func normalized(_ text: String) -> String {
        text.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private func renderHTML(
        title: String,
        blocks: [ExtractedBlock]
    ) -> Data {
        let renderedBlocks = blocks.map {
            "<\($0.tag)>\(escaped($0.text))</\($0.tag)>"
        }.joined(separator: "\n")
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><title>\(escaped(title))</title></head><body><article>
        \(renderedBlocks)
        </article></body></html>
        """
        return Data(html.utf8)
    }

    private func escaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }

    private func writePackage(contents: Data) throws -> URL {
        let packageURL = FileManager.default.temporaryDirectory
            .appending(path: "StaticWebPackage-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(
                at: packageURL,
                withIntermediateDirectories: false
            )
            try contents.write(
                to: packageURL.appending(path: "index.html"),
                options: .atomic
            )
            return packageURL
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw StaticWebBuildError.cannotWritePackage
        }
    }
}

private struct ExtractedBlock {
    let tag: String
    let role: String
    let text: String
    let locator: String
}
