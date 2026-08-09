# T08 Web Milestone Hardening Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Close the first-stage webpage acceptance gate of the master plan (Task 8): typed disk-space failure, refined Web degradation issue taxonomy, stage timing + publication facts, and hardening edge tests.

**Architecture:** All changes stay inside existing module boundaries. KnowledgeCore gains two `ImportIssue.Code` cases (pure data). DocumentImport refines failure classification (`classify`) and resource-localization issue codes, and threads per-stage timing into the terminal `ImportSuccess` as `ImportPublicationFacts` (no LocalLibrary schema change, no FTS/knowledge-log coupling). AppSupport is untouched unless compile fallout requires it.

**Tech Stack:** Swift 6, Swift Testing, GRDB-backed LocalLibrary, LocalHTTPFixtureServer for integration tests.

---

## Gap Analysis (verified 2026-08-09)

Covered by T04-T07, DO NOT rebuild:
- Checkpoint restart/retry across all durable boundaries (ImportRestartRecoveryTests, ImportLifecycleIntegrationTests)
- Cancellation during resource localization (WebResourceLocalizerTests:324, ImportTaskControlTests)
- Duplicate article from different URL (RealStaticWebImportIntegrationTests:262, DuplicateResolutionTests)
- Duplicate located in trash — location semantics covered (DuplicateResolutionTests:100/193/224); real moveToTrash API is a later phase, out of T08 scope
- Privacy: Sources/ has zero print/os_log; ImportFailure already carries only code/recovery/diagnosticID — but NO regression test exists

Real gaps T08 closes:
1. `LocalLibraryError.insufficientDiskSpace` is collapsed into `privacySafeFailure()` (`.localLibraryUnavailable`) inside `DocumentImport.classify` (DocumentImport.swift ~L969) and `ImportFailure.Code` has no `insufficientDiskSpace` case at all (ImportTaskModels.swift:84-96).
2. Issue taxonomy has a single code `optionalWebImageUnavailable` (SourceDocumentSemantics.swift:448-451) conflating network failure with safety/size/format rejection; encoding fallback in `StaticArticleExtractor.decodeHTML` is invisible.
3. No stage timing anywhere; no publication facts in the terminal success (ImportSuccess.published carries only documentID + issues, ImportTaskModels.swift:71-75).
4. No privacy regression test, no performance budget test, no restart-relocalization assertion, no manual acceptance checklist.

---

### Task 1: Typed insufficient-disk-space terminal failure

**Files:**
- Test: `Tests/DocumentImportTests/WebMilestoneHardeningTests.swift` (create)
- Modify: `Sources/DocumentImport/ImportTaskModels.swift` (ImportFailure.Code, ~L84)
- Modify: `Sources/DocumentImport/DocumentImport.swift` (classify, ~L960-975)

**Step 1: Write the failing test**

Create `Tests/DocumentImportTests/WebMilestoneHardeningTests.swift`:

```swift
import Testing

@testable import DocumentImport
import LocalLibrary

@Suite("Web milestone hardening")
struct WebMilestoneHardeningTests {
    @Test func classifyMapsInsufficientDiskSpaceToTypedRequiresUserActionFailure() {
        let failure = DocumentImport.classify(LocalLibraryError.insufficientDiskSpace)

        #expect(failure.code == .insufficientDiskSpace)
        #expect(failure.recovery == .requiresUserAction)
    }
}
```

**Step 2: Run test to verify it fails**

Run: `swift test --filter WebMilestoneHardeningTests`
Expected: compile error — `ImportFailure.Code` has no `insufficientDiskSpace` case.

**Step 3: Implement**

In `ImportFailure.Code` (ImportTaskModels.swift), add after `case publicationFailed`:

```swift
        case insufficientDiskSpace
```

In `DocumentImport.classify`, split `.insufficientDiskSpace` out of the collapsed `LocalLibraryError` group (DocumentImport.swift ~L963-975). Before that collapsed switch, add:

```swift
        if let error = error as? LocalLibraryError,
           error == .insufficientDiskSpace {
            return ImportFailure(
                code: .insufficientDiskSpace,
                recovery: .requiresUserAction
            )
        }
```

and remove `.insufficientDiskSpace` from the remaining collapse list so it still compiles.

**Step 4: Run test to verify it passes**

Run: `swift test --filter WebMilestoneHardeningTests`
Expected: PASS. Then run `swift test --filter DocumentImportTests` to confirm no classification regression.

**Step 5: Commit**

```bash
git add Tests/DocumentImportTests/WebMilestoneHardeningTests.swift Sources/DocumentImport/ImportTaskModels.swift Sources/DocumentImport/DocumentImport.swift
git commit -m "feat: surface insufficient disk space as a typed terminal failure"
```

---

### Task 2: Web degradation issue taxonomy

**Files:**
- Modify: `Sources/KnowledgeCore/SourceDocumentSemantics.swift` (~L448)
- Modify: `Sources/DocumentImport/Internal/WebResourceLocalizer.swift`
- Modify: `Sources/DocumentImport/Internal/StaticArticleExtractor.swift`
- Modify: `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift` (~L132)
- Test: `Tests/DocumentImportTests/WebResourceLocalizerTests.swift` (update expectations)
- Test: `Tests/DocumentImportTests/StaticArticleExtractorTests.swift` (add)
- Test: `Tests/DocumentImportTests/WebMilestoneHardeningTests.swift` (builder-level integration)

**Semantics decision:**
- `.optionalWebImageUnavailable` — network/HTTP fetch failure (non-2xx, transport error, bad scheme is EXCLUDED, see below).
- `.webImageRejected` — payload refused by safety gates: disallowed scheme/host guard, non-image MIME, Content-Length over cap, streamed bytes over cap, image validation failure.
- `.webEncodingFallback` — declared charset decode failed and a fallback path (utf-8 or meta scan) rescued the page.

**Step 1: Add KnowledgeCore codes**

```swift
    public enum Code: String, Codable, Hashable, Sendable {
        case optionalWebImageUnavailable
        case webImageRejected
        case webEncodingFallback
    }
```

**Step 2: Write failing localizer tests**

In `WebResourceLocalizerTests.swift`, existing tests that feed rejected payloads (wrong MIME / oversized / invalid image bytes — currently asserting `.optionalWebImageUnavailable`, around lines 64 and 91) must be updated to expect `.webImageRejected`. Add one new test proving a transport/HTTP failure still yields `.optionalWebImageUnavailable` if not already present. Run:

`swift test --filter WebResourceLocalizerTests`
Expected: FAIL on updated expectations.

**Step 3: Implement localizer rejection reasons**

In `WebResourceLocalizer.swift`, replace the binary `DownloadResult`:

```swift
private enum DownloadResult: Sendable {
    case available(Data, String, String, Int?, Int?)
    case unavailable(UnavailableReason)

    enum UnavailableReason: Sendable {
        case fetchFailed
        case payloadRejected
    }
}
```

Mapping inside `download(_:session:)`:
- scheme/host guard failure → `.unavailable(.payloadRejected)`
- non-2xx status or missing/non-image Content-Type → `.unavailable(.payloadRejected)`
- Content-Length over cap, streamed bytes over cap, empty or invalid payload → `.unavailable(.payloadRejected)`
- `catch` transport error path → `.unavailable(.fetchFailed)`

At the issue-emission site (~L89), choose the code:

```swift
            case .unavailable(let reason):
                issues.append(WebLocalizationIssue(
                    code: reason == .payloadRejected
                        ? .webImageRejected
                        : .optionalWebImageUnavailable,
                    candidateKey: candidate.stableKey
                ))
```

Run: `swift test --filter WebResourceLocalizerTests` — Expected: PASS.

**Step 4: Write failing extractor encoding-fallback test**

In `StaticArticleExtractorTests.swift` add:

```swift
    @Test func misdeclaredCharsetFallsBackAndFlagsTheDegradation() throws {
        // Declares utf-16 but is plain ASCII/UTF-8: the declared decode
        // fails and the UTF-8 fallback rescues the page.
        let html = Data("""
        <!DOCTYPE html><html><head><meta charset="utf-16">\
        <title>Encoding Rescue</title></head>\
        <body><article><p>Fallback body paragraph long enough to pass.</p>\
        </article></body></html>
        """.utf8)

        let article = try StaticArticleExtractor().extract(
            html: html,
            sourceURL: URL(string: "https://example.com/article")!
        )

        #expect(article.usedEncodingFallback)
    }
```

Run: `swift test --filter StaticArticleExtractorTests`
Expected: FAIL — `usedEncodingFallback` does not exist.

**Step 5: Implement extractor flag**

Add `public let usedEncodingFallback: Bool` (or internal, matching existing visibility) to `ExtractedWebArticle` and update its initializer. Change `decodeHTML` to return the decode outcome:

```swift
    private func decodeHTML(
        _ data: Data,
        persistedCharset: String?
    ) -> (text: String, usedFallback: Bool)? {
        if let encoding = htmlStringEncoding(for: persistedCharset),
           let decoded = String(data: data, encoding: encoding) {
            return (decoded, false)
        }
        if let decoded = String(data: data, encoding: .utf8) {
            return (decoded, true)
        }
        for charset in html5MetaCharsets(in: data) {
            guard let encoding = htmlStringEncoding(for: charset),
                  let decoded = String(data: data, encoding: encoding)
            else {
                continue
            }
            return (decoded, true)
        }
        return nil
    }
```

Thread the flag into `ExtractedWebArticle` construction inside `extractArticle`.

Run: `swift test --filter StaticArticleExtractorTests` — Expected: PASS.

**Step 6: Wire the encoding issue into the builder + failing integration test**

In `WebMilestoneHardeningTests.swift` add a builder-level test constructing an article whose `usedEncodingFallback == true` and asserting the built document carries `ImportIssue(code: .webEncodingFallback)`. Follow the existing construction pattern in `StaticWebDocumentBuilderTests.swift`. Run `swift test --filter WebMilestoneHardeningTests` — Expected: FAIL.

Then in `StaticWebDocumentBuilder.swift` (~L132), after mapping `localized.issues`, append the encoding degradation:

```swift
            var issues = localized.issues.map { issue in
                KnowledgeCore.ImportIssue(
                    code: issue.code,
                    relatedBlockID: imageBlockIDs[issue.candidateKey]
                )
            }
            if article.usedEncodingFallback {
                issues.append(KnowledgeCore.ImportIssue(
                    code: .webEncodingFallback
                ))
            }
```

Run: `swift test --filter "StaticWebDocumentBuilderTests|WebMilestoneHardeningTests"` — Expected: PASS.

**Step 7: Commit**

```bash
git add -A
git commit -m "feat: split web degradation issues into rejected, unavailable, and encoding fallback"
```

---

### Task 3: Stage timing and publication facts

**Files:**
- Modify: `Sources/DocumentImport/ImportTaskModels.swift`
- Modify: `Sources/DocumentImport/Internal/ImportTaskRunner.swift`
- Modify: `Sources/DocumentImport/DocumentImport.swift` (~L848 construction site)
- Test: `Tests/DocumentImportTests/WebMilestoneHardeningTests.swift`

**Design decision:** facts ride the existing terminal-success path (`ImportSuccess.published`). No LocalLibrary schema change; downstream projection (FTS/knowledge log) consumes facts later without T08 coupling.

**Step 1: Add the fact types**

In `ImportTaskModels.swift`:

```swift
public enum ImportStage: String, Codable, Hashable, Sendable {
    case acquiringSource
    case constructingDocument
    case publishing
}

public struct ImportStageTiming: Hashable, Codable, Sendable {
    public let stage: ImportStage
    public let durationMilliseconds: Int64

    public init(stage: ImportStage, durationMilliseconds: Int64) {
        self.stage = stage
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct ImportPublicationFacts: Hashable, Codable, Sendable {
    public let diagnosticID: UUID
    public let stageTimings: [ImportStageTiming]

    public init(diagnosticID: UUID = UUID(), stageTimings: [ImportStageTiming]) {
        self.diagnosticID = diagnosticID
        self.stageTimings = stageTimings
    }
}
```

Extend the success case:

```swift
    case published(
        documentID: SourceDocumentID,
        issues: [KnowledgeCore.ImportIssue],
        facts: ImportPublicationFacts
    )
```

**Step 2: Write failing integration test**

In `WebMilestoneHardeningTests.swift`, model on `RealStaticWebImportIntegrationTests` (real LocalLibrary + LocalHTTPFixtureServer, static fixture page): run one import to success and assert on the terminal success:

```swift
        #expect(facts.stageTimings.map(\.stage) == [
            .acquiringSource, .constructingDocument, .publishing,
        ])
        for timing in facts.stageTimings {
            #expect(timing.durationMilliseconds >= 0)
        }
```

Run: `swift test --filter WebMilestoneHardeningTests` — Expected: compile error / FAIL.

**Step 3: Implement timing in the runner**

In `ImportTaskRunner`, capture `let clock = ContinuousClock()`; wrap the three stage bodies with `clock.measure { }` (or `Instant` deltas if the bodies are async with awaits inside — measure with `let start = clock.now` / `start.duration(to: clock.now)` around each stage). Collect `[ImportStageTiming]` and thread it through the runner's existing successful-result path up to `DocumentImport.swift` ~L848, where the success is constructed:

```swift
            return .published(
                documentID: ...,
                issues: ...,
                facts: ImportPublicationFacts(stageTimings: timings)
            )
```

Fix every other `.published(` construction/destructure site the compiler reports (check AppSupport and existing tests; the gap analysis found none in AppSupport, but verify).

**Step 4: Verify**

Run: `swift test --filter WebMilestoneHardeningTests` — Expected: PASS.
Run: `swift build` — Expected: no warnings about unused result.

**Step 5: Commit**

```bash
git add -A
git commit -m "feat: record per-stage timing and publication facts on import success"
```

---

### Task 4: Hardening edge tests

**Files:**
- Test: `Tests/DocumentImportTests/WebMilestoneHardeningTests.swift`

**Step 1: Restart re-localizes resources after acquired checkpoint**

Add an integration test modeled on `DynamicWebImportIntegrationTests.restartAfterAcquiredCheckpointReusesRenderedHTML`, but with the STATIC fixture that contains images (identify it in `FixtureCatalog.swift`; if the existing static fixture has no image candidates, add a fixture HTML with one local relative image served by the fixture server):
- Crash injection at `.afterAcquiredCheckpoint` (existing `ImportRunnerCrashInjector` seam).
- Reopen and resume; assert the published artifact package contains an `assets/` entry and the document still publishes.

**Step 2: Privacy regression**

Add a test encoding a terminal failure to JSON and asserting no leakage vectors exist:

```swift
        let failure = ImportFailure(code: .requestTimedOut, recovery: .retryable)
        let encoded = try JSONEncoder().encode(failure)
        let payload = String(decoding: encoded, as: UTF8.self)

        #expect(!payload.contains("http"))
        #expect(!payload.contains(articleBodyMarker))
        #expect(payload.contains(failure.diagnosticID.uuidString))
```

Use a marker string standing in for article body content. Keep the assertion scoped to diagnostic payloads (`ImportFailure`); `ImportTaskSnapshot.source` intentionally shows the URL to the user and is out of scope.

**Step 3: Performance budget**

Add an integration test measuring the static-fixture import end to end:

```swift
        let clock = ContinuousClock()
        let elapsed = await clock.measure { /* enqueue + await terminal success */ }
        #expect(elapsed < .seconds(5))
```

Five seconds is generous for a local loopback fixture; it guards against order-of-magnitude regressions only.

**Step 4: Run and commit**

Run: `swift test --filter WebMilestoneHardeningTests` — Expected: all PASS.

```bash
git add -A
git commit -m "test: harden web milestone edges (restart re-localization, privacy, budget)"
```

---

### Task 5: Manual acceptance checklist, full regression, review, merge

**Step 1: Write the non-automated checklist**

Create `docs/product/web-import-acceptance-checklist.md` mapping each §5.4 gate of `docs/product/macos-v1-scope.md` to manual steps with representative public URLs (dynamic JS article, redirect chain, GBK/GB2312 page, image-heavy page, 401/auth page). Mark it explicitly as manual-only, never wired into CI.

**Step 2: Verify no automated test hits a public website**

Run: `rg -n "https?://" Tests/ --glob '!*Fixture*' | rg -v "example\.(com|org)|localhost|127\.0\.0\.1"` — review every hit; any real public fetch must be removed or moved into the manual checklist.

**Step 3: Full regression**

Run: `swift test` — Expected: all tests pass (baseline 381 + new).
Run: `swift build` — clean.

**Step 4: App-level build**

Run xcodebuild using the existing DerivedData at `.build/xcodebuild` (a fresh DerivedData will network-clone packages and may hang; the sandbox may require elevated permissions to write ~/Library/Caches). Expected: `** BUILD SUCCEEDED **`.

**Step 5: Code review**

Dispatch the CodeReview subagent on `main..HEAD`. Fix findings before merge.

**Step 6: Merge and push**

```bash
git checkout main
git merge --no-ff feature/t08-web-milestone-hardening
git push origin main
```

**Step 7: Record completion in this plan** (check off all steps, note review outcomes).

---

## Exit criteria (from master plan Task 8)

- Web Document Import satisfies the V1 webpage import requirements (gates verified by tests 1-4 + manual checklist).
- No automated test depends on a public website (verified in Task 5 Step 2).

## Assumptions

- Real trash move/restore APIs (§4.3) remain out of T08 scope; trash-location semantics are already tested.
- True ENOSPC injection (filling a volume) is impractical in CI; the classify chain from `LocalLibraryError.insufficientDiskSpace` is the tested seam, matching how T07 tested typed failures.
- Publication facts are delivered through the DocumentImport seam; LocalLibrary persistence of facts is deferred to keep GRDB schema stable.
