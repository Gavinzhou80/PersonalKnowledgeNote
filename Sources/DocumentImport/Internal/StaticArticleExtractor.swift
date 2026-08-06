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
        try clean(root)
        let rootSelector = selectorForRoot(root)
        var images: [WebImageCandidate] = []
        var blocks: [ExtractedWebBlock] = []
        try walk(root, root: root, sourceURL: sourceURL, images: &images, blocks: &blocks)
        guard !blocks.isEmpty else { throw StaticWebBuildError.noReadableBlocks }

        let title = try metadataContent(document, selector: "meta[property=og:title]", attribute: "content")
            ?? normalized(try document.title())
        let fallbackTitle = blocks.first(where: {
            if case .heading = $0.role { return true }
            return false
        })?.canonicalText ?? blocks[0].canonicalText
        let author = try metadataContent(document, selector: "meta[name=author]", attribute: "content")
            ?? metadataContent(document, selector: "meta[property=article:author]", attribute: "content")
        let dateText = try metadataContent(document, selector: "meta[property=article:published_time]", attribute: "content")
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
        let candidates = body.children().array().filter { !isNoise($0) }
        if let best = try candidates.max(by: { try score($0) < score($1) }), try score(best) > 0 {
            return best
        }
        return try score(body) > 0 ? body : nil
    }

    private func score(_ element: Element) throws -> Int {
        try element.select("h1,h2,h3,h4,h5,h6,p,li,blockquote,pre,figure,img,figcaption").size()
    }

    private func clean(_ root: Element) throws {
        try root.select("script,style,noscript,form,nav,iframe,[hidden],[aria-hidden=true]").remove()
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
        let value = element.id() + " " + ((try? element.className()) ?? "") + " " + ((try? element.attr("role")) ?? "")
        let tokens = ["ad", "advertisement", "recommend", "related", "share", "social", "subscribe", "newsletter", "cookie", "tracker", "promo"]
        let lower = value.lowercased()
        return tokens.contains { token in
            lower.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).contains(Substring(token))
                || (token.count > 3 && lower.contains(token))
        }
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
        images: inout [WebImageCandidate],
        blocks: inout [ExtractedWebBlock]
    ) throws {
        let tag = element.tagName().lowercased()
        if let level = headingLevel(tag) {
            appendTextBlock(element, root: root, category: .text, role: .heading(level: level), blocks: &blocks)
            return
        }
        switch tag {
        case "p": appendTextBlock(element, root: root, category: .text, role: .paragraph, blocks: &blocks); return
        case "li": appendTextBlock(element, root: root, category: .text, role: .listItem, blocks: &blocks); return
        case "blockquote": appendTextBlock(element, root: root, category: .text, role: .quotation, blocks: &blocks); return
        case "pre":
            let code = try element.select("code").first()
            let text = normalizeCode(rawText(code ?? element))
            if !text.isEmpty {
                let language = code.flatMap { languageName((try? $0.className()) ?? "") }
                blocks.append(.init(category: .code, role: .codeBlock(language: language), canonicalText: text, inlineMarkup: [], evidenceLocator: evidence(element, root: root), imageKey: nil, relationTargetKey: nil))
            }
            return
        case "img":
            guard let url = safeURL(try element.attr("src"), relativeTo: sourceURL) else { return }
            let locator = evidence(element, root: root)
            let key = "image:\(url.absoluteString)"
            let alt = normalized(try element.attr("alt"))
            images.append(.init(stableKey: key, resolvedURL: url, altText: alt.isEmpty ? nil : alt, evidenceLocator: locator))
            blocks.append(.init(category: .media, role: .image, canonicalText: alt, inlineMarkup: [], evidenceLocator: locator, imageKey: key, relationTargetKey: nil))
            return
        case "figcaption":
            let target = images.last?.stableKey
            let rendered = inlineText(element)
            if !rendered.text.isEmpty {
                blocks.append(.init(category: .text, role: .caption, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root), imageKey: nil, relationTargetKey: target))
            }
            return
        default: break
        }
        for child in element.children().array() {
            try walk(child, root: root, sourceURL: sourceURL, images: &images, blocks: &blocks)
        }
    }

    private func appendTextBlock(_ element: Element, root: Element, category: SourceBlockCategory, role: SourceBlockRole, blocks: inout [ExtractedWebBlock]) {
        let rendered = inlineText(element)
        guard !rendered.text.isEmpty else { return }
        blocks.append(.init(category: category, role: role, canonicalText: rendered.text, inlineMarkup: rendered.markup, evidenceLocator: evidence(element, root: root), imageKey: nil, relationTargetKey: nil))
    }

    private func inlineText(_ element: Element) -> (text: String, markup: [InlineMarkup]) {
        var builder = InlineBuilder()
        builder.visit(element)
        return (builder.text, builder.markup)
    }

    private func evidence(_ element: Element, root: Element) -> String {
        let id = element.id()
        if !id.isEmpty { return "#\(cssEscaped(id))" }
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
        parts.append(selectorForRoot(root))
        return parts.reversed().joined(separator: " > ")
    }

    private func selectorForRoot(_ root: Element) -> String {
        let id = root.id()
        if !id.isEmpty { return "#\(cssEscaped(id))" }
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
