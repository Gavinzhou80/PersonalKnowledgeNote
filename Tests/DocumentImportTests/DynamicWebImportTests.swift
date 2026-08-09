import Foundation
import TestFixtures
import Testing
@testable import DocumentImport

// WKWebView cannot be driven inside the `swift test` process: off-main-thread
// use traps and the main run loop never spins, so delegate callbacks never
// arrive. The production renderer is validated by a standalone diagnostic
// process instead (see the T07 plan). These tests pin the seam contract of
// DynamicWebRendering with a scripted stub and prove the simulated post-render
// DOM feeds the static extraction chain.
@Suite(.serialized)
struct DynamicWebRenderingSeamTests {
    @Test func stubReturnsScriptRenderedDOM() async throws {
        let sourceURL = URL(string: "https://example.com/dynamic/article")!
        let stub = ScriptedDynamicRenderer(page: RenderedWebPage(
            finalURL: sourceURL,
            html: Data(simulatedDynamicArticleHTML.utf8)
        ))

        let rendered = try await stub.render(sourceURL)

        #expect(stub.requestedURLs == [sourceURL])
        let html = try #require(String(data: rendered.html, encoding: .utf8))
        #expect(html.contains(
            "This paragraph is rendered entirely by script."
        ))
        #expect(html.contains("Generated Section"))
        #expect(rendered.finalURL == sourceURL)
    }

    @Test func stubSurfacesTypedAcquisitionFailure() async {
        let sourceURL = URL(string: "https://example.com/timeout")!
        let stub = ScriptedDynamicRenderer(
            error: WebAcquisitionError.requestTimedOut
        )

        await #expect(throws: WebAcquisitionError.self) {
            _ = try await stub.render(sourceURL)
        }
    }

    @Test func stubHonorsTaskCancellation() async throws {
        let sourceURL = URL(string: "https://example.com/slow")!
        let stub = ScriptedDynamicRenderer(hangAfterStart: true)
        let renderTask = Task {
            try await stub.render(sourceURL)
        }
        try await Task.sleep(for: .milliseconds(100))
        renderTask.cancel()

        await #expect(throws: CancellationError.self) {
            _ = try await renderTask.value
        }
    }

    @Test func simulatedRenderedDOMFeedsArticleExtraction() throws {
        let html = Data(simulatedDynamicArticleHTML.utf8)

        let article = try StaticArticleExtractor().extract(
            html: html,
            sourceURL: URL(string: "https://example.com/dynamic/article")!
        )

        #expect(article.blocks.isEmpty == false)
        let text = article.blocks.map(\.canonicalText).joined(separator: "\n")
        #expect(text.contains(
            "This paragraph is rendered entirely by script."
        ))
    }
}

/// Static acquirer stub that returns a fixed page regardless of the URL.
struct FixedWebAcquirer: WebAcquiring {
    let page: AcquiredWebPage

    func acquire(_ url: URL) async throws -> AcquiredWebPage { page }
}

@Suite(.serialized)
struct DynamicFallbackAcquirerTests {
    @Test func sufficientStaticContentNeverInvokesTheDynamicRenderer()
    async throws {
        let sourceURL = URL(string: "https://example.com/static/article")!
        let staticHTML = try Data(contentsOf: FixtureCatalog.webArticleURL)
        let spy = SpyDynamicRenderer(
            html: Data(simulatedDynamicArticleHTML.utf8)
        )
        let acquirer = DynamicFallbackWebAcquirer(
            staticAcquirer: FixedWebAcquirer(page: AcquiredWebPage(
                sourceURL: sourceURL,
                html: staticHTML
            )),
            dynamicRenderer: spy
        )

        let page = try await acquirer.acquire(sourceURL)

        #expect(await spy.renderCallCount == 0)
        #expect(page.bytes == staticHTML)
        #expect(page.finalURL == sourceURL)
    }

    @Test func insufficientStaticContentFallsBackToRenderedHTML()
    async throws {
        let sourceURL = URL(string: "https://example.com/dynamic/article")!
        let renderedFinalURL = URL(
            string: "https://cdn.example.com/rendered/article"
        )!
        let rawDynamicHTML = try Data(
            contentsOf: FixtureCatalog.dynamicWebArticleURL
        )
        let renderedHTML = Data(simulatedDynamicArticleHTML.utf8)
        let spy = SpyDynamicRenderer(
            html: renderedHTML,
            finalURLOverride: renderedFinalURL
        )
        let acquirer = DynamicFallbackWebAcquirer(
            staticAcquirer: FixedWebAcquirer(page: AcquiredWebPage(
                sourceURL: sourceURL,
                html: rawDynamicHTML
            )),
            dynamicRenderer: spy
        )

        let page = try await acquirer.acquire(sourceURL)

        #expect(await spy.renderCallCount == 1)
        #expect(page.bytes == renderedHTML)
        #expect(page.mimeType == "text/html")
        #expect(page.sourceURL == sourceURL)
        #expect(page.finalURL == renderedFinalURL)
    }

    @Test func rendererAcquisitionErrorsPropagate() async throws {
        let sourceURL = URL(string: "https://example.com/dynamic/slow")!
        let rawDynamicHTML = try Data(
            contentsOf: FixtureCatalog.dynamicWebArticleURL
        )
        let spy = SpyDynamicRenderer(
            html: Data(),
            errorToThrow: WebAcquisitionError.requestTimedOut
        )
        let acquirer = DynamicFallbackWebAcquirer(
            staticAcquirer: FixedWebAcquirer(page: AcquiredWebPage(
                sourceURL: sourceURL,
                html: rawDynamicHTML
            )),
            dynamicRenderer: spy
        )

        await #expect(throws: WebAcquisitionError.self) {
            _ = try await acquirer.acquire(sourceURL)
        }
    }
}

/// The DOM the dynamic-article fixture produces after its inline script runs.
/// Kept in sync with Tests/Fixtures/Web/dynamic-article/index.html so seam
/// tests exercise exactly what the production renderer would hand back.
let simulatedDynamicArticleHTML = """
<!DOCTYPE html>
<html lang="en">
<head><meta charset="utf-8"><title>Dynamic Fixture Article</title></head>
<body>
<div id="root"><article>
<h1>Dynamic Fixture Article</h1>
<p>This paragraph is rendered entirely by script.</p>
<h2>Generated Section</h2>
<p>Second rendered paragraph with a clean session.</p>
</article></div>
</body>
</html>
"""

/// Scripted stand-in for the isolated WKWebView renderer. The stub honors
/// task cancellation the way the production renderer does so composition
/// tests can rely on cooperative cancellation through the seam.
final class ScriptedDynamicRenderer: DynamicWebRendering,
                                     @unchecked Sendable
{
    let page: RenderedWebPage?
    let error: Error?
    let hangAfterStart: Bool
    private let requestsLock = NSLock()
    private var recorded: [URL] = []

    var requestedURLs: [URL] {
        requestsLock.withLock { recorded }
    }

    init(
        page: RenderedWebPage? = nil,
        error: Error? = nil,
        hangAfterStart: Bool = false
    ) {
        self.page = page
        self.error = error
        self.hangAfterStart = hangAfterStart
    }

    func render(_ url: URL) async throws -> RenderedWebPage {
        requestsLock.withLock { recorded.append(url) }
        try Task.checkCancellation()
        if hangAfterStart {
            while true {
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        if let error { throw error }
        guard let page else {
            throw WebAcquisitionError.invalidHTTPResponse
        }
        return page
    }
}
