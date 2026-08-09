import AppSupport
import AppKit
import SwiftUI
import WebKit

/// One-shot scroll command so repeated selection of the same outline
/// node still triggers a scroll.
struct ReadingScrollRequest: Equatable {
    let id: UUID
    let blockIndex: Int

    init(blockIndex: Int) {
        self.id = UUID()
        self.blockIndex = blockIndex
    }
}

/// WKWebView wrapper that renders the managed artifact through the
/// `pkn-reading` scheme, tags rendered blocks with read-time anchors,
/// and routes navigation through the tested policy.
struct ArtifactWebView: NSViewRepresentable {
    let library: any ReadingLibraryPort
    let loadURL: URL?
    let scrollRequest: ReadingScrollRequest?

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.setURLSchemeHandler(
            ArtifactSchemeHandler(library: library),
            forURLScheme: ArtifactSchemeHandler.scheme
        )
        configuration.userContentController.addUserScript(
            WKUserScript(
                source: Self.anchorScript,
                injectionTime: .atDocumentEnd,
                forMainFrameOnly: true
            )
        )
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.navigationDelegate = context.coordinator
        context.coordinator.currentDocument = loadURL
        if let loadURL {
            context.coordinator.requestedURL = loadURL
            webView.load(URLRequest(url: loadURL))
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context: Context) {
        context.coordinator.currentDocument = loadURL
        // Compare against the URL we already asked WebKit to load, not
        // `webView.url`: during the first update the provisional load
        // has not committed yet, and re-issuing the load interrupts
        // the in-flight main resource (frame load error 102).
        if let loadURL,
           context.coordinator.requestedURL != loadURL,
           webView.url != loadURL {
            context.coordinator.requestedURL = loadURL
            webView.load(URLRequest(url: loadURL))
        }
        if let scrollRequest,
           scrollRequest.id != context.coordinator.lastScrollID {
            context.coordinator.lastScrollID = scrollRequest.id
            webView.evaluateJavaScript(
                "window.pknScrollToBlock(\(scrollRequest.blockIndex));"
            )
        }
    }

    /// Read-time anchor injection: tags rendered block elements in
    /// document order and exposes the scroll entry point (ADR 0002).
    private static let anchorScript = """
    (() => {
      const article = document.querySelector('article') || document.body;
      const blocks = article.children;
      for (let index = 0; index < blocks.length; index += 1) {
        blocks[index].setAttribute('data-pkn-block', String(index));
      }
      window.pknScrollToBlock = (index) => {
        const target = article.querySelector(
          '[data-pkn-block="' + index + '"]'
        );
        if (target) {
          target.scrollIntoView({ behavior: 'smooth', block: 'start' });
        }
      };
    })();
    """

    @MainActor
    final class Coordinator: NSObject, WKNavigationDelegate {
        var currentDocument: URL?
        var requestedURL: URL?
        var lastScrollID: UUID?

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction
        ) async -> WKNavigationActionPolicy {
            guard let url = navigationAction.request.url else {
                return .cancel
            }
            let disposition = ReadingNavigationPolicy.disposition(
                for: url,
                currentDocument: currentDocument
            )
            switch disposition {
            case .allow:
                return .allow
            case .cancel:
                return .cancel
            case .openInBrowser:
                NSWorkspace.shared.open(url)
                return .cancel
            }
        }
    }
}
