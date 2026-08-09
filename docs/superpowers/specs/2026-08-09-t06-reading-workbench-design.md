# T06 Reading Workbench Tracer Bullet Design

## Status

Accepted for implementation on 2026-08-09 through the recorded grilling session. T06 is the reading-side tracer bullet of product milestone A.

## Goal

Let a user open, read, and navigate any Source Document published by the T01–T05 import chain inside the real application: a three-pane workbench with a document list, a WKWebView reading view rendering the managed script-free HTML package, and an outline derived from Source Structure. The app boots against a real Local Library and accepts URL imports end to end.

## Confirmed Product Decisions

- Reading renders the immutable Source Artifact through WKWebView over a custom URL scheme; anchors are injected at read time in Source Block order (ADR 0002).
- Tracer-bullet scope: open, read, outline navigation, end-to-end import entry. No tabs, no highlights, no annotations, no durable reading position, no Document Profile, no folder tree, no PDF.
- Automated tests stay Debug-only and never touch the public network; the WKWebView surface is verified by a manual acceptance checklist.

## Existing Baseline

- `LocalLibrary.sourceDocument(id:)` returns a verified `LocatedSourceDocument` for visible documents; there is no public listing of published documents.
- Published artifacts live at the managed path `Artifacts/<documentID>/`; a web package is `index.html` plus localized images under `assets/` referenced by relative paths; the HTML carries `script-src 'none'` CSP.
- `SourceStructure.orderedBlockIDs` gives rendering order; heading roles among blocks give the outline hierarchy.
- `DocumentImport` public API (submit/cancel/retry/task/updates) and `ImportTaskStore` (T05) are complete; the app target currently shows only an empty Import Center placeholder with no library bootstrap.

## Architecture

### Responsibility boundary

| Module | T06 responsibility |
|---|---|
| KnowledgeCore | Unchanged. |
| LocalLibrary | New public read-only queries: document summaries and artifact resource serving. No schema migration. |
| DocumentImport | Unchanged. |
| AppSupport | New observable reading presentation: document list, selection, outline, artifact URL construction, import submission wiring. |
| App | Three-pane workbench, WKWebView wrapper with scheme handler and injected anchor script, URL import control, library bootstrap. |

### Local Library read seam

- `public func publishedDocumentSummaries() async throws -> [SourceDocumentSummary]`
  - `SourceDocumentSummary`: `documentID: SourceDocumentID`, `title: String`.
  - Only `visibility == visible` rows; ordered by rowid descending (latest publication first); title decoded from stored content metadata.
- `public func artifactResource(documentID: SourceDocumentID, relativePath: String) async throws -> ArtifactResource?`
  - Resolves `relativePath` strictly inside `Artifacts/<documentID>/`; rejects path traversal, absolute paths, and parent segments.
  - Returns bytes plus content type derived from file extension; `nil` when the document or file does not exist.
  - Document row must be visible; final artifact corruption translates through the existing error envelope.

### Reading presentation (AppSupport)

- `ReadingWorkbenchStore` (Observable, MainActor): owns the document list, current selection, and the outline of the selected document; loads summaries and document content through an injected Local Library port so tests run without a real store.
- Outline projection: heading blocks in `orderedBlockIDs` order, indented by heading level, each node carrying the block's positional index.
- Artifact load URL: `pkn-reading://document/<documentID>/index.html`.
- Import wiring: submit a parsed URL through `DocumentImport`, surface task state through the existing `ImportTaskStore`, refresh the summary list on new publication.

### App target

- `ReadingWorkbenchView` in a `NavigationSplitView`: sidebar = document list + import control; content = reading view; inspector/detail = outline. Sidebar and inspector are collapsible; column visibility persists through `SceneStorage`.
- `ArtifactWebView` wraps WKWebView:
  - Registers the `pkn-reading` scheme handler once per configuration; the handler serves only through the Local Library read seam.
  - Injects an at-document-end user script that tags rendered block elements with positional anchors and exposes a scroll-to-anchor entry point.
  - Cancels every navigation away from the current document URL; `http`/`https` links open in the default browser through `NSWorkspace`.
- App bootstrap opens `LocalLibrary` at `Application Support/PersonalKnowledgeNote/Library`, constructs `DocumentImport(library:)`, and hands both to the store.

## Outline Navigation

- On load completion, the injected script assigns `data-pkn-block="<index>"` to the article's rendered block elements in document order.
- Selecting an outline node evaluates a scroll of the element whose positional index matches the heading block's index in `orderedBlockIDs`.
- Positions are not persisted; navigation is ephemeral in T06.

## Verification

- LocalLibraryTests: summary ordering/visibility filtering/title extraction; resource serving correctness, path-traversal rejection, unknown document/file nil.
- AppSupportTests: store loading/selection/outline projection and artifact URL construction against an in-memory port.
- Manual acceptance checklist (non-automated): boot with empty library; import a fixture URL from a local server; document appears; open it; scroll and read; outline nodes jump to sections; external link opens in default browser; relaunch keeps the list.
- All automated tests Debug-only, no public network.

## Out of Scope

- Document tabs, reading-position persistence, highlights, annotations, excerpts, notes.
- Document Profile metadata editing, folders, favorites, trash.
- PDF reading, translation, search, export, backup.
- Artifact regeneration or artifact-side block ids (revisit when durable annotations land).
