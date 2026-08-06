# T04 Real Static Web Import Design

## Goal

Allow a user to submit an ordinary public article URL and receive a focused, script-free, offline Source Document with localized reading assets and stable semantic content.

T04 extends the T03 tracer bullet into a production static-Web path. Static acquisition uses `URLSession`, HTML5 parsing uses SwiftSoup, images are localized into the managed Web package, rich article semantics become authoritative Source Document data, and duplicate canonical articles resolve through the existing Local Library provenance transaction.

## Scope

T04 includes:

- a production static `URLSession` acquisition adapter;
- a public `DocumentImport(library:)` composition entry point;
- a pinned SwiftSoup `2.13.7` dependency for HTML5 parsing;
- backward-compatible KnowledgeCore model extensions for Web semantics;
- extraction of article metadata, semantic blocks, limited inline markup, media, and Web evidence;
- removal of navigation, advertisements, trackers, forms, recommendations, and executable source scripts;
- bounded concurrent image localization;
- successful publication with persistent Import Issues for missing optional images;
- stable Web fingerprinting independent of source URL, tracking data, advertisements, capture time, and optional-image availability;
- Already Imported success and provenance attachment for the same canonical article submitted from another URL;
- automated Debug tests using an in-process local HTTP fixture server and no public network.

T04 does not include:

- WKWebView or other dynamic rendering;
- the T05 scheduler, cancellation, retry, or restart recovery;
- production Import Center submission controls;
- cloud parsing or AI-authored source authority;
- release-configuration test or build commands.

## Architecture

The static Web path is a staged internal pipeline:

1. `URLSessionStaticWebAcquirer`
2. `StaticArticleExtractor`
3. `WebResourceLocalizer`
4. `WebSourceDocumentBuilder`
5. `WebArtifactRenderer`
6. existing Local Library staging and atomic publication

Each component has one responsibility and communicates through internal Sendable values. Document Import remains the only public workflow interface. Network request types, SwiftSoup nodes, image download details, package paths, and parser stages do not cross the public seam.

The current injected `WebAcquiring` test seam remains available internally. A new public initializer composes the production static acquirer:

```swift
public init(library: LocalLibrary)
```

The existing internal initializer continues to accept deterministic acquisition and identity dependencies for tests.

T04 performs only static acquisition. T06 may later place isolated dynamic rendering after the static adapter reports that static content is unavailable. No WebKit type or dynamic-fallback hook is public.

## Backward-Compatible Source Document Model

The current Source Document model cannot represent T04's required links, citations, code, media, dates, or Import Issues. T04 extends KnowledgeCore without requiring a database schema migration because Local Library already stores these values as encoded domain JSON.

### Imported metadata

`ImportedDocumentMetadata` gains an optional publication date. Existing initializers retain a default `nil` value, and old JSON that omits the field decodes as `nil`.

Metadata extraction priority is deterministic:

- title: Open Graph/article metadata, document title, then article heading;
- author: standard author metadata, article metadata, then supported JSON-LD author values;
- publication date: article publication metadata, supported JSON-LD `datePublished`, then article `time[datetime]`.

Dates are normalized to an absolute `Date` only when a recognized representation parses successfully. An unparseable optional date does not fail an otherwise readable article.

### Source Blocks

`SourceBlock` gains fields with backward-compatible defaults:

- `category`: text, code, or media;
- `role`: heading level, paragraph, list item, quotation, code block, image, or caption;
- limited inline markup;
- optional media reference.

Old Source Blocks decode as text paragraphs with no markup or media.

Canonical Text remains the normalized textual authority. Text and code blocks require non-empty Canonical Text. A media block may use alt text or caption text; media that has neither usable content nor a localized asset is omitted rather than publishing an empty authority block.

### Inline markup

Supported inline markup kinds are:

- emphasis;
- strong emphasis;
- link;
- citation;
- inline code.

Ranges use UTF-16 offset and length within Canonical Text. This is stable across Codable persistence and interoperates with Cocoa text APIs. Validation rejects out-of-range spans and contradictory overlapping spans. Link and citation destinations accept only safe HTTP or HTTPS URLs; executable schemes are discarded.

Link destinations are not part of the principal content fingerprint. Common tracking query items are removed from preserved destinations when doing so does not change the destination resource.

### Media references

Localized image media stores:

- an artifact-relative path under `assets/`;
- MIME type;
- optional alt text;
- optional intrinsic width and height when safely known.

The model never exposes an absolute managed-library filesystem path. Artifact-relative paths reject traversal, absolute paths, and non-asset locations.

### Source Structure and relations

`SourceStructure` gains a default-empty relation list. T04 uses relations to connect caption blocks to their media blocks when a figure contains both. Existing structure JSON decodes with no relations.

### Import Issues

`ImportIssue` moves into KnowledgeCore so the public terminal success and the persisted Source Document use one value type. T04 adds `optionalWebImageUnavailable`, with an optional related block identity and no raw URL, query string, path, HTML, or credentials.

`SourceDocumentContent` gains an `issues` field that defaults to an empty array when decoding old content. A published success returns exactly the issues stored with the document. Already Imported returns the existing document outcome and does not replace its authoritative issues with degradation from a duplicate candidate.

## Static Acquisition

`URLSessionStaticWebAcquirer` uses an ephemeral session configuration:

- no persistent cookies or credential storage;
- no shared URL cache;
- HTTP and HTTPS only;
- explicit request and resource timeouts;
- an article-oriented `Accept` header;
- bounded response size;
- final response URL retained for relative URL resolution;
- successful HTTP status and HTML-compatible MIME type required.

Redirects remain within URLSession's normal HTTP handling. Redirect loops, timeout, access denial, non-HTML responses, oversized responses, and transport failure become typed internal acquisition errors and map to privacy-safe Import Failures.

The in-process test server uses Apple's Network framework. It binds only to loopback on an ephemeral port and serves deterministic HTML and image responses. Tests therefore exercise the production URLSession adapter without a public network, external process, fixed port, or Python dependency.

## Article Selection and Noise Removal

SwiftSoup parses the acquired HTML5 document. Article selection uses this deterministic order:

1. the readable `<article>` candidate with the most supported semantic content;
2. the readable `<main>` candidate with the most supported semantic content;
3. a focused body content container only when it passes the same minimum readability test.

Before extraction, the selected candidate is cloned and cleaned. The cleaner removes:

- scripts, executable templates, styles, noscript fallback controls, and forms;
- navigation, headers or footers outside the focused article content;
- asides that are not article quotations or figures;
- common advertisement, recommendation, sharing, subscription, cookie, and tracking containers;
- hidden elements and tracking pixels;
- event-handler attributes and unsafe URL schemes.

Noise detection uses semantic elements, ARIA roles, standard metadata, and a small documented set of conventional class/id tokens. It does not use remote AI or site-specific executable rules.

## Semantic Extraction

The extractor walks supported semantic elements in document order without double-counting nested content:

- `h1` through `h6` become text blocks with heading roles;
- `p` becomes paragraph text;
- `li` becomes list-item text while preserving list order;
- `blockquote` becomes quotation text;
- `pre` or block-level `code` becomes a code block with preserved line breaks and an optional language hint;
- `figure`, `img`, and `figcaption` produce media/caption blocks and relations;
- inline `em`, `strong`, `a`, `cite`, and inline `code` produce limited markup ranges.

Whitespace normalization is role-aware. Ordinary prose collapses insignificant whitespace; code blocks preserve line boundaries and indentation after safe common-indent normalization.

## Web Source Evidence

Every published Source Block has Web evidence. The strongest stable locator is selected in this order:

1. a unique element ID represented as a CSS ID selector;
2. a stable semantic attribute explicitly intended as an identity;
3. a tag and `nth-of-type` path relative to the selected article root.

Volatile class lists, byte offsets, capture timestamps, PDF coordinates, and generated artifact IDs are not evidence. Evidence locates the original acquired article structure, not the rewritten package layout.

## Image Localization

The resource localizer resolves image URLs against the final response URL and supported `<base>` metadata.

- Only HTTP and HTTPS image resources are fetched.
- Duplicate resolved image URLs share one request.
- At most four image requests run concurrently within one Import Task.
- Responses require a successful status, an image MIME type, and bounded size.
- Localized filenames derive from content hash and a safe MIME-derived extension.
- Files are written beneath `assets/` in the temporary Web package.
- HTML image references are rewritten to local relative paths.
- `srcset`, remote preload hints, tracking attributes, and other remote-loading attributes are removed.

If an optional image cannot be fetched or validated:

- the remote loading reference is removed from the artifact;
- readable alt text or caption content remains;
- an `optionalWebImageUnavailable` issue is attached;
- the article may still publish when its text is readable and locatable.

Image success, image failure, image content hash, and localized filename do not change the principal Web Content Fingerprint.

## Offline Artifact

The renderer creates a fresh package containing:

- `index.html`;
- zero or more files beneath `assets/`.

The artifact contains only extracted article content, sanitized limited markup, localized media, and minimal local presentation CSS. It contains no executable source scripts, forms, trackers, advertisements, recommendations, remote stylesheets, remote image loads, iframe content, or automatic network fetches.

Ordinary external article links may remain as user-activated HTTP or HTTPS anchors. Their presence does not prevent the document itself from opening and rendering offline.

Tests stop the fixture server and verify that every automatically loaded resource reference is local and exists in the package. Local Library independently verifies and copies the same package bytes into managed storage.

## Content Fingerprint and Duplicate Provenance

The principal fingerprint uses:

- an explicit import-rule version;
- Source Block category;
- semantic role;
- normalized Canonical Text;
- stable block order.

It excludes:

- Original Source URL and redirect URL;
- URL tracking parameters;
- navigation, advertisements, recommendations, and trackers;
- capture time;
- link destinations;
- optional-image presence, failure, content hash, and localized path;
- generated Source Block and Source Document identifiers.

Two fixture routes serve the same canonical article with different URLs, navigation, advertisements, and tracking values. Submitting the second route through the public interface must return Already Imported with `provenanceAdded: true`. Local Library remains the atomic authority for duplicate resolution and provenance attachment.

## Workflow and Success Semantics

The T03 task lifecycle remains unchanged:

- `submit` returns only after durable acceptance;
- acquisition, construction, and publication remain the only public activities;
- parser, image, package, and duplicate steps remain hidden;
- the Source Document is visible only after Local Library atomic publication;
- Import Center continues to consume only public task snapshots.

For a new document, `ImportSuccess.published` returns the exact persisted issue list. For a duplicate, `ImportSuccess.alreadyImported` returns the existing document identity, location, and provenance result.

## Failure Boundary

T04 extends privacy-safe failure classification for:

- request timeout;
- network unavailable;
- website access denied;
- non-HTML or unreadable static response;
- webpage with no readable article;
- oversized source or resource;
- Local Library and publication errors.

Failures after durable acceptance remain terminal task data. Failure values do not contain full URLs with query parameters, response bodies, cookies, credentials, Canonical Text, HTML, or local filesystem paths.

Missing optional images are Import Issues, not Import Failures.

## Test Strategy

### Fixture server scenarios

The loopback HTTP server provides:

- a rich article with metadata, headings, paragraphs, lists, quotations, code, links, citations, and figure/caption media;
- noise around the same article: navigation, advertisements, recommendations, forms, scripts, and tracking pixels;
- localized image success;
- optional image 404;
- alternate URL and tracking values for duplicate identity;
- redirect, timeout, access-denied, non-HTML, and no-readable-article responses.

### Focused tests

Focused tests cover:

- backward-compatible decoding of pre-T04 Source Document JSON;
- Source Block and markup validation;
- metadata extraction priority;
- semantic role and reading-order extraction;
- stable evidence selection;
- noise removal and safe URL handling;
- bounded image localization and issue creation;
- artifact resource closure after the server stops;
- fingerprint golden values and URL/image independence.

### Public-interface integration

Integration tests use the public Document Import lifecycle and real Local Library to verify:

- production static URLSession acquisition is attempted and succeeds without dynamic rendering;
- durable acceptance and authoritative task progress remain intact;
- rich Source Document publication with localized artifact and exact issues;
- missing optional image success;
- duplicate article from another URL returns Already Imported and records provenance;
- no Source Document is visible before publication.

Automated tests never contact a public website.

## Debug-Only Verification

Per user direction, T04 verification runs Debug configuration only:

- focused Swift tests while implementing;
- full `swift test` at completion;
- Debug `swift build` when needed for package verification;
- Debug macOS application build through the existing Xcode scheme.

T04 does not run `swift test -c release` or `swift build -c release`.

## Acceptance Mapping

- Static before dynamic: production static URLSession path exists; T04 contains no dynamic renderer.
- Rich preservation: metadata, semantic roles, inline markup, media, captions, and relations are authoritative model data and rendered artifact content.
- Noise removal: semantic and conventional noise filters plus sanitized rendering.
- Offline media: bounded localization into `assets/` with rewritten references.
- Missing image degradation: persistent `optionalWebImageUnavailable` issue and successful readable publication.
- Web evidence: stable ID/semantic/path locators without PDF coordinates.
- Stable fingerprint: category, role, text, and order only; URL/noise/time/image availability excluded.
- Duplicate provenance: alternate URL returns Already Imported with atomic provenance attachment.
