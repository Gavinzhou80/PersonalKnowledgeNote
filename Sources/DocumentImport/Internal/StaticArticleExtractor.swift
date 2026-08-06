import CoreFoundation
import Foundation
import KnowledgeCore
import SwiftSoup

struct EvidenceExtractionMetrics: Sendable {
    var documentPasses = 0
    var indexedElementCount = 0
    var ordinalComputations = 0
}

struct StaticArticleExtractor: Sendable {
    func extract(
        html: Data,
        sourceURL: URL,
        textEncodingName: String? = nil
    ) throws -> ExtractedWebArticle {
        try extractWithMetrics(
            html: html,
            sourceURL: sourceURL,
            textEncodingName: textEncodingName
        ).article
    }

    func extractWithMetrics(
        html: Data,
        sourceURL: URL,
        textEncodingName: String? = nil
    ) throws -> (article: ExtractedWebArticle, metrics: EvidenceExtractionMetrics) {
        var metrics = EvidenceExtractionMetrics()
        let article = try extractArticle(
            html: html,
            sourceURL: sourceURL,
            textEncodingName: textEncodingName,
            metrics: &metrics
        )
        return (article, metrics)
    }

    private func extractArticle(
        html: Data,
        sourceURL: URL,
        textEncodingName: String?,
        metrics: inout EvidenceExtractionMetrics
    ) throws -> ExtractedWebArticle {
        guard let source = decodeHTML(
            html,
            persistedCharset: textEncodingName
        ) else {
            throw StaticWebBuildError.unreadableHTML
        }
        let document: Document
        do {
            document = try SwiftSoup.parse(source, sourceURL.absoluteString)
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }
        let resolutionBase = try effectiveDocumentBase(
            in: document,
            sourceURL: sourceURL
        )
        guard let originalRoot = try readableRoot(in: document) else {
            throw StaticWebBuildError.noReadableBlocks
        }
        let structured = try structuredMetadata(in: document)
        let evidenceIndex = try buildEvidenceIndex(
            in: document,
            metrics: &metrics
        )
        let idCounts = evidenceIndex.idCounts
        let originalRootSelector = try uniqueSelector(
            for: originalRoot,
            evidenceIndex: evidenceIndex
        )
        let fragment = try SwiftSoup.parseBodyFragment(
            try originalRoot.outerHtml(),
            resolutionBase.absoluteString
        )
        guard let root = fragment.body()?.children().first() else {
            throw StaticWebBuildError.noReadableBlocks
        }
        try captureOriginalEvidence(
            originalRoot: originalRoot,
            clonedRoot: root,
            idCounts: idCounts,
            rootSelector: originalRootSelector,
            evidenceIndex: evidenceIndex
        )
        try clean(root)
        let rootSelector = originalRootSelector
        var images: [WebImageCandidate] = []
        var blocks: [ExtractedWebBlock] = []
        try walk(root, root: root, sourceURL: resolutionBase, idCounts: idCounts, images: &images, blocks: &blocks)
        guard !blocks.isEmpty else { throw StaticWebBuildError.noReadableBlocks }

        let title = try metadataContent(document, selector: "meta[property=og:title]", attribute: "content")
            ?? structured.title
            ?? normalized(try document.title())
        let fallbackTitle = blocks.first(where: {
            if case .heading = $0.role { return true }
            return false
        })?.canonicalText ?? blocks[0].canonicalText
        let author = try metadataContent(document, selector: "meta[name=author]", attribute: "content")
            ?? metadataContent(document, selector: "meta[property=article:author]", attribute: "content")
            ?? structured.author
        let dateText = try metadataContent(document, selector: "meta[property=article:published_time]", attribute: "content")
            ?? structured.publishedAt
            ?? document.select("time[datetime]").first()?.attr("datetime")
        return ExtractedWebArticle(
            metadata: ImportedDocumentMetadata(
                title: title.isEmpty ? fallbackTitle : title,
                author: author,
                publishedAt: dateText.flatMap { ISO8601DateFormatter().date(from: $0) }
            ),
            blocks: blocks,
            rootSelector: rootSelector,
            imageCandidates: images
        )
    }

    private func decodeHTML(
        _ data: Data,
        persistedCharset: String?
    ) -> String? {
        if let encoding = stringEncoding(for: persistedCharset),
           let decoded = String(data: data, encoding: encoding) {
            return decoded
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return decoded
        }
        for charset in html5MetaCharsets(in: data) {
            guard let encoding = stringEncoding(for: charset),
                  let decoded = String(data: data, encoding: encoding)
            else {
                continue
            }
            return decoded
        }
        return nil
    }

    private func html5MetaCharsets(in data: Data) -> [String] {
        var charsets: [String] = []
        for tag in html5MetaStartTags(in: data) {
            let attributes = metaAttributes(in: tag)
            if let charset = attributes["charset"] {
                charsets.append(charset)
                continue
            }
            guard attributes["http-equiv"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "content-type",
                  let content = attributes["content"],
                  let charset = pragmaCharset(in: content)
            else {
                continue
            }
            charsets.append(charset)
        }
        return charsets
    }

    private func html5MetaStartTags(in data: Data) -> [String] {
        let bytes = Array(data.prefix(1_024))
        var tags: [String] = []
        var index = 0
        while index < bytes.count {
            guard bytes[index] == UInt8(ascii: "<") else {
                index += 1
                continue
            }
            if bytesMatch("<!--", in: bytes, at: index) {
                guard let commentEnd = firstIndex(
                    of: "-->",
                    in: bytes,
                    startingAt: index + 4
                ) else {
                    break
                }
                index = commentEnd + 3
                continue
            }
            let nameStart = index + 1
            let delimiterIndex = nameStart + 4
            guard bytesMatchIgnoringASCIICase(
                "meta",
                in: bytes,
                at: nameStart
            ), delimiterIndex < bytes.count,
               isHTMLTagNameDelimiter(bytes[delimiterIndex]),
               let tagEnd = htmlTagEnd(in: bytes, startingAt: delimiterIndex)
            else {
                index += 1
                continue
            }
            let asciiBytes = bytes[index...tagEnd].map { byte in
                byte < 0x80 ? byte : UInt8(ascii: " ")
            }
            tags.append(String(decoding: asciiBytes, as: UTF8.self))
            index = tagEnd + 1
        }
        return tags
    }

    private func htmlTagEnd(
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Int? {
        var quote: UInt8?
        var index = start
        while index < bytes.count {
            let byte = bytes[index]
            if let activeQuote = quote {
                if byte == activeQuote {
                    quote = nil
                }
            } else if byte == UInt8(ascii: "\"")
                        || byte == UInt8(ascii: "'") {
                quote = byte
            } else if byte == UInt8(ascii: ">") {
                return index
            }
            index += 1
        }
        return nil
    }

    private func isHTMLTagNameDelimiter(_ byte: UInt8) -> Bool {
        byte == UInt8(ascii: "/")
            || byte == UInt8(ascii: ">")
            || [0x09, 0x0A, 0x0C, 0x0D, 0x20].contains(byte)
    }

    private func bytesMatch(
        _ literal: StaticString,
        in bytes: [UInt8],
        at index: Int
    ) -> Bool {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count else { return false }
        return bytes[index..<(index + expected.count)].elementsEqual(expected)
    }

    private func bytesMatchIgnoringASCIICase(
        _ literal: StaticString,
        in bytes: [UInt8],
        at index: Int
    ) -> Bool {
        let expected = Array(String(describing: literal).utf8)
        guard index + expected.count <= bytes.count else { return false }
        return zip(bytes[index..<(index + expected.count)], expected)
            .allSatisfy { asciiLowercased($0.0) == asciiLowercased($0.1) }
    }

    private func firstIndex(
        of literal: StaticString,
        in bytes: [UInt8],
        startingAt start: Int
    ) -> Int? {
        var index = start
        while index < bytes.count {
            if bytesMatch(literal, in: bytes, at: index) {
                return index
            }
            index += 1
        }
        return nil
    }

    private func asciiLowercased(_ byte: UInt8) -> UInt8 {
        guard (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte)
        else {
            return byte
        }
        return byte + (UInt8(ascii: "a") - UInt8(ascii: "A"))
    }

    private func metaAttributes(in tag: String) -> [String: String] {
        guard let expression = try? NSRegularExpression(
            pattern: #"([a-z_:][a-z0-9_.:-]*)\s*(?:=\s*(?:\"([^\"]*)\"|'([^']*)'|([^\s\"'=<>`]+)))?"#,
            options: [.caseInsensitive]
        ) else {
            return [:]
        }
        let source = tag as NSString
        let range = NSRange(location: 0, length: source.length)
        var attributes: [String: String] = [:]
        for match in expression.matches(in: tag, range: range) {
            guard match.numberOfRanges == 5 else { continue }
            let name = source.substring(with: match.range(at: 1)).lowercased()
            guard name != "meta", attributes[name] == nil else { continue }
            let valueRange = (2...4)
                .map { match.range(at: $0) }
                .first { $0.location != NSNotFound }
            attributes[name] = valueRange.map(source.substring(with:)) ?? ""
        }
        return attributes
    }

    private func pragmaCharset(in content: String) -> String? {
        for parameter in content.split(separator: ";", omittingEmptySubsequences: false) {
            let parts = parameter.split(
                separator: "=",
                maxSplits: 1,
                omittingEmptySubsequences: false
            )
            guard parts.count == 2,
                  parts[0].trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased() == "charset"
            else {
                continue
            }
            return parts[1]
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
        }
        return nil
    }

    private func stringEncoding(for charset: String?) -> String.Encoding? {
        guard let normalized = normalizedWebCharsetName(charset)?
            .replacingOccurrences(of: "_", with: "-")
        else {
            return nil
        }
        switch normalized {
        case "utf-8", "utf8":
            return .utf8
        case "utf-16", "utf16":
            return .utf16
        case "utf-16le", "utf16le":
            return .utf16LittleEndian
        case "utf-16be", "utf16be":
            return .utf16BigEndian
        case "iso-8859-1", "iso8859-1", "latin1", "latin-1":
            return .isoLatin1
        case "windows-1252", "cp1252":
            return .windowsCP1252
        case "shift-jis", "shiftjis", "sjis", "ms-kanji", "csshiftjis":
            return .shiftJIS
        case "euc-jp", "eucjp", "cseucpkdfmtjapanese":
            return .japaneseEUC
        case "gb18030", "gbk", "cp936":
            let coreFoundationName = normalized as CFString
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(
                coreFoundationName
            )
            guard cfEncoding != kCFStringEncodingInvalidId else {
                return nil
            }
            return String.Encoding(
                rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding)
            )
        default:
            return nil
        }
    }

    private func readableRoot(in document: Document) throws -> Element? {
        guard let body = document.body() else { return nil }
        for selector in ["article", "main"] {
            let candidates = try document.select(selector).array().filter {
                !shouldRemoveSubtree($0) && !hasNoiseAncestor($0, stopAt: body)
            }
            if let best = try candidates.max(by: { try score($0) < score($1) }), try score(best) > 0 {
                return best
            }
        }
        let candidates = try body.select("[role=main],section,div").array().filter {
            !shouldRemoveSubtree($0) && !hasNoiseAncestor($0, stopAt: body)
        }
        if let best = try candidates.max(by: { try score($0) < score($1) }), try score(best) > 0 {
            return best
        }
        return nil
    }

    private func effectiveDocumentBase(
        in document: Document,
        sourceURL: URL
    ) throws -> URL {
        guard let value = try document.select("base[href]").first()?.attr("href") else {
            return sourceURL
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let base = URL(string: trimmed, relativeTo: sourceURL)?.absoluteURL,
              ["http", "https"].contains(base.scheme?.lowercased() ?? ""),
              base.host != nil else {
            return sourceURL
        }
        return base
    }

    private func score(_ element: Element) throws -> Int {
        let semantic = try element
            .select("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figure,img,figcaption")
            .array()
            .filter { isReadableForScoring($0, root: element) }
            .count
        let standaloneCode = try element.select("code").array().filter { code in
            guard isReadableForScoring(code, root: element) else { return false }
            var parent = code.parent()
            while let current = parent, current !== element {
                if ["p", "pre"].contains(current.tagName().lowercased()) { return false }
                parent = current.parent()
            }
            return code.parent()?.tagName().lowercased() != "pre"
        }.count
        return semantic + standaloneCode
    }

    private func clean(_ root: Element) throws {
        try root.select("script,style,noscript,template,form,nav,iframe,[hidden],[aria-hidden=true],[role=navigation],[role=banner],[role=complementary],[role=contentinfo],[role=form],[role=search]").remove()
        for element in try root.getAllElements().array() {
            if element !== root, isNoise(element) || isTrackingPixel(element) {
                try element.remove()
                continue
            }
            for attribute in element.getAttributes()?.asList() ?? [] {
                let name = attribute.getKey().lowercased()
                let value = attribute.getValue().trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
                if name.hasPrefix("on") || (["href", "src", "cite"].contains(name) && (value.hasPrefix("javascript:") || value.hasPrefix("data:"))) {
                    _ = try element.removeAttr(attribute.getKey())
                }
            }
        }
    }

    private func isReadableForScoring(_ element: Element, root: Element) -> Bool {
        var current: Element? = element
        while let node = current, node !== root {
            if shouldRemoveSubtree(node) { return false }
            current = node.parent()
        }
        return true
    }

    private func shouldRemoveSubtree(_ element: Element) -> Bool {
        let tag = element.tagName().lowercased()
        if ["script", "style", "noscript", "template", "form", "nav", "iframe"].contains(tag) {
            return true
        }
        if element.hasAttr("hidden") { return true }
        if ((try? element.attr("aria-hidden")) ?? "").lowercased() == "true" { return true }
        let role = ((try? element.attr("role")) ?? "").lowercased()
        if ["navigation", "banner", "complementary", "contentinfo", "form", "search"].contains(role) {
            return true
        }
        return isNoise(element) || isTrackingPixel(element)
    }

    private func isNoise(_ element: Element) -> Bool {
        let tag = element.tagName().lowercased()
        if ["nav", "form"].contains(tag) { return true }
        if tag == "aside", (try? element.select("figure,blockquote").isEmpty()) != false { return true }
        let role = ((try? element.attr("role")) ?? "").lowercased()
        if ["navigation", "banner", "complementary", "contentinfo", "form", "search"].contains(role) { return true }
        let value = element.id() + " " + ((try? element.className()) ?? "") + " " + role
        let tokens = ["ad", "advertisement", "recommend", "related", "share", "social", "subscribe", "newsletter", "cookie", "tracker", "promo"]
        let lower = value.lowercased()
        return tokens.contains { token in
            lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(token))
                || (token.count > 3 && lower.contains(token))
        }
    }

    private func hasNoiseAncestor(_ element: Element, stopAt root: Element) -> Bool {
        var parent = element.parent()
        while let current = parent, current !== root {
            if shouldRemoveSubtree(current) { return true }
            parent = current.parent()
        }
        return false
    }

    private func isTrackingPixel(_ element: Element) -> Bool {
        guard element.tagName() == "img" else { return false }
        let width = try? element.attr("width")
        let height = try? element.attr("height")
        return width == "1" && height == "1"
    }

    private func walk(
        _ element: Element,
        root: Element,
        sourceURL: URL,
        idCounts: [String: Int],
        images: inout [WebImageCandidate],
        blocks: inout [ExtractedWebBlock]
    ) throws {
        let tag = element.tagName().lowercased()
        if let level = headingLevel(tag) {
            appendTextBlock(element, root: root, idCounts: idCounts, category: .text, role: .heading(level: level), blocks: &blocks)
            return
        }
        switch tag {
        case "p": appendTextBlock(element, root: root, idCounts: idCounts, category: .text, role: .paragraph, blocks: &blocks); return
        case "li":
            appendTextBlock(
                element,
                root: root,
                idCounts: idCounts,
                category: .text,
                role: .listItem,
                excludingNestedLists: true,
                blocks: &blocks
            )
            try walkNestedLists(
                in: element,
                root: root,
                sourceURL: sourceURL,
                idCounts: idCounts,
                images: &images,
                blocks: &blocks
            )
            return
        case "blockquote": appendTextBlock(element, root: root, idCounts: idCounts, category: .text, role: .quotation, blocks: &blocks); return
        case "pre":
            let code = try element.select("code").first()
            let text = normalizeCode(rawText(code ?? element))
            if !text.isEmpty {
                let language = code.flatMap { languageName((try? $0.className()) ?? "") }
                blocks.append(.init(category: .code, role: .codeBlock(language: language), canonicalText: text, inlineMarkup: [], evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: nil))
            }
            return
        case "code":
            let text = normalizeCode(rawText(element))
            if !text.isEmpty {
                blocks.append(.init(category: .code, role: .codeBlock(language: languageName((try? element.className()) ?? "")), canonicalText: text, inlineMarkup: [], evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: nil))
            }
            return
        case "figure":
            let figureImageKey = try element.select("img").array().lazy.compactMap { image -> String? in
                imageKey(
                    for: image,
                    root: root,
                    sourceURL: sourceURL,
                    idCounts: idCounts
                )
            }.first
            try walkFigureChildren(element, root: root, sourceURL: sourceURL, idCounts: idCounts, targetKey: figureImageKey, images: &images, blocks: &blocks)
            return
        case "img":
            _ = appendImage(element, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
            return
        case "figcaption":
            appendCaption(element, root: root, idCounts: idCounts, targetKey: nil, blocks: &blocks)
            return
        default: break
        }
        for child in element.children().array() {
            try walk(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
        }
    }

    private func walkNestedLists(
        in container: Element,
        root: Element,
        sourceURL: URL,
        idCounts: [String: Int],
        images: inout [WebImageCandidate],
        blocks: inout [ExtractedWebBlock]
    ) throws {
        for child in container.children().array() {
            let tag = child.tagName().lowercased()
            if ["ul", "ol"].contains(tag) {
                try walk(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
            } else if tag != "li" {
                try walkNestedLists(in: child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
            }
        }
    }

    private func walkFigureChildren(
        _ container: Element,
        root: Element,
        sourceURL: URL,
        idCounts: [String: Int],
        targetKey: String?,
        images: inout [WebImageCandidate],
        blocks: inout [ExtractedWebBlock]
    ) throws {
        for child in container.children().array() {
            switch child.tagName().lowercased() {
            case "img":
                _ = appendImage(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
            case "figcaption":
                appendCaption(child, root: root, idCounts: idCounts, targetKey: targetKey, blocks: &blocks)
            case "figure":
                try walk(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
            default:
                try walkFigureChildren(child, root: root, sourceURL: sourceURL, idCounts: idCounts, targetKey: targetKey, images: &images, blocks: &blocks)
            }
        }
    }

    @discardableResult
    private func appendImage(_ element: Element, root: Element, sourceURL: URL, idCounts: [String: Int], images: inout [WebImageCandidate], blocks: inout [ExtractedWebBlock]) -> String? {
        guard let source = try? element.attr("src"),
              let url = safeURL(source, relativeTo: sourceURL),
              let key = imageKey(
                for: element,
                root: root,
                sourceURL: sourceURL,
                idCounts: idCounts
              )
        else { return nil }
        let locator = evidence(element, root: root, idCounts: idCounts)
        let alt = normalized((try? element.attr("alt")) ?? "")
        images.append(.init(stableKey: key, resolvedURL: url, altText: alt.isEmpty ? nil : alt, evidenceLocator: locator))
        blocks.append(.init(category: .media, role: .image, canonicalText: alt, inlineMarkup: [], evidenceLocator: locator, imageKey: key, relationTargetKey: nil))
        return key
    }

    private func imageKey(
        for element: Element,
        root: Element,
        sourceURL: URL,
        idCounts: [String: Int]
    ) -> String? {
        guard let source = try? element.attr("src"),
              let url = safeURL(source, relativeTo: sourceURL)
        else { return nil }
        return "image:\(evidence(element, root: root, idCounts: idCounts)):\(url.absoluteString)"
    }

    private func appendCaption(_ element: Element, root: Element, idCounts: [String: Int], targetKey: String?, blocks: inout [ExtractedWebBlock]) {
        let rendered = inlineText(element)
        guard !rendered.text.isEmpty else { return }
        blocks.append(.init(category: .text, role: .caption, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: targetKey))
    }

    private func appendTextBlock(_ element: Element, root: Element, idCounts: [String: Int], category: SourceBlockCategory, role: SourceBlockRole, excludingNestedLists: Bool = false, blocks: inout [ExtractedWebBlock]) {
        let rendered = inlineText(
            element,
            excludingNestedLists: excludingNestedLists
        )
        guard !rendered.text.isEmpty else { return }
        blocks.append(.init(category: category, role: role, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: nil))
    }

    private func inlineText(_ element: Element, excludingNestedLists: Bool = false) -> (text: String, markup: [InlineMarkup]) {
        var builder = InlineBuilder(
            baseURL: URL(string: element.getBaseUri()),
            excludesNestedLists: excludingNestedLists
        )
        builder.visit(element, isRoot: true)
        return (builder.text, builder.markup)
    }

    private func evidence(
        _ element: Element,
        root _: Element,
        idCounts _: [String: Int]
    ) -> String {
        guard let original = try? element.attr(Self.originalEvidenceAttribute),
              !original.isEmpty else {
            preconditionFailure("Missing original evidence on retained element")
        }
        return original
    }

    private func metadataContent(_ document: Document, selector: String, attribute: String) throws -> String? {
        guard let value = try document.select(selector).first()?.attr(attribute) else { return nil }
        let result = normalized(value)
        return result.isEmpty ? nil : result
    }

    private func structuredMetadata(in document: Document) throws -> StructuredMetadata {
        for script in try document.select("script[type=application/ld+json]").array() {
            let source = try script.html()
            guard let data = source.data(using: .utf8),
                  let json = try? JSONSerialization.jsonObject(with: data) else { continue }
            let objects: [[String: Any]]
            if let object = json as? [String: Any], let graph = object["@graph"] as? [[String: Any]] {
                objects = graph
            } else if let object = json as? [String: Any] {
                objects = [object]
            } else {
                continue
            }
            let object = objects.first(where: { dictionary in
                let type = dictionary["@type"] as? String
                return type?.lowercased().contains("article") == true
            }) ?? objects.first
            guard let object else { continue }
            let title = stringValue(object["headline"]) ?? stringValue(object["name"])
            let author = authorName(object["author"])
            let date = stringValue(object["datePublished"])
            if title != nil || author != nil || date != nil {
                return StructuredMetadata(title: title, author: author, publishedAt: date)
            }
        }
        return StructuredMetadata(title: nil, author: nil, publishedAt: nil)
    }

    private func authorName(_ value: Any?) -> String? {
        if let string = stringValue(value) { return string }
        if let object = value as? [String: Any] { return stringValue(object["name"]) }
        if let array = value as? [Any] {
            return array.lazy.compactMap(authorName).first
        }
        return nil
    }

    private func stringValue(_ value: Any?) -> String? {
        guard let string = value as? String else { return nil }
        let result = normalized(string)
        return result.isEmpty ? nil : result
    }

    private func safeURL(_ value: String, relativeTo base: URL) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else { return nil }
        return url
    }

    private func languageName(_ classes: String) -> String? {
        classes.split(separator: " ").first(where: { $0.hasPrefix("language-") }).map { String($0.dropFirst(9)) }
    }

    private func headingLevel(_ tag: String) -> Int? {
        guard tag.count == 2, tag.first == "h", let level = tag.last?.wholeNumberValue, (1...6).contains(level) else { return nil }
        return level
    }

    private func normalized(_ value: String) -> String {
        value.split(whereSeparator: \ .isWhitespace).joined(separator: " ")
    }

    private func normalizeCode(_ value: String) -> String {
        var lines = value.replacingOccurrences(of: "\r\n", with: "\n").split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.first?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeFirst() }
        while lines.last?.trimmingCharacters(in: .whitespaces).isEmpty == true { lines.removeLast() }
        let indents = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { $0.prefix { $0 == " " || $0 == "\t" }.count }
        let common = indents.min() ?? 0
        return lines.map { String($0.dropFirst(min(common, $0.count))) }.joined(separator: "\n")
    }

    private func rawText(_ node: Node) -> String {
        if let text = node as? TextNode { return text.getWholeText() }
        return node.getChildNodes().map(rawText).joined()
    }

    private func buildEvidenceIndex(
        in document: Document,
        metrics: inout EvidenceExtractionMetrics
    ) throws -> EvidenceIndex {
        metrics.documentPasses += 1
        let elements = try document.getAllElements().array()
        metrics.indexedElementCount = elements.count
        var index = EvidenceIndex()
        var siblingTagCounts: [ObjectIdentifier: [String: Int]] = [:]
        for element in elements {
            let owner = ObjectIdentifier(element)
            if let parent = element.parent() {
                let parentID = ObjectIdentifier(parent)
                let tag = element.tagName().lowercased()
                let ordinal = siblingTagCounts[parentID, default: [:]][tag, default: 0] + 1
                siblingTagCounts[parentID, default: [:]][tag] = ordinal
                index.tagOrdinals[owner] = ordinal
                metrics.ordinalComputations += 1
            } else {
                index.tagOrdinals[owner] = 1
                metrics.ordinalComputations += 1
            }
            let id = element.id()
            if !id.isEmpty {
                index.idCounts[id, default: 0] += 1
                if index.idCounts[id] == 1 {
                    index.uniqueIDOwners[id] = owner
                } else {
                    index.uniqueIDOwners[id] = nil
                }
            }
            for name in Self.stableEvidenceAttributeNames {
                guard let value = try? element.attr(name), !value.isEmpty else {
                    continue
                }
                let key = EvidenceAttributeKey(name: name, value: value)
                index.stableAttributeCounts[key, default: 0] += 1
                if index.stableAttributeCounts[key] == 1 {
                    index.uniqueStableAttributeOwners[key] = owner
                } else {
                    index.uniqueStableAttributeOwners[key] = nil
                }
            }
        }
        return index
    }

    static func cssIdentifierEscaped(_ value: String) -> String {
        let scalars = Array(value.unicodeScalars)
        var result = ""
        for (index, scalar) in scalars.enumerated() {
            let code = scalar.value
            let isControl = code <= 0x1F || code == 0x7F
            let isLeadingDigit = index == 0 && (0x30...0x39).contains(code)
            let isSecondDigitAfterHyphen = index == 1
                && scalars.first?.value == 0x2D
                && (0x30...0x39).contains(code)
            let isLoneHyphen = scalars.count == 1 && code == 0x2D
            if code == 0 {
                result.append("�")
            } else if isControl || isLeadingDigit || isSecondDigitAfterHyphen {
                result += "\\\(String(code, radix: 16)) "
            } else if isLoneHyphen {
                result += "\\-"
            } else if code >= 0x80
                || code == 0x2D
                || code == 0x5F
                || (0x30...0x39).contains(code)
                || (0x41...0x5A).contains(code)
                || (0x61...0x7A).contains(code) {
                result.unicodeScalars.append(scalar)
            } else {
                result.append("\\")
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func idSelector(_ id: String) -> String? {
        let scalars = Array(id.unicodeScalars)
        guard let first = scalars.first else { return nil }
        let hasUnsupportedControl = scalars.contains {
            $0.value == 0 || $0.value <= 0x1F || $0.value == 0x7F
        }
        let startsWithDigit = (0x30...0x39).contains(first.value)
        let startsWithHyphenDigit = first.value == 0x2D
            && scalars.dropFirst().first.map {
                (0x30...0x39).contains($0.value)
            } == true
        let isLoneHyphen = scalars.count == 1 && first.value == 0x2D
        guard !hasUnsupportedControl,
              !startsWithDigit,
              !startsWithHyphenDigit,
              !isLoneHyphen else {
            return nil
        }
        return "#\(Self.cssIdentifierEscaped(id))"
    }

    private func cssStringEscaped(_ value: String) -> String {
        var result = ""
        for scalar in value.unicodeScalars {
            let code = scalar.value
            if code == 0 {
                result.append("�")
            } else if code <= 0x1F || code == 0x7F {
                result += "\\\(String(code, radix: 16)) "
            } else if code == 0x22 || code == 0x5C {
                result.append("\\")
                result.unicodeScalars.append(scalar)
            } else {
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    private func captureOriginalEvidence(
        originalRoot: Element,
        clonedRoot: Element,
        idCounts: [String: Int],
        rootSelector: String,
        evidenceIndex: EvidenceIndex
    ) throws {
        let originals = try originalRoot.getAllElements().array()
        let clones = try clonedRoot.getAllElements().array()
        guard originals.count == clones.count,
              zip(originals, clones).allSatisfy({
                  $0.tagName().lowercased() == $1.tagName().lowercased()
              }) else {
            throw StaticWebBuildError.unreadableHTML
        }
        for (original, clone) in zip(originals, clones) {
            try clone.attr(
                Self.originalEvidenceAttribute,
                uniqueEvidenceLocator(
                    for: original,
                    root: originalRoot,
                    rootSelector: rootSelector,
                    evidenceIndex: evidenceIndex
                )
            )
        }
    }

    private func uniqueEvidenceLocator(
        for element: Element,
        root: Element,
        rootSelector: String,
        evidenceIndex: EvidenceIndex
    ) throws -> String {
        if element === root { return rootSelector }
        let id = element.id()
        if !id.isEmpty,
           evidenceIndex.idCounts[id] == 1,
           evidenceIndex.uniqueIDOwners[id] == ObjectIdentifier(element),
           let selector = idSelector(id),
           !selector.isEmpty {
            return selector
        }
        if let selector = try uniqueStableAttributeSelector(
            for: element,
            evidenceIndex: evidenceIndex,
            includeTag: false
        ) {
            return selector
        }
        return rootSelector + " > " + relativeStructuralPath(
            from: element,
            to: root,
            evidenceIndex: evidenceIndex
        )
    }

    private func uniqueSelector(
        for element: Element,
        evidenceIndex: EvidenceIndex
    ) throws -> String {
        let id = element.id()
        if !id.isEmpty,
           evidenceIndex.idCounts[id] == 1,
           evidenceIndex.uniqueIDOwners[id] == ObjectIdentifier(element),
           let selector = idSelector(id),
           !selector.isEmpty {
            return selector
        }
        if let selector = try uniqueStableAttributeSelector(
            for: element,
            evidenceIndex: evidenceIndex,
            includeTag: true
        ) {
            return selector
        }
        return fullStructuralPath(for: element, evidenceIndex: evidenceIndex)
    }

    private func uniqueStableAttributeSelector(
        for element: Element,
        evidenceIndex: EvidenceIndex,
        includeTag: Bool
    ) throws -> String? {
        for name in ["data-testid", "itemprop", "aria-label", "role"] {
            guard let value = try? element.attr(name), !value.isEmpty else { continue }
            guard value.unicodeScalars.allSatisfy({ scalar in
                let code = scalar.value
                return code >= 0x20 && code != 0x7F && code != 0x22 && code != 0x5C
            }) else { continue }
            let key = EvidenceAttributeKey(name: name, value: value)
            guard evidenceIndex.stableAttributeCounts[key] == 1,
                  evidenceIndex.uniqueStableAttributeOwners[key]
                    == ObjectIdentifier(element) else {
                continue
            }
            let prefix = includeTag ? element.tagName().lowercased() : ""
            let selector = "\(prefix)[\(name)=\"\(cssStringEscaped(value))\"]"
            return selector
        }
        return nil
    }

    private func fullStructuralPath(
        for element: Element,
        evidenceIndex: EvidenceIndex
    ) -> String {
        var parts: [String] = []
        var current: Element? = element
        while let node = current {
            if node is Document { break }
            parts.append(structuralComponent(for: node, evidenceIndex: evidenceIndex))
            current = node.parent()
        }
        return parts.reversed().joined(separator: " > ")
    }

    private func relativeStructuralPath(
        from element: Element,
        to root: Element,
        evidenceIndex: EvidenceIndex
    ) -> String {
        var parts: [String] = []
        var current: Element? = element
        while let node = current, node !== root {
            parts.append(structuralComponent(for: node, evidenceIndex: evidenceIndex))
            current = node.parent()
        }
        return parts.reversed().joined(separator: " > ")
    }

    private func structuralComponent(
        for element: Element,
        evidenceIndex: EvidenceIndex
    ) -> String {
        let tag = element.tagName().lowercased()
        if tag == "html" || tag == "body" { return tag }
        let ordinal = evidenceIndex.tagOrdinals[ObjectIdentifier(element)] ?? 1
        return "\(tag):nth-of-type(\(ordinal))"
    }

    private static let originalEvidenceAttribute = "data-document-import-original-evidence"
    private static let stableEvidenceAttributeNames = [
        "data-testid", "itemprop", "aria-label", "role",
    ]
}

private struct EvidenceAttributeKey: Hashable {
    let name: String
    let value: String

    init(name: String, value: String) {
        self.name = name.lowercased()
        self.value = value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
}

private struct EvidenceIndex {
    var idCounts: [String: Int] = [:]
    var uniqueIDOwners: [String: ObjectIdentifier] = [:]
    var stableAttributeCounts: [EvidenceAttributeKey: Int] = [:]
    var uniqueStableAttributeOwners: [EvidenceAttributeKey: ObjectIdentifier] = [:]
    var tagOrdinals: [ObjectIdentifier: Int] = [:]
}

private struct StructuredMetadata {
    let title: String?
    let author: String?
    let publishedAt: String?
}

private struct InlineBuilder {
    var text = ""
    var markup: [InlineMarkup] = []
    let baseURL: URL?
    let excludesNestedLists: Bool
    private var pendingSpace = false

    init(baseURL: URL?, excludesNestedLists: Bool) {
        self.baseURL = baseURL
        self.excludesNestedLists = excludesNestedLists
    }

    mutating func visit(_ node: Node, isRoot: Bool = false) {
        if let textNode = node as? TextNode {
            append(textNode.getWholeText())
            return
        }
        guard let element = node as? Element else { return }
        if excludesNestedLists,
           !isRoot,
           ["ul", "ol"].contains(element.tagName().lowercased()) {
            return
        }
        let kind = markupKind(element)
        flushPendingSpace()
        let start = text.utf16.count
        for child in element.getChildNodes() { visit(child) }
        let end = text.utf16.count
        if let kind, end > start {
            markup.append(InlineMarkup(range: SourceTextRange(utf16Offset: start, utf16Length: end - start), kind: kind))
        }
    }

    private mutating func append(_ value: String) {
        for scalar in value.unicodeScalars {
            if CharacterSet.whitespacesAndNewlines.contains(scalar) {
                pendingSpace = !text.isEmpty && text.last != " "
                continue
            }
            if pendingSpace { text.append(" "); pendingSpace = false }
            text.unicodeScalars.append(scalar)
        }
    }

    private mutating func flushPendingSpace() {
        if pendingSpace && !text.isEmpty {
            text.append(" ")
            pendingSpace = false
        }
    }

    private func markupKind(_ element: Element) -> InlineMarkupKind? {
        switch element.tagName().lowercased() {
        case "em", "i": return .emphasis
        case "strong", "b": return .strong
        case "code": return .inlineCode
        case "cite":
            let href = try? element.attr("cite")
            return .citation(href.flatMap(cleanLink))
        case "a":
            guard let href = try? element.attr("href"), let url = cleanLink(href) else { return nil }
            return .link(url)
        default: return nil
        }
    }

    private func cleanLink(_ value: String) -> URL? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed, relativeTo: baseURL)?.absoluteURL,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
              components.host != nil else { return nil }
        let tracking = Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid"])
        components.queryItems = components.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }
}
