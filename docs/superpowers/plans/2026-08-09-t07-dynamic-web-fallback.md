# T07 Dynamic Webpage Import Fallback — Execution Plan

> Product source: `docs/product/macos-v1-scope.md` (§5.2 本地静态阅读副本, Gate C of the Document Import roadmap)
> Master plan task: `docs/superpowers/plans/2026-08-05-document-import-implementation-plan.md` — "Task 7: Add isolated dynamic webpage fallback"
> Branch: `feature/t07-dynamic-web-fallback` (from `main`)
> Mode: TDD red-green per task; focused suites inside tasks, full suite at task boundaries; Debug only; no public network in automated tests.

**Goal:** Support common JavaScript-rendered public articles by adding an isolated WKWebView rendering fallback that triggers only when static extraction is insufficient, without importing source scripts into the local artifact and without widening the Document Import public interface.

**Architecture:** Document Import gains a composite `WebAcquiring` adapter: static URLSession acquisition first, then a cheap extraction probe reusing `StaticArticleExtractor`; only when the probe fails does an isolated WKWebView (non-persistent website data store, fresh process pool, dedicated run-loop thread) render the page and hand the serialized DOM back through the identical sanitizer/builder pipeline. The fallback lives entirely inside the existing internal `WebAcquiring` seam injected at the composition root, so checkpoints, queue semantics, cancellation, and publication are untouched.

**Tech Stack:** Swift 6, Swift Concurrency, Swift Testing, WebKit (WKWebView), Foundation, Network (existing fixture server), SwiftSoup 2.13.7 (existing extractor).

---

## Scope and Execution Constraints

- Work in the current workspace on `feature/t07-dynamic-web-fallback`; do not create a worktree.
- Use strict TDD for every behavior change: RED, GREEN, refactor, focused regression.
- Run only Debug tests and builds (`swift test`, `swift build`, `xcodebuild -configuration Debug`).
- Do not run `swift test -c release`, `swift build -c release`, or any Release Xcode build.
- No automated test may contact the public network; every dynamic fixture is served by `LocalHTTPFixtureServer` on loopback.
- Do not widen the Document Import public interface: no new public types, no KnowledgeCore or AppSupport changes.
- Do not modify checkpoint codecs, queue schema, publication, or reading-side code.
- Do not add PDF support, SwiftUI screens, persistent annotations, translation, or search.

## Design Notes and Risks

- **Fallback trigger**: the composite acquirer probes with `StaticArticleExtractor.extract`. Any probe failure (including `noReadableBlocks` and `unreadableHTML`) selects the dynamic path; probe success returns the static page unchanged. This keeps the "static first" guarantee and reuses one tested heuristic.
- **Isolation**: `WKWebsiteDataStore.nonPersistent()` plus a fresh `WKProcessPool()` per render session; authentication challenges are always rejected, so no Safari credential or cookie state is imported.
- **Headless execution**: WKWebView is driven on a dedicated run-loop thread owned by Document Import so the renderer works under `swift test` without a UI. Risk: WebKit off-main-thread use; fallback plan if it proves unstable in this environment is a `@MainActor` renderer plus `RunLoop.main` pumping in tests — stop and report before switching approaches.
- **Limits**: redirect count cap, page-load timeout, serialized-DOM byte cap, main-frame-only navigation, http(s)-only schemes. Limit violations map to existing `WebAcquisitionError` cases so failure classification needs no new public failure codes.
- **Checkpointing**: dynamic rendering happens inside the existing `acquiring` stage. The acquired checkpoint stores rendered HTML bytes, so restart after the acquired checkpoint resumes without network or re-rendering.

### Hosting Strategy Decision (2026-08-09)

The original risk materialized: WKWebView cannot be driven inside the `swift test` process. Off-main-thread hosting traps (SIGTRAP), and main-thread hosting hangs because the test runner blocks the main thread and the main run loop never spins. A standalone diagnostic process with a spinning main run loop confirmed the renderer logic works. **Decision (user-approved):** keep the production `IsolatedWKWebViewRenderer` (valid in the app, whose main run loop always spins) and test through the `DynamicWebRendering` seam with scripted stubs; the dynamic fixture's script effect is simulated by a kept-in-sync rendered-DOM string. The renderer itself is validated by the standalone diagnostic, not the automated suite.

---

## File Structure

- Create `Sources/DocumentImport/Internal/IsolatedWebRenderer.swift` — `DynamicWebRendering` seam, `RenderedWebPage` value, isolated WKWebView production renderer, run-loop host.
- Create `Sources/DocumentImport/Internal/WebResourceLoading.swift` — `DynamicFallbackWebAcquirer` composite (static-first probe + dynamic fallback).
- Modify `Sources/DocumentImport/DocumentImport.swift` — composition root default uses the composite acquirer.
- Create `Tests/Fixtures/Web/dynamic-article/index.html` — script-rendered article fixture.
- Modify `Tests/Fixtures/FixtureCatalog.swift` — expose `dynamicWebArticleURL`.
- Create `Tests/DocumentImportTests/DynamicWebImportTests.swift` — renderer, acquirer, and end-to-end integration tests.
- Modify `Tests/DocumentImportTests/DocumentImportTestSupport.swift` — spy dynamic renderer helper.

---

## Task 1: Isolated dynamic rendering seam

**Goal**

A tested `DynamicWebRendering` seam with a production WKWebView adapter that renders JavaScript-driven pages in isolation under enforced limits.

**Files:**

- Create: `Sources/DocumentImport/Internal/IsolatedWebRenderer.swift`
- Create: `Tests/Fixtures/Web/dynamic-article/index.html`
- Modify: `Tests/Fixtures/FixtureCatalog.swift`
- Create: `Tests/DocumentImportTests/DynamicWebImportTests.swift`

- [x] **Step 1: Add the dynamic article fixture**

Create `Tests/Fixtures/Web/dynamic-article/index.html`:

```html
<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<title>Dynamic Fixture Article</title>
</head>
<body>
<div id="root"></div>
<script>
(function () {
    var root = document.getElementById("root");
    var article = document.createElement("article");
    var title = document.createElement("h1");
    title.textContent = "Dynamic Fixture Article";
    var intro = document.createElement("p");
    intro.textContent = "This paragraph is rendered entirely by script.";
    var heading = document.createElement("h2");
    heading.textContent = "Generated Section";
    var body = document.createElement("p");
    body.textContent = "Second rendered paragraph with a "
        + (document.cookie ? "leaked cookie" : "clean session") + ".";
    article.appendChild(title);
    article.appendChild(intro);
    article.appendChild(heading);
    article.appendChild(body);
    root.appendChild(article);
})();
</script>
</body>
</html>
```

The static DOM must fail the extraction probe: `<body>` contains only an empty `div#root` and a script, so `readableRoot` finds no scorable candidate.

Add to `FixtureCatalog.swift`:

```swift
public static let dynamicWebArticleURL = requiredResource(
    name: "index",
    extension: "html",
    subdirectory: "Web/dynamic-article"
)
```

- [x] **Step 2: Write failing renderer tests**

> Adjusted per Hosting Strategy Decision: WKWebView-based renderer tests cannot run under `swift test`; the suite became `DynamicWebRenderingSeamTests` — scripted-stub seam contract tests plus a check that the simulated post-render DOM feeds `StaticArticleExtractor`.

Create `Tests/DocumentImportTests/DynamicWebImportTests.swift` with the renderer suite (serve fixtures through `LocalHTTPFixtureServer`):

```swift
@Suite(.serialized)
struct IsolatedWebRendererTests {
    @Test(.timeLimit(.minutes(2)))
    func rendersScriptDrivenContentIntoStaticHTML() async throws

    @Test(.timeLimit(.minutes(2)))
    func singleRedirectIsFollowedAndFinalURLIsReported() async throws

    @Test(.timeLimit(.minutes(2)))
    func redirectChainBeyondLimitFailsAsInvalidResponse() async throws

    @Test(.timeLimit(.minutes(2)))
    func pageLoadBeyondTimeoutFailsAsTimedOut() async throws

    @Test(.timeLimit(.minutes(2)))
    func renderedDOMBeyondByteCapFailsAsTooLarge() async throws

    @Test(.timeLimit(.minutes(2)))
    func nonHTTPSchemeIsRejected() async throws

    @Test(.timeLimit(.minutes(2)))
    func noCookieStateLeakIntoRenderedPage() async throws

    @Test(.timeLimit(.minutes(2)))
    func taskCancellationStopsRendering() async throws
}
```

Behavior under test:

- `rendersScriptDrivenContentIntoStaticHTML`: serving the dynamic fixture, `render` returns HTML containing `This paragraph is rendered entirely by script.`; the returned `finalURL` equals the requested URL.
- `singleRedirectIsFollowedAndFinalURLIsReported`: `/redirect/1` answers 302 to the dynamic page; render succeeds with `finalURL` pointing at the final path.
- `redirectChainBeyondLimitFailsAsInvalidResponse`: `/redirect/12` chains past the injected `maximumRedirectCount: 10`; render throws `WebAcquisitionError.invalidHTTPResponse`.
- `pageLoadBeyondTimeoutFailsAsTimedOut`: the route delays the response 30 s; inject `pageLoadTimeout: .seconds(2)`; render throws `.requestTimedOut`.
- `renderedDOMBeyondByteCapFailsAsTooLarge`: serve a page whose script appends `'x'.repeat(200_000)` text; inject `maximumRenderedHTMLBytes: 65_536`; render throws `.responseTooLarge`.
- `nonHTTPSchemeIsRejected`: `render(URL(fileURLWithPath:))` throws `.invalidHTTPResponse` without touching the network.
- `noCookieStateLeakIntoRenderedPage`: the server sends `Set-Cookie: pkn-session=secret`; the fixture prints `document.cookie` into the article; the rendered HTML must contain `clean session` and never `pkn-session=secret`.
- `taskCancellationStopsRendering`: start `render` against a 30 s-delayed route in a child task, cancel it, and expect `CancellationError`.

- [x] **Step 3: Run tests to verify RED**

Run:

```bash
swift test --filter IsolatedWebRendererTests
```

Expected: compile failure because `IsolatedWebRenderer.swift` does not exist yet.

- [x] **Step 4: Implement the isolated renderer**

> Adjusted per Hosting Strategy Decision: delegate methods pin explicit Objective-C selectors; `WKProcessPool` reuse dropped (deprecated on macOS 12+); isolation rests on the non-persistent data store.

Create `Sources/DocumentImport/Internal/IsolatedWebRenderer.swift` with:

```swift
import Foundation
import WebKit

struct RenderedWebPage: Hashable, Sendable {
    let finalURL: URL
    let html: Data
}

protocol DynamicWebRendering: Sendable {
    func render(_ url: URL) async throws -> RenderedWebPage
}

struct IsolatedWKWebViewRenderer: DynamicWebRendering {
    var pageLoadTimeout: Duration
    var maximumRedirectCount: Int
    var maximumRenderedHTMLBytes: Int

    init(
        pageLoadTimeout: Duration = .seconds(30),
        maximumRedirectCount: Int = 10,
        maximumRenderedHTMLBytes: Int = 10 * 1024 * 1024
    )

    func render(_ url: URL) async throws -> RenderedWebPage
}
```

Implementation requirements:

- `WebKitRunLoopHost`: a single `@unchecked Sendable` host owning a dedicated `Thread` whose body spins `RunLoop.current.run(mode:before:)` in a loop; expose `perform(_ block: @escaping () -> Void)` via `thread.perform`. All WKWebView objects are created, used, and destroyed on this thread.
- Each `render` call builds one render session on the host thread: fresh `WKWebViewConfiguration` with `websiteDataStore = .nonPersistent()`, a fresh `WKProcessPool()`, and `defaultWebpagePreferences.allowsContentJavaScript = true`; one `WKWebView`; one `WKNavigationDelegate`.
- Navigation policy (`decidePolicyFor navigationAction`): allow only main-frame http(s); count `navigationAction.isRedirect` occurrences and cancel with `.invalidHTTPResponse` beyond the cap; cancel everything else without failing the primary load.
- Authentication (`didReceive challenge`): always `cancelAuthenticationChallenge`; record an auth flag so the resulting load failure maps to `.accessDenied`.
- Timeout: schedule a `Timer` on the host run loop for `pageLoadTimeout`; on fire, stop loading and fail with `.requestTimedOut`.
- Success (`didFinish`): invalidate the timer, evaluate `document.documentElement.outerHTML`; on a non-string result fail `.invalidHTTPResponse`; on byte count above `maximumRenderedHTMLBytes` fail `.responseTooLarge`; otherwise finish with `RenderedWebPage(finalURL: webView.url ?? requestedURL, html:)`.
- Failure mapping: `didFail` / `didFailProvisionalNavigation` map `NSURLError` codes — `timedOut` → `.requestTimedOut`; connectivity codes → `.networkUnavailable`; `cancelled` caused by our own policy/timeout/cancellation decisions keeps the decision error; auth-flagged loads → `.accessDenied`; anything else → `.networkUnavailable`.
- Swift Task cancellation: `withTaskCancellationHandler` performs cancellation on the host thread — `stopLoading()`, teardown, resume with `CancellationError()`. A `finished` flag guarantees exactly one continuation resume.
- Teardown after every terminal outcome: invalidate timer, `stopLoading()`, nil the navigation delegate, drop the web view, all on the host thread.

- [x] **Step 5: Run renderer tests to verify GREEN**

Run:

```bash
swift test --filter IsolatedWebRendererTests
```

Expected: PASS. If WKWebView proves unusable off the main thread in this environment, stop and report before changing the hosting strategy.

> Outcome: WKWebView proved unusable under `swift test` (see Hosting Strategy Decision). GREEN was verified on the seam suite instead:
>
> ```bash
> swift test --filter DynamicWebRenderingSeamTests
> ```

- [x] **Step 6: Run focused regressions and commit**

Run:

```bash
swift test --filter DocumentImportTests
```

Expected: PASS.

```bash
git add Sources/DocumentImport/Internal/IsolatedWebRenderer.swift \
  Tests/Fixtures/Web/dynamic-article/index.html \
  Tests/Fixtures/FixtureCatalog.swift \
  Tests/DocumentImportTests/DynamicWebImportTests.swift
git commit -m "feat: add isolated dynamic web renderer"
```

---

## Task 2: Composite fallback acquirer and composition root

**Goal**

Static-first acquisition with extraction-probe-gated dynamic fallback, wired into the production composition root without widening the public interface.

**Files:**

- Create: `Sources/DocumentImport/Internal/WebResourceLoading.swift`
- Modify: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Modify: `Tests/DocumentImportTests/DynamicWebImportTests.swift`

- [x] **Step 1: Write failing acquirer tests**

> Adjusted: `SpyDynamicRenderer` injects its error at construction (actor properties are not externally mutable), and a `FixedWebAcquirer` stub feeds the static side.

Add a spy helper to `DocumentImportTestSupport.swift`:

```swift
actor SpyDynamicRenderer: DynamicWebRendering {
    private let html: Data
    private(set) var renderCallCount = 0
    var errorToThrow: Error?

    init(html: Data)
    func render(_ url: URL) async throws -> RenderedWebPage
}
```

Add suite `DynamicFallbackAcquirerTests` to `DynamicWebImportTests.swift`:

```swift
@Test func sufficientStaticContentNeverInvokesTheDynamicRenderer() async throws
@Test func insufficientStaticContentFallsBackToRenderedHTML() async throws
@Test func rendererAcquisitionErrorsPropagate() async throws
```

- `sufficientStaticContentNeverInvokesTheDynamicRenderer`: a static acquirer returning the catalog article; `renderCallCount == 0`; returned bytes identical to the static page.
- `insufficientStaticContentFallsBackToRenderedHTML`: a static acquirer returning the raw dynamic fixture bytes (static probe fails); the spy returns rendered HTML with a distinct final URL; the composite returns those bytes, `mimeType == "text/html"`, `sourceURL` preserved, `finalURL` from the renderer.
- `rendererAcquisitionErrorsPropagate`: spy throws `WebAcquisitionError.requestTimedOut`; the composite throws the same error.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter DynamicFallbackAcquirerTests
```

Expected: compile failure because `DynamicFallbackWebAcquirer` does not exist.

- [x] **Step 3: Implement the composite acquirer**

Create `Sources/DocumentImport/Internal/WebResourceLoading.swift`:

```swift
import Foundation

struct DynamicFallbackWebAcquirer: WebAcquiring {
    private let staticAcquirer: any WebAcquiring
    private let dynamicRenderer: any DynamicWebRendering

    init(
        staticAcquirer: any WebAcquiring = URLSessionStaticWebAcquirer(),
        dynamicRenderer: any DynamicWebRendering = IsolatedWKWebViewRenderer()
    )

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
```

Update the public composition root in `DocumentImport.swift`:

```swift
public init(library: LocalLibrary) {
    self.init(
        library: library,
        webAcquirer: DynamicFallbackWebAcquirer()
    )
}
```

- [x] **Step 4: Run acquirer tests and regressions**

Run:

```bash
swift test --filter DynamicFallbackAcquirerTests
swift test --filter URLSessionStaticWebAcquirerTests
swift test --filter StaticArticleExtractorTests
```

Expected: PASS. Existing suites keep injecting their own `WebAcquiring` doubles, so no behavioral change for them.

- [x] **Step 5: Commit**

```bash
git add Sources/DocumentImport/Internal/WebResourceLoading.swift \
  Sources/DocumentImport/DocumentImport.swift \
  Tests/DocumentImportTests/DocumentImportTestSupport.swift \
  Tests/DocumentImportTests/DynamicWebImportTests.swift
git commit -m "feat: gate dynamic fallback behind static extraction probe"
```

---

## Task 3: End-to-end dynamic import integration

**Goal**

Prove dynamic articles publish through identical task semantics: durable queue, script-free artifact, restart reuse from the acquired checkpoint, and typed failures.

**Files:**

- Modify: `Tests/DocumentImportTests/DynamicWebImportTests.swift`

- [x] **Step 1: Write failing integration tests**

Add suite `DynamicWebImportIntegrationTests` (`@Suite(.serialized)`, real `LocalLibrary` + real `DocumentImport` + `LocalHTTPFixtureServer` following the `RealStaticWebImportIntegrationTests` harness style):

```swift
@Test(.timeLimit(.minutes(3)))
func dynamicArticlePublishesAScriptFreeSourceDocument() async throws

@Test(.timeLimit(.minutes(3)))
func restartAfterAcquiredCheckpointReusesRenderedHTML() async throws

@Test(.timeLimit(.minutes(3)))
func dynamicRenderingFailureSurfacesTypedRetryableFailure() async throws
```

- `dynamicArticlePublishesAScriptFreeSourceDocument`: serve the dynamic fixture; submit through the public API; expect terminal `.published`; the published blocks contain `This paragraph is rendered entirely by script.` and `clean session`; the published artifact `index.html` bytes contain no `<script` and include the CSP header meta; the dynamic renderer was invoked exactly once (inject a spy through the internal initializer).
- `restartAfterAcquiredCheckpointReusesRenderedHTML`: inject `importRunnerBoundaryHook` throwing `ImportTaskRunnerInterruption.injectedProcessTermination` at `.afterAcquiredCheckpoint`; discard the importer, reopen `LocalLibrary.open(at:)` on the same root with a fresh `DocumentImport` sharing the same spy renderer; the task resumes to `.published` and total `renderCallCount` stays 1 (no network for the page either: fixture server counts requests).
- `dynamicRenderingFailureSurfacesTypedRetryableFailure`: static acquirer succeeds but returns the dynamic fixture bytes while the renderer throws `WebAcquisitionError.requestTimedOut`; expect terminal failure with code `.requestTimedOut` and recovery `.retryable`.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter DynamicWebImportIntegrationTests
```

Expected: FAIL — publication of script-rendered content, restart reuse, or typed failure edges are not yet proven (first run may already pass partially; any failing edge justifies the task; if all pass immediately, record that and move on without inventing behavior).

> Outcome: all three integration tests passed on the first run — the seam composition from Tasks 1–2 already carries dynamic content through the shared task semantics, so no new behavior was invented.

- [x] **Step 3: Fix until GREEN**

Only fix genuine gaps (e.g., probe edge cases, fixture serving details). Do not widen interfaces.

Run:

```bash
swift test --filter DynamicWebImportIntegrationTests
```

Expected: PASS.

- [x] **Step 4: Commit**

```bash
git add Tests/DocumentImportTests/DynamicWebImportTests.swift
git commit -m "test: prove dynamic web import publishes through shared semantics"
```

---

## Task 4: Final regression, review, and merge

- [ ] **Step 1: Run full Debug verification**

```bash
swift test
swift build
```

Expected: all tests pass, Debug build succeeds.

- [ ] **Step 2: Run Debug macOS app build**

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t07 \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: Whitespace and scope check**

```bash
git diff --check origin/main...HEAD
git diff --name-only origin/main...HEAD
```

Expected: no whitespace errors; diff limited to this plan plus the T07-owned source, fixture, and test files.

- [x] **Step 4: Final code review**

Use `superpowers:requesting-code-review` against the master plan Task 7 definition and `origin/main...HEAD`. Fix every Critical and Important finding with a failing regression test first.

> Review outcome: no Critical findings. One Important finding fixed: the navigation-policy and authentication callbacks were migrated to the SDK's async delegate variants (the completion-handler variants share their Objective-C selectors with those async requirements in the current SDK, so selector pinning conflicted); a bounded grace timer now covers DOM serialization after `didFinish`. Standalone diagnostics were extended to prove real WKWebView dispatch of the pinned selectors for redirect follow, redirect-overflow cancellation, and basic rendering; the 401 probe showed WKWebView delivers that case as a finished empty load rather than an authentication challenge, which still degrades safely to the typed `webpageHasNoReadableArticle` failure with a script-free artifact.

- [ ] **Step 5: Push and merge**

```bash
git push -u origin feature/t07-dynamic-web-fallback
```

After review approval: merge into `main` with `--no-ff`, verify the full suite on `main`, push.

---

## Completion Criteria

- Static articles import exactly as before; the dynamic renderer is never invoked for extractable static content.
- Script-rendered public articles publish Source Documents through the identical public task semantics (queued/running/published snapshots, checkpoints, cancel/retry untouched).
- The published artifact for a dynamic page contains no executable source scripts and retains the existing CSP guarantees.
- The renderer uses non-persistent website storage, rejects authentication challenges, and imports no cookie or Safari state.
- Redirect, timeout, rendered-DOM-size, scheme, and frame limits are enforced and mapped to existing `WebAcquisitionError` cases; no new public failure codes.
- Restart after the acquired checkpoint resumes a dynamic import without re-rendering or touching the network for the page.
- The Document Import public interface, KnowledgeCore, AppSupport, and LocalLibrary are unchanged.
- No automated test contacts the public network; only Debug tests and builds are run.
