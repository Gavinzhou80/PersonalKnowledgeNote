import Foundation
import KnowledgeCore
import SwiftSoup

struct StaticArticleExtractor: Sendable {
    func extract(html: Data, sourceURL: URL) throws -> ExtractedWebArticle {
        guard let source = String(data: html, encoding: .utf8) else {
            throw StaticWebBuildError.unreadableHTML
        }
        let document: Document
        do {
            document = try SwiftSoup.parse(source, sourceURL.absoluteString)
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }
        guard let root = try readableRoot(in: document) else {
            throw StaticWebBuildError.noReadableBlocks
        }
        let structured = try structuredMetadata(in: document)
        let idCounts = try document.select("[id]").array().reduce(into: [String: Int]()) { counts, element in
            let id = element.id()
            if !id.isEmpty { counts[id, default: 0] += 1 }
        }
        try clean(root)
        let rootSelector = selectorForRoot(root, idCounts: idCounts)
        var images: [WebImageCandidate] = []
        var blocks: [ExtractedWebBlock] = []
        try walk(root, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
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

    private func readableRoot(in document: Document) throws -> Element? {
        for selector in ["article", "main"] {
            let candidates = try document.select(selector).array()
            if let best = try candidates.max(by: { try score($0) < score($1) }), try score(best) > 0 {
                return best
            }
        }
        guard let body = document.body() else { return nil }
        let candidates = try body.select("[role=main],section,div").array().filter {
            !isNoise($0) && !hasNoiseAncestor($0, stopAt: body)
        }
        if let best = try candidates.max(by: { try score($0) < score($1) }), try score(best) > 0 {
            return best
        }
        return nil
    }

    private func score(_ element: Element) throws -> Int {
        try element.select("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figure,img,figcaption").size()
    }

    private func clean(_ root: Element) throws {
        try root.select("script,style,noscript,template,form,nav,header,footer,iframe,[hidden],[aria-hidden=true],[role=navigation],[role=banner],[role=complementary],[role=contentinfo],[role=form],[role=search]").remove()
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

    private func isNoise(_ element: Element) -> Bool {
        let tag = element.tagName().lowercased()
        if ["nav", "header", "footer", "form"].contains(tag) { return true }
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
            if isNoise(current) { return true }
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
        case "li": appendTextBlock(element, root: root, idCounts: idCounts, category: .text, role: .listItem, blocks: &blocks); return
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
            var figureImageKey: String?
            for child in element.children().array() {
                if child.tagName().lowercased() == "img" {
                    figureImageKey = appendImage(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks) ?? figureImageKey
                } else if child.tagName().lowercased() == "figcaption" {
                    appendCaption(child, root: root, idCounts: idCounts, targetKey: figureImageKey, blocks: &blocks)
                } else {
                    try walk(child, root: root, sourceURL: sourceURL, idCounts: idCounts, images: &images, blocks: &blocks)
                }
            }
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

    @discardableResult
    private func appendImage(_ element: Element, root: Element, sourceURL: URL, idCounts: [String: Int], images: inout [WebImageCandidate], blocks: inout [ExtractedWebBlock]) -> String? {
        guard let source = try? element.attr("src"), let url = safeURL(source, relativeTo: sourceURL) else { return nil }
        let locator = evidence(element, root: root, idCounts: idCounts)
        let key = "image:\(url.absoluteString)"
        let alt = normalized((try? element.attr("alt")) ?? "")
        images.append(.init(stableKey: key, resolvedURL: url, altText: alt.isEmpty ? nil : alt, evidenceLocator: locator))
        blocks.append(.init(category: .media, role: .image, canonicalText: alt, inlineMarkup: [], evidenceLocator: locator, imageKey: key, relationTargetKey: nil))
        return key
    }

    private func appendCaption(_ element: Element, root: Element, idCounts: [String: Int], targetKey: String?, blocks: inout [ExtractedWebBlock]) {
        let rendered = inlineText(element)
        guard !rendered.text.isEmpty else { return }
        blocks.append(.init(category: .text, role: .caption, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: targetKey))
    }

    private func appendTextBlock(_ element: Element, root: Element, idCounts: [String: Int], category: SourceBlockCategory, role: SourceBlockRole, blocks: inout [ExtractedWebBlock]) {
        let rendered = inlineText(element)
        guard !rendered.text.isEmpty else { return }
        blocks.append(.init(category: category, role: role, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root, idCounts: idCounts), imageKey: nil, relationTargetKey: nil))
    }

    private func inlineText(_ element: Element) -> (text: String, markup: [InlineMarkup]) {
        var builder = InlineBuilder()
        builder.visit(element)
        return (builder.text, builder.markup)
    }

    private func evidence(_ element: Element, root: Element, idCounts: [String: Int]) -> String {
        let id = element.id()
        if !id.isEmpty, idCounts[id] == 1 { return "#\(cssEscaped(id))" }
        if let selector = stableAttributeSelector(element, includeTag: false) { return selector }
        var parts: [String] = []
        var current: Element? = element
        while let node = current, node !== root {
            let tag = node.tagName().lowercased()
            var ordinal = 1
            if let parent = node.parent() {
                for sibling in parent.children().array() {
                    if sibling === node { break }
                    if sibling.tagName().lowercased() == tag { ordinal += 1 }
                }
            }
            parts.append("\(tag):nth-of-type(\(ordinal))")
            current = node.parent()
        }
        parts.append(selectorForRoot(root, idCounts: idCounts))
        return parts.reversed().joined(separator: " > ")
    }

    private func selectorForRoot(_ root: Element, idCounts: [String: Int]) -> String {
        let id = root.id()
        if !id.isEmpty, idCounts[id] == 1 { return "#\(cssEscaped(id))" }
        if let selector = stableAttributeSelector(root, includeTag: true) { return selector }
        return root.tagName().lowercased()
    }

    private func stableAttributeSelector(_ element: Element, includeTag: Bool) -> String? {
        for name in ["data-testid", "itemprop", "aria-label", "role"] {
            guard let value = try? element.attr(name), !value.isEmpty else { continue }
            let prefix = includeTag ? element.tagName().lowercased() : ""
            return "\(prefix)[\(name)=\"\(cssEscaped(value))\"]"
        }
        return nil
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
        guard let url = URL(string: value, relativeTo: base)?.absoluteURL,
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

    private func cssEscaped(_ value: String) -> String { value.replacingOccurrences(of: "\"", with: "\\\"") }
}

private struct StructuredMetadata {
    let title: String?
    let author: String?
    let publishedAt: String?
}

private struct InlineBuilder {
    var text = ""
    var markup: [InlineMarkup] = []
    private var pendingSpace = false

    mutating func visit(_ node: Node) {
        if let textNode = node as? TextNode {
            append(textNode.getWholeText())
            return
        }
        guard let element = node as? Element else { return }
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
            if CharacterSet.whitespacesAndNewlines.contains(scalar) { pendingSpace = !text.isEmpty; continue }
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
        guard var components = URLComponents(string: value), ["http", "https"].contains(components.scheme?.lowercased() ?? ""), components.host != nil else { return nil }
        let tracking = Set(["utm_source", "utm_medium", "utm_campaign", "utm_term", "utm_content", "gclid", "fbclid"])
        components.queryItems = components.queryItems?.filter { !tracking.contains($0.name.lowercased()) }
        if components.queryItems?.isEmpty == true { components.queryItems = nil }
        return components.url
    }
}
