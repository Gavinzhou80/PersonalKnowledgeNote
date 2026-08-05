# T02 Local Library Publication Seam Design

> Status: approved; implementation tracked by the T02 Local Library publication seam plan
> Date: 2026-08-05
> Ticket: GitHub issue #3 — T02 Define and prove the minimum Local Library publication seam
> Parent design: Document Import Architecture Design

## Goal

Define and prove a deep Local Library module that gives Document Import durable Import Tasks, task-owned staging, recoverable checkpoints, duplicate resolution, provenance attachment, and observable all-or-nothing Source Document publication.

The interface must make the safe order easy and the unsafe order unavailable. Callers do not coordinate SQLite transactions, managed-file moves, fingerprint reservations, trash lookup, provenance writes, or crash recovery.

## Confirmed constraints

- V1 has one macOS application process writing the library.
- One Local Library actor serializes mutations inside that process.
- The application can terminate at any persistence or file-publication point and must recover on reopen.
- SQLite and the managed filesystem are local-substitutable dependencies.
- Production and tests use the same SQLite and filesystem implementations; tests substitute only a temporary library root and internal fault-injection hook.
- Managed staging and final artifacts reside on the same filesystem so directory rename is atomic.
- Database schema, table names, managed-file layout, manifests, and low-level errors remain internal.
- Local Library depends on KnowledgeCore domain values. KnowledgeCore does not depend on LocalLibrary, GRDB, or filesystem implementation types.
- T02 does not implement Web/PDF parsing, Document Import scheduling, search projection, knowledge-log projection, trash restoration UI, or a generic repository layer.

## Design alternatives considered

### Command-oriented session

A single perform-command entry point produces a very small nominal interface, but the command enum becomes a second workflow language. It is less discoverable and encourages exposing duplicate lookup as a separate command.

### Flexible session and leases

Separate original-source, workspace, checkpoint, failure, and publication capabilities maximize future flexibility. They also create more lifecycle rules and interface surface than T02 requires.

### Import Workspace capability

The selected design binds all task mutations to one Import Workspace. Local Library owns acceptance and recovery, while the workspace owns staging, checkpointing, publication, and abandonment for exactly one Import Task.

This gives the common caller a direct path while keeping fingerprint lookup, provenance, file publication, and task completion inside one deep finish operation.

## Module direction

~~~text
PersonalKnowledgeNote / AppSupport
              |
              v
        KnowledgeCore
              ^
              |
        LocalLibrary
              |
              +-- GRDB / SQLite
              +-- managed filesystem
~~~

KnowledgeCore owns stable domain values. LocalLibrary implements persistence and managed-file behavior for those values.

Package dependencies become:

~~~text
AppSupport -> KnowledgeCore
AppSupport -> LocalLibrary
LocalLibrary -> KnowledgeCore
KnowledgeCore -> Foundation only
~~~

## Public interface

The following Swift defines the intended seam. Minor naming refinements are allowed during implementation, but the ordering and invariants are fixed.

~~~swift
public actor LocalLibrary {
    /// Opens the library only after migrations and crash recovery complete.
    public static func open(
        at root: URL
    ) async throws -> LocalLibrary

    /// Returns only after the Import Task is durable.
    ///
    /// For a PDF Original Source, acceptance also copies and verifies the
    /// selected bytes into task-owned staging before returning.
    public func accept(
        _ source: OriginalSource
    ) async throws -> ImportWorkspace

    /// Returns unfinished tasks after startup recovery has reconciled
    /// publication intents, staging, and managed files.
    public func recoverableImports()
        async throws -> [ImportWorkspace]

    /// Recreates a capability for an accepted or retained completed task.
    /// This lets a caller retry finish after a crash that happened after the
    /// durable outcome committed but before the reply was received.
    public func importWorkspace(
        id: ImportTaskID
    ) async throws -> ImportWorkspace?

    /// Returns a Source Document only after publication is fully visible.
    /// Hidden publication rows and incomplete artifacts never appear.
    public func sourceDocument(
        id: SourceDocumentID
    ) async throws -> LocatedSourceDocument?
}
~~~

~~~swift
public actor ImportWorkspace {
    public nonisolated let taskID: ImportTaskID

    public func snapshot()
        async throws -> DurableImportSnapshot

    /// Copies a file or package into task-owned staging, verifies it, and
    /// returns an opaque capability. The input URL is never retained as the
    /// managed location.
    public func stageArtifact(
        _ input: SourceArtifactInput,
        expectedRevision: UInt64
    ) async throws -> StagedArtifact

    /// Persists the next versioned, safe resume point.
    @discardableResult
    public func checkpoint(
        _ update: CheckpointUpdate
    ) async throws -> DurableImportSnapshot

    /// The only publication operation. It rechecks the Content Fingerprint,
    /// chooses duplicate resolution or new publication, attaches provenance,
    /// publishes managed files and database records, and completes the task.
    public func finish(
        _ candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) async throws -> PublicationOutcome

    /// Durable and idempotent before publication becomes visible.
    public func abandon(
        expectedRevision: UInt64
    ) async throws
}
~~~

The module does not expose findDuplicate, attachProvenance, insertDocument, moveArtifact, transaction, repository, database, or managed-path methods.

## Required domain values

T02 adds only the stable KnowledgeCore values needed by the seam:

~~~swift
public struct ImportTaskID: Hashable, Codable, Sendable
public struct SourceDocumentID: Hashable, Codable, Sendable
public struct SourceBlockID: Hashable, Codable, Sendable
public struct ContentFingerprint: Hashable, Codable, Sendable

public enum OriginalSource: Hashable, Codable, Sendable {
    case webpage(URL)
    case pdfFile(URL)
}

public enum ExistingDocumentLocation: Hashable, Codable, Sendable {
    case library
    case trash
}

public enum SourceArtifactKind: Hashable, Codable, Sendable {
    case webPackage
    case pdf
}

public struct SourceArtifactDescriptor: Hashable, Codable, Sendable {
    public let kind: SourceArtifactKind
    public let byteCount: UInt64
    public let contentHash: String
}
~~~

A Source Document's domain content is already constructed and validated by Document Import. KnowledgeCore defines it without any LocalLibrary capability or managed-path type:

~~~swift
public struct SourceDocumentContent: Sendable {
    public let documentID: SourceDocumentID
    public let importedMetadata: ImportedDocumentMetadata
    public let blocks: [SourceBlock]
    public let structure: SourceStructure
    public let evidence: [SourceBlockID: SourceEvidence]
}

public struct SourceDocument: Sendable {
    public let content: SourceDocumentContent
    public let artifact: SourceArtifactDescriptor
}
~~~

T02 implements the minimum valid versions of ImportedDocumentMetadata, SourceBlock, SourceStructure, and SourceEvidence needed to publish a readable, locatable fixture document. Later tickets deepen those domain values without changing the Local Library publication ordering.

## Opaque staging and durable task state

~~~swift
public enum SourceArtifactInput: Sendable {
    case file(URL, descriptor: SourceArtifactDescriptor)
    case package(URL, descriptor: SourceArtifactDescriptor)
}

public struct StagedArtifact: Hashable, Sendable {
    // Opaque token. No URL or relative managed path is public.
}

public struct PublicationCandidate: Sendable {
    public let fingerprint: ContentFingerprint
    public let artifact: StagedArtifact
    public let document: SourceDocumentContent
    public let originalSource: OriginalSource
}

public struct DurableImportSnapshot: Sendable {
    public let taskID: ImportTaskID
    public let attempt: UInt
    public let revision: UInt64
    public let state: ImportTaskState
    public let checkpoint: CheckpointEnvelope?
    public let stagedArtifact: StagedArtifact?
}

public struct CheckpointUpdate: Sendable {
    public let expectedRevision: UInt64
    public let ordinal: UInt64
    public let envelope: CheckpointEnvelope
}

public struct CheckpointEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data
}

public enum ImportTaskState: Hashable, Codable, Sendable {
    case accepted
    case working
    case publicationPending
    case completed
    case abandoned
}
~~~

Local Library treats the checkpoint envelope as opaque bytes. Document Import owns its codec and evolution. Local Library enforces task ownership, expected revision, monotonically increasing ordinal, a 1 MiB maximum encoded payload, and legal terminal-state rules.

## Publication outcome

~~~swift
public enum PublicationOutcome: Sendable {
    case published(
        documentID: SourceDocumentID
    )

    case alreadyImported(
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation,
        provenanceAdded: Bool
    )
}

public struct LocatedSourceDocument: Sendable {
    public let document: SourceDocument
    public let location: ExistingDocumentLocation
}
~~~

Calling finish again for the same completed task returns the durable prior outcome. It never creates a second Source Document or repeats a successful provenance insertion.

A read-only fingerprint lookup is deliberately not part of the external workflow. Fingerprint uniqueness is decided inside finish. The database may maintain private lookup operations and unique constraints.

## Core invariants

- accept returns only after the Import Task can be recovered from a reopened library.
- For PDF acceptance, the external file is no longer required after accept returns.
- One Import Workspace is permanently bound to one Import Task.
- Every mutation checks expectedRevision; stale writes fail without changing state.
- Checkpoint ordinal and snapshot revision increase monotonically.
- A Staged Artifact belongs to one Import Task and cannot be consumed by another.
- Sealed staged content is immutable.
- The Publication Candidate's Original Source must match the Import Task's accepted source.
- Every Import Task publishes at most one Source Document.
- finish is idempotent for a completed task.
- Fingerprint lookup is repeated inside finish; an earlier result can never guarantee uniqueness.
- Duplicate lookup, provenance insertion, stored outcome, and task completion share one SQLite transaction.
- A duplicate in trash remains one Source Document and reports trash as its location.
- A provenance-write failure cannot report provenanceAdded as true.
- Only fully visible Source Documents can be returned by sourceDocument.
- Published Source Documents are immutable.
- Abandon is idempotent before publication visibility and cannot undo a published document.

## Publication protocol

SQLite and the filesystem cannot share one physical transaction. Local Library therefore provides observable atomicity through a durable publication intent and a single database visibility point.

### Duplicate path

Inside the Local Library actor:

1. Validate task state, expected revision, candidate, fingerprint, and staged-artifact ownership.
2. Start one SQLite transaction.
3. Look up the fingerprint across library and trash.
4. Insert Original Source provenance only when it is new.
5. Store the durable already-imported outcome.
6. Complete the Import Task.
7. Commit the transaction.
8. Release task staging after the commit.

No new managed artifact or Source Document is published.

### New-document path

1. Validate and synchronize the sealed staged artifact.
2. In one SQLite transaction:
   - reserve the Content Fingerprint;
   - persist a hidden publication intent;
   - persist the complete Source Document graph as hidden;
   - record the intended final managed-artifact identity.
3. Commit the hidden intent transaction.
4. Atomically rename the staged artifact/package to its final managed location.
5. Synchronize the final artifact and parent directory.
6. In one SQLite transaction:
   - verify the managed artifact and manifest;
   - mark the complete Source Document graph visible;
   - insert Original Source provenance;
   - store the durable published outcome;
   - complete the Import Task;
   - delete the publication intent.
7. Commit the visibility transaction.

The second SQLite commit is the only Source Document visibility point. Readers never query hidden rows.

## Startup recovery

LocalLibrary.open runs migrations and recovery before returning.

For each durable publication intent:

- Intent exists, final artifact absent: remove the hidden document graph and fingerprint reservation, then retain or restore the task to its latest safe checkpoint.
- Intent exists, verified final artifact present: complete the visibility transaction idempotently.
- Intent exists, final artifact invalid: remove or quarantine the artifact, keep the Source Document hidden, and surface a retryable task failure.
- Visible Source Document exists but its artifact is missing or mismatched: report corruptLibrary; never return the document as valid.
- Staging has no owning Import Task or retained lease: remove it.
- Managed artifact has no visible document or valid intent: remove or quarantine it.
- A completed task whose caller did not receive finish's reply returns its stored PublicationOutcome when finish is retried.
- importWorkspace(id:) can recreate the task capability after restart, including for a retained completed outcome.

Recovery is idempotent and can itself be interrupted safely.

## Error interface

~~~swift
public enum LocalLibraryError: Error, Sendable {
    case unavailable
    case insufficientDiskSpace
    case staleRevision(current: UInt64)
    case invalidTaskState
    case checkpointRegression
    case artifactMissing
    case artifactOwnershipViolation
    case publicationFailed(retryable: Bool)
    case corruptLibrary(diagnosticID: UUID)
}
~~~

Errors expose only facts callers can act on. GRDB errors, SQLite codes, POSIX errors, full local paths, table names, and manifest details stay in privacy-safe internal diagnostics.

## Internal implementation shape

Suggested internal files:

~~~text
Sources/LocalLibrary/
├── LocalLibrary.swift
├── ImportWorkspace.swift
├── LibraryDatabase.swift
├── SchemaMigrations.swift
├── ManagedArtifacts.swift
├── ImportTaskJournal.swift
├── PublicationCoordinator.swift
├── PublicationRecovery.swift
└── Internal/
    └── PublicationFaultInjector.swift
~~~

These files form one deep module, not public repositories. PublicationCoordinator owns ordering across LibraryDatabase and ManagedArtifacts so transaction knowledge remains local.

GRDB is an implementation dependency of LocalLibrary only.

## Testing strategy

Tests cross the same public seam used by Document Import and use a unique temporary directory containing a real SQLite database and managed-files tree.

Required tests:

1. Accept an Import Task, release all library/workspace handles, reopen the same root, and recover the task.
2. Accept a PDF, remove the external original, and prove the staged artifact remains available.
3. Stage a deterministic Web package and prove the returned capability belongs to the task.
4. Publish a complete fixture Source Document and reload it through sourceDocument.
5. Inject termination before and after hidden-intent commit, atomic rename, final synchronization, and visibility commit.
6. Reopen after each injected point and observe either no Source Document or one complete readable and locatable Source Document.
7. Reopen the library, recreate the workspace by ImportTaskID, retry finish after a committed result, and receive the same outcome.
8. Reimport an identical fingerprint from a different source and receive alreadyImported without a second document.
9. Distinguish an existing document in library from one in trash.
10. Attach new provenance atomically during duplicate resolution.
11. Force provenance insertion failure and verify provenanceAdded is never true.
12. Verify stale revisions, cross-task staged-artifact use, checkpoint regression, and mutation after terminal state are rejected.
13. Verify tests do not access SQLite tables, managed relative paths, or repository mocks.

Fault injection is a package/internal test seam. It is not part of the production interface.

## Acceptance mapping

- Focused interface documented first: this design is the approval gate before production workflow code.
- Durable Import Task: accept and recoverableImports prove reopen behavior.
- Atomic Source Document: publication intent plus one visibility transaction.
- Failure injection: every cross-resource publication point is tested.
- Fingerprint location: finish returns alreadyImported with library or trash location.
- Atomic provenance: duplicate resolution, provenance, outcome, and task completion share a transaction.
- Real persistence: temporary SQLite and filesystem integration tests.
- Encapsulation: callers see domain values and capabilities, never tables or managed paths.

## Domain-model note

All public names use the existing CONTEXT.md vocabulary. T02 adds no new domain term. Import Workspace, publication intent, staging token, checkpoint envelope, and visibility point are implementation/interface concepts and do not belong in the domain glossary.
