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
        guard let innerHTML = NarrowArticleScanner(rawHTML: rawHTML)
            .firstOuterArticleInnerHTML()
        else {
            throw StaticWebBuildError.missingArticle
        }

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

private struct NarrowArticleScanner {
    private struct Tag {
        let range: Range<Int>
        let nameRange: Range<Int>
        let isClosing: Bool
        let isSelfClosing: Bool
    }

    private struct Replacement {
        let range: Range<Int>
        let bytes: [UInt8]
    }

    private let bytes: [UInt8]

    init(rawHTML: String) {
        bytes = Array(rawHTML.utf8)
    }

    func firstOuterArticleInnerHTML() -> String? {
        var index = 0
        while index < bytes.count {
            guard bytes[index] == Self.lessThan else {
                index += 1
                continue
            }
            if startsComment(at: index) {
                index = endOfComment(startingAt: index)
                continue
            }
            guard let tag = tag(startingAt: index) else {
                index += 1
                continue
            }
            if isRawTextOpeningTag(tag) {
                index = endOfRawTextElement(openingTag: tag)
                continue
            }
            guard tagName(tag, equals: "article"),
                  !tag.isClosing,
                  !tag.isSelfClosing
            else {
                index = tag.range.upperBound
                continue
            }
            return balancedArticleInnerHTML(after: tag)
        }
        return nil
    }

    private func balancedArticleInnerHTML(after openingTag: Tag) -> String? {
        let innerStart = openingTag.range.upperBound
        var replacements: [Replacement] = []
        var depth = 1
        var index = innerStart

        while index < bytes.count {
            guard bytes[index] == Self.lessThan else {
                index += 1
                continue
            }
            if startsComment(at: index) {
                index = endOfComment(startingAt: index)
                continue
            }
            guard let tag = tag(startingAt: index) else {
                index += 1
                continue
            }
            if isRawTextOpeningTag(tag) {
                index = endOfRawTextElement(openingTag: tag)
                continue
            }
            guard tagName(tag, equals: "article") else {
                index = tag.range.upperBound
                continue
            }

            if tag.isClosing {
                if depth == 1 {
                    return string(
                        from: innerStart..<tag.range.lowerBound,
                        replacing: replacements
                    )
                }
                depth -= 1
                replacements.append(Replacement(
                    range: tag.range,
                    bytes: Array("</div>".utf8)
                ))
            } else if tag.isSelfClosing {
                replacements.append(Replacement(
                    range: tag.range,
                    bytes: Array("<div></div>".utf8)
                ))
            } else {
                depth += 1
                replacements.append(Replacement(
                    range: tag.range,
                    bytes: Array("<div>".utf8)
                ))
            }
            index = tag.range.upperBound
        }
        return nil
    }

    private func tag(startingAt start: Int) -> Tag? {
        var cursor = start + 1
        guard cursor < bytes.count else {
            return nil
        }

        let isClosing = bytes[cursor] == Self.slash
        if isClosing {
            cursor += 1
        }
        let nameStart = cursor
        guard cursor < bytes.count, Self.isASCIINameStart(bytes[cursor]) else {
            return nil
        }
        cursor += 1
        while cursor < bytes.count, Self.isASCIINameByte(bytes[cursor]) {
            cursor += 1
        }
        guard cursor < bytes.count, Self.isTagNameBoundary(bytes[cursor]),
              let tagEnd = tagEnd(startingAt: cursor)
        else {
            return nil
        }

        var beforeEnd = tagEnd - 2
        while beforeEnd > cursor, Self.isASCIIWhitespace(bytes[beforeEnd]) {
            beforeEnd -= 1
        }
        return Tag(
            range: start..<tagEnd,
            nameRange: nameStart..<cursor,
            isClosing: isClosing,
            isSelfClosing: !isClosing && bytes[beforeEnd] == Self.slash
        )
    }

    private func tagEnd(startingAt start: Int) -> Int? {
        var quote: UInt8?
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if byte == activeQuote {
                    quote = nil
                }
            } else if byte == Self.singleQuote || byte == Self.doubleQuote {
                quote = byte
            } else if byte == Self.greaterThan {
                return index + 1
            }
            index += 1
        }
        return nil
    }

    private func isRawTextOpeningTag(_ tag: Tag) -> Bool {
        !tag.isClosing
            && !tag.isSelfClosing
            && (tagName(tag, equals: "script")
                || tagName(tag, equals: "style"))
    }

    private func endOfRawTextElement(openingTag: Tag) -> Int {
        var index = openingTag.range.upperBound
        while index < bytes.count {
            guard bytes[index] == Self.lessThan,
                  let closingTag = tag(startingAt: index),
                  closingTag.isClosing,
                  tagName(
                    closingTag,
                    equals: string(for: openingTag.nameRange)
                  )
            else {
                index += 1
                continue
            }
            return closingTag.range.upperBound
        }
        return bytes.count
    }

    private func startsComment(at index: Int) -> Bool {
        let marker = Array("<!--".utf8)
        guard index <= bytes.count - marker.count else {
            return false
        }
        return bytes[index..<(index + marker.count)].elementsEqual(marker)
    }

    private func endOfComment(startingAt start: Int) -> Int {
        let marker = Array("-->".utf8)
        var index = start + 4
        while index <= bytes.count - marker.count {
            if bytes[index..<(index + marker.count)].elementsEqual(marker) {
                return index + marker.count
            }
            index += 1
        }
        return bytes.count
    }

    private func tagName(_ tag: Tag, equals expected: String) -> Bool {
        let expectedBytes = Array(expected.utf8)
        let name = bytes[tag.nameRange]
        guard name.count == expectedBytes.count else {
            return false
        }
        return zip(name, expectedBytes).allSatisfy {
            Self.asciiLowercased($0) == Self.asciiLowercased($1)
        }
    }

    private func string(for range: Range<Int>) -> String {
        String(decoding: bytes[range], as: UTF8.self)
    }

    private func string(
        from range: Range<Int>,
        replacing replacements: [Replacement]
    ) -> String {
        var result: [UInt8] = []
        var cursor = range.lowerBound
        for replacement in replacements {
            result.append(contentsOf: bytes[cursor..<replacement.range.lowerBound])
            result.append(contentsOf: replacement.bytes)
            cursor = replacement.range.upperBound
        }
        result.append(contentsOf: bytes[cursor..<range.upperBound])
        return String(decoding: result, as: UTF8.self)
    }

    private static func isASCIINameStart(_ byte: UInt8) -> Bool {
        (65...90).contains(byte) || (97...122).contains(byte)
    }

    private static func isASCIINameByte(_ byte: UInt8) -> Bool {
        isASCIINameStart(byte)
            || (48...57).contains(byte)
            || byte == 45
            || byte == 58
    }

    private static func isTagNameBoundary(_ byte: UInt8) -> Bool {
        isASCIIWhitespace(byte) || byte == slash || byte == greaterThan
    }

    private static func isASCIIWhitespace(_ byte: UInt8) -> Bool {
        byte == 9 || byte == 10 || byte == 12 || byte == 13 || byte == 32
    }

    private static func asciiLowercased(_ byte: UInt8) -> UInt8 {
        (65...90).contains(byte) ? byte + 32 : byte
    }

    private static let lessThan: UInt8 = 60
    private static let greaterThan: UInt8 = 62
    private static let slash: UInt8 = 47
    private static let singleQuote: UInt8 = 39
    private static let doubleQuote: UInt8 = 34
}
