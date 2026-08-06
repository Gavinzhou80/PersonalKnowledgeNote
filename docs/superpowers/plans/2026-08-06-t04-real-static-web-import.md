# T04 Real Static Web Import Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Import ordinary public static articles through production URLSession acquisition into rich, script-free, offline Source Documents with localized images, persistent Import Issues, stable identity, and duplicate provenance.

**Architecture:** Extend KnowledgeCore with backward-compatible semantic Web document values, then implement a staged internal pipeline: URLSession acquisition, SwiftSoup article extraction, bounded resource localization, offline artifact rendering, Source Document construction, and existing Local Library publication. Automated tests use a loopback Network-framework HTTP server and Debug configuration only.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, Network, CryptoKit, SwiftSoup 2.13.7, GRDB-backed LocalLibrary, AsyncStream, URLSession.

---

## Scope and Execution Constraints

- Work in the current workspace and feature branch; do not create a worktree.
- Preserve the user's existing modified and untracked files.
- Use strict TDD for every behavior change.
- Run focused Debug tests regularly and full `swift test` at the end.
- Run a Debug macOS app build at the final gate.
- Do not run release tests or release builds.
- Do not add WKWebView, dynamic rendering, scheduling, cancellation, retry, or restart recovery.

## File Structure

### KnowledgeCore

- Create `Sources/KnowledgeCore/SourceDocumentSemantics.swift` — block categories and roles, inline markup ranges, media references, relations, and persistent Import Issues.
- Modify `Sources/KnowledgeCore/SourceDocument.swift` — backward-compatible metadata, block, structure, and content encoding/validation.
- Modify `Tests/KnowledgeCoreTests/PublicationModelTests.swift` — legacy decoding and validation coverage.

### Package and fixtures

- Modify `Package.swift` — pin SwiftSoup 2.13.7 and add the DocumentImport dependency; declare direct AppSupportTests dependency on DocumentImport.
- Modify `Tests/Fixtures/FixtureCatalog.swift` — rich article and image fixture access.
- Create `Tests/Fixtures/Web/RichArticle/index.html` — rich semantic fixture.
- Create `Tests/Fixtures/Web/RichArticle/hero.svg` — deterministic text-based localized image fixture.

### DocumentImport pipeline

- Modify `Sources/DocumentImport/ImportTaskModels.swift` — consume KnowledgeCore's persistent ImportIssue type and extend privacy-safe acquisition failure codes.
- Modify `Sources/DocumentImport/Internal/WebAcquisition.swift` — richer acquisition result and exhaustive acquisition errors.
- Create `Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift` — production static acquisition.
- Create `Sources/DocumentImport/Internal/WebArticleModel.swift` — focused internal extracted article values.
- Create `Sources/DocumentImport/Internal/StaticArticleExtractor.swift` — SwiftSoup selection, cleanup, metadata, blocks, markup, media, and evidence.
- Create `Sources/DocumentImport/Internal/WebResourceLocalizer.swift` — bounded image downloads and issue creation.
- Create `Sources/DocumentImport/Internal/WebArtifactRenderer.swift` — safe offline package rendering.
- Modify `Sources/DocumentImport/Internal/StableWebIdentity.swift` — semantic block identity and principal fingerprint.
- Replace the implementation of `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift` with the orchestration façade for extraction, localization, rendering, and Source Document construction.
- Modify `Sources/DocumentImport/DocumentImport.swift` — public production initializer, async builder flow, issue propagation, and richer failure mapping.

### LocalLibrary descriptor authority

- Modify `Sources/LocalLibrary/LocalLibrary.swift` — package-level Web package descriptor calculation backed by ManagedArtifactPayload.
- Test in `Tests/LocalLibraryTests/ArtifactStagingTests.swift` — DocumentImport can request the same descriptor Local Library later verifies.

### Tests

- Create `Tests/DocumentImportTests/LocalHTTPFixtureServer.swift` — in-process loopback HTTP server.
- Create `Tests/DocumentImportTests/URLSessionStaticWebAcquirerTests.swift` — production URLSession behavior.
- Create `Tests/DocumentImportTests/StaticArticleExtractorTests.swift` — rich semantics and noise removal.
- Create `Tests/DocumentImportTests/WebResourceLocalizerTests.swift` — local image and missing-image issue behavior.
- Create `Tests/DocumentImportTests/RealStaticWebImportIntegrationTests.swift` — public lifecycle, offline package, issues, and duplicate provenance.
- Modify existing DocumentImport tests to retain the T03 tracer expectations under the richer model.

---

### Task 1: Extend the authoritative Source Document model compatibly

**Files:**

- Create: `Sources/KnowledgeCore/SourceDocumentSemantics.swift`
- Modify: `Sources/KnowledgeCore/SourceDocument.swift`
- Modify: `Sources/DocumentImport/ImportTaskModels.swift`
- Modify: `Tests/KnowledgeCoreTests/PublicationModelTests.swift`
- Modify: `Tests/DocumentImportTests/ImportTaskModelTests.swift`

- [ ] **Step 1: Write failing backward-compatibility and semantic validation tests**

Add tests that encode a legacy shape containing only the pre-T04 fields and decode it as current values:

```swift
@Test
func legacySourceDocumentJSONDecodesWithSemanticDefaults() throws {
    let blockID = SourceBlockID()
    let legacy = LegacySourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: LegacyMetadata(
            title: "Legacy",
            author: nil
        ),
        blocks: [LegacyBlock(
            id: blockID,
            canonicalText: "Legacy paragraph"
        )],
        structure: LegacyStructure(orderedBlockIDs: [blockID]),
        evidence: [blockID: .web(locator: "article > p")]
    )

    let decoded = try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.importedMetadata.publishedAt == nil)
    #expect(decoded.blocks[0].category == .text)
    #expect(decoded.blocks[0].role == .paragraph)
    #expect(decoded.blocks[0].inlineMarkup.isEmpty)
    #expect(decoded.blocks[0].media == nil)
    #expect(decoded.structure.relations.isEmpty)
    #expect(decoded.issues.isEmpty)
}
```

Add focused tests for:

- a heading, code, media, and caption block round trip;
- UTF-16 inline ranges at the exact end of Canonical Text;
- rejection of an out-of-range markup span;
- rejection of an absolute or traversal media path;
- rejection of a relation whose endpoint is not a block;
- rejection of an Import Issue that references an unknown block;
- media block validation and non-media empty-text rejection.

- [ ] **Step 2: Run the tests to verify RED**

Run:

```bash
swift test --filter legacySourceDocumentJSONDecodesWithSemanticDefaults
swift test --filter webSourceDocumentSemanticsRoundTrip
```

Expected: FAIL because the semantic values and new fields do not exist.

- [ ] **Step 3: Define semantic values**

Create `SourceDocumentSemantics.swift` with these public Codable, Hashable, Sendable types:

```swift
public enum SourceBlockCategory: String, Codable, Hashable, Sendable {
    case text
    case code
    case media
}

public enum SourceBlockRole: Codable, Hashable, Sendable {
    case heading(level: Int)
    case paragraph
    case listItem
    case quotation
    case codeBlock(language: String?)
    case image
    case caption
}

public struct SourceTextRange: Codable, Hashable, Sendable {
    public let utf16Offset: Int
    public let utf16Length: Int
    public init(utf16Offset: Int, utf16Length: Int) {
        precondition(utf16Offset >= 0 && utf16Length > 0)
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }
}

public enum InlineMarkupKind: Codable, Hashable, Sendable {
    case emphasis
    case strong
    case link(URL)
    case citation(URL?)
    case inlineCode
}

public struct InlineMarkup: Codable, Hashable, Sendable {
    public let range: SourceTextRange
    public let kind: InlineMarkupKind
    public init(range: SourceTextRange, kind: InlineMarkupKind) {
        self.range = range
        self.kind = kind
    }
}

public struct SourceMediaReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable { case image }
    public let kind: Kind
    public let artifactRelativePath: String
    public let mimeType: String
    public let altText: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?
}

public enum SourceRelationKind: String, Codable, Hashable, Sendable {
    case captionForMedia
}

public struct SourceRelation: Codable, Hashable, Sendable {
    public let sourceBlockID: SourceBlockID
    public let targetBlockID: SourceBlockID
    public let kind: SourceRelationKind
}

public struct ImportIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case optionalWebImageUnavailable
    }
    public let code: Code
    public let relatedBlockID: SourceBlockID?
    public init(code: Code, relatedBlockID: SourceBlockID? = nil) {
        self.code = code
        self.relatedBlockID = relatedBlockID
    }
}
```

Validate heading levels 1...6, safe asset-relative media paths, positive optional dimensions, and HTTP/HTTPS link destinations.

- [ ] **Step 4: Extend existing document values with decode defaults**

Modify `SourceDocument.swift`:

- `ImportedDocumentMetadata` gains `publishedAt: Date? = nil`.
- `SourceBlock` gains category, role, inlineMarkup, and media with defaults matching a legacy paragraph.
- `SourceStructure` gains `relations: [SourceRelation] = []`.
- `SourceDocumentContent` gains `issues: [ImportIssue] = []`.
- Custom decoders use `decodeIfPresent` and the documented defaults.
- Validation checks exact graph coverage plus markup ranges, relation endpoints, issue references, category/role/media consistency, and duplicate relations.

Keep existing initializer call sites source-compatible by providing default arguments.

- [ ] **Step 5: Move ImportIssue authority to KnowledgeCore**

Remove the DocumentImport-local `ImportIssue` declaration. `ImportSuccess.published` continues to use `[ImportIssue]`, now resolved from imported KnowledgeCore. Update model tests to compile through the same public success API.

- [ ] **Step 6: Run Debug tests**

Run:

```bash
swift test --filter KnowledgeCoreTests
swift test --filter DocumentImportTests
swift test --filter LocalLibraryTests
```

Expected: PASS, including existing persisted publication tests.

- [ ] **Step 7: Commit**

```bash
git add Sources/KnowledgeCore Sources/DocumentImport/ImportTaskModels.swift Tests/KnowledgeCoreTests/PublicationModelTests.swift Tests/DocumentImportTests/ImportTaskModelTests.swift
git commit -m "feat: extend source documents with web semantics"
```

---

### Task 2: Pin SwiftSoup and implement rich static article extraction

**Files:**

- Modify: `Package.swift`
- Modify: `Tests/Fixtures/FixtureCatalog.swift`
- Create: `Tests/Fixtures/Web/RichArticle/index.html`
- Create: `Tests/Fixtures/Web/RichArticle/hero.svg`
- Create: `Sources/DocumentImport/Internal/WebArticleModel.swift`
- Create: `Sources/DocumentImport/Internal/StaticArticleExtractor.swift`
- Create: `Tests/DocumentImportTests/StaticArticleExtractorTests.swift`

- [ ] **Step 1: Add the rich deterministic fixture**

The fixture must contain:

- `og:title`, standard author metadata, and `article:published_time`;
- article ID `story`;
- `h1`, `h2`, paragraphs, unordered and ordered list items;
- `blockquote`;
- inline `em`, `strong`, link with UTM parameters, `cite`, and inline code;
- a fenced `pre > code.language-swift` block;
- `figure` with `img` and `figcaption`;
- surrounding nav, advertisement, recommendation, form, script, tracking pixel, and hidden content.

Expose fixture URLs in FixtureCatalog.

- [ ] **Step 2: Write the failing extractor test**

The test parses fixture bytes and asserts exact metadata, ordered roles, canonical text, inline ranges, media candidate, caption relation intent, and evidence locators. It also asserts that noise text never appears.

Run:

```bash
swift test --filter extractsRichStaticArticleSemantics
```

Expected: FAIL because SwiftSoup and the extractor do not exist.

- [ ] **Step 3: Add SwiftSoup 2.13.7**

Add the dependency:

```swift
.package(
    url: "https://github.com/scinfu/SwiftSoup.git",
    exact: "2.13.7"
),
```

Add `.product(name: "SwiftSoup", package: "SwiftSoup")` only to the DocumentImport target. Add `"DocumentImport"` directly to AppSupportTests dependencies because that test target imports it.

- [ ] **Step 4: Define focused internal extracted values**

`WebArticleModel.swift` defines Sendable values independent of SwiftSoup nodes:

- `ExtractedWebArticle` with metadata, ordered blocks, root selector, and image candidates;
- `ExtractedWebBlock` with category, role, canonical text, inline markup, evidence locator, optional image key, and optional relation target key;
- `WebImageCandidate` with stable key, resolved URL, alt text, and evidence locator.

No SwiftSoup `Document`, `Element`, or `Node` leaves the extractor.

- [ ] **Step 5: Implement the SwiftSoup extractor**

Use `SwiftSoup.parse`. Select the best readable `article`, then `main`, then focused body candidate by supported semantic text count. Clone and clean the selected root.

Remove semantic noise and conventional id/class tokens for nav, ad, recommendation, sharing, subscription, cookie, and tracker content. Remove hidden elements, forms, scripts, styles, iframes, unsafe attributes, and tracking pixels.

Walk supported block elements without double counting. Build Canonical Text and UTF-16 markup ranges while visiting inline descendants. Normalize prose whitespace and preserve code line structure. Generate evidence by unique ID, stable semantic attribute, then relative tag/nth-of-type path.

Metadata priority and date parsing must match the design document.

- [ ] **Step 6: Run focused and regression tests**

```bash
swift test --filter StaticArticleExtractorTests
swift test --filter StaticWebDocumentBuilderTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Package.swift Tests/Fixtures Sources/DocumentImport/Internal/WebArticleModel.swift Sources/DocumentImport/Internal/StaticArticleExtractor.swift Tests/DocumentImportTests/StaticArticleExtractorTests.swift
git commit -m "feat: extract rich static article semantics"
```

---

### Task 3: Implement production URLSession static acquisition and loopback tests

**Files:**

- Modify: `Sources/DocumentImport/Internal/WebAcquisition.swift`
- Create: `Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift`
- Create: `Tests/DocumentImportTests/LocalHTTPFixtureServer.swift`
- Create: `Tests/DocumentImportTests/URLSessionStaticWebAcquirerTests.swift`

- [ ] **Step 1: Write failing real-session tests**

Create a Network-framework loopback server with route handlers for:

- HTML 200;
- redirect to HTML;
- 403;
- non-HTML content type;
- oversized response;
- delayed response longer than the configured timeout.

Tests use a real ephemeral URLSession and assert final URL, bytes, status classification, MIME classification, timeout, and no public network.

- [ ] **Step 2: Verify RED**

```bash
swift test --filter URLSessionStaticWebAcquirerTests
```

Expected: FAIL because production acquisition and server support do not exist.

- [ ] **Step 3: Extend acquisition values and errors**

`AcquiredWebPage` gains final URL, MIME type, and response bytes. `WebAcquisitionError` becomes exhaustive:

```swift
enum WebAcquisitionError: Error {
    case networkUnavailable
    case requestTimedOut
    case accessDenied
    case invalidHTTPResponse
    case unsupportedContentType
    case responseTooLarge
}
```

Update failure classification with an exhaustive switch and privacy-safe public codes.

- [ ] **Step 4: Implement URLSessionStaticWebAcquirer**

Use an ephemeral session, disabled cache, disabled credential persistence, request/resource timeouts, HTTP/HTTPS validation, article Accept header, 2xx validation, HTML MIME validation, and a fixed maximum response byte count.

The adapter must not instantiate WebKit or expose URLRequest/HTTPURLResponse publicly.

- [ ] **Step 5: Run tests**

```bash
swift test --filter URLSessionStaticWebAcquirerTests
swift test --filter DocumentImportTests
```

Expected: PASS without a public network.

- [ ] **Step 6: Commit**

```bash
git add Sources/DocumentImport/Internal/WebAcquisition.swift Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift Tests/DocumentImportTests/LocalHTTPFixtureServer.swift Tests/DocumentImportTests/URLSessionStaticWebAcquirerTests.swift
git commit -m "feat: acquire static webpages with urlsession"
```

---

### Task 4: Centralize Web package descriptors in LocalLibrary

**Files:**

- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Tests/LocalLibraryTests/ArtifactStagingTests.swift`
- Modify: `Sources/DocumentImport/Internal/StableWebIdentity.swift`
- Modify: existing DocumentImport builder tests.

- [ ] **Step 1: Write a failing descriptor-authority test**

Create a package containing `index.html` and `assets/hero.svg`. Assert that a package-level LocalLibrary operation returns the same descriptor later attached by `stageArtifact`.

```swift
let described = try LocalLibrary.describeWebPackage(at: packageURL)
let staged = try await workspace.stageArtifact(
    .package(packageURL, descriptor: described),
    expectedRevision: snapshot.revision
)
#expect(staged.descriptor == described)
```

- [ ] **Step 2: Verify RED**

```bash
swift test --filter documentImportUsesLocalLibraryDescriptorAuthority
```

Expected: FAIL because `describeWebPackage` does not exist.

- [ ] **Step 3: Implement the package-level LocalLibrary API**

Add a `package` static operation that validates a directory through `ManagedArtifactPayload.verifyAndSynchronize` and returns a `.webPackage` descriptor. Do not expose manifest bytes, managed paths, or hashing rules publicly.

Remove DocumentImport's copied manifest implementation. StableWebIdentity remains responsible only for block IDs and content fingerprinting.

- [ ] **Step 4: Run tests**

```bash
swift test --filter ArtifactStagingTests
swift test --filter StaticWebDocumentBuilderTests
```

Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/LocalLibrary/LocalLibrary.swift Tests/LocalLibraryTests/ArtifactStagingTests.swift Sources/DocumentImport/Internal/StableWebIdentity.swift Tests/DocumentImportTests
git commit -m "refactor: centralize web package descriptors"
```

---

### Task 5: Localize images and render a closed offline package

**Files:**

- Create: `Sources/DocumentImport/Internal/WebResourceLocalizer.swift`
- Create: `Sources/DocumentImport/Internal/WebArtifactRenderer.swift`
- Create: `Tests/DocumentImportTests/WebResourceLocalizerTests.swift`
- Modify: `Tests/DocumentImportTests/LocalHTTPFixtureServer.swift`

- [ ] **Step 1: Write failing localization tests**

The loopback server serves one valid `image/svg+xml` fixture and one missing image. Tests assert:

- at most four concurrent requests through an instrumented route counter;
- duplicate image URLs issue one request;
- valid image is written under `assets/<sha256>.svg`;
- missing image creates `optionalWebImageUnavailable` with no raw URL;
- generated HTML uses local `src`, removes `srcset`, and contains no automatic remote loads;
- after stopping the server, every referenced asset exists and the package remains parseable.

- [ ] **Step 2: Verify RED**

```bash
swift test --filter WebResourceLocalizerTests
```

Expected: FAIL because the localizer and renderer do not exist.

- [ ] **Step 3: Implement bounded localization**

Resolve candidates against the final page URL and `<base>`. Deduplicate URLs. Use a task group with an explicit four-request limit. Require 2xx image responses, image MIME types, and bounded bytes. Derive safe extensions from MIME type and filenames from SHA-256 content hash.

Return localized media keyed by image candidate plus Import Issues for optional failures. Do not include image success, image hash, or image failure in the principal fingerprint.

- [ ] **Step 4: Implement the artifact renderer**

Render a new HTML document from extracted semantic values and localized media. Permit only known tags and safe attributes. Rewrite media to local assets; remove source scripts, forms, event handlers, iframes, remote styles/resources, and unsafe schemes. Preserve safe user-activated external anchors.

Ask LocalLibrary to describe the completed package.

- [ ] **Step 5: Run tests**

```bash
swift test --filter WebResourceLocalizerTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/DocumentImport/Internal/WebResourceLocalizer.swift Sources/DocumentImport/Internal/WebArtifactRenderer.swift Tests/DocumentImportTests/WebResourceLocalizerTests.swift Tests/DocumentImportTests/LocalHTTPFixtureServer.swift
git commit -m "feat: localize web images for offline reading"
```

---

### Task 6: Build rich Source Documents and propagate persistent issues

**Files:**

- Modify: `Sources/DocumentImport/Internal/StableWebIdentity.swift`
- Modify: `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift`
- Modify: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Sources/DocumentImport/ImportTaskModels.swift`
- Modify: existing builder and integration tests.

- [ ] **Step 1: Write failing builder and success-issue tests**

Tests assert:

- stable IDs use rule version, category, role, ordinal, and Canonical Text;
- principal fingerprint ignores source URL, link destinations, tracking query items, image localization outcome, and Import Issues;
- rich extracted values become exact SourceBlock, SourceStructure relation, evidence, metadata, media, and issue values;
- published success issues exactly equal persisted document issues.

- [ ] **Step 2: Verify RED**

```bash
swift test --filter richWebDocumentBuilderProducesAuthoritativeGraph
swift test --filter publishedSuccessMatchesPersistentIssues
```

Expected: FAIL under the T03 builder and empty issue mapping.

- [ ] **Step 3: Make StaticWebDocumentBuilder asynchronous**

The builder becomes an internal async façade that:

1. extracts the article;
2. localizes resources;
3. assigns deterministic block identities;
4. constructs media/caption relations;
5. renders the package;
6. requests the LocalLibrary descriptor;
7. validates SourceDocumentContent;
8. returns package URL, descriptor, fingerprint, content, and issues.

Update T03 fixture tests to await the builder and assert legacy heading/paragraph defaults under the richer model.

- [ ] **Step 4: Update workflow issue propagation**

DocumentImport awaits the builder. On `.published`, map the exact product issues into ImportSuccess. On `.alreadyImported`, return only the existing duplicate outcome. Persist issues inside SourceDocumentContent.

Add the public `DocumentImport(library:)` initializer using URLSessionStaticWebAcquirer and production builder dependencies. Keep internal injected composition for tests.

- [ ] **Step 5: Run Debug tests**

```bash
swift test --filter StaticWebDocumentBuilderTests
swift test --filter DocumentImportIntegrationTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/DocumentImport Tests/DocumentImportTests
git commit -m "feat: build rich offline web source documents"
```

---

### Task 7: Prove production static import, missing-image success, and duplicate provenance

**Files:**

- Create: `Tests/DocumentImportTests/RealStaticWebImportIntegrationTests.swift`
- Modify: `Tests/DocumentImportTests/LocalHTTPFixtureServer.swift`
- Modify: fixtures when route-specific variants are needed.

- [ ] **Step 1: Write the failing public production-path integration test**

Start the local server, create `DocumentImport(library:)`, submit the rich article URL, and assert through public task APIs:

- durable acceptance and acquiring/constructing/publishing/completed progress;
- terminal `.published` with expected issues;
- exact metadata, ordered semantic roles, markup, evidence, media, relations, and persistent issues;
- `.webPackage` managed artifact descriptor;
- no document visible before publication.

- [ ] **Step 2: Write missing-image and duplicate tests**

Missing image route returns readable article plus image 404. Assert successful publication and one persistent `optionalWebImageUnavailable` issue.

Duplicate route serves the same canonical article with a different path, UTM values, navigation, advertisement, and optional-image result. Submit after the first publication and assert:

```swift
.alreadyImported(
    documentID: firstDocumentID,
    location: .library,
    provenanceAdded: true
)
```

Assert only one Source Document identity is returned and the second candidate does not replace existing issues.

- [ ] **Step 3: Verify RED**

```bash
swift test --filter RealStaticWebImportIntegrationTests
```

Expected: FAIL until production composition, localization, issue persistence, and fingerprint independence are complete.

- [ ] **Step 4: Implement only integration fixes exposed by the tests**

Use focused production changes. Do not add dynamic fallback, scheduler, cancellation, retry, or UI controls.

- [ ] **Step 5: Run focused Debug regression tests**

```bash
swift test --filter RealStaticWebImportIntegrationTests
swift test --filter DocumentImportTests
swift test --filter LocalLibraryTests
swift test --filter AppSupportTests
```

Expected: PASS with no public-network access.

- [ ] **Step 6: Commit**

```bash
git add Tests/DocumentImportTests Sources/DocumentImport Sources/KnowledgeCore Sources/LocalLibrary Package.swift
git commit -m "test: prove real static web import lifecycle"
```

---

### Task 8: Debug-only verification, review, and push

**Files:**

- Review every T04-owned file and commit.
- Preserve user-owned dirty and untracked files.

- [ ] **Step 1: Run whitespace and branch checks**

```bash
git diff --check origin/main...HEAD
git diff --name-only origin/main...HEAD
git status --short --branch
```

Expected: no whitespace errors; committed diff contains only T04 design, plan, source, fixtures, and tests; user-owned paths remain uncommitted.

- [ ] **Step 2: Run full Debug tests**

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 3: Run Debug package build**

```bash
swift build
```

Expected: Debug build succeeds.

- [ ] **Step 4: Run Debug macOS application build**

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t04 \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run required code review**

Use `superpowers:requesting-code-review` against the T04 design, this plan, Issue #5, and `origin/main...HEAD`. Fix every Critical or Important finding with a failing regression test first, rerun focused tests, and repeat review until approved.

- [ ] **Step 6: Confirm no release commands were run**

The T04 verification report must list only Debug commands. Do not run `swift test -c release` or `swift build -c release`.

- [ ] **Step 7: Push the feature branch**

```bash
git push -u origin feature/t04-real-static-web-import
```

Expected: local and remote branch SHAs match.

---

## Completion Criteria

- Public production composition imports a loopback-served ordinary static article through URLSession.
- Static acquisition exists without any dynamic renderer.
- Rich metadata, semantic block categories/roles, inline markup, media, relations, and evidence persist authoritatively.
- Noise and executable content are absent from the generated package.
- Images are localized under assets and automatically loaded resources are fully local.
- Optional image failure publishes with a persistent Import Issue.
- Principal fingerprint ignores URL/noise/time/link destinations/image availability.
- Alternate URL returns Already Imported with provenance added.
- Existing T02/T03 stored JSON remains decodable.
- Full Debug tests and Debug macOS app build pass.
- No release test or release build is run.
- Final review has no Critical or Important findings and the feature branch is pushed.
