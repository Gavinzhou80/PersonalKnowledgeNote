import Foundation
import KnowledgeCore

struct WebArtifactRenderer: Sendable {
    func render(
        _ article: ExtractedWebArticle,
        localizedMedia: [String: SourceMediaReference],
        into packageURL: URL
    ) throws {
        let body = renderBlocks(article.blocks, media: localizedMedia)
        let title = escape(article.metadata.title)
        let html = """
        <!doctype html>
        <html><head><meta charset="utf-8"><meta name="referrer" content="no-referrer"><meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src 'self'; style-src 'none'; script-src 'none'; connect-src 'none'; frame-src 'none'; object-src 'none'; base-uri 'none'; form-action 'none'"><title>\(title)</title></head><body><article>
        \(body)
        </article></body></html>
        """
        let destination = packageURL.appending(path: "index.html")
        try Data(html.utf8).write(to: destination, options: [.atomic])
    }

    private func renderBlocks(
        _ blocks: [ExtractedWebBlock],
        media: [String: SourceMediaReference]
    ) -> String {
        let captions = Dictionary(grouping: blocks.compactMap { block in
            block.relationTargetKey.map { ($0, block) }
        }, by: \ .0).mapValues { $0.map(\ .1) }
        let captionConsumingImageKeys = Set<String>(blocks.compactMap { block in
            guard block.role == .image else { return nil }
            return block.imageKey
        })
        var rendered: [String] = []
        for block in blocks {
            if block.role == .caption,
               let targetKey = block.relationTargetKey,
               captionConsumingImageKeys.contains(targetKey) {
                continue
            }
            let value = render(block, media: media)
            guard !value.isEmpty else { continue }
            if block.role == .image,
               let key = block.imageKey,
               let relatedCaptions = captions[key],
               !relatedCaptions.isEmpty {
                let captionHTML = relatedCaptions.map { render($0, media: media) }
                    .joined(separator: "\n")
                rendered.append("<figure>\(value)\n\(captionHTML)</figure>")
            } else {
                rendered.append(value)
            }
        }
        return rendered.joined(separator: "\n")
    }

    private func render(
        _ block: ExtractedWebBlock,
        media: [String: SourceMediaReference]
    ) -> String {
        switch block.role {
        case .heading(let level):
            let safeLevel = min(6, max(1, level))
            return "<h\(safeLevel)>\(inline(block))</h\(safeLevel)>"
        case .paragraph: return "<p>\(inline(block))</p>"
        case .listItem: return "<ul><li>\(inline(block))</li></ul>"
        case .quotation: return "<blockquote>\(inline(block))</blockquote>"
        case .codeBlock(let language):
            let attribute = language.flatMap(safeToken).map { " class=\"language-\($0)\"" } ?? ""
            return "<pre><code\(attribute)>\(escape(block.canonicalText))</code></pre>"
        case .image:
            guard let key = block.imageKey, let reference = media[key] else {
                guard !block.canonicalText.isEmpty else {
                    return "<div data-missing-image=\"true\" aria-hidden=\"true\"></div>"
                }
                let alt = escape(block.canonicalText)
                return "<div data-missing-image=\"true\" role=\"img\" aria-label=\"\(alt)\">\(alt)</div>"
            }
            return "<img src=\"\(escape(reference.artifactRelativePath))\" alt=\"\(escape(reference.altText ?? block.canonicalText))\">"
        case .caption: return "<figcaption>\(inline(block))</figcaption>"
        }
    }

    private func inline(_ block: ExtractedWebBlock) -> String {
        guard !block.inlineMarkup.isEmpty else { return escape(block.canonicalText) }
        let text = block.canonicalText as NSString
        let markup = block.inlineMarkup.filter {
            $0.range.utf16Offset >= 0
                && $0.range.utf16Length > 0
                && $0.range.utf16Offset + $0.range.utf16Length <= text.length
        }
        let boundaries = Set(
            [0, text.length] + markup.flatMap {
                [$0.range.utf16Offset, $0.range.utf16Offset + $0.range.utf16Length]
            }
        ).sorted()
        var result = ""
        for (index, position) in boundaries.enumerated() {
            let closing = markup.filter {
                $0.range.utf16Offset + $0.range.utf16Length == position
            }.sorted {
                if $0.range.utf16Offset != $1.range.utf16Offset {
                    return $0.range.utf16Offset > $1.range.utf16Offset
                }
                if $0.range.utf16Length != $1.range.utf16Length {
                    return $0.range.utf16Length < $1.range.utf16Length
                }
                return tagPriority($0.kind) > tagPriority($1.kind)
            }
            result += closing.compactMap { tags(for: $0.kind)?.closing }.joined()
            let opening = markup.filter { $0.range.utf16Offset == position }.sorted {
                if $0.range.utf16Length != $1.range.utf16Length {
                    return $0.range.utf16Length > $1.range.utf16Length
                }
                return tagPriority($0.kind) < tagPriority($1.kind)
            }
            result += opening.compactMap { tags(for: $0.kind)?.opening }.joined()
            guard index + 1 < boundaries.count else { continue }
            let next = boundaries[index + 1]
            result += escape(text.substring(with: NSRange(location: position, length: next - position)))
        }
        return result
    }

    private func tags(for kind: InlineMarkupKind) -> (opening: String, closing: String)? {
        switch kind {
        case .emphasis: return ("<em>", "</em>")
        case .strong: return ("<strong>", "</strong>")
        case .inlineCode: return ("<code>", "</code>")
        case .citation(let url):
            guard let url, safeHTTPURL(url) else { return ("<cite>", "</cite>") }
            return ("<cite><a href=\"\(escape(url.absoluteString))\" rel=\"noopener noreferrer\" referrerpolicy=\"no-referrer\">", "</a></cite>")
        case .link(let url):
            guard safeHTTPURL(url) else { return nil }
            return ("<a href=\"\(escape(url.absoluteString))\" rel=\"noopener noreferrer\" referrerpolicy=\"no-referrer\">", "</a>")
        }
    }

    private func tagPriority(_ kind: InlineMarkupKind) -> Int {
        switch kind {
        case .link: 0
        case .citation: 1
        case .strong: 2
        case .emphasis: 3
        case .inlineCode: 4
        }
    }

    private func safeHTTPURL(_ url: URL) -> Bool {
        ["http", "https"].contains(url.scheme?.lowercased() ?? "") && url.host != nil
    }

    private func safeToken(_ value: String) -> String? {
        let token = value.lowercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        return token.isEmpty ? nil : token
    }

    private func escape(_ value: String) -> String {
        value.replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
