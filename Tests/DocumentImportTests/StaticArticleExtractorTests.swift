import Foundation
import KnowledgeCore
import SwiftSoup
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

@Test
func metadataUsesMetaBeforeJSONLDAndFallsBackThroughStructuredSources() throws {
    let sourceURL = URL(string: "https://fixture.invalid/metadata")!
    let preferred = Data("""
    <html><head>
      <meta property="og:title" content="Meta title"><meta name="author" content="Meta author">
      <meta property="article:published_time" content="2025-01-02T03:04:05Z">
      <script type="application/ld+json">{"headline":"JSON title","author":{"name":"JSON author"},"datePublished":"2024-01-01T00:00:00Z"}</script>
    </head><body><article><h1>Body title</h1></article></body></html>
    """.utf8)
    let meta = try StaticArticleExtractor().extract(html: preferred, sourceURL: sourceURL).metadata
    #expect(meta.title == "Meta title")
    #expect(meta.author == "Meta author")
    #expect(meta.publishedAt == ISO8601DateFormatter().date(from: "2025-01-02T03:04:05Z"))

    let json = Data("""
    <html><head><script type="application/ld+json">{"@graph":[{"@type":"WebSite","name":"Ignored"},{"@type":"Article","headline":"Graph title","author":[{"name":"Graph author"}],"datePublished":"2024-02-03T04:05:06Z"}]}</script></head>
    <body><article><p>Body text.</p></article></body></html>
    """.utf8)
    let structured = try StaticArticleExtractor().extract(html: json, sourceURL: sourceURL).metadata
    #expect(structured.title == "Graph title")
    #expect(structured.author == "Graph author")
    #expect(structured.publishedAt == ISO8601DateFormatter().date(from: "2024-02-03T04:05:06Z"))

    let time = Data("<html><body><article><h1>Timed title</h1><time datetime='2023-05-06T07:08:09Z'>May 6</time></article></body></html>".utf8)
    let timed = try StaticArticleExtractor().extract(html: time, sourceURL: sourceURL).metadata
    #expect(timed.publishedAt == ISO8601DateFormatter().date(from: "2023-05-06T07:08:09Z"))
}

@Test
func bodyFallbackSelectsOnlyTheBestFocusedContainer() throws {
    let html = Data("""
    <html><body>
      <header role="banner"><h1>Site chrome</h1></header><nav><p>Navigation noise.</p></nav>
      <aside><p>Aside noise.</p></aside>
      <div role="search"><h1>Search chrome</h1><p>Search noise one.</p><p>Search noise two.</p></div>
      <div id="focused"><h1>Focused title</h1><p>Focused body.</p><template><p>Template noise.</p></template></div>
      <section><p>Smaller candidate.</p></section><footer role="contentinfo"><p>Footer noise.</p></footer>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/focused")!
    )
    #expect(result.rootSelector == "#focused")
    #expect(result.blocks.map(\.canonicalText) == ["Focused title", "Focused body."])

    #expect(throws: StaticWebBuildError.noReadableBlocks) {
        try StaticArticleExtractor().extract(
            html: Data("<html><body><header><h1>Chrome</h1></header><footer><p>Footer</p></footer></body></html>".utf8),
            sourceURL: URL(string: "https://fixture.invalid/chrome")!
        )
    }
}

@Test
func extractsStandaloneCodeButKeepsParagraphCodeInline() throws {
    let html = Data("""
    <html><body><main id="code-root"><code class="language-js">const answer = 42;</code><p>Call <code>answer()</code> now.</p></main></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/code")!
    )
    #expect(result.blocks.map(\.role) == [.codeBlock(language: "js"), .paragraph])
    #expect(result.blocks.map(\.canonicalText) == ["const answer = 42;", "Call answer() now."])
    #expect(result.blocks[1].inlineMarkup.map(\.kind) == [.inlineCode])
}

@Test
func captionsOnlyTargetImagesFromTheirOwnFigure() throws {
    let html = Data("""
    <html><body><article id="figures">
      <figure><img src="one.png" alt="One"><figcaption>First caption.</figcaption></figure>
      <figure><figcaption>Orphan caption.</figcaption></figure>
      <figure><img src="two.png" alt="Two"><figcaption>Second caption.</figcaption></figure>
    </article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/figures/")!
    )
    let captions = result.blocks.filter { $0.role == .caption }
    #expect(captions.map(\.canonicalText) == ["First caption.", "Orphan caption.", "Second caption."])
    #expect(captions[0].relationTargetKey == result.imageCandidates[0].stableKey)
    #expect(captions[1].relationTargetKey == nil)
    #expect(captions[2].relationTargetKey == result.imageCandidates[1].stableKey)
}

@Test
func evidenceUsesIDsOnlyWhenTheyAreUnique() throws {
    let html = Data("""
    <html><body><article id="root"><h1 id="unique">Unique</h1><p id="duplicate">First</p><p id="duplicate">Second</p></article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/evidence")!
    )
    #expect(result.blocks[0].evidenceLocator == "#unique")
    #expect(result.blocks[1].evidenceLocator == "#root > p:nth-of-type(1)")
    #expect(result.blocks[2].evidenceLocator == "#root > p:nth-of-type(2)")
}

@Test
func metadataSurvivesCleaningOfAClonedFocusedRoot() throws {
    let html = Data("""
    <html><head></head><body>
      <article id="metadata-root">
        <script type="application/ld+json">{"headline":"Embedded title","author":{"name":"Embedded author"}}</script>
        <header><h1>Semantic heading</h1></header>
        <footer><time datetime="2022-06-07T08:09:10Z">Published</time><p>Written by Ada.</p></footer>
      </article>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/cloned")!
    )
    #expect(result.metadata.title == "Embedded title")
    #expect(result.metadata.author == "Embedded author")
    #expect(result.metadata.publishedAt == ISO8601DateFormatter().date(from: "2022-06-07T08:09:10Z"))
    #expect(result.blocks.map(\.canonicalText) == ["Semantic heading", "Written by Ada."])
}

@Test
func codeOnlyMainIsReadableAndProducesAStandaloneCodeBlock() throws {
    let html = Data("<html><body><main id='code-only'><code class='language-rust'>fn main() {}</code></main></body></html>".utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/code-only")!
    )
    #expect(result.rootSelector == "#code-only")
    #expect(result.blocks.map(\.role) == [.codeBlock(language: "rust")])
    #expect(result.blocks.map(\.canonicalText) == ["fn main() {}"])
}

@Test
func figureCaptionsTargetNestedImagesRegardlessOfDOMOrder() throws {
    let html = Data("""
    <html><body><article id="compound-figures">
      <figure><figcaption>Caption first.</figcaption><picture><source srcset="wide.webp"><img src="first.png" alt="First"></picture></figure>
      <figure><picture><img src="second.png" alt="Second"></picture><figcaption>Caption last.</figcaption></figure>
    </article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/compound/")!
    )
    #expect(result.blocks.map(\.canonicalText) == ["Caption first.", "First", "Second", "Caption last."])
    #expect(result.blocks[0].relationTargetKey == result.imageCandidates[0].stableKey)
    #expect(result.blocks[3].relationTargetKey == result.imageCandidates[1].stableKey)
    #expect(result.imageCandidates.map(\.resolvedURL) == [
        URL(string: "https://fixture.invalid/compound/first.png")!,
        URL(string: "https://fixture.invalid/compound/second.png")!,
    ])
}

@Test
func candidateScoringIgnoresContentThatCleaningWouldRemove() throws {
    let html = Data("""
    <html><body>
      <article id="noise-heavy">
        <nav><h1>Noise heading</h1><p>Noise one.</p><p>Noise two.</p></nav>
        <form><p>Noise three.</p><p>Noise four.</p></form>
        <section class="recommendation"><p>Noise five.</p></section>
      </article>
      <article id="real-story"><h1>Real heading</h1><p>Real body.</p></article>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/candidates")!
    )
    #expect(result.rootSelector == "#real-story")
    #expect(result.blocks.map(\.canonicalText) == ["Real heading", "Real body."])
}

@Test
func evidenceKeepsOriginalNthOfTypeAfterNoiseSiblingRemoval() throws {
    let html = Data("""
    <html><body><article id="original-positions">
      <p class="advertisement">Removed advertisement.</p>
      <p>Retained paragraph.</p>
    </article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/evidence-position")!
    )
    #expect(result.blocks.map(\.canonicalText) == ["Retained paragraph."])
    #expect(result.blocks[0].evidenceLocator == "#original-positions > p:nth-of-type(2)")
}

@Test
func candidateSelectionRejectsAConventionalNoiseRoot() throws {
    let html = Data("""
    <html><body>
      <article class="related"><h1>Related heading</h1><p>Related one.</p><p>Related two.</p></article>
      <article id="primary"><h1>Primary heading</h1><p>Primary body.</p></article>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/root-noise")!
    )
    #expect(result.rootSelector == "#primary")
    #expect(result.blocks.map(\.canonicalText) == ["Primary heading", "Primary body."])
}

@Test
func sourceCannotInjectTheInternalOriginalEvidenceMarker() throws {
    let html = Data("""
    <html><body><article id="trusted-root">
      <p data-document-import-original-evidence="#attacker-controlled">Trusted paragraph.</p>
    </article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/untrusted-marker")!
    )
    #expect(result.blocks[0].evidenceLocator == "#trusted-root > p:nth-of-type(1)")
}

@Test
func candidateSelectionRejectsArticlesInsideNoiseAncestors() throws {
    let html = Data("""
    <html><body>
      <div class="advertisement">
        <article id="nested-candidate"><h1>Ad heading</h1><p>Ad one.</p><p>Ad two.</p></article>
      </div>
      <section aria-hidden="true">
        <main><h1>Hidden heading</h1><p>Hidden one.</p><p>Hidden two.</p><p>Hidden three.</p></main>
      </section>
      <article id="real-article"><h1>Real heading</h1><p>Real body.</p></article>
    </body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/noise-ancestor")!
    )
    #expect(result.rootSelector == "#real-article")
    #expect(result.blocks.map(\.canonicalText) == ["Real heading", "Real body."])
}

@Test
func effectiveDocumentBaseResolvesImagesAndRejectsUnsafeBase() throws {
    let sourceURL = URL(string: "https://fixture.invalid/articles/page.html")!
    let valid = Data("<html><head><base href='/shared/assets/'></head><body><article><h1>Base</h1><img src='hero.png' alt='Hero'></article></body></html>".utf8)
    let based = try StaticArticleExtractor().extract(html: valid, sourceURL: sourceURL)
    #expect(based.imageCandidates.map(\.resolvedURL) == [URL(string: "https://fixture.invalid/shared/assets/hero.png")!])

    let unsafe = Data("<html><head><base href='javascript:alert(1)'></head><body><article><h1>Fallback</h1><img src='hero.png' alt='Hero'></article></body></html>".utf8)
    let fallback = try StaticArticleExtractor().extract(html: unsafe, sourceURL: sourceURL)
    #expect(fallback.imageCandidates.map(\.resolvedURL) == [URL(string: "https://fixture.invalid/articles/hero.png")!])
}

@Test
func evidenceLocatorsAreValidCSSForComplexIdentifiersAndStrings() throws {
    let complexID = "1lead: odd\\path\nline"
    let semanticHTML = "quote &quot; slash\\line&#10;next"
    let html = """
    <html><body><article id="root"><h1 id="\(complexID)">Complex ID</h1><p data-testid="\(semanticHTML)">Complex attribute</p></article></body></html>
    """
    let result = try StaticArticleExtractor().extract(
        html: Data(html.utf8),
        sourceURL: URL(string: "https://fixture.invalid/css")!
    )
    let original = try SwiftSoup.parse(html)
    for block in result.blocks {
        let matches = try original.select(block.evidenceLocator)
        #expect(matches.size() == 1)
        #expect(try matches.first()?.text() == block.canonicalText)
    }
}

@Test
func nestedListItemsBecomeIndependentBlocksWithoutDuplicatedText() throws {
    let html = Data("""
    <html><body><article id="lists"><ul><li>Parent <strong>own</strong><ul><li>Child <em>emphasis</em></li></ul> tail</li></ul></article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/lists")!
    )
    #expect(result.blocks.map(\.role) == [.listItem, .listItem])
    #expect(result.blocks.map(\.canonicalText) == ["Parent own tail", "Child emphasis"])
    #expect(result.blocks[0].inlineMarkup.map(\.kind) == [.strong])
    #expect(result.blocks[1].inlineMarkup.map(\.kind) == [.emphasis])
}

@Test
func relativeLinksUseTheEffectiveDocumentBaseAndUnsafeLinksAreIgnored() throws {
    let html = Data("""
    <html><head><base href="https://cdn.example.test/docs/"></head><body><article><p>Read <a href="guide.html?utm_source=x&amp;keep=1">guide</a> but not <a href="data:text/html,no">unsafe</a>.</p></article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/article")!
    )
    #expect(result.blocks[0].inlineMarkup.map(\.kind) == [
        .link(URL(string: "https://cdn.example.test/docs/guide.html?keep=1")!),
    ])
}

@Test
func blankImageSourcesDoNotBecomePageURLCandidates() throws {
    let html = Data("<html><body><article><h1>Images</h1><img src='   ' alt='Blank'><p>Body.</p></article></body></html>".utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/article/page.html")!
    )
    #expect(result.imageCandidates.isEmpty)
    #expect(!result.blocks.contains { $0.role == .image })
}

@Test
func cssIdentifierEscapingMatchesCSSOMRules() {
    let cases: [(String, String)] = [
        ("1lead", "\\31 lead"),
        ("-1lead", "-\\31 lead"),
        ("-", "\\-"),
        ("line\nbreak", "line\\a break"),
        ("control\u{1}char", "control\\1 char"),
        ("delete\u{7f}char", "delete\\7f char"),
        ("colon: space\\slash", "colon\\:\\ space\\\\slash"),
        ("nul\0char", "nul�char"),
        ("éclair", "éclair"),
    ]
    for (input, expected) in cases {
        #expect(StaticArticleExtractor.cssIdentifierEscaped(input) == expected)
    }
}

@Test
func standardsEscapedEvidenceFallsBackWhenSwiftSoupCannotParseIt() throws {
    let html = """
    <html><body><article id="css-root">
      <h1 id="1lead">Leading digit</h1>
      <h2 id="-1lead">Hyphen digit</h2>
      <h3 id="-">Lone hyphen</h3>
      <h4 id="line&#10;break">Control newline</h4>
      <h5 id="colon: space\\slash">Escaped punctuation</h5>
      <h6 id="éclair">Non ASCII</h6>
    </article></body></html>
    """
    let result = try StaticArticleExtractor().extract(
        html: Data(html.utf8),
        sourceURL: URL(string: "https://fixture.invalid/cssom")!
    )
    #expect(result.blocks.map(\.evidenceLocator) == [
        "#css-root > h1:nth-of-type(1)",
        "#css-root > h2:nth-of-type(1)",
        "#css-root > h3:nth-of-type(1)",
        "#css-root > h4:nth-of-type(1)",
        "#colon\\:\\ space\\\\slash",
        "#éclair",
    ])
    let original = try SwiftSoup.parse(html)
    for block in result.blocks {
        #expect(
            try original.select(block.evidenceLocator).size() == 1,
            Comment(rawValue: block.evidenceLocator)
        )
    }
}

@Test
func nestedListsInsideFlowWrappersAreStillExtracted() throws {
    let html = Data("""
    <html><body><article id="wrapped-list"><ul><li>Parent<div>before<ul><li>Wrapped child</li></ul>after</div>tail</li></ul></article></body></html>
    """.utf8)
    let result = try StaticArticleExtractor().extract(
        html: html,
        sourceURL: URL(string: "https://fixture.invalid/wrapped-list")!
    )
    #expect(result.blocks.map(\.canonicalText) == [
        "Parent before after tail", "Wrapped child",
    ])
    #expect(result.blocks.map(\.role) == [.listItem, .listItem])
}

@Test
func structuralRootSelectorsUniquelyIdentifyTheChosenRoot() throws {
    let cases = [
        """
        <html><body><article><p>Short.</p></article><article><h1>Chosen article</h1><p>Article body.</p></article></body></html>
        """,
        """
        <html><body><div><p>Short.</p></div><div><h1>Chosen div</h1><p>Div body.</p></div></body></html>
        """,
        """
        <html><body><article><p>Short.</p></article><article id="1complex: root"><h1>Chosen complex root</h1><p>Complex body.</p></article></body></html>
        """,
    ]
    for html in cases {
        let result = try StaticArticleExtractor().extract(
            html: Data(html.utf8),
            sourceURL: URL(string: "https://fixture.invalid/unique-root")!
        )
        let original = try SwiftSoup.parse(html)
        #expect(try original.select(result.rootSelector).size() == 1)
        for block in result.blocks {
            let matches = try original.select(block.evidenceLocator)
            #expect(matches.size() == 1, Comment(rawValue: block.evidenceLocator))
            #expect(try matches.first()?.text() == block.canonicalText)
        }
    }
}

@Test
func duplicateStableSemanticAttributesFallBackToStructuralEvidence() throws {
    let html = """
    <html><body><article id="semantic-root"><p data-testid="shared">First.</p><p data-testid="shared">Second.</p></article></body></html>
    """
    let result = try StaticArticleExtractor().extract(
        html: Data(html.utf8),
        sourceURL: URL(string: "https://fixture.invalid/semantic-duplicates")!
    )
    #expect(result.blocks.map(\.evidenceLocator) == [
        "#semantic-root > p:nth-of-type(1)",
        "#semantic-root > p:nth-of-type(2)",
    ])
    let original = try SwiftSoup.parse(html)
    for block in result.blocks {
        #expect(try original.select(block.evidenceLocator).size() == 1)
    }
}

@Test
func evidenceIndexPrecomputesAnonymousSiblingOrdinalsLinearly() throws {
    let paragraphs = (0..<240).map { index in
        "<p>Item \(index).</p>"
    }.joined()
    let html = "<html><body><article id=\"large-root\">\(paragraphs)</article></body></html>"
    let extraction = try StaticArticleExtractor().extractWithMetrics(
        html: Data(html.utf8),
        sourceURL: URL(string: "https://fixture.invalid/large-evidence")!
    )
    let result = extraction.article
    let metrics = extraction.metrics

    #expect(result.blocks.count == 240)
    #expect(metrics.documentPasses == 1)
    #expect(metrics.indexedElementCount >= 243)
    #expect(metrics.ordinalComputations <= metrics.indexedElementCount)

    let original = try SwiftSoup.parse(html)
    for block in result.blocks {
        #expect(try original.select(block.evidenceLocator).size() == 1)
    }
}
