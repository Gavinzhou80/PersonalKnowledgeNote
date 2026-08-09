import Foundation
import WebKit

struct RenderedWebPage: Hashable, Sendable {
    let finalURL: URL
    let html: Data
}

protocol DynamicWebRendering: Sendable {
    func render(_ url: URL) async throws -> RenderedWebPage
}

/// Renders a page with JavaScript enabled inside an isolated WKWebView and
/// returns the serialized DOM. Isolation means a non-persistent website data
/// store, a fresh process pool per render, and rejected authentication
/// challenges, so no cookie or Safari credential state enters the import.
struct IsolatedWKWebViewRenderer: DynamicWebRendering {
    let pageLoadTimeout: Duration
    let maximumRedirectCount: Int
    let maximumRenderedHTMLBytes: Int

    init(
        pageLoadTimeout: Duration = .seconds(30),
        maximumRedirectCount: Int = 10,
        maximumRenderedHTMLBytes: Int = 10 * 1024 * 1024
    ) {
        precondition(maximumRedirectCount > 0)
        precondition(maximumRenderedHTMLBytes > 0)
        self.pageLoadTimeout = pageLoadTimeout
        self.maximumRedirectCount = maximumRedirectCount
        self.maximumRenderedHTMLBytes = maximumRenderedHTMLBytes
    }

    func render(_ url: URL) async throws -> RenderedWebPage {
        try Task.checkCancellation()
        return try await IsolatedRenderSession(
            url: url,
            pageLoadTimeout: pageLoadTimeout,
            maximumRedirectCount: maximumRedirectCount,
            maximumRenderedHTMLBytes: maximumRenderedHTMLBytes
        ).run()
    }
}

/// A single background thread whose run loop stays alive so WKWebView can be
/// created, driven, and destroyed away from the main thread. This keeps the
/// renderer usable from headless test processes and from the import runner,
/// which never runs on the main actor.
final class WebKitRunLoopHost: @unchecked Sendable {
    static let shared = WebKitRunLoopHost()

    private let lock = NSLock()
    private var runLoop: RunLoop?
    private var pendingBlocks: [@Sendable () -> Void] = []

    private init() {
        let thread = Thread { [self] in
            let current = RunLoop.current
            let initialBlocks = lock.withLock { () -> [@Sendable () -> Void] in
                runLoop = current
                let blocks = pendingBlocks
                pendingBlocks.removeAll()
                return blocks
            }
            for block in initialBlocks {
                current.perform(block)
            }
            while true {
                current.run(
                    mode: .default,
                    before: Date(timeIntervalSinceNow: 0.25)
                )
            }
        }
        thread.name = "pkn.import.webkit"
        thread.start()
    }

    func perform(_ block: @escaping @Sendable () -> Void) {
        let target = lock.withLock { () -> RunLoop? in
            guard let runLoop else {
                pendingBlocks.append(block)
                return nil
            }
            return runLoop
        }
        target?.perform(block)
    }
}

/// Navigation decisions and load callbacks arrive on the session's own
/// run-loop thread. Every delegate method pins its Objective-C selector so
/// dispatch matches the WKNavigationDelegate requirements exactly; Swift 6
/// selector inference for labeled parameters like `didFinish navigation:`
/// does not match WebKit's `webView:didFinishNavigation:`.
private final class IsolatedRenderSession: NSObject, WKNavigationDelegate,
                                          @unchecked Sendable
{
    private let host = WebKitRunLoopHost.shared
    private let requestedURL: URL
    private let pageLoadTimeout: Duration
    private let maximumRedirectCount: Int
    private let maximumRenderedHTMLBytes: Int

    private var continuation: CheckedContinuation<RenderedWebPage, Error>?
    private var webView: WKWebView?
    private var timer: Timer?
    private var mainFrameNavigationCount = 0
    private var sawAuthenticationChallenge = false
    private var failedByPolicy = false
    private var timedOut = false
    private var cancellationRequested = false
    private var finished = false

    init(
        url: URL,
        pageLoadTimeout: Duration,
        maximumRedirectCount: Int,
        maximumRenderedHTMLBytes: Int
    ) {
        requestedURL = url
        self.pageLoadTimeout = pageLoadTimeout
        self.maximumRedirectCount = maximumRedirectCount
        self.maximumRenderedHTMLBytes = maximumRenderedHTMLBytes
    }

    func run() async throws -> RenderedWebPage {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                host.perform { [self] in
                    start(continuation: continuation)
                }
            }
        } onCancel: {
            host.perform { [self] in
                cancelFromTask()
            }
        }
    }

    private func start(
        continuation: CheckedContinuation<RenderedWebPage, Error>
    ) {
        guard finished == false else {
            continuation.resume(throwing: CancellationError())
            return
        }
        self.continuation = continuation
        guard let scheme = requestedURL.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = requestedURL.host,
              !host.isEmpty
        else {
            finish(.failure(WebAcquisitionError.invalidHTTPResponse))
            return
        }

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.navigationDelegate = self
        webView = view

        let timeoutSeconds = Double(
            pageLoadTimeout.components.seconds
        ) + Double(pageLoadTimeout.components.attoseconds) / 1e18
        let scheduledTimer = Timer(
            timeInterval: max(timeoutSeconds, 0.05),
            repeats: false
        ) { [weak self] _ in
            self?.handleTimeout()
        }
        RunLoop.current.add(scheduledTimer, forMode: .default)
        timer = scheduledTimer

        view.load(URLRequest(
            url: requestedURL,
            cachePolicy: .reloadIgnoringLocalCacheData,
            timeoutInterval: max(timeoutSeconds, 0.05)
        ))
    }

    private func cancelFromTask() {
        guard !finished else { return }
        cancellationRequested = true
        webView?.stopLoading()
        finish(.failure(CancellationError()))
    }

    private func handleTimeout() {
        guard !finished else { return }
        timedOut = true
        webView?.stopLoading()
        finish(.failure(WebAcquisitionError.requestTimedOut))
    }

    @objc func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        guard navigationAction.targetFrame?.isMainFrame == true else {
            decisionHandler(.cancel)
            return
        }
        guard let scheme = navigationAction.request.url?.scheme?
                .lowercased(),
              scheme == "http" || scheme == "https"
        else {
            decisionHandler(.cancel)
            policyFailure(.invalidHTTPResponse)
            return
        }
        // macOS exposes no redirect flag on WKNavigationAction; every
        // main-frame navigation decision beyond the initial load is a
        // redirect hop, bounded by the same cap.
        mainFrameNavigationCount += 1
        guard mainFrameNavigationCount <= maximumRedirectCount + 1 else {
            decisionHandler(.cancel)
            policyFailure(.invalidHTTPResponse)
            return
        }
        decisionHandler(.allow)
    }

    @objc func webView(
        _ webView: WKWebView,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping (
            URLSession.AuthChallengeDisposition,
            URLCredential?
        ) -> Void
    ) {
        sawAuthenticationChallenge = true
        completionHandler(.cancelAuthenticationChallenge, nil)
    }

    @objc(webView:didFinishNavigation:)
    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        timer?.invalidate()
        timer = nil
        webView.evaluateJavaScript("document.documentElement.outerHTML") {
            [weak self] value, error in
            guard let self else { return }
            if error != nil {
                self.finish(.failure(WebAcquisitionError.invalidHTTPResponse))
                return
            }
            guard let htmlString = value as? String,
                  let html = htmlString.data(using: .utf8)
            else {
                self.finish(.failure(WebAcquisitionError.invalidHTTPResponse))
                return
            }
            guard html.count <= self.maximumRenderedHTMLBytes else {
                self.finish(.failure(WebAcquisitionError.responseTooLarge))
                return
            }
            self.finish(.success(RenderedWebPage(
                finalURL: webView.url ?? self.requestedURL,
                html: html
            )))
        }
    }

    @objc(webView:didFailNavigation:withError:)
    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(mapped(error)))
    }

    @objc(webView:didFailProvisionalNavigation:withError:)
    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        finish(.failure(mapped(error)))
    }

    private func policyFailure(_ error: WebAcquisitionError) {
        failedByPolicy = true
        webView?.stopLoading()
        finish(.failure(error))
    }

    private func mapped(_ error: Error) -> WebAcquisitionError {
        if cancellationRequested {
            return .networkUnavailable
        }
        if timedOut {
            return .requestTimedOut
        }
        if failedByPolicy {
            return .invalidHTTPResponse
        }
        if sawAuthenticationChallenge {
            return .accessDenied
        }
        let code = (error as? URLError)?.code
            ?? URLError.Code(rawValue: (error as NSError).code)
        switch code {
        case .timedOut:
            return .requestTimedOut
        case .cancelled:
            return .networkUnavailable
        case .userAuthenticationRequired,
             .userCancelledAuthentication:
            return .accessDenied
        case .dataLengthExceedsMaximum:
            return .responseTooLarge
        case .badURL,
             .unsupportedURL,
             .redirectToNonExistentLocation,
             .httpTooManyRedirects,
             .badServerResponse,
             .cannotParseResponse:
            return .invalidHTTPResponse
        default:
            return .networkUnavailable
        }
    }

    private func finish(
        _ result: Result<RenderedWebPage, Error>
    ) {
        guard !finished else { return }
        finished = true
        timer?.invalidate()
        timer = nil
        if let view = webView {
            view.stopLoading()
            view.navigationDelegate = nil
        }
        webView = nil
        let pending = continuation
        continuation = nil
        pending?.resume(with: result)
    }
}
