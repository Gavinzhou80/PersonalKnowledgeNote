# Document Import

> Status: published as GitHub issue #1  
> Issue label: `ready-for-agent`  
> Date: 2026-08-05

## Problem Statement

Users need to bring public web articles and local PDFs into a personal knowledge library before they can read, mark, translate, search, and take notes against them. A URL or file path alone is not durable enough: webpages change or disappear, external files move, PDF text order can be ambiguous, and format-specific positions cannot safely become long-lived note references.

The product therefore needs a reliable Document Import capability that converts each Original Source into an immutable, managed Source Document. The result must be readable offline, structurally useful, traceable to exact source positions, safe to resume after application failure, and consistent enough for later reading, translation, annotation, export, and search modules to trust.

Users must not be exposed to parsing stages, persistence ordering, adapter selection, duplicate-resolution rules, or recovery bookkeeping. They should submit an Original Source, observe one Import Task, optionally preview a large PDF, and receive a clear final result.

## Solution

Build a deep Document Import module with one task-oriented interface for both public webpages and local PDFs.

When a user submits an Original Source, the module durably creates an Import Task, queues it, obtains and stages the source, constructs a Source Artifact and normalized Source Blocks, records Source Structure and Source Evidence, calculates a Content Fingerprint, validates the result, and asks the Local Library module to publish the Source Document atomically.

Web imports become static, script-free local HTML packages with localized article images. Normal-text-layer PDFs remain managed PDF artifacts and gain normalized text, structure, media identification, and page/region evidence. Format-specific behavior remains behind Web and PDF adapters.

Import Tasks survive application restart, expose coarse progress, support cancellation and retry, and never publish half-complete Source Documents. Large PDFs can offer a temporary read-only Import Preview before formal publication. Duplicate content produces an Already Imported success result and attaches new Original Source provenance rather than creating a second Source Document.

Localized parsing uncertainty becomes an Import Issue attached to a successful Source Document. Whole-task failures are typed and actionable. Search and knowledge-log projection occur after publication and cannot roll back an otherwise successful import.

The primary testing seam is the public Document Import interface: submit an Original Source, observe and control its Import Task, and assert its final result. Local Library atomicity and crash recovery are tested through the separate Local Library module interface.

## User Stories

1. As a researcher, I want to enter a public article URL, so that I can preserve the article in my local knowledge library.
2. As a researcher, I want the imported webpage to remain readable offline, so that the source does not depend on future network access.
3. As a researcher, I want article images stored locally, so that the offline copy remains understandable.
4. As a researcher, I want advertisements, navigation, forms, and tracking content removed, so that the local article is focused on reading.
5. As a privacy-conscious user, I want the saved webpage to contain no executable source scripts, so that remote code cannot run inside my local library.
6. As a user importing a modern website, I want the application to recover dynamically rendered article text when necessary, so that JavaScript-driven public articles can still be imported.
7. As a privacy-conscious user, I want dynamic webpage acquisition isolated from Safari cookies and login state, so that importing does not expose my browser session.
8. As a user, I want unsupported login, subscription, CAPTCHA, and paywall pages to fail clearly, so that I understand the import limitation.
9. As a user, I want a missing nonessential webpage image reported without losing the readable article, so that local degradation does not unnecessarily fail the whole import.
10. As a user, I want a webpage’s title, author, date, headings, paragraphs, lists, quotations, code, links, citations, and media preserved, so that later reading retains useful structure.
11. As a user, I want the same webpage content imported from a different URL recognized as existing content, so that my library does not accumulate duplicates.
12. As a user, I want URL tracking parameters and advertisements excluded from document identity, so that irrelevant website variations do not create duplicates.
13. As a user, I want to select a local PDF for import, so that I can manage papers and documents in the same library as web articles.
14. As a user, I want the application to copy an imported PDF into its managed library, so that moving or deleting the external original does not break my notes later.
15. As a user, I want a normal-text-layer PDF parsed into stable content blocks, so that it can support translation, search, and source-linked notes.
16. As a user, I want PDF bookmarks and inferred headings captured, so that the document has an initial Source Structure.
17. As a user, I want common single-column PDFs read in the expected order, so that later translation and export remain coherent.
18. As a user, I want common double-column academic PDFs read in the expected order, so that columns do not become interleaved incorrectly.
19. As a user, I want uncertain PDF reading order reported as an Import Issue, so that I know which areas may require a later Reading Order correction.
20. As a user, I want uncertain heading hierarchy reported without rejecting an otherwise readable PDF, so that I can correct the Reading Outline later.
21. As a user, I want figures, tables, and standalone formulas represented as Media Blocks, so that their visual form can be reused in reading and translation.
22. As a user, I want captions represented as independent Text Blocks related to their media, so that captions can be searched, translated, marked, and quoted.
23. As a user, I want page and region evidence retained for PDF content, so that later notes can return to the original location.
24. As a user, I want webpage source evidence retained without pretending it uses PDF coordinates, so that each source format keeps its strongest positioning evidence.
25. As a user, I want repeated identical sentences at different positions treated as distinct Source Blocks, so that each occurrence keeps the correct section and source location.
26. As a user, I want code and commands distinguished from prose, so that they are preserved rather than translated as ordinary natural language.
27. As a user, I want inline formulas, citations, links, emphasis, and inline code preserved in limited Inline Markup, so that semantic meaning survives normalization.
28. As a user, I want common PDF spacing, line-break, and hyphenation noise normalized, so that Canonical Text is suitable for search and translation.
29. As a user, I want the imported Source Artifact and normalized structure preserved together, so that visual reading and machine-readable content remain traceable to each other.
30. As a user, I want Source Document content to remain immutable after publication, so that existing quotations and source positions do not silently change.
31. As a user, I want corrected display metadata kept separately from imported source metadata, so that I can fix titles, authors, dates, or Primary Language without rewriting the source.
32. As a user, I want Reading Outline and Reading Order corrections stored separately from Source Structure, so that I can repair interpretation without changing source authority.
33. As a user, I want the application to suggest one Primary Language for the document, so that translation can start with a sensible source-language default.
34. As a user, I want to correct the Primary Language before translation, so that a wrong detection does not cause a bad translation request.
35. As a user, I want Document Import to work without cloud AI, so that authoritative source structure is reproducible and available offline.
36. As a user, I want AI suggestions to remain optional after import, so that models cannot silently rewrite Source Blocks or Source Structure.
37. As a user, I want accepted Import Tasks persisted before the application reports success, so that quitting immediately does not lose my request.
38. As a user, I want multiple imports added to a visible queue, so that I can select several articles and PDFs without waiting after each one.
39. As a user on an 8 GB Mac, I want only one heavy import processed at a time, so that document import does not exhaust memory or make the application unusable.
40. As a user, I want webpage image downloads allowed to run concurrently within one task, so that ordinary article imports do not become unnecessarily slow.
41. As a user, I want import progress described in understandable activities, so that I know whether the source is being acquired, constructed, or published.
42. As a user, I want closing an import progress view to leave the task running, so that interface navigation does not cancel durable work.
43. As a user, I want an interrupted Import Task resumed from a safe checkpoint after application restart, so that long imports do not always restart from zero.
44. As a user, I want to cancel an Import Task, so that I can stop unwanted work and clean its temporary data.
45. As a user, I want repeated cancellation requests to be safe, so that quick repeated clicks cannot corrupt task state.
46. As a user, I want to retry a failed or cancelled Import Task using the same task identity, so that its history remains understandable.
47. As a user, I want a retry to increment its attempt number, so that diagnostics can distinguish separate executions.
48. As a user, I want recoverable failures identified as retryable, so that the task center can offer the correct action.
49. As a user, I want failures that require a new source or external user action identified clearly, so that retry is not offered when it cannot succeed.
50. As a user, I want a selected PDF copied into staging before submission returns, so that losing access to the external file does not break an accepted task.
51. As a user importing a large PDF, I want a read-only preview quickly, so that I can begin navigating while structure is still being constructed.
52. As a user, I want PDF preview to support pages, zoom, search, and ordinary copy, so that waiting for formal publication is less disruptive.
53. As a user, I want annotation, translation, and durable note creation disabled in Import Preview, so that temporary positions cannot become permanent knowledge references.
54. As a user, I want cancellation to close active preview use before deleting staged data, so that the application does not remove a file still being read.
55. As a user, I want a preview replaced by the formal Source Document after publication, so that all later knowledge actions use durable source positions.
56. As a user, I want a duplicate PDF recognized regardless of filename or external folder, so that renaming a paper does not create a second document.
57. As a user, I want Already Imported treated as success, so that normal repeated import behavior does not appear as an application error.
58. As a user, I want a new URL or file path recorded as provenance for existing content, so that the library preserves where the document came from.
59. As a user, I want a duplicate located in the trash identified clearly, so that I can restore it instead of creating a hidden duplicate.
60. As a user, I want Source Document publication to be atomic, so that application failure never leaves a document with missing files or incomplete records.
61. As a user, I want a Source Document to appear only after it is readable and locatable, so that every published document can support later knowledge operations.
62. As a user, I want localized uncertainty represented as Import Issues, so that useful documents are not rejected for correctable imperfections.
63. As a user, I want completely unreadable or unlocatable sources rejected, so that unusable half-documents do not enter my library.
64. As a user, I want search-index failure after import to leave the Source Document intact, so that a derived feature cannot destroy authoritative content.
65. As a user, I want knowledge-log projection failure after import to leave the Source Document intact, so that logging does not control document durability.
66. As a user, I want failed search or log projection retried later, so that derived views eventually become complete.
67. As a privacy-conscious user, I want diagnostics to omit article text, notes, cookies, credentials, and API keys, so that troubleshooting does not expose private reading material.
68. As a privacy-conscious user, I want logged URLs stripped of query strings and fragments, so that sensitive URL data is not recorded unnecessarily.
69. As a privacy-conscious user, I want local paths redacted in ordinary logs, so that personal directory information is not exposed.
70. As a user, I want diagnostic failures identified by an opaque diagnostic ID, so that I can report a problem without sharing document content.
71. As a user, I want an explanation before exporting a diagnostic package, so that I know exactly which information will be included.
72. As a user, I want a typical public article imported within the agreed performance target, so that URL import feels interactive.
73. As a user, I want a normal 50-page PDF imported within the agreed performance target, so that common papers are quickly available.
74. As a user, I want a large PDF preview within the agreed performance target, so that long parsing does not create an empty waiting experience.
75. As a user, I want import work kept off the main interaction path, so that scrolling and typing remain responsive.
76. As a user, I want oversized PDFs warned rather than rejected solely for size, so that I can choose whether to proceed.
77. As a user, I want disk capacity checked before large work begins, so that failure happens before avoidable partial processing.
78. As a user, I want password-protected PDFs rejected with a clear explanation, so that the application does not request or retain document passwords.
79. As a user, I want restricted PDF permissions reported rather than bypassed, so that the application respects document restrictions.
80. As a returning user, I want previously published Source Documents left unchanged after parser upgrades, so that application updates cannot silently invalidate notes and translations.
81. As a returning user, I want a future structure rebuild to require explicit confirmation, so that source migration never occurs unnoticed.
82. As a developer, I want Web and PDF callers to use the same Document Import interface, so that format workflow does not leak into application code.
83. As a developer, I want SwiftUI Observation isolated in an application adapter, so that the core module remains usable and testable without view lifetimes.
84. As a developer, I want production and deterministic test adapters for true external web access, so that network behavior can be tested offline.
85. As a developer, I want real temporary SQLite and filesystem storage in Local Library tests, so that atomicity is verified rather than mocked.
86. As a developer, I want PDFKit exercised against fixed PDF fixtures, so that production parsing behavior is represented in regression tests.
87. As a developer, I want tests to submit sources and assert task outcomes rather than call parser stages, so that tests survive internal refactoring.
88. As a developer, I want Content Fingerprint fixtures to remain stable across repeated runs, so that duplicate behavior is predictable.
89. As a developer, I want crash injection at safe checkpoints and publication points, so that recovery and atomicity are proven.
90. As a developer, I want stage timing and memory measurements, so that performance regressions can be localized without logging sensitive content.

## Implementation Decisions

- The capability is implemented as a deep Document Import module with a task-oriented external interface.
- The standard domain name is Document Import; Document Ingestion is not used.
- The external interface accepts a closed Original Source with webpage and PDF variants for V1.
- A public generic format registry, public capability map, and public option bag are rejected until a third confirmed format creates a real need.
- Submission returns a task handle only after the Import Task has been durably accepted.
- The module exposes observation of task snapshots, waiting for the current attempt’s terminal result, cancellation, retry, and acquisition of an Import Preview lease.
- SwiftUI uses a separate observable Import Task adapter; SwiftUI Observation and MainActor ownership do not cross the core seam.
- Import Task snapshots carry a monotonically increasing revision and an attempt number.
- Multiple tasks use a durable FIFO queue with one heavy task active at a time.
- A retry retains the Import Task identity, increments the attempt number, and resumes from the latest remaining safe checkpoint.
- Cancellation is durable and idempotent before publication commits.
- Source Document publication is atomic; a half-published Source Document is forbidden.
- Document Import owns workflow coordination but does not own SQLite tables, managed-file layout, backup, or trash behavior.
- The neighboring Local Library module owns durable task records, staging, duplicate lookup, provenance attachment, file/database publication, and crash recovery.
- Web and PDF are hidden format adapters behind the Document Import seam.
- True external web access uses a production adapter and a deterministic offline test adapter or local HTTP adapter.
- PDF parsing is a private local-substitutable seam with PDFKit production behavior and fixture/fault behavior for testing.
- Deterministic normalization, Source Block construction, validation, Content Fingerprint composition, and Import Issue classification remain ordinary in-process implementation without unnecessary adapters.
- A Source Document is an immutable composition of Source Artifact, Source Blocks, Source Structure, and Source Evidence.
- Source Artifact is the managed local HTML package or PDF and remains the visual authority.
- Canonical Text is the normalized authority used for quotation, search, translation, verification, and export.
- Source Blocks represent stable occurrences, not deduplicated text values.
- Source Blocks use Text Block, Code Block, and Media Block as their principal categories.
- Captions are independent Text Blocks connected to Media Blocks through Source Relations.
- Inline Markup is limited to semantically necessary spans such as emphasis, links, citations, inline code, and inline formulas.
- Source Evidence remains format-specific; the system does not invent one universal Web/PDF coordinate system.
- Source Structure records immutable inferred hierarchy, reading order, and Source Relations.
- Reading Outline, Reading Order, and Document Profile are editable overlays outside Document Import.
- Document Import suggests one document-level Primary Language; the user-confirmed value belongs to Document Profile.
- Source Block Canonical Text cannot be edited in V1.
- Existing Source Documents are not automatically reprocessed after import-rule changes.
- Cloud AI cannot produce authoritative Source Blocks, Source Structure, or Source Evidence.
- AI may later suggest changes to editable overlays after publication.
- Static webpage acquisition is attempted before isolated dynamic WKWebView fallback.
- Dynamic webpage acquisition uses non-persistent website state and does not reuse Safari authentication.
- Final webpage Source Artifacts are static, local, and script-free.
- Web images are localized during import when available.
- Missing optional Web images become Import Issues rather than whole-task failures.
- PDF media is identified during import, but crops are generated lazily by later consumers.
- Password-protected PDFs are unsupported in V1; the application does not request or store PDF passwords.
- The PDF size/page performance figures are soft baselines, not hard product limits.
- PDF Import Preview is a temporary read-only lease over staged content.
- Import Preview cannot create durable annotation, translation, note, or source-position data.
- Document Import never owns PDFView or WKWebView reading-view lifecycle.
- Content Fingerprint determines Source Document identity; title, URL, filename, and path do not.
- PDF identity uses a deterministic hash of managed PDF bytes in V1.
- Web identity primarily uses Canonical Text, Source Block category/role, and stable order.
- URL, trackers, advertisements, recommendations, capture time, and missing optional images do not determine webpage identity.
- Already Imported is a success result, not a failure.
- Duplicate resolution and provenance attachment occur atomically in Local Library.
- A duplicate in trash is returned as success with its location so the user can restore it.
- Import Issues represent localized uncertainty or degradation and remain attached to a successful Source Document.
- No-readable-content, no-locatable-blocks, corrupt source, unsupported protection, insufficient disk, and local-library failure are typed failures.
- Submission throws only when the Import Task itself cannot be safely accepted; later work failures are observable task results.
- Source Document publication precedes search and knowledge-log projection.
- Projection failure cannot roll back Source Document success and must remain retryable.
- Ordinary diagnostics contain identifiers, stage, duration, counts, and typed errors, not content or secrets.
- Product performance is measured on an Apple Silicon M1 Mac with 8 GB memory.
- The target is a typical public webpage within 10 seconds, a normal 50-page text PDF within 5 seconds, and a large-PDF Import Preview within 2 seconds.
- A single Import Task targets an approximate memory peak below 500 MB and must not block main-window interaction.
- The minimum Local Library publication seam must be designed before production implementation of durable tasks and atomic publication.

## Testing Decisions

- The highest and primary test seam is the external Document Import interface.
- Good Document Import tests submit an Original Source, observe task snapshots, control the task when needed, and assert the final observable result.
- Tests must not call acquisition, parsing, normalization, fingerprinting, validation, or publication stages in order.
- Tests must not inspect private task-journal tables or managed-file naming rules.
- The separate Local Library module interface is the test seam for atomic publication, crash recovery, duplicate lookup, provenance attachment, and staging cleanup.
- Local Library tests use real temporary SQLite databases and temporary managed-file directories rather than layered repository mocks.
- Automated tests never depend on public websites.
- A local HTTP server or deterministic web adapter simulates static pages, dynamic pages, redirects, timeouts, missing images, and network interruption.
- Fixed HTML and image fixtures verify Source Artifact output, Source Block roles, Source Structure, Source Relations, Source Evidence, Canonical Text, Inline Markup, Content Fingerprint, and Import Issues.
- Fixed PDF fixtures cover single-column and double-column papers, bookmarks, headings, repeated text, figures, tables, formulas, captions, references, uncertain order, restricted files, corrupt files, and representative large documents.
- Golden-path PDF tests use PDFKit against fixed real PDF fixtures.
- Focused fault adapters may simulate failures that are difficult to create reliably, but they do not replace production-adapter fixture tests.
- Every observation stream begins with current authoritative state; tests verify no query/subscription race.
- Tests verify durable task acceptance before submission returns.
- Tests verify FIFO ordering and the single-heavy-task rule.
- Tests inject termination at every safe checkpoint and confirm recovery after reopening.
- Tests inject failure before and after each Local Library publication step and confirm that no half Source Document appears.
- Tests verify cancellation before acquisition, during construction, during preview, and immediately before publication.
- Tests verify preview leases delay staged-file cleanup until released.
- Tests verify retry keeps task identity, increments attempt, and reacquires cleaned source data when necessary.
- Tests verify Already Imported for a document in the library and a document in trash.
- Tests verify provenance attachment and duplicate resolution are atomic.
- Tests verify a usable document can publish with Import Issues.
- Tests verify unreadable or unlocatable documents do not publish.
- Tests verify projection failure after publication does not alter Import Success.
- Tests verify diagnostics never contain Canonical Text, credentials, cookies, URL query parameters, or complete local paths.
- Tests verify Web and PDF use the same external task lifecycle.
- Performance tests record acquisition, construction, validation, and publication timing separately.
- Performance tests cover the agreed M1/8 GB targets and monitor memory peaks.
- Public websites are used only for a documented manual acceptance checklist.
- No existing implementation provides prior test patterns; the approved Document Import interface and temporary Local Library are the initial project test precedent.

## Out of Scope

- OCR and scanned-PDF text extraction.
- Password entry or storage for protected PDFs.
- EPUB, DOCX, Markdown, browser-extension, clipboard, or pasted-text import.
- Importing authenticated, paywalled, CAPTCHA-protected, or subscription-only webpage content.
- Detecting or migrating later changes to an Original Source webpage.
- Automatically reprocessing existing Source Documents after parser upgrades.
- Editing Source Block Canonical Text.
- A universal coordinate model shared by Web and PDF.
- Persistent annotations, highlights, notes, Source Anchor resolution, or source-jump behavior.
- Translation requests, translation caching, translated-document composition, or bilingual scrolling.
- Full-text search implementation.
- Knowledge-log implementation.
- Knowledge cards, semantic search, clustering, spaced repetition, or knowledge graphs.
- A generic AI orchestration framework or DeepSeek explanation workflow.
- Cloud sync, multiple libraries, collaboration, or account management.
- Complete Local Library backup, restore, and trash implementation beyond the minimum publication seam required by this feature.
- PDF table recognition, formula conversion, or eager media-image extraction.
- SwiftUI reading-view implementation.
- Windows, Linux, iOS, or iPadOS support.
- Mac App Store distribution.

## Further Notes

- This spec is derived from the confirmed macOS V1 product scope, the Document Import architecture design, the project domain glossary, and the approved implementation plan.
- The project is greenfield and currently contains design documents rather than application code, so there is no prior implementation behavior to preserve.
- The capability was renamed from Document Ingestion to Document Import during domain modeling; Document Ingestion should not reappear in code or product language.
- The next architecture dependency is the minimum Local Library module seam required for durable Import Tasks and atomic publication.
- The intended issue tracker is the repository’s GitHub remote.
- The spec is published as GitHub issue #1 with the `ready-for-agent` label.
- The implementation work is published as GitHub issues #2–#17, with blocking dependencies recorded in each ticket.
