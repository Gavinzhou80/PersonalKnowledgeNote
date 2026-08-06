# T03 Static Web Import Tracer Bullet Design

## Goal

Deliver the first production-shaped Document Import vertical slice for one deterministic static webpage. A caller submits a webpage `OriginalSource` through the public Document Import interface, receives a handle only after durable task acceptance, observes authoritative progress, waits for terminal success, and reads the Source Document only after atomic publication.

The slice proves the boundary between Document Import, Local Library, and Import Center without adding dynamic rendering, cancellation, retry, crash recovery, or a public-network dependency to automated tests.

## Scope

T03 includes:

- a new `DocumentImport` Swift target;
- public submission, per-task updates, terminal-value waiting, and task-list observation;
- durable acceptance through `LocalLibrary.accept`;
- deterministic static Web acquisition through an injected internal port;
- construction of a managed, script-free HTML package;
- ordered Source Blocks, Source Structure, and Web Source Evidence;
- stable Web content fingerprinting;
- atomic Source Document publication through `ImportWorkspace.finish`;
- Import Center presentation mapping from public task snapshots;
- interface-level integration tests with no public network access.

T03 does not include:

- isolated WKWebView dynamic fallback;
- production URLSession acquisition;
- cancellation, retry, preview leases, or restart recovery;
- the full FIFO scheduler and one-heavy-task policy;
- image downloading or localization;
- broad HTML semantics beyond the deterministic tracer-bullet fixture;
- durable failed-task recovery.

These omissions keep the ticket focused while preserving seams for the later Document Import tickets.

## Module Architecture

Add a standalone `DocumentImport` target that depends on `KnowledgeCore` and `LocalLibrary`.

This placement avoids a dependency cycle: Local Library already depends on KnowledgeCore, while Document Import must call Local Library to accept tasks, manage staging, and publish documents. Workflow coordination therefore cannot live inside KnowledgeCore. It also must not live in AppSupport, because AppSupport is only an application presentation adapter, or inside LocalLibrary, because Local Library must not own Web parsing and import workflow policy.

The public lifecycle boundary is:

> submit an Original Source, observe its Import Task, and receive a terminal result.

`DocumentImport` owns the workflow and public task state. `LocalLibrary` remains authoritative for durable acceptance, staged-artifact ownership, revision-checked checkpoints, duplicate resolution, and atomic publication. `AppSupport` maps public snapshots to display values and does not call parser, staging, checkpoint, or publication operations.

## Public T03 Interface

The T03 interface contains the subset needed for the tracer bullet:

- `DocumentImport.submit(_:)` returns an `ImportTaskHandle` only after Local Library has durably accepted the task.
- `ImportTaskHandle.updates()` immediately emits the current authoritative snapshot and then newer revisions.
- `ImportTaskHandle.value()` waits for the same terminal result represented by the final snapshot.
- `DocumentImport.observeTasks(_:)` immediately emits the current matching task set and then replacement sets after authoritative changes.

Public snapshots expose only caller-relevant state:

- queued;
- running with `acquiringOriginalSource`, `constructingSourceDocument`, or `publishing` activity;
- failed with a typed, privacy-safe failure;
- completed with `published` or `alreadyImported` success.

They do not expose acquisition adapters, parser steps, checkpoint payloads, staging handles, or publication ordering. Revisions increase monotonically for the current attempt. T03 uses Local Library's initial attempt value of one and defers retry semantics.

Task-list queries retain the approved meanings within the T03 state set: `.active` contains queued and running tasks, `.unfinished` contains active and failed tasks, and `.all` also contains completed tasks.

The acquisition injection point is internal. Tests may use package or testable construction to assemble a Document Import instance with the fixture adapter, but all import operations and assertions after assembly use public interfaces.

## End-to-End Data Flow

1. A caller submits `.webpage(url)`.
2. `DocumentImport` calls `LocalLibrary.accept` and obtains an `ImportWorkspace`.
3. After the accepted durable snapshot exists at revision zero, Document Import records and emits the public queued snapshot, returns the task handle, and starts background processing.
4. Document Import stores a small versioned checkpoint and emits running progress for static acquisition.
5. The injected Web acquisition port resolves the valid HTTPS fixture URL to deterministic HTML bytes. The integration test never passes a fixture file URL through `OriginalSource` and never accesses a public network.
6. A second checkpoint and snapshot mark Source Document construction.
7. The Web builder parses the page title and the semantic children of `<article>` in DOM order. For the current fixture it creates one heading block followed by one paragraph block.
8. The builder creates exact Source Structure coverage and one Web locator for every Source Block.
9. The builder writes a fresh `index.html` package from accepted content rather than retaining the original page. The result contains no scripts, forms, trackers, executable source content, or remote-resource requirements.
10. Document Import calculates the package descriptor required by Local Library and stages the package through the workspace. Local Library independently verifies the descriptor and owns the staged copy.
11. Document Import calculates a stable Web fingerprint from a version marker, semantic block roles, normalized canonical text, and block order. The source URL and generated block identifiers do not affect identity.
12. A final checkpoint and public snapshot mark publication.
13. Document Import calls `ImportWorkspace.finish` with the staged artifact, fingerprint, Source Document content, and original source.
14. Local Library atomically publishes a new document or resolves an existing duplicate.
15. Only after `finish` returns does Document Import emit completed success and resume `value()` waiters.

Before step 14 commits, `LocalLibrary.sourceDocument(id:)` returns no visible Source Document. After success is emitted, it returns the complete content and verified managed artifact descriptor.

## Static Web Construction

The tracer-bullet builder uses the deterministic fixture at `Tests/Fixtures/Web/article.html`.

Expected imported metadata:

- title: `Fixture Article`;
- author: absent.

Expected ordered content:

1. heading block with canonical text `Fixture Article`;
2. paragraph block with canonical text `Deterministic offline content.`

The Source Structure lists exactly those block identifiers in that order. Evidence contains exactly one `.web(locator:)` entry per block. Locators identify the corresponding semantic element under the article, such as the first `h1` and first `p`, rather than byte offsets in the acquired response.

Block identifiers are deterministic for the import-rule version, role, ordinal, and normalized text. The Web fingerprint is separately derived from the versioned semantic content and order so identity does not depend on URLs or random UUID generation.

Source Document identity comes from an internal identity factory. Normal composition uses fresh identifiers; the integration-test composition supplies a known identifier so the test can query the public Local Library interface before publication without inspecting staging or database internals.

The generated artifact is a one-file Web package with `index.html`. It preserves the title and ordered readable article content while omitting executable and navigational source-page content. Local Library performs the final descriptor verification and managed publication.

## Authoritative Progress and Observation

The Document Import actor owns public task records and observation continuations. A public snapshot is emitted only after the corresponding authoritative transition has succeeded.

Coarse progress is descriptive:

- acquiring original source;
- constructing Source Document;
- publishing.

Import Center may select text, icons, and progress decoration from these values. It must not use them to trigger work or infer hidden parser, staging, or publication ordering.

Every stream starts with current state. Dropping a stream removes only that observer and never cancels the task. Terminal waiters and snapshot observers receive the same success value. Completed tasks remain available to the in-memory `.all` task query for the lifetime of the Document Import instance.

## Failure Boundary

Failures before durable acceptance are submission failures. `submit` throws and no handle is returned.

Failures after a handle is returned become a terminal failed task snapshot and `ImportTerminalState.failure`. T03 classifies acquisition, unreadable fixture content, artifact construction, and Local Library publication failures into typed, privacy-safe failures with a diagnostic identifier. It does not expose raw HTML, filesystem paths, or database details.

After a post-acceptance failure, Document Import makes a best-effort `abandon` call using the current durable revision so Local Library can remove nonessential staging. The public failed result remains observable in the current Document Import instance. Durable failed-task retry and restart recovery are explicitly deferred.

## Import Center Presentation

AppSupport gains a pure mapping from `ImportTaskSnapshot` to presentation data. The mapping covers:

- queued task;
- each running activity;
- failed task;
- published success;
- already-imported success.

The adapter consumes only Document Import public values. It neither imports LocalLibrary workflow types nor switches on checkpoint, parser, staging, or publication details. The existing empty presentation remains available when there are no tasks.

T03 does not add a webpage submission control or production application composition. The Import Center requirement is satisfied at the presentation seam and its tests; wiring live production acquisition into the SwiftUI application belongs to a later ticket.

## Test Strategy

Implementation follows test-driven development at pre-agreed seams.

### Public-interface integration test

A gated deterministic acquisition adapter assembles the test system. The test then uses public interfaces to:

1. submit a valid HTTPS webpage source;
2. verify the returned task already exists in Local Library while acquisition remains blocked;
3. query the known test Source Document identifier and verify that no document is visible;
4. observe an immediate current snapshot;
5. release acquisition and observe monotonically increasing progress through acquisition, construction, and publication;
6. wait for terminal success;
7. read the published Source Document through `LocalLibrary.sourceDocument`;
8. assert metadata, ordered blocks, exact structure coverage, exact Web evidence coverage, and the managed `.webPackage` descriptor.

The test also verifies that no Source Document is visible before publication completes.

### Focused tests

Focused tests verify:

- fixture acquisition is deterministic and performs no public network access;
- article extraction preserves DOM order;
- generated `index.html` is script-free, form-free, and self-contained for the fixture;
- block identifiers and content fingerprint are stable across repeated construction;
- task streams begin with current state and terminate consistently;
- Import Center mapping depends only on public task state;
- accepted-task and publication errors cross the correct failure boundary.

### Verification

During implementation, run the narrow DocumentImport and AppSupport tests regularly, run Swift typechecking through package builds, and run the full `swift test` suite at the end. Before completion, run the project code-review workflow and address findings. Commit only T03-owned files and preserve unrelated dirty and untracked workspace content.

## Acceptance Mapping

- Public webpage submission: `DocumentImport.submit(.webpage(url))`.
- Durable return boundary: handle returned only after `LocalLibrary.accept` and accepted snapshot success.
- Authoritative progress and terminal success: revisioned snapshots plus `ImportTaskHandle.value()`.
- Deterministic managed Web result: fixture acquisition, generated static package, verified `.webPackage` descriptor.
- Ordered document model: deterministic blocks, exact structure, and exact Web evidence coverage.
- Atomic visibility: completed success emitted only after `ImportWorkspace.finish` returns.
- Import Center isolation: pure snapshot-to-presentation mapping.
- Network-independent integration: injected deterministic acquisition, valid HTTPS source, no local server or public network.
