# T05 Durable Import Task Queue, Control, and Recovery Design

## Status

- Ticket: GitHub Issue #6, `[Document Import] T05 — Support durable Import Task queueing, control, and recovery`
- Parent: GitHub Issue #1, `Document Import`
- Date: 2026-08-06
- Scope: durable FIFO scheduling, cancellation, retry, restart recovery, and the application observation adapter
- Baseline: T04 static webpage import merged to `main` at `7651fb5`

## Goal

Allow several accepted imports to remain durably ordered, run no more than one heavy import at a time, survive application restart, and support safe cancellation and retry without exposing internal workflow stages to callers.

T05 preserves the existing public Document Import seam. It deepens the implementation behind that seam by making Local Library the durable authority for queue order, task state, attempts, checkpoints, cancellation requests, and terminal outcomes. Document Import owns scheduling and format workflow but can rebuild all in-memory coordination from Local Library after restart.

## Confirmed Product Decisions

- A webpage acquired before interruption is persisted as a task-owned managed checkpoint artifact. Restart continues from construction without requesting the URL again.
- A failed or cancelled task retried by the user retains its task identity, increments its attempt, and enters the end of the durable FIFO queue.
- A cancellation request that arrives after publication has committed returns a typed `tooLate` control error. The successful result is unchanged.
- T05 includes the core queue and a `@MainActor @Observable ImportTaskStore` application adapter, but no new SwiftUI Import Center screen.
- The current workspace and a feature branch are used; no additional worktree is required.
- Automated verification remains Debug-only and fixture-driven. No public-network test is introduced.

## Existing Baseline

T04 already provides:

- a task-oriented public `DocumentImport` interface;
- durable acceptance through `LocalLibrary.accept`;
- task IDs, attempts, revisions, checkpoints, staged artifacts, atomic publication, duplicate outcomes, and publication recovery in Local Library;
- public task and list observation streams;
- production static webpage acquisition and offline Source Document publication;
- typed import failures and privacy-safe diagnostic IDs.

The current limitations are deliberate tracer shortcuts:

- every `submit` starts an independent unstructured task immediately;
- queued positions are always zero and are not durable;
- there is no single-heavy-task scheduler;
- `DocumentImport` does not hydrate retained tasks on startup;
- the handle has no cancel or retry operations;
- acquired webpage bytes are held only in memory;
- the public state model has no `cancelling` or `cancelled` state;
- AppSupport maps presentation strings but has no observable task-store adapter.

## Architecture

### Responsibility boundary

Document Import owns:

- FIFO scheduling policy;
- the one-heavy-task execution limit;
- selecting and running the correct format workflow;
- translating durable Local Library records into public snapshots;
- cancellation propagation into active async work;
- retry eligibility based on the public task result;
- observer and waiter delivery.

Local Library owns:

- durable task records and state transitions;
- queue sequence allocation and ordering;
- attempt and revision mutation;
- cancellation-request persistence;
- checkpoint envelopes and task-owned checkpoint artifacts;
- staged publication artifacts;
- terminal outcomes;
- cleanup ownership;
- atomic publication and duplicate provenance;
- crash recovery around publication.

Local Library must not learn Web or PDF parser stages. Document Import must not make an in-memory scheduler authoritative.

### Internal Document Import components

`DocumentImport` remains the public actor and composition root. Its current responsibilities are separated internally into three focused components.

#### ImportScheduler

The scheduler mirrors the durable queue and owns at most one active runner task.

Responsibilities:

- request the next runnable workspace from Local Library in queue order;
- start one `ImportTaskRunner`;
- recalculate public queued positions after every durable queue mutation;
- continue to the next task after completion, failure, or cancellation;
- prevent duplicate runners during simultaneous submit, retry, recovery, and runner completion events;
- cancel the active Swift task only after the cancellation request is durably recorded.

The scheduler does not store task results or checkpoints itself.

#### ImportTaskRunner

The runner executes one attempt for one workspace.

Responsibilities:

- load and validate the durable checkpoint;
- resume at the earliest incomplete stage;
- periodically check structured cancellation;
- persist every observable transition before publishing it to observers;
- retain or clean checkpoint artifacts according to failure and cancellation policy;
- return a small runner completion classification to the scheduler.

The runner never selects the next task.

#### TaskSnapshotRegistry

The registry is the in-memory delivery layer, not the state authority.

Responsibilities:

- cache the latest decoded durable snapshot for efficient delivery;
- manage task observers, list observers, and per-attempt terminal waiters;
- enforce monotonic delivery by revision and attempt;
- finish waiters exactly once;
- rebuild its cache from Local Library during bootstrap;
- discard stale in-memory events that lose a durable revision race.

## Bootstrap and Startup Barrier

The public `DocumentImport(library:)` initializer remains synchronous for source compatibility. It creates one internal bootstrap task.

All public and internal entry points that need task state wait for the same bootstrap barrier:

- `submit`;
- `observeTasks` registration;
- per-task update registration;
- `value`;
- `cancel`;
- `retry`;
- scheduler wake-up.

Bootstrap performs these steps:

1. Ask Local Library for retained import snapshots in authoritative order.
2. Rebuild the snapshot registry.
3. Consume the recovery reconciliation already performed once by `LocalLibrary.open`; Document Import bootstrap does not independently reset running rows.
4. Complete any cancellation cleanup left in `cancelling`.
5. Start the scheduler if a runnable task exists.
6. Release the barrier.

This prevents a newly submitted task from jumping ahead of older durable tasks while recovery is still loading.

Bootstrap failure is retained as a privacy-safe Local Library failure. Public operations that require durable state fail consistently instead of operating on a partial in-memory view.

T05 adds an explicit asynchronous readiness operation for the application adapter:

```swift
public func start() async throws
```

Bootstrap exposes a dedicated availability error rather than reusing submission or task-control errors:

```swift
public enum DocumentImportAvailabilityError: Error, Hashable, Sendable {
    case localLibraryUnavailable
}
```

`start()` and the implicit bootstrap used by `submit` share the same idempotent barrier. A failed bootstrap may be retried by calling `start()` again; it never creates a second scheduler. The existing synchronous initializer remains source-compatible.

If implicit bootstrap fails during `submit`, no task has been accepted, so `submit` maps the failure to the existing `ImportSubmissionError.localLibraryUnavailable`. Cancel, retry, and handle lookup surface `DocumentImportAvailabilityError` when durable state cannot be loaded.

The existing observation APIs remain non-throwing. Registrations made before bootstrap succeeds stay registered but do not receive a fabricated empty authoritative set. Their first emission occurs only after a successful bootstrap. `ImportTaskStore.start()` awaits `DocumentImport.start()` and exposes a privacy-safe application error if bootstrap fails, so a view never mistakes unavailable durable state for an empty queue.

## Durable Task Model

### Public states

```swift
public enum ImportTaskState: Hashable, Sendable {
    case queued(position: Int)
    case running(ImportProgress)
    case cancelling
    case failed(ImportFailure)
    case cancelled
    case completed(ImportSuccess)
}
```

`queued(position:)` is a projection of durable queue order. Position one is the next waiting task. The active task is represented as `running`, not as queued position zero.

### Terminal states

```swift
public enum ImportTerminalState: Hashable, Sendable {
    case success(ImportSuccess)
    case failure(ImportFailure)
    case cancelled
}
```

### Durable state machine

```text
accepted/queued -> running -> completed
                         -> failed
                         -> cancelling -> cancelled
queued -----------------> cancelling -> cancelled
failed -----------------> queued (retry, attempt + 1, new queue sequence)
cancelled --------------> queued (retry, attempt + 1, new queue sequence)
```

Publication commit is the cancellation boundary. Once Local Library commits a published or duplicate outcome, the task remains completed permanently.

### Revisions and attempts

- Revision is monotonic for the lifetime of a task and never resets on retry.
- Attempt starts at one and increments exactly once in the same transaction that requeues a retry.
- Every externally visible state change increments revision.
- Queue position changes caused only by another task leaving the queue are emitted as new public snapshots. Local Library may derive position from queue sequence, but the affected snapshot revisions still advance before observers are notified.
- Stale expected revisions are rejected rather than overwritten.

### Queue sequence

Local Library allocates a monotonically increasing queue sequence in the same transaction as acceptance or retry.

- New submissions enter the tail.
- Retried tasks enter the tail.
- Queue order survives restart.
- A failed, cancelled, or completed task does not retain an active queue sequence.
- Sequence allocation must remain safe across database reopen and concurrent callers.

## Recoverable Web Checkpoints

T05 defines versioned Web checkpoint payloads behind the existing opaque `CheckpointEnvelope` seam.

### Accepted checkpoint

Durable data:

- Original Source;
- queue sequence;
- attempt and revision;
- no acquired artifact.

Recovery action: start static acquisition.

### Acquired Web Page checkpoint

After acquisition succeeds, Document Import creates a task-owned managed checkpoint package containing:

- response bytes;
- final HTTP(S) URL;
- normalized MIME type;
- HTTP character encoding name when present;
- deterministic integrity metadata and checkpoint codec version.

Local Library atomically associates the checkpoint artifact and envelope with the task before construction begins.

Recovery action:

1. Verify ownership, descriptor, byte bounds, and payload integrity.
2. Decode the acquired page value.
3. Continue with extraction, localization, and construction without network access.

If the artifact is missing, corrupt, or unsupported by the checkpoint codec, the attempt becomes a retryable failure. It does not silently reacquire. A user retry clears the invalid checkpoint and begins a new attempt from acquisition.

### Publication Prepared checkpoint

After construction and Local Library staging succeed, the checkpoint records enough deterministic metadata to revalidate and publish the staged candidate:

- staged artifact identity and descriptor;
- Source Document content payload or a task-owned validated candidate payload;
- content fingerprint;
- Original Source provenance;
- checkpoint codec and integrity metadata.

Recovery action:

1. Verify the staged artifact and candidate payload.
2. Resume atomic Local Library publication.
3. Reuse Local Library's existing publication-intent crash recovery at transaction and final-file boundaries.

No source acquisition or semantic construction is repeated when this checkpoint remains valid.

### Checkpoint artifact ownership

Checkpoint artifacts are distinct from publication staging and remain task-owned.

Local Library provides package-scoped operations to:

- persist and atomically attach a checkpoint artifact;
- verify and open a checkpoint artifact without exposing its path publicly;
- replace or remove checkpoint artifacts with expected-revision checks;
- recover or clean orphaned checkpoint artifacts on open.

Callers never receive managed paths.

## Scheduling and Execution

The scheduler is event-driven. It wakes after:

- bootstrap;
- successful submission;
- successful retry;
- active runner completion;
- completion of cancellation cleanup.

`LocalLibrary.open` performs interrupted-runner reconciliation once for that opened library instance, before any Document Import scheduler exists. It returns prior `running` rows to queued while preserving valid checkpoints. A second `DocumentImport` actor sharing the same opened `LocalLibrary` does not repeat reconciliation.

The scheduling transaction claims the lowest active queue sequence and moves that task to running with a new revision. Claiming is durable and exclusive. A second scheduler sharing that Local Library or a reentrant wake-up cannot claim the same task.

Only one runner exists per `DocumentImport` instance. Local Library claim semantics additionally protect two `DocumentImport` instances that share the same opened `LocalLibrary`. Concurrent independent `LocalLibrary.open` calls for the same root are outside T05 and remain an application composition error.

The runner uses structured child tasks for acquisition, resource localization, and construction. Closing an observation stream does not retain or cancel any runner task.

## Cancellation

### Public API

```swift
public func cancel() async throws
```

### Control errors

```swift
public enum ImportTaskControlError: Error, Hashable, Sendable {
    case taskNotFound
    case invalidState
    case retryNotAllowed
    case tooLate
}
```

Control errors describe failure to perform a user command. They are not `ImportFailure` values and do not replace task state.

### Queued cancellation

Local Library atomically:

1. removes the active queue sequence;
2. records `cancelling` and increments revision;
3. performs owned checkpoint cleanup;
4. records `cancelled` and increments revision.

The scheduler never starts the task after the durable cancellation request wins.

### Running cancellation

1. Local Library durably records `cancelling`.
2. Document Import publishes that snapshot.
3. The scheduler cancels the active runner task.
4. The runner and its adapters propagate `CancellationError` rather than converting cancellation into a failure or Import Issue.
5. Local Library removes nonessential acquired and publication-prepared checkpoint artifacts.
6. The task becomes `cancelled`.

If cleanup fails transiently, the task remains `cancelling`. Bootstrap retries cleanup after reopen. It is never reported as cancelled before owned resources are in the required state.

Repeated cancellation is idempotent while queued, running, cancelling, or cancelled.

If publication has committed, `cancel()` throws `.tooLate`. The completed success remains authoritative.

## Retry

### Public API

```swift
public func retry() async throws
```

Retry is permitted only for:

- `failed` with `failure.recovery == .retryable`;
- `cancelled`.

Retry atomically:

1. verifies the expected state and revision;
2. increments attempt;
3. retains the task ID and Original Source;
4. clears the prior terminal result;
5. retains only a checkpoint that is still valid and permitted by cleanup policy;
6. allocates a new queue-tail sequence;
7. records queued state and increments revision.

Cancelled tasks normally reacquire because cancellation removes acquired and staged checkpoint artifacts. A failed task may resume from the acquired or publication-prepared checkpoint when validation succeeds.

Completed and non-retryable failed tasks reject retry with `.retryNotAllowed`.

## Observation and Waiting Semantics

### Per-task updates

`ImportTaskHandle.updates()` first emits the current durable snapshot, then later authoritative revisions.

- The handle remains valid across retry attempts.
- Old or duplicate revisions are suppressed.
- Stream termination only unregisters the observer.
- A reopened `DocumentImport` can recreate a handle for a retained task without changing task identity.

T05 adds the lookup needed by the application adapter and other public clients:

```swift
public func task(id: ImportTaskID) async throws -> ImportTaskHandle?
```

The lookup waits for bootstrap, returns `nil` for unknown or dismissed records, and does not start, retry, or otherwise mutate the task.

### Task list observation

`observeTasks` first emits the complete matching set ordered by active queue position and then retained history order.

Query meanings:

- `active`: queued, running, and cancelling;
- `unfinished`: active plus failed and cancelled;
- `all`: unfinished plus retained completed tasks.

### Terminal waiting

`value()` binds to the current attempt observed when the call registers.

- It returns that attempt's success, failure, or cancellation.
- A concurrent retry cannot silently move an existing waiter to the next attempt.
- Calling `value()` after retry registers against the new attempt.
- Waiters resume exactly once and do not own task execution.

## Application Adapter

T05 adds `ImportTaskStore` in AppSupport.

```swift
@MainActor
@Observable
public final class ImportTaskStore {
    public private(set) var tasks: [ImportTaskSnapshot]
    public private(set) var controlError: ImportTaskControlError?

    public private(set) var availabilityError: DocumentImportAvailabilityError?

    public func start() async
    public func stopObserving()
    public func submit(_ source: OriginalSource) async
    public func cancel(id: ImportTaskID) async
    public func retry(id: ImportTaskID) async
}
```

The exact presentation surface may evolve, but these boundaries are fixed:

- the store owns only its observation task and MainActor state;
- the store awaits `DocumentImport.start()` before treating its task list as available;
- stopping or deinitializing the store never cancels an import;
- the store recreates handles with `DocumentImport.task(id:)` rather than retaining workflow objects in views;
- cancel and retry are mapped to user actions without exposing checkpoints or adapters;
- success, Already Imported, failure, and cancellation remain ordinary task snapshots;
- no SwiftUI view is introduced in T05.

## Failure and Privacy Policy

- Failures after durable acceptance are stored task data.
- Scheduler failures cannot strand later queued tasks.
- Corrupt or incompatible checkpoints produce a retryable failure with an opaque diagnostic ID.
- Cancellation is never translated to network failure, construction failure, or optional-resource issue.
- Cleanup failure leaves the task cancelling and is retried on startup.
- Queue and checkpoint diagnostics exclude Canonical Text, response bodies, cookies, credentials, query strings, fragments, and complete local paths.
- Queue sequence, task ID, attempt, checkpoint kind, codec version, byte count, and opaque diagnostic ID are safe diagnostic fields.

## Testing Strategy

All automated tests use Debug configuration, temporary SQLite/filesystem storage, and deterministic local adapters or loopback HTTP fixtures.

### Durable FIFO and execution limit

- submit at least three tasks and prove durable queue order;
- gate the first runner and prove later heavy work does not start;
- reopen before execution and prove order is unchanged;
- prove queued positions update authoritatively as tasks leave the queue;
- prove simultaneous scheduler wake-ups cannot start two runners.

### Observation lifetime

- first emissions contain the current authoritative task or matching set;
- dropping and recreating streams does not cancel work;
- rebuilding `ImportTaskStore` rehydrates the same tasks;
- revisions are monotonic and attempt changes are explicit;
- old revisions cannot overwrite newer snapshots.

### Cancellation

- cancel queued work before acquisition;
- cancel active acquisition, localization, and construction;
- repeat cancellation concurrently and prove idempotency;
- prove cancellation state is durable before child-task cancellation;
- inject cleanup failure, reopen, and prove cancelling cleanup resumes;
- race cancellation against publication commit and prove either cancelled before commit or `.tooLate` after commit, never a half result.

### Retry

- retry retains task ID and increments attempt once;
- retry enters the queue tail behind already queued tasks;
- existing `value()` waiters finish the old attempt only;
- cancelled retry reacquires after cleanup;
- retryable failure reuses a valid acquired checkpoint;
- corrupt checkpoint retry clears it and reacquires;
- non-retryable and completed tasks reject retry.

### Restart recovery

Inject termination after:

- durable acceptance;
- acquisition checkpoint attachment;
- publication-prepared checkpoint attachment;
- publication intent commit;
- artifact move;
- visibility commit.

After reopening, verify exactly one terminal outcome, no duplicate publication, correct provenance, and no unowned checkpoint or staging artifact.

### Application adapter

- start/stop observation without controlling task lifetime;
- expose queued, running, cancelling, failed, cancelled, published, and Already Imported snapshots;
- route cancel and retry to the correct task;
- map control errors without leaking internal stages.

## Migration and Compatibility

The Local Library schema migration adds queue/control/checkpoint-artifact fields without invalidating existing T02–T04 task records.

- Existing completed tasks decode as retained history with no active queue sequence.
- Existing accepted or working tracer tasks are reconciled conservatively during bootstrap.
- Existing checkpoint envelopes remain versioned; unsupported payloads become retryable failures rather than being misinterpreted.
- Existing Source Documents and managed publication artifacts are not rebuilt or modified.
- Existing T04 public submit, updates, value, and production import behavior remain source-compatible.

## Scope Exclusions

T05 does not include:

- a SwiftUI Import Center screen;
- PDF Import Preview or preview leases;
- PDF acceptance or parsing;
- dynamic WKWebView fallback;
- a generic scheduler shared with unrelated application work;
- search or knowledge-log projection;
- task dismissal, history pruning, or retention settings;
- cloud AI;
- public-network automated tests;
- Release tests or Release builds.

## Acceptance Mapping

- Durable FIFO and one heavy task: Local Library queue sequence plus Document Import scheduler.
- Monotonic revisions and attempts: transactional durable transitions and retry mutation.
- View closure independence: observer-only `ImportTaskStore` ownership.
- Durable idempotent cancellation: persisted cancelling state, structured cancellation, owned cleanup.
- Retry with same identity: atomic attempt increment and queue-tail sequence.
- Restart recovery: bootstrap barrier plus versioned managed checkpoints.
- Submission errors remain acceptance-only: post-acceptance failures are durable snapshots.
- App adapter semantics: observable store exposes public task states and actions only.

## Risks and Mitigations

### Duplicate runner race

Mitigation: durable exclusive queue claim, one scheduler-owned runner, and idempotent wake-up.

### Bootstrap versus new submission ordering

Mitigation: all public operations wait for one bootstrap barrier before allocating a queue sequence.

### Checkpoint artifact drift or corruption

Mitigation: task ownership, descriptor verification, codec versioning, integrity checks, and explicit retryable failure.

### Cancellation versus publication race

Mitigation: Local Library transaction boundary decides the winner; cancellation before commit prevents publication, commit before cancellation produces `.tooLate`.

### Observer-driven lifecycle bugs

Mitigation: observation owns only continuations and adapter tasks, never scheduler or runner tasks.

### Cleanup failure after cancellation

Mitigation: retain durable `cancelling`, retry cleanup during bootstrap, and do not report cancelled prematurely.

### Monolithic DocumentImport growth

Mitigation: extract scheduler, runner, checkpoint codec, and snapshot registry as internal focused units while preserving one public actor seam.
