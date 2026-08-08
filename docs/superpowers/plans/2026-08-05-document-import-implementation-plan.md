# Document Import Implementation Plan

> Status: draft for user review  
> Date: 2026-08-05  
> Design source: [Document Import Architecture Design](../specs/2026-08-05-document-import-design.md)  
> Product source: [macOS V1 Scope](../../product/macos-v1-scope.md)

## 1. Goal

Implement the approved deep Document Import module for the macOS application, delivering the product sequence in this order:

1. public webpage import into a local, static Source Document;
2. normal-text-layer PDF import and read-only Import Preview;
3. durable queueing, recovery, deduplication, atomic publication, and production hardening across both formats.

This plan stops at Source Document publication. Reading annotations, translation, notes, full-text search, and the knowledge log consume the published result later.

## 2. Delivery constraints

- One developer.
- macOS only, Apple Silicon baseline.
- Swift, Swift Concurrency, SwiftUI/AppKit adapters.
- PDFKit for production PDF parsing.
- WKWebView for isolated dynamic webpage fallback.
- SQLite with GRDB for durable local state.
- All automated tests run without public-network access.
- Core-chain quality is more important than a fixed deadline.

## 3. Blocking prerequisites

### 3.1 Repository initialization

The workspace is not currently a Git repository and contains no Xcode or Swift package project. Before implementation:

- initialize version control or confirm that source control will be managed elsewhere;
- establish the macOS app and local Swift package structure;
- choose the supported macOS deployment target consistent with “current and previous major version” support;
- configure test and fixture targets.

This plan does not authorize those mutations until the user explicitly starts implementation.

### 3.2 Local Library design gate

Document Import depends on a neighboring deep Local Library module for:

- durable Import Task records and checkpoints;
- staging ownership;
- atomic file/database publication;
- Content Fingerprint lookup;
- provenance attachment;
- trash-location lookup.

Before implementing Task 4, approve a focused Local Library design covering those capabilities. Do not replace it with a collection of shallow table repositories or mocks.

## 4. Proposed project shape

```text
Package.swift
Sources/
├── KnowledgeCore/
│   ├── Documents/
│   └── DocumentImport/
│       ├── DocumentImport.swift
│       ├── ImportTask.swift
│       ├── ImportOutcome.swift
│       ├── ImportPreview.swift
│       └── Internal/
│           ├── ImportScheduler.swift
│           ├── ImportRecovery.swift
│           ├── SourceDocumentBuilder.swift
│           ├── WebImportAdapter.swift
│           └── PDFImportAdapter.swift
├── Infrastructure/
│   ├── LocalLibrary/
│   └── Diagnostics/
└── AppSupport/
    └── ImportTaskStore.swift

Tests/
├── DocumentImportTests/
├── LocalLibraryTests/
└── Fixtures/
    ├── Web/
    └── PDF/
```

The final Xcode app may consume these targets as a local package. Exact project grouping can change without changing module seams.

## 5. Verification commands

Once the Swift package exists, every implementation task should finish with the smallest relevant command, followed by the full suite at milestone gates:

```bash
swift test --filter DocumentImportTests
swift test --filter LocalLibraryTests
swift test
```

App-level WKWebView and PDFKit integration tests may additionally use `xcodebuild test` with the selected scheme and destination. The exact command belongs in the generated project README once the scheme exists.

## 6. Implementation tasks

### Task 1: Bootstrap the testable module skeleton

**Goal**

Create a macOS Swift package structure that can compile domain types and run tests without launching SwiftUI.

**Planned files**

- `Package.swift`
- `Sources/KnowledgeCore/Documents/`
- `Sources/KnowledgeCore/DocumentImport/`
- `Sources/Infrastructure/LocalLibrary/`
- `Tests/DocumentImportTests/`
- `Tests/Fixtures/Web/`
- `Tests/Fixtures/PDF/`

**Tests first**

- Add a smoke test proving the `KnowledgeCore` target imports.
- Add a fixture-access test proving resources can be located in the test bundle.

**Implementation steps**

1. Create library targets for domain/import logic and infrastructure.
2. Restrict platform support to macOS.
3. Add GRDB only to the infrastructure target.
4. Keep SwiftUI, PDFKit, and WebKit out of the core target unless required by a private adapter target.
5. Configure fixture resources.

**Exit criteria**

- `swift test` runs from a clean checkout.
- KnowledgeCore does not depend on SwiftUI.

---

### Task 2: Implement the immutable Source Document model

**Goal**

Represent the approved domain language without parser or persistence behavior.

**Planned files**

- `Sources/KnowledgeCore/Documents/SourceDocument.swift`
- `Sources/KnowledgeCore/Documents/SourceArtifact.swift`
- `Sources/KnowledgeCore/Documents/SourceBlock.swift`
- `Sources/KnowledgeCore/Documents/SourceStructure.swift`
- `Sources/KnowledgeCore/Documents/SourceEvidence.swift`
- `Sources/KnowledgeCore/Documents/ImportIssue.swift`
- `Tests/DocumentImportTests/SourceDocumentModelTests.swift`

**Tests first**

- Identical Canonical Text at two positions creates distinct Source Block identities.
- Text Block, Code Block, and Media Block preserve their role information.
- Caption and Media Block remain distinct and connect through Source Relation.
- Source Evidence supports Web- and PDF-specific evidence without a universal coordinate.
- Source Document construction rejects missing required Source Artifact or block identity.

**Implementation steps**

1. Add strongly typed IDs.
2. Add immutable value types for Source Artifact metadata and Source Blocks.
3. Model Canonical Text and limited Inline Markup.
4. Model Source Structure, Source Relation, Primary Language suggestion, and Import Issues.
5. Avoid GRDB, PDFKit, WebKit, and view types in these files.

**Exit criteria**

- Domain tests pass entirely in process.
- No source-format type crosses the Source Document interface except Source Evidence variants.

---

### Task 3: Implement deterministic normalization and validation

**Goal**

Build the in-process implementation that turns format-adapter output into a validated Source Document candidate.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/Internal/SourceDocumentBuilder.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/TextNormalizer.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/InlineMarkupNormalizer.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/SourceDocumentValidator.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/ContentFingerprint.swift`
- `Tests/DocumentImportTests/NormalizationTests.swift`
- `Tests/DocumentImportTests/ContentFingerprintTests.swift`
- `Tests/DocumentImportTests/ValidationTests.swift`

**Tests first**

- Normalize whitespace, line endings, common PDF hyphenation, and safe Unicode forms deterministically.
- Preserve citations, inline formulas, inline code, links, and emphasis as limited Inline Markup.
- Reject a candidate with no readable content.
- Reject required Source Blocks without usable Source Evidence.
- Accept localized uncertainty as Import Issues.
- PDF byte fingerprint ignores filename and path.
- Web fingerprint ignores URL and missing optional images while remaining stable for the same canonical article.

**Implementation steps**

1. Define internal candidate types; do not expose them publicly.
2. Implement normalization as pure functions inside the Document Import implementation.
3. Implement format-specific fingerprint strategies behind one internal operation.
4. Implement publication-minimum validation.
5. Ensure import-rule version is included in the candidate metadata but not in document identity.

**Exit criteria**

- Golden normalization and fingerprint tests are deterministic across repeated runs.
- No adapter exists for logic with only one implementation.

---

### Task 4: Design and implement the minimum Local Library publication seam

**Prerequisite**

Approve the focused Local Library design before writing code.

**Goal**

Provide real local durability for Import Tasks and atomic Source Document publication.

**Planned files**

- `Sources/Infrastructure/LocalLibrary/LocalLibrary.swift`
- `Sources/Infrastructure/LocalLibrary/LibraryDatabase.swift`
- `Sources/Infrastructure/LocalLibrary/ManagedFiles.swift`
- `Sources/Infrastructure/LocalLibrary/SchemaMigrations.swift`
- `Sources/Infrastructure/LocalLibrary/ImportTaskJournal.swift`
- `Tests/LocalLibraryTests/ImportPublicationTests.swift`
- `Tests/LocalLibraryTests/CrashRecoveryTests.swift`

**Tests first**

- Persist an accepted Import Task and recover it after reopening the temporary library.
- Stage a Source Artifact, then atomically publish files and database records.
- Simulate failure before and after each publication step and verify no half Source Document appears.
- Resolve a duplicate Content Fingerprint without creating a second Source Document.
- Attach new Original Source provenance atomically.
- Report whether an existing document is in the library or trash.
- Clean abandoned staging safely.

**Implementation steps**

1. Create GRDB migrations for the minimum required records.
2. Store managed files under deterministic internal paths that never cross the module seam.
3. Implement staging manifests and atomic publication.
4. Implement Import Task checkpoint records.
5. Use temporary SQLite and directories in tests rather than repository mocks.

**Exit criteria**

- Crash-point tests prove Source Document publication is all-or-nothing.
- Database table and file-layout knowledge remains local to Local Library.

---

### Task 5: Implement the public Import Task interface and scheduler

**Goal**

Deliver the approved `DocumentImport.submit`, task-handle, observation, cancellation, retry, and queue semantics.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/DocumentImport.swift`
- `Sources/KnowledgeCore/DocumentImport/ImportTask.swift`
- `Sources/KnowledgeCore/DocumentImport/ImportOutcome.swift`
- `Sources/KnowledgeCore/DocumentImport/ImportPreview.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/ImportScheduler.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/ImportRecovery.swift`
- `Tests/DocumentImportTests/ImportTaskInterfaceTests.swift`
- `Tests/DocumentImportTests/ImportSchedulerTests.swift`

**Tests first**

- `submit` returns only after the task is durable.
- Submission errors are limited to task-acceptance failures.
- The first task update is current authoritative state.
- Revisions increase monotonically.
- Multiple tasks queue FIFO and only one heavy task runs.
- Dropping observation does not cancel work.
- Cancel is durable and idempotent before publication.
- Retry keeps task ID, increments attempt, and reacquires cleaned data when required.
- Startup recovery resumes interrupted tasks from a safe checkpoint.

**Implementation steps**

1. Implement the core actor and public value types.
2. Implement task list and per-task observation streams.
3. Add the single-heavy-task scheduler.
4. Add durable lifecycle actions through Local Library.
5. Add privacy-safe failure classification.
6. Keep internal stage names out of caller-controlled ordering.

**Exit criteria**

- All task lifecycle behavior is testable through the approved external interface.
- No SwiftUI Observation types appear in KnowledgeCore.

---

### Task 6: Deliver the static Web import vertical slice

**Goal**

Import one ordinary public article into a complete local Source Document without dynamic rendering.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/Internal/WebImportAdapter.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/WebArticleExtractor.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/WebArtifactBuilder.swift`
- `Tests/DocumentImportTests/WebImportTests.swift`
- `Tests/Fixtures/Web/static-article/`

**Tests first**

- Import title, author, date, headings, paragraphs, lists, quotations, code, links, citations, and images from a fixture.
- Remove navigation, advertisements, trackers, forms, and scripts.
- Produce a static Source Artifact that opens without network access.
- Build stable Source Blocks, Source Structure, and Web Source Evidence.
- Record a missing optional image as Import Issue without failing.
- Complete through `DocumentImport.submit` and Local Library publication.

**Implementation steps**

1. Implement the internal Web adapter for static acquisition.
2. Extract article content and semantic roles.
3. Download and localize article images.
4. Build a static, script-free HTML package.
5. Feed adapter output through the common builder, validator, fingerprint, and publication workflow.

**Exit criteria**

- A fixture article completes the entire external interface flow.
- Reopening the Source Artifact requires no network.
- A second URL with identical canonical content returns Already Imported.

---

### Task 7: Add isolated dynamic webpage fallback

**Goal**

Support common JavaScript-rendered public articles without importing source scripts into the local artifact.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/Internal/IsolatedWebRenderer.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/WebResourceLoading.swift`
- `Tests/DocumentImportTests/DynamicWebImportTests.swift`
- `Tests/Fixtures/Web/dynamic-article/`

**Tests first**

- Static extraction is attempted before dynamic fallback.
- Dynamic fallback uses non-persistent website storage.
- Redirect, timeout, resource-size, and navigation limits are enforced.
- Cookies and authenticated Safari state are not imported.
- Final local HTML contains no executable source scripts.
- A local HTTP fixture simulates dynamic content without public network access.

**Implementation steps**

1. Create the private web-resource seam.
2. Add URLSession/static and isolated WKWebView production adapters.
3. Add deterministic local-server or fixture adapters for tests.
4. Trigger dynamic rendering only when static extraction is insufficient.
5. Feed rendered DOM through the same sanitizer and artifact builder.

**Exit criteria**

- Static and dynamic articles publish through identical external task semantics.
- The dynamic adapter does not widen the Document Import interface.

---

### Task 8: Complete Web milestone hardening

**Goal**

Meet the product’s first-stage webpage acceptance gate.

**Tests first**

- Network interruption and retry from checkpoint.
- Cancellation during image acquisition.
- Duplicate article from a different URL.
- Existing duplicate in trash.
- Insufficient disk space.
- Projection failure after successful publication.
- Privacy-safe diagnostics.
- Typical webpage performance target.

**Implementation steps**

1. Finish Import Issue taxonomy for Web degradation.
2. Add stage timing and diagnostic IDs.
3. Add projection publication facts without coupling to FTS or knowledge-log schemas.
4. Add representative manual acceptance URLs to a non-automated checklist.

**Exit criteria**

- Web Document Import satisfies the V1 webpage import requirements.
- No automated test depends on a public website.

---

### Task 9: Add PDF staging and Import Preview

**Goal**

Accept a selected PDF durably and provide a safe read-only preview before full import completes.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/Internal/PDFImportAdapter.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/PDFStaging.swift`
- `Sources/KnowledgeCore/DocumentImport/ImportPreview.swift`
- `Tests/DocumentImportTests/PDFPreviewTests.swift`

**Tests first**

- `submit` copies the selected PDF into staging before returning.
- Moving or deleting the external original after submission does not break the task.
- Preview becomes available within the task lifecycle.
- Preview lease keeps the staged file alive.
- Cancel enters `cancelling` until preview leases are released.
- Preview cannot produce persistent annotation identifiers.
- Password-protected, restricted, corrupt, and unreadable PDFs return typed failures.

**Implementation steps**

1. Implement security-scoped file access where required.
2. Stage and verify PDF bytes.
3. Implement preview lease lifetime and cleanup.
4. Keep PDFView creation in the Reading adapter, not Document Import.

**Exit criteria**

- Large PDF preview is available within the agreed performance target.
- No staging path or cleanup rule leaks beyond the lease.

---

### Task 10: Build PDF Source Blocks and Source Evidence

**Goal**

Publish normal-text-layer PDFs as complete Source Documents.

**Planned files**

- `Sources/KnowledgeCore/DocumentImport/Internal/PDFTextExtractor.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/PDFLayoutAnalyzer.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/PDFSourceEvidenceBuilder.swift`
- `Sources/KnowledgeCore/DocumentImport/Internal/PDFStructureBuilder.swift`
- `Tests/DocumentImportTests/PDFImportTests.swift`
- `Tests/Fixtures/PDF/`

**Tests first**

- Single-column reading order.
- Common double-column reading order.
- Headings and PDF bookmarks.
- Paragraphs, lists, references, code-like blocks, and captions.
- Figures, tables, standalone formulas, and caption relations.
- Page and region Source Evidence.
- Repeated identical text remains distinct by occurrence.
- Uncertain order, hierarchy, decoding, and media association produce Import Issues.
- Completely unreadable or unlocatable content fails publication.
- Content Fingerprint ignores filename and external path.

**Implementation steps**

1. Extract PDFKit page text and geometry.
2. Group glyphs/lines into blocks deterministically.
3. Infer common single- and double-column order.
4. Infer headings, media regions, captions, and relations.
5. Generate Source Evidence with page, region, text range, and quote context.
6. Pass output through shared normalization, validation, deduplication, and publication.

**Exit criteria**

- Representative Chinese and English normal-text PDFs publish through the same interface as Web.
- Media crops are not eagerly generated.

---

### Task 11: Add PDF correction inputs and Import Issues handoff

**Goal**

Produce enough immutable evidence for later Reading Outline and Reading Order correction without editing Source Document.

**Tests first**

- Import Issue identifies the affected page/block range.
- Initial Reading Outline can be constructed from Source Structure.
- Initial Reading Order can be constructed from inferred order.
- Reordering Source Block references later does not change Source Block identity or Source Block content hashes.
- Caption relations survive editable outline/order overlays.

**Implementation steps**

1. Add stable issue location and confidence data.
2. Ensure Source Structure provides deterministic initialization inputs.
3. Do not add user-editing behavior to Document Import.

**Exit criteria**

- Later reading modules can correct interpretation without mutating imported authority.

---

### Task 12: Add the SwiftUI ImportTaskStore adapter

**Goal**

Expose task state to SwiftUI without moving Observation or MainActor ownership into the core module.

**Planned files**

- `Sources/AppSupport/ImportTaskStore.swift`
- app-target task list and row views when the app project exists
- app-level adapter tests

**Tests first**

- Store begins with the authoritative task set.
- Snapshot replacement respects revision ordering.
- Store reconnects after app launch without manually resuming tasks.
- View disappearance does not cancel import.
- Cancel, retry, preview, success, failure, and Already Imported intents map to the task handle correctly.

**Implementation steps**

1. Build a `@MainActor @Observable` adapter over `observeTasks`.
2. Keep view formatting and localized strings outside KnowledgeCore.
3. Ensure the adapter holds preview leases only while a preview is visible.

**Exit criteria**

- SwiftUI callers do not know queue, checkpoint, parser, fingerprint, or publication ordering.

---

### Task 13: Performance, recovery, and privacy release gate

**Goal**

Verify the complete module against its production acceptance criteria.

**Tests and measurements**

- Typical webpage publishes within 10 seconds under controlled network conditions.
- Normal 50-page text PDF publishes within 5 seconds on the target M1/8 GB baseline.
- Large PDF preview appears within 2 seconds.
- Single-task memory peak targets less than approximately 500 MB.
- Main-window input and scrolling remain responsive.
- Every safe checkpoint survives forced termination and reopening.
- No half Source Document appears at any injected crash point.
- Diagnostics omit Canonical Text, query parameters, full local paths, cookies, credentials, and keys.
- Files above the performance baseline receive a warning but are not rejected solely for size.

**Implementation steps**

1. Add signposts or equivalent stage timing.
2. Stream/batch block processing and image acquisition.
3. Run leak and memory profiling.
4. Run the complete offline fixture suite.
5. Run the manual public-web acceptance checklist.

**Exit criteria**

- Every completion criterion in the approved architecture design is evidenced by a passing test, measurement, or documented manual check.

## 7. Milestone gates

### Gate A: Architecture readiness

- Document Import design approved.
- Domain language approved.
- Minimum Local Library design approved.
- Repository and test project initialized.

### Gate B: Web vertical slice

- One static article completes the full durable task and publication flow.
- Local HTML is offline and script-free.
- Duplicate URL/content behavior works.
- Recovery, cancellation, and diagnostics work.

### Gate C: Web production readiness

- Dynamic fallback works in isolation.
- Missing images and other localized degradation become Import Issues.
- Web performance and offline automated tests pass.

### Gate D: PDF vertical slice

- PDF staging and Import Preview work.
- One normal-text PDF publishes Source Blocks, Source Structure, and Source Evidence.
- Duplicate PDF behavior works.

### Gate E: Document Import complete

- Representative single- and double-column PDFs pass.
- Recovery and crash-point testing pass.
- Performance, memory, privacy, and projection handoff pass.
- SwiftUI task adapter consumes the interface without core leakage.

## 8. Risk register

| Risk | Early proof | Fallback |
|---|---|---|
| WKWebView extraction is nondeterministic | Local dynamic fixture and repeated golden runs | Restrict fallback sites and publish clear failure |
| PDFKit reading order is wrong | Double-column fixture in Task 10 | Import Issue plus editable Reading Order later |
| Atomic DB/file publication is fragile | Crash injection in Task 4 | Block downstream work until Local Library passes |
| Preview file lifetime leaks | Lease/cancellation tests in Task 9 | Disable preview until lifecycle is proven |
| Content Fingerprint produces false duplicates | Cross-source golden corpus | Prefer false negatives; never merge uncertain matches |
| Task recovery duplicates work | Checkpoint restart tests in Task 5 | Re-run idempotent stages; publication remains atomic |
| Memory spikes on large PDFs | Profiling before PDF milestone exit | Batch page extraction and media detection |

## 9. Scope guardrails

During this plan, do not add:

- OCR;
- translation calls;
- Source Anchor resolution;
- persistent annotations or notes;
- semantic search;
- knowledge cards;
- generic import plugins;
- cloud sync;
- automatic Source Document reprocessing;
- a Canonical Text editor.

New requests go to the later-version candidate list unless they unblock an approved Document Import requirement.

## 10. Final definition of done

The implementation plan is complete when the code can demonstrate:

> A URL or PDF is durably accepted, recoverably transformed into an immutable and locatable Source Document, deduplicated and atomically published, while callers only submit, observe, control, preview, and consume the final result.

No caller may contain Web/PDF parsing, staging, fingerprint, validation, deduplication, checkpoint, or publication-ordering logic.
