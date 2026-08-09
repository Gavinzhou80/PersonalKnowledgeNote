# T06 Reading Workbench Tracer Bullet — Execution Plan

> Design: `docs/superpowers/specs/2026-08-09-t06-reading-workbench-design.md`
> Decision record: `docs/adr/0002-reading-render-webview-read-time-anchors.md`
> Branch: `feature/t06-reading-workbench` (from `main`)
> Mode: TDD red-green per task; focused suites inside tasks, full suite at task boundaries; Debug only; no public network in automated tests.

## Delivery constraints

- Every task starts with failing tests; verify red before implementing.
- `swift test --filter <suite>` inside tasks; full `swift test` at each task boundary.
- Check each step box below as it completes; commit per task with the given message shape.
- Stop and ask only on unplanned conflicts, design divergence, or destructive operations.

---

## Task 1: Local Library read seam

**Goal**

Expose the read-only queries the reading side needs: listed published document summaries and confined artifact resource serving.

**Tests first** — `Tests/LocalLibraryTests/ReadingSeamTests.swift`

- Summaries return only visible documents, newest (rowid) first.
- Summary title comes from stored content metadata.
- `artifactResource` serves `index.html` bytes matching the published artifact.
- `artifactResource` serves a localized asset under `assets/`.
- Unknown document and missing file return `nil`.
- Path traversal (`../`, absolute paths, backslashes) is rejected without touching disk outside the artifact.

**Implementation steps**

1. Add `SourceDocumentSummary` and `ArtifactResource` value types to `LocalLibraryTypes.swift`.
2. Add `publishedDocumentSummaries()` to `LibraryDatabase` (visible rows ordered by rowid desc, title decoded from content JSON) and surface through `LocalLibrary`.
3. Add artifact resource resolution to `ManagedArtifacts` confined to `Artifacts/<documentID>/` and surface `artifactResource(documentID:relativePath:)` through `LocalLibrary` with visibility check via the existing record path.

**Steps**

- [x] **Step 1: Write ReadingSeamTests and verify red**
- [x] **Step 2: Implement summaries and resource serving until green**
- [x] **Step 3: Run LocalLibraryTests suite; then full `swift test`**
- [x] **Step 4: Commit** `feat: expose library reading seam`

---

## Task 2: Reading workbench presentation (AppSupport)

**Goal**

An observable store that projects document list, selection, outline, and artifact load URLs through an injected port, plus import submission wiring.

**Tests first** — `Tests/AppSupportTests/ReadingWorkbenchStoreTests.swift`

- Store loads summaries through the port and exposes them newest first.
- Selecting a document loads its content and projects the outline: heading blocks in reading order, nested by heading level, each node carrying the positional block index.
- Documents without headings yield an empty outline.
- Artifact load URL is `pkn-reading://document/<documentID>/index.html`.
- Import submission forwards a valid URL and rejects unparsable input with a typed state.
- Publication completion refreshes the summary list.

**Implementation steps**

1. Define `ReadingLibraryPort` protocol in AppSupport covering summaries, document content, and import submission; add an in-memory test double.
2. Implement `ReadingWorkbenchStore` (`@Observable`, `@MainActor`) with list/selection/outline state and actions.
3. Implement outline projection from `SourceStructure.orderedBlockIDs` plus block roles.

**Steps**

- [ ] **Step 1: Write ReadingWorkbenchStoreTests and verify red**
- [ ] **Step 2: Implement port, store, and projection until green**
- [ ] **Step 3: Run AppSupportTests suite; then full `swift test`**
- [ ] **Step 4: Commit** `feat: add reading workbench presentation store`

---

## Task 3: Workbench UI, artifact web view, and app bootstrap

**Goal**

Replace the placeholder window with the three-pane workbench backed by a real library, rendering artifacts through the custom scheme with read-time anchors.

**Tests first**

- No automated UI tests (per design). Verification is `swift build`, `xcodebuild` Debug, and the manual checklist in Task 4.
- Extract the navigation-policy decision (cancel in-document navigation, hand http(s) to default browser) into a small pure function in AppSupport and unit-test it.

**Implementation steps**

1. `ArtifactSchemeHandler` (App target): serves `pkn-reading://document/<id>/<path>` through the library read seam; refuses everything else.
2. `ArtifactWebView` (NSViewRepresentable): registers the scheme handler, injects the end-of-document anchor script (`data-pkn-block` tagging + `scrollToBlock` entry point), intercepts navigation per the tested policy.
3. `ReadingWorkbenchView`: NavigationSplitView with sidebar list + URL import control, content reading view, inspector outline; column visibility via SceneStorage.
4. App bootstrap: open `LocalLibrary` at Application Support, build `DocumentImport(library:)`, wire the store; keep a launch error surface if the library cannot open.

**Steps**

- [ ] **Step 1: Write and verify navigation-policy tests**
- [ ] **Step 2: Implement scheme handler, web view, workbench view, bootstrap**
- [ ] **Step 3: `swift build` + `xcodebuild` Debug succeed; focused suites green**
- [ ] **Step 4: Commit** `feat: open published documents in reading workbench`

---

## Task 4: Acceptance, final review, and merge

**Steps**

- [ ] **Step 1: Manual acceptance checklist** (run the Debug app; record results in the completion report)
  - Boot with an empty library shows the empty list state.
  - Import a fixture URL served by the local test fixture server pattern or a local static file server; task completes.
  - The document appears at the top of the list with its title.
  - Opening it renders the article with localized images and no scripts.
  - Every outline node scrolls to its section.
  - Clicking an external link opens the default browser and the view does not navigate.
  - Relaunch keeps the document list.
- [ ] **Step 2: Full `swift test`; `git diff --check origin/main...HEAD`**
- [ ] **Step 3: Final code review** — fix every Critical/Important finding with a failing regression test first.
- [ ] **Step 4: Push branch** `git push -u origin feature/t06-reading-workbench`
- [ ] **Step 5: Merge into `main` (--no-ff), verify full suite on `main`, push**
