import Foundation

/// Static-first web acquisition with an extraction-probe-gated dynamic
/// fallback. The static page is returned unchanged whenever
/// `StaticArticleExtractor` can read it; only pages whose static DOM yields
/// no article are re-acquired through the isolated dynamic renderer, whose
/// serialized DOM re-enters the identical sanitizer/builder pipeline.
struct DynamicFallbackWebAcquirer: WebAcquiring {
    private let staticAcquirer: any WebAcquiring
    private let dynamicRenderer: any DynamicWebRendering

    init(
        staticAcquirer: any WebAcquiring = URLSessionStaticWebAcquirer(),
        dynamicRenderer: any DynamicWebRendering = IsolatedWKWebViewRenderer()
    ) {
        self.staticAcquirer = staticAcquirer
        self.dynamicRenderer = dynamicRenderer
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        let page = try await staticAcquirer.acquire(url)
        guard !Self.staticArticleIsExtractable(page) else { return page }
        let rendered = try await dynamicRenderer.render(url)
        return AcquiredWebPage(
            sourceURL: url,
            finalURL: rendered.finalURL,
            mimeType: "text/html",
            textEncodingName: "utf-8",
            bytes: rendered.html
        )
    }

    private static func staticArticleIsExtractable(
        _ page: AcquiredWebPage
    ) -> Bool {
        (try? StaticArticleExtractor().extract(
            html: page.bytes,
            sourceURL: page.finalURL,
            textEncodingName: page.textEncodingName
        )) != nil
    }
}
