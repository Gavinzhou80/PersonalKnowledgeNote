# T05 Durable Import Task Queue, Control, and Recovery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a durable FIFO Import Task scheduler with one-heavy-task execution, persistent Web checkpoints, cancellation, retry, restart recovery, and an observable AppSupport adapter.

**Architecture:** Local Library remains the durable authority for queue order, states, attempts, revisions, checkpoint artifacts, and terminal data. Document Import adds an internal bootstrap barrier, scheduler, task runner, and snapshot registry that can be rebuilt from Local Library after restart. Web acquisition and prepared-publication values are stored in versioned task-owned checkpoint packages so valid work resumes without repeating completed stages.

**Tech Stack:** Swift 6, Swift Concurrency, Swift Testing, Foundation, Network, ImageIO, SwiftSoup 2.13.7, GRDB 7.11.1, Observation, SQLite WAL, managed filesystem packages.

---

## Scope and Execution Constraints

- Work in the current workspace on `feature/t05-durable-import-queue`; do not create a worktree.
- Preserve the user's existing modified and untracked files.
- Use strict TDD for every behavior change: RED, GREEN, refactor, focused regression.
- Execute tasks through fresh implementation subagents with specification and code-quality review after every task.
- Run only Debug tests and builds.
- Do not run `swift test -c release`, `swift build -c release`, or any Release Xcode build.
- Do not use public-network tests.
- Do not add SwiftUI screens, PDF preview, PDF parsing, WKWebView fallback, search projection, task dismissal, or history pruning.
- Do not modify existing published Source Documents or reprocess T04 content.

## User-Owned Dirty Paths to Preserve

```text
M  docs/superpowers/specs/2026-08-05-document-import-design.md
?? .agents/
?? docs/specs/
?? docs/superpowers/plans/2026-08-05-document-import-implementation-plan.md
```

## File Structure

### KnowledgeCore and LocalLibrary durable authority

- Modify `Sources/KnowledgeCore/ImportTask.swift` — durable journal states and opaque failure envelope.
- Modify `Sources/LocalLibrary/LocalLibraryTypes.swift` — queue/control/checkpoint artifact values.
- Modify `Sources/LocalLibrary/Internal/SchemaMigrations.swift` — v2 queue migration followed by the additive v3 checkpoint-artifact migration.
- Modify `Sources/LocalLibrary/Internal/Records.swift` — new columns and checkpoint artifact record.
- Modify `Sources/LocalLibrary/Internal/LibraryDatabase.swift` — transactional queue claim, cancellation, failure, retry, retained snapshots, and checkpoint ownership.
- Modify `Sources/LocalLibrary/Internal/ManagedArtifactPath.swift` — task-owned checkpoint path scope.
- Modify `Sources/LocalLibrary/Internal/ManagedArtifacts.swift` — copy, verify, replace, remove, and recover checkpoint packages.
- Modify `Sources/LocalLibrary/LocalLibrary.swift` — package-facing queue and checkpoint operations.
- Modify `Sources/LocalLibrary/ImportWorkspace.swift` — workspace transitions used by the runner.

### DocumentImport workflow

- Modify `Sources/DocumentImport/ImportTaskModels.swift` — public cancelling/cancelled states and control/availability errors.
- Modify `Sources/DocumentImport/ImportTaskHandle.swift` — cancel and retry commands.
- Create `Sources/DocumentImport/Internal/TaskSnapshotRegistry.swift` — authoritative snapshot delivery and per-attempt waiters.
- Create `Sources/DocumentImport/Internal/ImportScheduler.swift` — one-heavy-task FIFO scheduler.
- Create `Sources/DocumentImport/Internal/ImportTaskRunner.swift` — one-attempt Web workflow and resume logic.
- Create `Sources/DocumentImport/Internal/WebImportCheckpoint.swift` — acquired/prepared package codecs.
- Modify `Sources/DocumentImport/Internal/WebAcquisition.swift` — persisted charset metadata.
- Modify `Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift` — retain response charset.
- Modify `Sources/DocumentImport/Internal/StaticArticleExtractor.swift` — decode using persisted HTTP charset before UTF-8 fallback.
- Refactor `Sources/DocumentImport/DocumentImport.swift` — composition root, bootstrap barrier, submit, lookup, cancel, retry, and scheduling events.

### AppSupport

- Create `Sources/AppSupport/ImportTaskStore.swift` — `@MainActor @Observable` adapter.
- Modify `Sources/AppSupport/ImportCenterPresentation.swift` — cancelling and cancelled presentation mappings.

### Tests

- Modify `Tests/KnowledgeCoreTests/PublicationModelTests.swift`.
- Modify `Tests/LocalLibraryTests/ImportAcceptanceTests.swift`.
- Modify `Tests/LocalLibraryTests/CheckpointTests.swift`.
- Create `Tests/LocalLibraryTests/ImportQueueTests.swift`.
- Create `Tests/LocalLibraryTests/CheckpointArtifactTests.swift`.
- Create `Tests/DocumentImportTests/DurableImportQueueTests.swift`.
- Create `Tests/DocumentImportTests/ImportTaskControlTests.swift`.
- Create `Tests/DocumentImportTests/ImportRestartRecoveryTests.swift`.
- Modify `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift`.
- Modify `Tests/DocumentImportTests/DocumentImportTestSupport.swift`.
- Create `Tests/AppSupportTests/ImportTaskStoreTests.swift`.
- Modify `Tests/AppSupportTests/ImportCenterPresentationTests.swift`.

---

### Task 1: Extend public and durable task models compatibly

**Files:**

- Modify: `Sources/KnowledgeCore/ImportTask.swift`
- Modify: `Sources/DocumentImport/ImportTaskModels.swift`
- Modify: `Sources/LocalLibrary/Internal/Records.swift`
- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Sources/AppSupport/ImportCenterPresentation.swift`
- Modify: `Tests/KnowledgeCoreTests/PublicationModelTests.swift`
- Modify: `Tests/DocumentImportTests/ImportTaskModelTests.swift`
- Modify: `Tests/AppSupportTests/ImportCenterPresentationTests.swift`

- [x] **Step 1: Write failing model and API tests**

Add tests that require the new states, terminal cancellation, and errors:

```swift
@Test
func taskControlModelsAreStableAndSendable() {
    let failure = ImportFailure(
        code: .networkUnavailable,
        recovery: .retryable,
        diagnosticID: UUID(uuidString: "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE")!
    )

    #expect(ImportTaskState.cancelling != .cancelled)
    #expect(ImportTerminalState.cancelled != .failure(failure))
    #expect(ImportTaskControlError.tooLate != .retryNotAllowed)
    #expect(
        DocumentImportAvailabilityError.localLibraryUnavailable
            == .localLibraryUnavailable
    )
}

@Test
func durableJournalStatesAndFailureEnvelopeRoundTrip() throws {
    let envelope = ImportTaskFailureEnvelope(
        codecVersion: 1,
        payload: Data("retryable-network".utf8)
    )
    let data = try JSONEncoder().encode(envelope)
    #expect(try JSONDecoder().decode(
        ImportTaskFailureEnvelope.self,
        from: data
    ) == envelope)
    #expect(KnowledgeCore.ImportTaskState.allCases.contains(.queued))
    #expect(KnowledgeCore.ImportTaskState.allCases.contains(.cancelled))
}
```

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter taskControlModelsAreStableAndSendable
swift test --filter durableJournalStatesAndFailureEnvelopeRoundTrip
```

Expected: FAIL because the new public states, durable states, and errors do not exist.

- [x] **Step 3: Add durable and public values**

Extend the existing KnowledgeCore journal enum. Keep its legacy values for v1 decoding and schema migration; qualify it as `KnowledgeCore.ImportTaskState` where the public DocumentImport enum would otherwise be ambiguous:

```swift
public enum ImportTaskState: String, CaseIterable, Codable, Sendable {
    // Legacy v1 values retained only for decoding and schema migration.
    case accepted
    case working
    case queued
    case running
    case cancelling
    case failed
    case cancelled
    case publicationPending
    case completed
    case abandoned
}

public struct ImportTaskFailureEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data

    public init(codecVersion: UInt16, payload: Data) {
        self.codecVersion = codecVersion
        self.payload = payload
    }
}
```

Keep `CheckpointEnvelope` unchanged for source compatibility.

Extend DocumentImport models exactly as approved:

```swift
public enum ImportTaskState: Hashable, Sendable {
    case queued(position: Int)
    case running(ImportProgress)
    case cancelling
    case failed(ImportFailure)
    case cancelled
    case completed(ImportSuccess)
}

public enum ImportTerminalState: Hashable, Sendable {
    case success(ImportSuccess)
    case failure(ImportFailure)
    case cancelled
}

public enum ImportTaskControlError: Error, Hashable, Sendable {
    case taskNotFound
    case invalidState
    case retryNotAllowed
    case tooLate
}

public enum DocumentImportAvailabilityError: Error, Hashable, Sendable {
    case localLibraryUnavailable
}
```

Also add `Codable` conformance to `ImportFailure.Code` and
`ImportFailure.Recovery`. Task 6 persists those exact values in the versioned
failure envelope, so the conformance must be established with the public model
instead of introducing a second set of raw-string enums later.

Add `ImportFailure.Code.checkpointInvalid` for missing, corrupt, or unsupported
durable checkpoint data. It is persisted with `.retryable` recovery and an
opaque diagnostic ID; callers never receive a managed path, response body, or
decoder detail.

- [x] **Step 4: Update exhaustive state switches**

Update `ImportCenterPresentation`, query matching, tests, and all switches so `cancelling` and `cancelled` are explicit. Use these initial presentation mappings:

Classify `cancelling` as `.active` and `.unfinished`; classify `cancelled` as
`.unfinished` but not `.active`. Both remain visible in `.all`.

```swift
case .cancelling:
    ImportCenterPresentation(
        title: "Import Center",
        message: "Cancelling import",
        systemImage: "xmark.circle"
    )

case .cancelled:
    ImportCenterPresentation(
        title: "Import Center",
        message: "Import cancelled",
        systemImage: "xmark.circle"
    )
```

Until Task 2 adds the v2 schema invariants, update the existing LocalLibrary
validation switches in `Records.swift` and `LibraryDatabase.swift` so the new
durable states are explicit under the v1 column model. Treat `queued`,
`running`, `cancelling`, `failed`, and `cancelled` as corrupt/impossible in
those v1-only switches; do not silently map them to legacy states. Task 2 must
replace these temporary guards with the complete v2 validation rules.

- [x] **Step 5: Run focused model tests**

Run:

```bash
swift test --filter ImportTaskModelTests
swift test --filter PublicationModelTests
swift test --filter ImportCenterPresentationTests
```

Expected: PASS.

- [x] **Step 6: Commit**

```bash
git add Sources/KnowledgeCore/ImportTask.swift Sources/DocumentImport/ImportTaskModels.swift Sources/AppSupport/ImportCenterPresentation.swift Sources/LocalLibrary/Internal/Records.swift Sources/LocalLibrary/Internal/LibraryDatabase.swift Tests/KnowledgeCoreTests/PublicationModelTests.swift Tests/DocumentImportTests/ImportTaskModelTests.swift Tests/AppSupportTests/ImportCenterPresentationTests.swift
git commit -m "feat: define durable import task lifecycle"
```

---

### Task 2: Add LocalLibrary durable FIFO queue authority

**Files:**

- Modify: `Sources/LocalLibrary/Internal/SchemaMigrations.swift`
- Modify: `Sources/LocalLibrary/Internal/Records.swift`
- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Sources/LocalLibrary/LocalLibraryTypes.swift`
- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Tests/LocalLibraryTests/ImportAcceptanceTests.swift`
- Create: `Tests/LocalLibraryTests/ImportQueueTests.swift`

- [x] **Step 1: Write failing migration and FIFO tests**

Add tests that submit three sources and inspect package-level durable snapshots:

```swift
@Test
func acceptedTasksReceiveDurableFIFOSequence() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(.webpage(URL(string: "https://example.test/1")!))
    let second = try await library.accept(.webpage(URL(string: "https://example.test/2")!))
    let third = try await library.accept(.webpage(URL(string: "https://example.test/3")!))

    let retained = try await library.retainedImports()
    #expect(retained.map(\.taskID) == [first.taskID, second.taskID, third.taskID])
    #expect(retained.compactMap(\.queueSequence) == [1, 2, 3])
    #expect(retained.allSatisfy { $0.queueSequence != nil })
    #expect(retained.allSatisfy { $0.state == .queued })
}

@Test
func claimNextRunnableIsExclusiveAndDurable() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(.webpage(URL(string: "https://example.test/1")!))
    _ = try await library.accept(.webpage(URL(string: "https://example.test/2")!))

    let claimed = try await library.claimNextRunnable()
    #expect(claimed?.claimed.taskID == first.taskID)
    #expect(claimed?.claimed.state == .running)
    #expect(claimed?.queueUpdates.count == 1)
    #expect(try await library.claimNextRunnable() == nil)
}
```

Add a migration fixture with v1 rows in `accepted`, `working`, `completed`, and `abandoned` states. Assert migration maps accepted/working to queued in deterministic `rowid` order, leaves completed history intact, and does not resurrect abandoned rows.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter acceptedTasksReceiveDurableFIFOSequence
swift test --filter claimNextRunnableIsExclusiveAndDurable
swift test --filter migratesV1ImportTasksIntoDurableQueue
```

Expected: FAIL because queue columns and APIs do not exist.

- [x] **Step 3: Add the v2 schema migration**

Register `v2_durable_import_queue` after v1:

```swift
migrator.registerMigration("v2_durable_import_queue") { db in
    try db.alter(table: "import_tasks") { table in
        table.add(column: "journal_sequence", .integer)
        table.add(column: "queue_sequence", .integer)
        table.add(column: "failure_codec_version", .integer)
        table.add(column: "failure_payload", .blob)
        table.add(column: "cancellation_requested", .boolean)
            .notNull()
            .defaults(to: false)
    }
    try db.create(
        index: "import_tasks_journal_sequence",
        on: "import_tasks",
        columns: ["journal_sequence"],
        unique: true
    )
    try db.create(
        index: "import_tasks_active_queue",
        on: "import_tasks",
        columns: ["queue_sequence"],
        unique: true,
        condition: Column("queue_sequence") != nil
    )
    try db.execute(sql: """
        CREATE TABLE import_queue_clock (
            singleton INTEGER PRIMARY KEY CHECK (singleton = 1),
            last_sequence INTEGER NOT NULL CHECK (last_sequence >= 0)
        )
        """)
    try db.execute(sql: """
        UPDATE import_tasks
        SET state = 'queued'
        WHERE state IN ('accepted', 'working')
        """)
    let rows = try Row.fetchAll(
        db,
        sql: """
            SELECT task_id, state
            FROM import_tasks
            ORDER BY rowid
            """
    )
    for (offset, row) in rows.enumerated() {
        let sequence = offset + 1
        try db.execute(
            sql: """
                UPDATE import_tasks
                SET journal_sequence = ?,
                    queue_sequence = CASE WHEN state = 'queued' THEN ? ELSE NULL END
                WHERE task_id = ?
                """,
            arguments: [
                sequence,
                sequence,
                row["task_id"] as String,
            ]
        )
    }
    try db.execute(
        sql: """
            INSERT INTO import_queue_clock(singleton, last_sequence)
            VALUES (1, ?)
            """,
        arguments: [rows.count]
    )
}
```

Use GRDB APIs that compile under 7.11.1; if conditional-index builder syntax differs, issue an explicit `CREATE UNIQUE INDEX ... WHERE queue_sequence IS NOT NULL` statement.

- [x] **Step 4: Extend records and snapshots**

Add record fields:

```swift
var journalSequence: Int64
var queueSequence: Int64?
var failureCodecVersion: Int64?
var failurePayload: Data?
var cancellationRequested: Bool
```

Extend `DurableImportSnapshot`:

```swift
package let journalSequence: UInt64
public let queueSequence: UInt64?
public let failure: ImportTaskFailureEnvelope?
```

Add mutation result values so position-only revision changes cannot be lost:

```swift
package struct DurableQueueMutation: Sendable {
    package let primary: DurableImportSnapshot
    package let queueUpdates: [DurableImportSnapshot]
}

package struct DurableQueueClaim: Sendable {
    package let claimed: DurableImportSnapshot
    package let queueUpdates: [DurableImportSnapshot]
}
```

Validate that every retained row has a unique positive journal sequence, queued
rows have a positive queue sequence, nonqueued rows do not, failed rows have a
valid failure envelope, and other rows do not carry failure payload.

- [x] **Step 5: Implement queue allocation and exclusive claim**

In one SQLite write transaction, read and increment the singleton
`import_queue_clock.last_sequence`, reject Int64 overflow, and insert accepted
Web tasks as `.queued` revision zero with that new value. Never derive the next
value from `MAX(queue_sequence)`: terminal tasks clear their active sequence,
so that calculation would reuse old values and violate monotonicity. Retry uses
the same clock transaction but preserves the task's immutable journal
sequence. On first acceptance, the allocated value becomes both journal and
queue sequence.

Add package APIs:

```swift
package func retainedImports() async throws -> [DurableImportSnapshot]

package func claimNextRunnable() throws -> DurableQueueClaim?
```

`retainedImports()` orders the running or cancelling record first, queued
records by queue sequence next, then failed/cancelled/completed history by
immutable journal sequence. Legacy abandoned rows remain excluded. The
registry uses this order for the first authoritative task-list emission.

`claimNextRunnable` must:

1. return nil if any row is already running, cancelling, or publication pending;
2. select the lowest queued sequence;
3. clear its queue sequence;
4. set running;
5. increment revision;
6. return the updated snapshot.

Every queue mutation that removes a queued item must also increment the durable
revision of each later queued row whose derived public position changes. Return
those rows in `queueUpdates`, ordered by queue sequence, from the same
transaction. Appending a new tail item does not change existing positions and
does not revise existing rows.

- [x] **Step 6: Run LocalLibrary queue tests**

Run:

```bash
swift test --filter ImportQueueTests
swift test --filter ImportAcceptanceTests
swift test --filter LocalLibraryTests
```

Expected: PASS.

- [x] **Step 7: Commit**

```bash
git add Sources/LocalLibrary Sources/KnowledgeCore/ImportTask.swift Tests/LocalLibraryTests/ImportAcceptanceTests.swift Tests/LocalLibraryTests/ImportQueueTests.swift
git commit -m "feat: persist import task fifo queue"
```

---

### Task 3: Add task-owned checkpoint artifact authority

**Files:**

- Modify: `Sources/LocalLibrary/LocalLibraryTypes.swift`
- Modify: `Sources/LocalLibrary/Internal/SchemaMigrations.swift`
- Modify: `Sources/LocalLibrary/Internal/Records.swift`
- Modify: `Sources/LocalLibrary/Internal/ManagedArtifactPath.swift`
- Modify: `Sources/LocalLibrary/Internal/ManagedArtifacts.swift`
- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Sources/LocalLibrary/ImportWorkspace.swift`
- Modify: `Tests/LocalLibraryTests/CheckpointTests.swift`
- Create: `Tests/LocalLibraryTests/CheckpointArtifactTests.swift`

- [x] **Step 1: Write failing checkpoint package tests**

Create a deterministic package containing `metadata.json` and `payload.bin`. Assert attach, verify, replace, cleanup, and reopen behavior:

```swift
@Test
func checkpointPackageIsTaskOwnedAndReplaceable() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(.webpage(URL(string: "https://example.test/article")!))
    let initial = try await workspace.snapshot()

    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    let first = try await workspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 2,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("first".utf8)
            )
        )
    )
    let verified = try await workspace.loadCheckpointArtifact(first.artifact)
    #expect(verified.descriptor.byteCount > 0)
    #expect(verified.files["payload.bin"] == Data("first".utf8))

    let secondPackage = try makeCheckpointPackage(body: Data("second".utf8))
    let second = try await workspace.replaceCheckpointArtifact(
        packageURL: secondPackage,
        update: CheckpointUpdate(
            expectedRevision: first.snapshot.revision,
            ordinal: 4,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("second".utf8)
            )
        )
    )
    #expect(second.artifact != first.artifact)
    #expect(try await workspace.checkpointArtifactCount() == 1)
}
```

Define the deterministic unmanaged-package fixture in
`CheckpointArtifactTests.swift`:

```swift
private func makeCheckpointPackage(body: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data(#"{"codecVersion":1}"#.utf8).write(
        to: root.appending(path: "metadata.json"),
        options: .atomic
    )
    try body.write(
        to: root.appending(path: "payload.bin"),
        options: .atomic
    )
    return root
}
```

Add tests for cross-task artifact forgery, symlinked packages, corruption after attach, cleanup after cancellation, and orphan cleanup on library reopen.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter CheckpointArtifactTests
```

Expected: FAIL because checkpoint artifact types, storage, and APIs do not exist.

- [x] **Step 3: Define checkpoint artifact values**

Add package-scoped values that expose identity and descriptor but not paths:

```swift
package struct CheckpointArtifactDescriptor: Hashable, Codable, Sendable {
    package let byteCount: Int64
    package let contentHash: String
}

package struct ManagedCheckpointArtifact: Hashable, Sendable {
    package let rawValue: UUID
    package let descriptor: CheckpointArtifactDescriptor
}

package struct VerifiedCheckpointPackage: Sendable {
    package let descriptor: CheckpointArtifactDescriptor
    package let files: [String: Data]
}

package struct CheckpointArtifactReplacement: Sendable {
    package let artifact: ManagedCheckpointArtifact
    package let snapshot: DurableImportSnapshot
}
```

Add `package let checkpointArtifact: ManagedCheckpointArtifact?` to `DurableImportSnapshot`. Checkpoint identity remains invisible outside the Swift package.

- [x] **Step 4: Add the additive schema migration and managed path scope**

Register `v3_import_checkpoint_artifacts` after
`v2_durable_import_queue`; never append this table to the already-applied v2
migration. Add a `checkpoint_artifacts` table with one row per task:

```sql
CREATE TABLE checkpoint_artifacts (
    artifact_id TEXT PRIMARY KEY,
    task_id TEXT NOT NULL UNIQUE REFERENCES import_tasks(task_id) ON DELETE CASCADE,
    descriptor_json BLOB NOT NULL,
    relative_path TEXT NOT NULL
)
```

Extend `ManagedArtifactPath`:

```swift
case checkpoint(taskID: ImportTaskID, artifactID: UUID)
```

Canonical relative path:

```text
Checkpoints/<TASK-UUID>/<ARTIFACT-UUID>
```

Create and validate a dedicated `Checkpoints` root beside `Staging` and `Artifacts`.

- [x] **Step 5: Implement safe copy, verify, replace, and remove**

Reuse `ManagedArtifactPayload.verifyAndSynchronize` for package hashing. Replacement order must be:

1. copy new package into a new task-owned checkpoint path;
2. verify bytes and descriptor;
3. in one database transaction, replace the artifact row, persist the supplied
   checkpoint ordinal and envelope, and increment task revision once;
4. remove the previous package after commit;
5. if database mutation fails, remove only the new package.

The database must never expose a new artifact with an old checkpoint envelope,
or a new envelope with an old artifact. Never overwrite an existing package in
place. Never expose the resolved path to Document Import.

- [x] **Step 6: Add workspace operations**

Add:

```swift
package func replaceCheckpointArtifact(
    packageURL: URL,
    update: CheckpointUpdate
) async throws -> CheckpointArtifactReplacement

package func loadCheckpointArtifact(
    _ artifact: ManagedCheckpointArtifact
) async throws -> VerifiedCheckpointPackage

package func removeCheckpointArtifact(
    expectedRevision: UInt64
) async throws -> DurableImportSnapshot
```

`removeCheckpointArtifact` clears the artifact row and checkpoint envelope in
the same revisioned transaction before removing owned bytes. Add crash/fault
tests proving reopen observes either the complete old pair or the complete new
pair, never a mixed association.

`loadCheckpointArtifact` verifies ownership, path scope, symlink absence,
descriptor hash, and byte bounds before returning an in-memory map keyed only
by normalized relative file names. It never returns the managed root or a
resolved managed URL. The Web codec performs its own exact-file-set and domain
validation on this verified package.

Add package-only test helpers for artifact count and fault injection.

- [x] **Step 7: Run checkpoint artifact tests**

Run:

```bash
swift test --filter CheckpointArtifactTests
swift test --filter CheckpointTests
swift test --filter LocalLibraryTests
```

Expected: PASS.

- [x] **Step 8: Commit**

```bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/CheckpointTests.swift Tests/LocalLibraryTests/CheckpointArtifactTests.swift
git commit -m "feat: manage import checkpoint packages"
```

---

### Task 4: Implement versioned Web checkpoint codecs

**Files:**

- Create: `Sources/DocumentImport/Internal/WebImportCheckpoint.swift`
- Modify: `Sources/DocumentImport/Internal/WebAcquisition.swift`
- Modify: `Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift`
- Modify: `Sources/DocumentImport/Internal/StaticArticleExtractor.swift`
- Modify: `Tests/DocumentImportTests/URLSessionStaticWebAcquirerTests.swift`
- Modify: `Tests/DocumentImportTests/StaticArticleExtractorTests.swift`
- Create: `Tests/DocumentImportTests/WebImportCheckpointTests.swift`

- [x] **Step 1: Write failing acquired and prepared checkpoint tests**

Add exact round-trip tests:

```swift
@Test
func acquiredWebCheckpointRoundTripsResponseBytesAndCharset() throws {
    let page = AcquiredWebPage(
        sourceURL: URL(string: "https://example.test/start")!,
        finalURL: URL(string: "https://example.test/final")!,
        mimeType: "text/html",
        textEncodingName: "windows-1252",
        bytes: Data([0x93, 0x48, 0x69, 0x94])
    )
    let package = try WebImportCheckpointCodec.writeAcquired(page)
    defer { try? FileManager.default.removeItem(at: package.url) }

    #expect(try WebImportCheckpointCodec.readAcquired(at: package.url) == page)
}
```

Add prepared-candidate round trip with fixed document content, fingerprint, issues, staged artifact identity, and Original Source. Add rejection tests for missing files, extra files, traversal, unsupported codec, mismatched integrity metadata, oversized body, and corrupt JSON.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter WebImportCheckpointTests
swift test --filter URLSessionStaticWebAcquirerTests
```

Expected: FAIL because charset and checkpoint codec do not exist.

- [x] **Step 3: Preserve HTTP charset**

Extend `AcquiredWebPage`:

```swift
let textEncodingName: String?
```

Set it from `HTTPURLResponse.textEncodingName`, normalized to lowercase ASCII. Persist nil when absent. Keep MIME normalization separate.

Update the extractor to decode bytes in this order:

1. recognized HTTP charset;
2. UTF-8;
3. HTML5 meta charset detection limited to the first 1024 bytes;
4. throw `unreadableHTML`.

Use Foundation `String.Encoding` mappings for UTF-8, UTF-16, ISO-8859-1, Windows-1252, Shift-JIS, EUC-JP, GB18030/GBK where supported. Unknown charsets do not bypass byte bounds.

- [x] **Step 4: Define checkpoint metadata and package layout**

Use these exact package layouts:

```text
acquired/
  metadata.json
  response.bin

prepared/
  metadata.json
  candidate.json
```

Define a tagged metadata enum:

```swift
enum WebImportCheckpointMetadata: Codable, Sendable {
    case acquired(AcquiredMetadata)
    case prepared(PreparedMetadata)
}
```

Writers return this concrete value:

```swift
struct EncodedWebCheckpointPackage: Sendable {
    let url: URL
    let descriptor: CheckpointArtifactDescriptor
}
```

Readers provide both a temporary-package entry point for codec unit tests and
a runtime entry point that consumes LocalLibrary's path-free value:

```swift
static func readAcquired(
    _ package: VerifiedCheckpointPackage
) throws -> AcquiredWebPage

static func readPrepared(
    _ package: VerifiedCheckpointPackage
) throws -> PreparedWebPublication
```

Both variants include codec version 1, SHA-256 hashes for payload files, byte counts, and a domain tag. URLs are stored only as required task data and never logged.

- [x] **Step 5: Implement strict read/write validation**

Writers create a new temporary directory, write deterministic sorted-key JSON, synchronize files, and return the package URL plus descriptor. Readers require the exact file set, reject symlinks, verify byte counts and hashes before decoding, and validate every domain value.

Prepared candidate JSON must encode:

```swift
struct PreparedWebPublication: Codable, Sendable {
    let documentID: SourceDocumentID
    let fingerprint: ContentFingerprint
    let document: SourceDocumentContent
    let originalSource: OriginalSource
    let stagedArtifactID: UUID
    let stagedDescriptor: SourceArtifactDescriptor
    let issues: [ImportIssue]
}
```

- [x] **Step 6: Run focused codec and extraction tests**

Run:

```bash
swift test --filter WebImportCheckpointTests
swift test --filter URLSessionStaticWebAcquirerTests
swift test --filter StaticArticleExtractorTests
```

Expected: PASS.

- [x] **Step 7: Commit**

```bash
git add Sources/DocumentImport/Internal/WebImportCheckpoint.swift Sources/DocumentImport/Internal/WebAcquisition.swift Sources/DocumentImport/Internal/URLSessionStaticWebAcquirer.swift Sources/DocumentImport/Internal/StaticArticleExtractor.swift Tests/DocumentImportTests/WebImportCheckpointTests.swift Tests/DocumentImportTests/URLSessionStaticWebAcquirerTests.swift Tests/DocumentImportTests/StaticArticleExtractorTests.swift
git commit -m "feat: persist web import checkpoints"
```

---

### Task 5: Build bootstrap, snapshot registry, and FIFO scheduler

**Files:**

- Create: `Sources/DocumentImport/Internal/TaskSnapshotRegistry.swift`
- Create: `Sources/DocumentImport/Internal/ImportScheduler.swift`
- Refactor: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift`
- Modify: `Tests/DocumentImportTests/RealStaticWebImportIntegrationTests.swift`
- Create: `Tests/DocumentImportTests/DurableImportQueueTests.swift`

- [x] **Step 1: Write failing scheduler and bootstrap tests**

Use a deterministic runner gate and real temporary LocalLibrary:

```swift
@Test
func schedulerRunsOneHeavyTaskInDurableFIFOOrder() async throws {
    let harness = try await DurableQueueHarness.make()
    let first = try await harness.importer.submit(.webpage(harness.url("/1")))
    let second = try await harness.importer.submit(.webpage(harness.url("/2")))
    let third = try await harness.importer.submit(.webpage(harness.url("/3")))

    try await harness.runner.waitUntilStarted(first.id)
    #expect(await harness.runner.maximumConcurrentRuns == 1)
    #expect(await harness.runner.startedIDs == [first.id])
    #expect(try await currentQueuedPosition(second) == 1)
    #expect(try await currentQueuedPosition(third) == 2)

    await harness.runner.release(first.id)
    try await harness.runner.waitUntilStarted(second.id)
    #expect(await harness.runner.startedIDs == [first.id, second.id])
}
```

In `DocumentImportTestSupport.swift`, define the test seam used by this and later tasks:

```swift
actor DeterministicRunnerGate {
    private(set) var startedIDs: [ImportTaskID] = []
    private(set) var maximumConcurrentRuns = 0

    func run(_ workspace: ImportWorkspace) async throws
    func waitUntilStarted(_ taskID: ImportTaskID) async throws
    func release(_ taskID: ImportTaskID)
    func isStillRunning(_ taskID: ImportTaskID) -> Bool
}

struct DurableQueueHarness {
    let root: URL
    let library: LocalLibrary
    let importer: DocumentImport
    let runner: DeterministicRunnerGate

    static func make() async throws -> DurableQueueHarness
    func url(_ path: String) -> URL
}

func latestSnapshot(_ handle: ImportTaskHandle) async throws
    -> ImportTaskSnapshot

func currentQueuedPosition(_ handle: ImportTaskHandle) async throws
    -> Int
```

Implement waits with cancellation and one-second timeouts using the bounded continuation pattern already used by `RealStaticWebImportIntegrationTests`; no test helper may wait indefinitely.

Add a bootstrap ordering test that accepts tasks directly in LocalLibrary, creates `DocumentImport`, immediately submits another task, and proves recovered tasks run first. Add simultaneous wake-up stress coverage.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter DurableImportQueueTests
```

Expected: FAIL because scheduler, bootstrap, and durable positions do not exist.

- [x] **Step 3: Implement TaskSnapshotRegistry**

Use an actor-confined value owned by `DocumentImport`. Store records keyed by task ID and terminal waiters keyed by `(taskID, attempt)`.

Required operations:

```swift
mutating func hydrate(_ snapshots: [DurableImportSnapshot])
mutating func apply(
    _ snapshot: ImportTaskSnapshot,
    journalSequence: UInt64
)
mutating func registerTaskObserver(...)
mutating func registerListObserver(...)
mutating func registerWaiter(taskID: ImportTaskID, attempt: UInt, ...)
mutating func finishAttempt(taskID: ImportTaskID, attempt: UInt, terminal: ImportTerminalState)
```

Ignore stale snapshots whose attempt or revision decreases. Treat an identical
same-attempt/same-revision snapshot as an idempotent no-op; treat conflicting
data at the same revision as durable corruption. Only a greater revision may
produce observer emissions.

Hydration and every later durable transition pass the immutable journal
sequence alongside the public projection. The registry keeps it as internal
ordering metadata; it never appears on `ImportTaskSnapshot` or
`ImportTaskHandle`.

Use these exact query predicates:

- `.active`: queued, running, or cancelling;
- `.unfinished`: active plus failed and cancelled;
- `.all`: unfinished plus completed.

List emissions order running/cancelling first, queued snapshots by public
position, and retained terminal history by immutable journal sequence. A
position-only durable revision produces a new list emission.

- [x] **Step 4: Implement idempotent bootstrap barrier**

Add a stored bootstrap state:

```swift
private enum BootstrapState {
    case idle
    case running(Task<Void, Error>)
    case ready
}
```

Expose the explicit barrier:

```swift
public func start() async throws
```

`start()` creates or awaits one task. On failure it returns to idle so a later
call can retry and throws
`DocumentImportAvailabilityError.localLibraryUnavailable`; it never creates a
second scheduler. Hydrate retained tasks before starting the scheduler.
Observation registrations remain pending until successful hydration and do
not receive a fabricated empty authoritative list.

- [x] **Step 5: Implement ImportScheduler**

The scheduler owns:

```swift
private var active: Task<Void, Never>?
private var wakeRequested = false
```

Every wake is routed through the DocumentImport actor. If active is nil, claim the next durable task and start the injected runner closure. Runner completion clears active and immediately requests another wake. Never loop on a stale in-memory queue.

Apply `DurableQueueClaim.queueUpdates` and then the claimed running snapshot to
the registry before starting the runner, so every shifted queued position is
observable at its new revision.

- [x] **Step 6: Route submit through the scheduler**

`submit` now:

1. awaits bootstrap;
2. validates source;
3. durably accepts queued task;
4. hydrates/applies its durable snapshot;
5. wakes the scheduler;
6. returns a handle.

Remove the direct unstructured `Task { runWebImport(...) }` launch.
If implicit bootstrap fails, map it to
`ImportSubmissionError.localLibraryUnavailable` before durable acceptance.

- [x] **Step 7: Run queue and legacy integration tests**

Run:

```bash
swift test --filter DurableImportQueueTests
swift test --filter DocumentImportIntegrationTests
swift test --filter RealStaticWebImportIntegrationTests
```

Expected: PASS with T04 lifecycle semantics preserved for a single task.

- [x] **Step 8: Commit**

```bash
git add Sources/DocumentImport/Internal/TaskSnapshotRegistry.swift Sources/DocumentImport/Internal/ImportScheduler.swift Sources/DocumentImport/DocumentImport.swift Tests/DocumentImportTests/DocumentImportTestSupport.swift Tests/DocumentImportTests/DurableImportQueueTests.swift Tests/DocumentImportTests/DocumentImportIntegrationTests.swift Tests/DocumentImportTests/RealStaticWebImportIntegrationTests.swift
git commit -m "feat: schedule durable import queue"
```

---

### Task 6: Implement resumable ImportTaskRunner

**Files:**

- Create: `Sources/DocumentImport/Internal/ImportTaskRunner.swift`
- Modify: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Sources/LocalLibrary/ImportWorkspace.swift`
- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift`
- Create: `Tests/DocumentImportTests/ImportRestartRecoveryTests.swift`

- [x] **Step 1: Write failing stage-resume tests**

Add three focused tests using injected acquisition/build counters:

```swift
@Test
func restartAfterAcquisitionReusesPersistedPageWithoutNetwork() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterAcquiredCheckpoint
    )
    let handle = try await harness.firstImporter.submit(.webpage(harness.articleURL))
    try await harness.crashInjector.waitForInjectedTermination()
    #expect(await harness.acquirer.callCount == 1)

    let reopened = try await harness.reopenImporter(acquirer: .failingIfCalled)
    let recovered = try #require(try await reopened.task(id: handle.id))
    #expect(await recovered.value().isSuccess)
    #expect(await harness.acquirer.callCount == 1)
}

@Test
func restartAfterPreparedCheckpointPublishesWithoutRebuilding() async throws {
    let harness = try await RecoveryHarness.make(
        crashPoint: .afterPreparedCheckpoint
    )
    let handle = try await harness.firstImporter.submit(.webpage(harness.articleURL))
    try await harness.crashInjector.waitForInjectedTermination()
    #expect(await harness.builder.callCount == 1)

    let reopened = try await harness.reopenImporter(builder: .failingIfCalled)
    let recovered = try #require(try await reopened.task(id: handle.id))
    #expect(await recovered.value().isSuccess)
    #expect(await harness.builder.callCount == 1)
}
```

Add this concrete recovery harness contract to
`DocumentImportTestSupport.swift`. The tests reference the internal
`T05CrashPoint` enum added to the runner source during GREEN in Step 3:

```swift
actor ImportRunnerCrashInjector {
    init(crashPoint: T05CrashPoint?)
    func hit(_ point: T05CrashPoint) async throws
    func waitForInjectedTermination() async throws
}

struct RecoveryHarness {
    let root: URL
    let articleURL: URL
    let firstImporter: DocumentImport
    let acquirer: CountingWebAcquirer
    let builder: CountingWebBuilder
    let crashInjector: ImportRunnerCrashInjector

    static func make(
        crashPoint: T05CrashPoint? = nil
    ) async throws -> RecoveryHarness

    func reopenImporter(
        acquirer: CountingWebAcquirer.Mode = .normal,
        builder: CountingWebBuilder.Mode = .normal
    ) async throws -> DocumentImport
}
```

`CountingWebAcquirer` and `CountingWebBuilder` are actors with `callCount` and `.normal` / `.failingIfCalled` modes. `ImportRunnerCrashInjector` suspends at an exact durable boundary and then throws its injected termination without performing graceful task cleanup, simulating process loss while leaving SQLite and managed files intact.

The injected runner boundary must treat
`ImportTaskRunnerInterruption.injectedProcessTermination` as a test-only abrupt
stop: let it escape the attempt without recording failure or cancellation.
`waitForInjectedTermination()` uses the same bounded one-second continuation
pattern as the other harness waits. Production errors and
`CancellationError` keep their normal handling.

Add accepted-only recovery and corrupt checkpoint retryable-failure tests.

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter ImportRestartRecoveryTests
```

Expected: FAIL because the runner does not resume checkpoints.

- [x] **Step 3: Define runner stage decoding**

Map durable checkpoint ordinals:

```swift
enum WebImportStage: UInt64 {
    case acquiring = 1
    case acquired = 2
    case constructing = 3
    case prepared = 4
    case publishing = 5
}
```

Define the internal injection seam in the runner source so tests do not leak a
test-target type into production code:

```swift
enum T05CrashPoint: CaseIterable, Sendable {
    case afterAcceptance
    case afterAcquiredCheckpoint
    case afterPreparedCheckpoint
    case afterPublicationIntent
    case afterArtifactMove
    case afterVisibilityCommit
    case duringCancellationCleanup
}

enum ImportTaskRunnerInterruption: Error, Sendable {
    case injectedProcessTermination
}

typealias ImportRunnerBoundaryHook = @Sendable (
    T05CrashPoint
) async throws -> Void
```

The default hook is a no-op. The test initializer supplies
`ImportRunnerCrashInjector.hit`; that actor throws
`.injectedProcessTermination` only at its configured point. Catch this error
before the ordinary failure and cancellation handlers and return without a
durable transition.

The runner reads the snapshot and selects:

- no checkpoint or acquiring: acquire;
- acquired: load the path-free verified package and decode the acquired page;
- constructing: load the acquired package and rebuild;
- prepared or publishing: load and decode the prepared package, verify the
  staged artifact, then publish.

Unknown ordinals or codec versions become retryable checkpoint failures.

- [x] **Step 4: Persist acquisition before construction**

After URLSession succeeds:

1. write acquired checkpoint package;
2. atomically replace the artifact and persist the acquired checkpoint update;
3. apply the returned snapshot;
4. emit constructing progress;
5. only then invoke the builder.

Remove temporary package data after LocalLibrary owns the copy.

- [x] **Step 5: Persist prepared publication candidate**

After builder and publication staging succeed:

1. create `PreparedWebPublication` from authoritative product values;
2. write prepared checkpoint package;
3. atomically replace the acquired package and persist the prepared checkpoint
   update;
4. apply the returned snapshot;
5. emit publishing progress;
6. call `finish`.

The prepared package is removed after durable completion. LocalLibrary publication recovery still owns publication-intent boundaries.

For both published and Already Imported outcomes, delete the checkpoint
artifact row in the same terminal database transaction. Return its owned
cleanup placement to the LocalLibrary actor and remove the package only after
commit; if post-commit removal fails, the next `LocalLibrary.open` orphan sweep
finishes cleanup without changing the completed result.

- [x] **Step 6: Persist failures instead of abandoning tasks**

Add a versioned DocumentImport failure codec:

```swift
struct PersistedImportFailure: Codable, Sendable {
    let code: ImportFailure.Code
    let recovery: ImportFailure.Recovery
    let diagnosticID: UUID
}
```

On noncancellation failure, call a LocalLibrary transition that records `.failed`, clears active queue sequence, stores the failure envelope, increments revision, and retains only valid retry checkpoints. Do not call legacy `abandon` for ordinary task failure.

- [x] **Step 7: Run recovery and full DocumentImport tests**

Run:

```bash
swift test --filter ImportRestartRecoveryTests
swift test --filter DocumentImportIntegrationTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [x] **Step 8: Commit**

```bash
git add Sources/DocumentImport/Internal/ImportTaskRunner.swift Sources/DocumentImport/DocumentImport.swift Sources/LocalLibrary/ImportWorkspace.swift Sources/LocalLibrary/LocalLibrary.swift Sources/LocalLibrary/Internal/LibraryDatabase.swift Tests/DocumentImportTests/DocumentImportTestSupport.swift Tests/DocumentImportTests/DocumentImportIntegrationTests.swift Tests/DocumentImportTests/ImportRestartRecoveryTests.swift
git commit -m "feat: resume web imports from checkpoints"
```

---

### Task 7: Implement durable cancellation, retry, and per-attempt waiting

**Files:**

- Modify: `Sources/LocalLibrary/LocalLibraryTypes.swift`
- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Sources/LocalLibrary/ImportWorkspace.swift`
- Modify: `Sources/DocumentImport/Internal/TaskSnapshotRegistry.swift`
- Modify: `Sources/DocumentImport/Internal/ImportScheduler.swift`
- Modify: `Sources/DocumentImport/Internal/ImportTaskRunner.swift`
- Modify: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Sources/DocumentImport/ImportTaskHandle.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Modify: `Tests/DocumentImportTests/DurableImportQueueTests.swift`
- Create: `Tests/DocumentImportTests/ImportTaskControlTests.swift`
- Modify: `Tests/LocalLibraryTests/ImportQueueTests.swift`

- [x] **Step 1: Write failing cancel, retry, and waiter tests**

Cover queued cancellation, running cancellation, repeated cancellation, too-late publication, retry tail fairness, attempt increments, and waiter binding:

```swift
@Test
func retryKeepsIdentityIncrementsAttemptAndEntersQueueTail() async throws {
    let harness = try await DurableQueueHarness.make()
    let failed = try await harness.submitRetryableFailure()
    let waiting = try await harness.importer.submit(.webpage(harness.url("/waiting")))

    try await failed.retry()
    let retried = try await latestSnapshot(failed)
    #expect(retried.id == failed.id)
    #expect(retried.attempt == 2)
    #expect(retried.state == .queued(position: 2))
    #expect(try await currentQueuedPosition(waiting) == 1)
}

@Test
func valueWaiterRemainsBoundToAttemptThatRegisteredIt() async throws {
    let harness = try await DurableQueueHarness.make()
    let handle = try await harness.submitRetryableFailure(blockTerminalDelivery: true)
    let firstAttempt = Task { await handle.value() }
    await harness.releaseFailure()
    #expect(await firstAttempt.value.isRetryableFailure)

    try await handle.retry()
    let secondAttempt = await handle.value()
    #expect(secondAttempt != await firstAttempt.value)
}
```

Extend `DurableQueueHarness` with exact control fixtures:

```swift
func submitRetryableFailure(
    blockTerminalDelivery: Bool = false
) async throws -> ImportTaskHandle

func releaseFailure() async
```

Add test-only computed properties on `ImportTerminalState`:

```swift
var isRetryableFailure: Bool {
    guard case .failure(let failure) = self else { return false }
    return failure.recovery == .retryable
}

var isSuccess: Bool {
    if case .success = self { return true }
    return false
}
```

- [x] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter ImportTaskControlTests
```

Expected: FAIL because durable control transitions are not implemented.

- [x] **Step 3: Implement LocalLibrary cancellation transitions**

Add transactional operations:

```swift
package func requestCancellation(
    taskID: ImportTaskID,
    expectedRevision: UInt64
) throws -> DurableQueueMutation

package func finishCancellation(
    taskID: ImportTaskID,
    expectedRevision: UInt64
) throws -> DurableImportSnapshot
```

Rules:

- queued/running -> cancelling, clear queue sequence, set cancellation requested, revision +1;
- cancelling/cancelled repeat returns current snapshot without another revision;
- completed throws `.invalidTaskState`, translated by DocumentImport to `.tooLate`;
- failure remains failure until explicit retry;
- finishCancellation requires cancelling, no publication intent, and completed owned checkpoint/staging cleanup.

- [x] **Step 4: Implement LocalLibrary retry transaction**

Add:

```swift
package func retryImport(
    taskID: ImportTaskID,
    expectedRevision: UInt64,
    checkpointDisposition: RetryCheckpointDisposition
) throws -> DurableImportSnapshot
```

Define the package-scoped disposition in `LocalLibraryTypes.swift`:

```swift
package enum RetryCheckpointDisposition: Sendable {
    case retainVerified
    case clear
}
```

Document Import first decodes the failure and checks
`recovery == .retryable`. For failed tasks it loads and decodes the current
checkpoint before selecting `retainVerified`; missing, corrupt, unsupported,
or disallowed data selects `clear`. Cancelled tasks always select `clear`.
Local Library accepts only durable failed or cancelled states with the expected
revision; package access keeps this transition behind the trusted Document
Import boundary. In the same transaction it increments attempt, clears
terminal failure and cancellation request, clears checkpoint ownership when
requested, allocates the queue tail, sets queued, and increments revision once.
Owned bytes selected for clearing are removed after commit and any orphan is
recovered on open.

- [x] **Step 5: Connect structured cancellation**

`DocumentImport.cancel(taskID:)`:

1. awaits bootstrap;
2. loads current durable snapshot;
3. requests durable cancellation;
4. applies every returned queue-position update and the cancelling snapshot;
5. cancels the active runner if IDs match;
6. otherwise performs queued cleanup;
7. applies cancelled snapshot;
8. wakes scheduler.

The runner catches `CancellationError` separately and never records failure. Resource localizer and URLSession cancellation regressions must remain green.

- [x] **Step 6: Implement retry and task lookup**

Add:

```swift
public func task(id: ImportTaskID) async throws -> ImportTaskHandle?
```

Lookup awaits bootstrap, returns `nil` for an unknown or legacy-abandoned task,
and never starts or mutates work. Bootstrap failures from lookup, cancel, and
retry surface `DocumentImportAvailabilityError.localLibraryUnavailable`.
Unknown cancel/retry IDs throw `.taskNotFound`; completed or non-retryable
retry throws `.retryNotAllowed`; state races use `.invalidState`; completed
cancel maps the LocalLibrary publication winner to `.tooLate`.

`retry(taskID:)` decodes the durable failure when present, validates recovery,
performs the retry transaction, applies the queued snapshot, and wakes the
scheduler.

Complete the public handle commands only after the owner transitions are implemented:

```swift
public func cancel() async throws {
    try await owner.cancel(taskID: id)
}

public func retry() async throws {
    try await owner.retry(taskID: id)
}
```

The handle exposes no queue sequence, checkpoint, workspace, or runner value.

- [x] **Step 7: Bind waiters to attempt**

Change registry waiters from a task-only array to:

```swift
private var waiters: [TaskAttemptKey: [CheckedContinuation<ImportTerminalState, Never>]]
```

where `TaskAttemptKey` contains task ID and attempt. `value()` captures the current attempt after bootstrap and registration. Finishing attempt one never resumes attempt-two waiters.

- [x] **Step 8: Run control and regression tests**

Run:

```bash
swift test --filter ImportTaskControlTests
swift test --filter DurableImportQueueTests
swift test --filter WebResourceLocalizerTests
swift test --filter URLSessionStaticWebAcquirerTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [x] **Step 9: Commit**

```bash
git add Sources/LocalLibrary Sources/DocumentImport Tests/LocalLibraryTests/ImportQueueTests.swift Tests/DocumentImportTests/DocumentImportTestSupport.swift Tests/DocumentImportTests/ImportTaskControlTests.swift Tests/DocumentImportTests/DurableImportQueueTests.swift
git commit -m "feat: control durable import tasks"
```

---

### Task 8: Prove restart recovery and cross-instance exclusivity

**Files:**

- Modify: `Sources/LocalLibrary/Internal/LibraryDatabase.swift`
- Modify: `Sources/LocalLibrary/LocalLibrary.swift`
- Modify: `Sources/DocumentImport/Internal/ImportScheduler.swift`
- Modify: `Tests/DocumentImportTests/ImportRestartRecoveryTests.swift`
- Modify: `Tests/LocalLibraryTests/PublicationRecoveryTests.swift`
- Modify: `Tests/LocalLibraryTests/CheckpointArtifactTests.swift`

- [ ] **Step 1: Write failing crash-boundary matrix**

Use the internal `T05CrashPoint` cases already defined with
`ImportTaskRunner` and add the parameterized recovery test:

```swift
@Test(arguments: T05CrashPoint.allCases)
func restartRecoversEachDurableImportBoundary(_ point: T05CrashPoint) async throws {
    let harness = try await RecoveryHarness.make(crashPoint: point)
    let taskID = try await harness.runUntilInjectedTermination()
    let reopened = try await harness.reopen()
    let handle = try #require(try await reopened.importer.task(id: taskID))
    let terminal = await handle.value()

    #expect(terminal.isExpectedFor(point))
    #expect(reopened.visibleDocumentCount <= 1)
    #expect(try await reopened.checkpointArtifactCount(taskID) == 0)
    #expect(reopened.unownedStagingCount == 0)
}
```

Extend `RecoveryHarness` with the exact APIs used by the matrix:

```swift
struct ReopenedRecoveryHarness {
    let importer: DocumentImport
    let visibleDocumentCount: Int
    let unownedStagingCount: Int

    func checkpointArtifactCount(_ taskID: ImportTaskID) async throws -> Int
}

extension RecoveryHarness {
    func runUntilInjectedTermination() async throws -> ImportTaskID
    func reopen() async throws -> ReopenedRecoveryHarness
}

extension ImportTerminalState {
    func isExpectedFor(_ point: T05CrashPoint) -> Bool
}
```

Add a test that constructs two `DocumentImport` instances sharing the same opened LocalLibrary actor and proves durable claim allows only one runner.

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter restartRecoversEachDurableImportBoundary
swift test --filter twoImportersCannotRunTheSameDurableTask
```

Expected: FAIL at unimplemented reconciliation or exclusivity edges.

- [ ] **Step 3: Harden bootstrap reconciliation**

`LocalLibrary.open` reconciles interrupted runner/publication states exactly
once before returning the actor. Document Import bootstrap hydrates that
result and does not reset running rows a second time. Reconcile states as
follows:

- queued: leave queued;
- running: return to queued without changing attempt, retaining valid checkpoint;
- cancelling: retain as cancelling for the Document Import bootstrap cleanup
  pass;
- failed/cancelled/completed: retained, not scheduled;
- publicationPending: let Local Library publication recovery finish or rollback before Document Import hydration;
- abandoned legacy: excluded from retained public tasks.

Each reconciliation is transactional and revisioned.

After hydration and before the scheduler starts, Document Import bootstrap
invokes the same idempotent owned-resource cleanup used by `cancel()` for every
retained cancelling task, applies the cancelled snapshot only after cleanup
succeeds, and leaves the task cancelling if cleanup fails so a later `start()`
or reopen can retry.

- [ ] **Step 4: Harden claim ownership across importer instances**

Claim must be a single SQLite write transaction that first checks no active durable runner state. If two Document Import schedulers sharing one LocalLibrary race, one receives a running snapshot and the other receives nil. Do not use process-global locks. Concurrent independent LocalLibrary actors for the same root are outside T05.

- [ ] **Step 5: Recover and clean checkpoint artifacts**

On LocalLibrary open:

- delete checkpoint directories with no database owner;
- quarantine or report database-owned corrupt checkpoint packages;
- let Document Import bootstrap finish cancelling cleanup before scheduler
  claims queued work;
- never remove a package owned by another task;
- synchronize checkpoint root after removals.

- [ ] **Step 6: Run recovery and publication regression tests**

Run:

```bash
swift test --filter ImportRestartRecoveryTests
swift test --filter PublicationRecoveryTests
swift test --filter CheckpointArtifactTests
swift test --filter LocalLibraryTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/LocalLibrary Sources/DocumentImport/Internal/ImportScheduler.swift Tests/DocumentImportTests/ImportRestartRecoveryTests.swift Tests/LocalLibraryTests/PublicationRecoveryTests.swift Tests/LocalLibraryTests/CheckpointArtifactTests.swift
git commit -m "test: prove import task restart recovery"
```

---

### Task 9: Add the observable ImportTaskStore adapter

**Files:**

- Modify: `Package.swift`
- Create: `Sources/AppSupport/ImportTaskStore.swift`
- Modify: `Sources/AppSupport/ImportCenterPresentation.swift`
- Create: `Tests/AppSupportTests/ImportTaskStoreTests.swift`
- Modify: `Tests/AppSupportTests/ImportCenterPresentationTests.swift`

- [ ] **Step 1: Write failing adapter lifecycle tests**

Add tests using a real DocumentImport with gated tasks:

```swift
@MainActor
@Test
func recreatingStoreDoesNotCancelDurableWork() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    var firstStore: ImportTaskStore? = ImportTaskStore(importer: harness.importer)
    await firstStore?.start()
    await firstStore?.submit(.webpage(harness.articleURL))
    let taskID = try #require(firstStore?.tasks.first?.id)

    firstStore?.stopObserving()
    firstStore = nil

    let secondStore = ImportTaskStore(importer: harness.importer)
    await secondStore.start()
    #expect(secondStore.tasks.contains { $0.id == taskID })
    #expect(await harness.runner.isStillRunning(taskID))
}
```

Define `ImportTaskStoreHarness` and its bounded `StoreRunnerGate` locally in
`ImportTaskStoreTests.swift`; test targets cannot import helpers from
`DocumentImportTests`:

```swift
actor StoreRunnerGate {
    func run(_ workspace: ImportWorkspace) async throws
    func waitUntilStarted(_ taskID: ImportTaskID) async throws
    func release(_ taskID: ImportTaskID)
    func isStillRunning(_ taskID: ImportTaskID) -> Bool
}

struct ImportTaskStoreHarness {
    let root: URL
    let importer: DocumentImport
    let runner: StoreRunnerGate
    let articleURL: URL

    static func make() async throws -> ImportTaskStoreHarness
}
```

Add `KnowledgeCore` and `LocalLibrary` as direct dependencies of the
`AppSupportTests` target in `Package.swift`, allowing the local harness to open
a real library and construct deterministic sources.

Add cancel/retry routing, bootstrap availability error, Already Imported, failed, cancelled, and presentation tests.

- [ ] **Step 2: Run tests to verify RED**

Run:

```bash
swift test --filter ImportTaskStoreTests
```

Expected: FAIL because `ImportTaskStore` does not exist.

- [ ] **Step 3: Implement the MainActor observable store**

Create:

```swift
import DocumentImport
import KnowledgeCore
import Observation

@MainActor
@Observable
public final class ImportTaskStore {
    public private(set) var tasks: [ImportTaskSnapshot] = []
    public private(set) var controlError: ImportTaskControlError?
    public private(set) var availabilityError: DocumentImportAvailabilityError?

    private let importer: DocumentImport
    private var observationTask: Task<Void, Never>?

    public init(importer: DocumentImport) {
        self.importer = importer
    }
}
```

`start()` cancels only the previous observation task, awaits importer readiness, then consumes `.unfinished`. `stopObserving()` cancels only observation. `deinit` cancels observation without calling task cancel.

- [ ] **Step 4: Implement submit, cancel, and retry actions**

Implement these exact actions:

```swift
public func submit(_ source: OriginalSource) async
public func cancel(id: ImportTaskID) async
public func retry(id: ImportTaskID) async
```

Use `DocumentImport.task(id:)` for recovered tasks. Clear the corresponding error before each action. Map availability and control errors separately; do not synthesize task failures.

- [ ] **Step 5: Run AppSupport and DocumentImport tests**

Run:

```bash
swift test --filter ImportTaskStoreTests
swift test --filter ImportCenterPresentationTests
swift test --filter AppSupportTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/AppSupport/ImportTaskStore.swift Sources/AppSupport/ImportCenterPresentation.swift Tests/AppSupportTests/ImportTaskStoreTests.swift Tests/AppSupportTests/ImportCenterPresentationTests.swift
git commit -m "feat: expose import task store adapter"
```

---

### Task 10: Debug-only final integration, review, and push

**Files:**

- Review every T05-owned source, migration, fixture, test, design, and plan file.
- Preserve the user-owned dirty paths.

- [ ] **Step 1: Add final public-path lifecycle coverage**

Create or extend a public integration test that:

1. submits three loopback webpages;
2. proves durable FIFO and one active runner;
3. drops and recreates observers;
4. cancels the second queued task;
5. lets the first publish;
6. retries the cancelled task and proves it enters behind the third;
7. terminates after acquisition and reopens;
8. proves the acquired page is reused without network;
9. reaches published, cancelled, failed, retried, and Already Imported outcomes through public APIs;
10. verifies AppSupport sees no internal stage or checkpoint type.

- [ ] **Step 2: Run branch and whitespace checks**

Run:

```bash
git diff --check origin/main...HEAD
git diff --name-only origin/main...HEAD
git status --short --branch
```

Expected: no committed whitespace errors; diff contains only T05 design, plan, source, migrations, and tests; user-owned dirty paths remain uncommitted.

- [ ] **Step 3: Run focused Debug suites**

Run:

```bash
swift test --filter ImportQueueTests
swift test --filter CheckpointArtifactTests
swift test --filter DurableImportQueueTests
swift test --filter ImportTaskControlTests
swift test --filter ImportRestartRecoveryTests
swift test --filter ImportTaskStoreTests
```

Expected: PASS.

- [ ] **Step 4: Run full Debug tests**

Run:

```bash
swift test
```

Expected: all tests pass with zero failures.

- [ ] **Step 5: Run Debug package build**

Run:

```bash
swift build
```

Expected: Debug build succeeds.

- [ ] **Step 6: Run Debug macOS app build**

Run:

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t05 \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 7: Request final code review**

Use `superpowers:requesting-code-review` against Issue #6, the approved T05 design, this plan, and `origin/main...HEAD`. Fix every Critical and Important finding with a failing regression test first. Repeat review until approved.

- [ ] **Step 8: Confirm Debug-only verification**

The completion report must list only the Debug commands above. Confirm no Release test or build command was run and no automated test contacted a public network.

- [ ] **Step 9: Push the feature branch**

Run:

```bash
git push -u origin feature/t05-durable-import-queue
```

Expected: local and remote branch SHAs match.

---

## Completion Criteria

- Accepted tasks remain in durable FIFO order across restart.
- Exactly one heavy Import Task runs at a time, including across competing importer instances.
- Public snapshots carry monotonic revisions, attempts, dynamic queue positions, cancelling, and cancelled states.
- Dropping or recreating observation and `ImportTaskStore` never cancels work.
- Queued and running cancellation is durable and idempotent.
- Publication wins the cancellation race only by committing first, after which cancel returns `.tooLate`.
- Retry keeps task identity, increments attempt once, and enters the queue tail.
- Acquired Web bytes and prepared publication candidates resume from verified managed checkpoint packages.
- Invalid checkpoints fail retryably and are reacquired only after explicit retry.
- Restart recovery produces at most one Source Document and no unowned checkpoint or staging artifact.
- Submission errors remain limited to failures before durable acceptance.
- AppSupport exposes cancel, retry, success, failure, cancellation, and Already Imported without internal stages.
- Existing T02–T04 persistence and public Web import behavior remain compatible.
- Full Debug tests, Debug package build, and Debug macOS app build pass.
- Final review has no Critical or Important findings and the feature branch is pushed.
