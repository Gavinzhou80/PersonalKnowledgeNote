import Foundation
import KnowledgeCore
import TestFixtures
import Testing
@testable import DocumentImport

@Test
func extractsRichStaticArticleSemantics() throws {
    let sourceURL = URL(string: "https://fixture.invalid/articles/rich/index.html")!
    let article = try StaticArticleExtractor().extract(
        html: Data(contentsOf: FixtureCatalog.richArticleURL),
        sourceURL: sourceURL
    )

    #expect(article.metadata.title == "Rich Fixture Article")
    #expect(article.metadata.author == "Ada Example")
    #expect(article.metadata.publishedAt == ISO8601DateFormatter().date(from: "2025-04-03T10:15:30Z"))
    #expect(article.rootSelector == "#story")
    #expect(article.blocks.map(\.role) == [
        .heading(level: 1), .paragraph, .heading(level: 2), .paragraph,
        .listItem, .listItem, .listItem, .quotation,
        .codeBlock(language: "swift"), .image, .caption,
    ])
    #expect(article.blocks.map(\.canonicalText) == [
        "Rich Fixture Article",
        "A careful article with strong evidence, a useful link, Example Journal, and inline().",
        "Details", "Second paragraph.", "First unordered item", "Second unordered item",
        "First ordered item", "Quoted insight.",
        "let greeting = \"hello\"\nprint(greeting)", "Abstract fixture hero", "The fixture hero image.",
    ])

    let intro = article.blocks[1]
    func substring(_ markup: InlineMarkup) -> String {
        let text = intro.canonicalText as NSString
        return text.substring(with: NSRange(
            location: markup.range.utf16Offset,
            length: markup.range.utf16Length
        ))
    }
    #expect(intro.inlineMarkup.map(substring) == [
        "careful", "strong evidence", "useful link", "Example Journal", "inline()",
    ])
    #expect(intro.inlineMarkup.map(\.kind) == [
        .emphasis, .strong,
        .link(URL(string: "https://example.com/reference?keep=yes")!),
        .citation(nil), .inlineCode,
    ])

    let image = try #require(article.imageCandidates.first)
    #expect(image.resolvedURL == URL(string: "https://fixture.invalid/articles/rich/hero.svg"))
    #expect(image.altText == "Abstract fixture hero")
    #expect(image.evidenceLocator == "#hero-image")
    #expect(article.blocks[9].imageKey == image.stableKey)
    #expect(article.blocks[10].relationTargetKey == image.stableKey)
    #expect(article.blocks[0].evidenceLocator == "#headline")
    #expect(article.blocks[2].evidenceLocator == "#story > h2:nth-of-type(1)")
    #expect(article.blocks[3].evidenceLocator == "#story > p:nth-of-type(2)")

    let allText = article.blocks.map(\.canonicalText).joined(separator: " ")
    for noise in ["Navigation", "Advertisement", "Recommendation", "Form", "Hidden", "Tracking", "Script", "Related"] {
        #expect(!allText.contains(noise))
    }
}

@Test
func fallsBackToMainWhenArticleIsAbsent() throws {
    let html = Data("<html><body><nav>Noise</nav><main id='content'><h1>Main title</h1><p>Main text.</p></main></body></html>".utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/main")!
    )
    #expect(result.rootSelector == "#content")
    #expect(result.blocks.map(\.canonicalText) == ["Main title", "Main text."])
}

@Test
func rejectsPagesWithoutReadableBlocks() throws {
    #expect(throws: StaticWebBuildError.noReadableBlocks) {
        try StaticArticleExtractor().extract(
            html: Data("<html><body><nav>Only navigation</nav><script>noise</script></body></html>".utf8),
            sourceURL: URL(string: "https://fixture.invalid/empty")!
        )
    }
}

@Test
func prefersTheRichestArticleAndUsesStableSemanticEvidence() throws {
    let html = Data("""
    <html><body>
      <article><p>Short teaser.</p></article>
      <article aria-label="Primary story">
        <h1 data-testid="headline">Chosen title</h1>
        <p itemprop="articleBody">Chosen body with <a href="javascript:alert(1)">unsafe</a> and <cite cite="https://example.com/source?utm_campaign=x&amp;id=7">citation</cite>.</p>
      </article>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/choice")!
    )
    #expect(result.rootSelector == "article[aria-label=\"Primary story\"]")
    #expect(result.blocks.map(\.canonicalText) == [
        "Chosen title", "Chosen body with unsafe and citation.",
    ])
    #expect(result.blocks[0].evidenceLocator == "[data-testid=\"headline\"]")
    #expect(result.blocks[1].evidenceLocator == "[itemprop=\"articleBody\"]")
    #expect(result.blocks[1].inlineMarkup.map(\.kind) == [
        .citation(URL(string: "https://example.com/source?id=7")!),
    ])
}
