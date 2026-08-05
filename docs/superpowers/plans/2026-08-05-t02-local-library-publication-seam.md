# T02 Local Library Publication Seam Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Implement a deep Local Library module that durably accepts Import Tasks, owns staging, persists checkpoints, atomically resolves duplicates or publishes Source Documents, and recovers every cross-resource crash point.

**Architecture:** KnowledgeCore owns stable domain values. LocalLibrary depends on KnowledgeCore and hides GRDB/SQLite, managed paths, staging manifests, publication intents, provenance records, and recovery behind LocalLibrary and ImportWorkspace. SQLite visibility is the authoritative publication point; a durable intent plus atomic same-volume rename makes file/database publication observably all-or-nothing.

**Tech Stack:** Swift 6, Swift Concurrency actors, Swift Testing, GRDB.swift 7.11.1, SQLite WAL, Foundation FileManager/FileHandle, CryptoKit SHA-256, macOS 15+.

---

## File map

- Package.swift — add GRDB 7.11.1 and LocalLibrary -> KnowledgeCore dependency.
- Package.resolved — pin the resolved GRDB revision.
- Sources/KnowledgeCore/Identifiers.swift — strongly typed Import Task, Source Document, Source Block, and fingerprint identities.
- Sources/KnowledgeCore/OriginalSource.swift — closed webpage/PDF Original Source.
- Sources/KnowledgeCore/SourceArtifact.swift — artifact kind and verified descriptor.
- Sources/KnowledgeCore/SourceDocument.swift — minimum complete readable/locatable Source Document values.
- Sources/KnowledgeCore/ImportTask.swift — durable task state and opaque checkpoint envelope.
- Sources/LocalLibrary/LocalLibraryTypes.swift — public capability and outcome types with no managed paths.
- Sources/LocalLibrary/LocalLibrary.swift — open, accept, recoverable task, task lookup, and visible document interface.
- Sources/LocalLibrary/ImportWorkspace.swift — task-bound capability methods.
- Sources/LocalLibrary/Internal/LibraryDatabase.swift — all GRDB reads/writes and transactions.
- Sources/LocalLibrary/Internal/SchemaMigrations.swift — private schema.
- Sources/LocalLibrary/Internal/Records.swift — private GRDB records and JSON encoding helpers.
- Sources/LocalLibrary/Internal/ManagedArtifacts.swift — staging, hashing, atomic rename, synchronization, and cleanup.
- Sources/LocalLibrary/Internal/PublicationCoordinator.swift — duplicate/new publication ordering.
- Sources/LocalLibrary/Internal/PublicationRecovery.swift — startup reconciliation.
- Sources/LocalLibrary/Internal/PublicationFaultInjector.swift — package-only deterministic fault points.
- Tests/LocalLibraryTests/LocalLibraryTestSupport.swift — temporary roots and fixture candidates.
- Tests/LocalLibraryTests/ImportAcceptanceTests.swift — durable acceptance and reopen.
- Tests/LocalLibraryTests/ArtifactStagingTests.swift — PDF capture and task-owned staging.
- Tests/LocalLibraryTests/CheckpointTests.swift — revision, ordinal, payload, and abandon rules.
- Tests/LocalLibraryTests/ImportPublicationTests.swift — complete publication and visibility.
- Tests/LocalLibraryTests/DuplicateResolutionTests.swift — duplicate, trash, provenance, and idempotency.
- Tests/LocalLibraryTests/PublicationRecoveryTests.swift — injected crash matrix and reopen recovery.
- README.md — GRDB resolution, module direction, and verification commands.
- docs/superpowers/specs/2026-08-05-t02-local-library-publication-seam-design.md — implementation tracking status.

### Task 1: Add the minimum KnowledgeCore publication model

**Files:**
- Create: Sources/KnowledgeCore/Identifiers.swift
- Create: Sources/KnowledgeCore/OriginalSource.swift
- Create: Sources/KnowledgeCore/SourceArtifact.swift
- Create: Sources/KnowledgeCore/SourceDocument.swift
- Create: Sources/KnowledgeCore/ImportTask.swift
- Create: Tests/KnowledgeCoreTests/PublicationModelTests.swift

- [ ] **Step 1: Write the failing domain-value tests**

Create Tests/KnowledgeCoreTests/PublicationModelTests.swift:

~~~swift
import Foundation
import KnowledgeCore
import Testing

@Test
func identifiersRoundTripThroughCodable() throws {
    let original = ImportTaskID()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ImportTaskID.self, from: data)

    #expect(decoded == original)
}

@Test
func identicalTextAtDifferentPositionsKeepsDistinctBlockIdentity() {
    let first = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )
    let second = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )

    #expect(first.id != second.id)
    #expect(first.canonicalText == second.canonicalText)
}

@Test
func sourceDocumentContentIsReadableAndLocatable() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let content = SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [
            block.id: .web(locator: "article > p:nth-of-type(1)")
        ]
    )

    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: data
    )

    #expect(decoded == content)
}
~~~

- [ ] **Step 2: Run the focused tests and verify the domain types are missing**

Run:

~~~bash
swift test --filter PublicationModelTests
~~~

Expected: FAIL during compilation because ImportTaskID, SourceBlock, and SourceDocumentContent do not exist.

- [ ] **Step 3: Implement strongly typed identifiers**

Create Sources/KnowledgeCore/Identifiers.swift:

~~~swift
import Foundation

public struct ImportTaskID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SourceDocumentID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SourceBlockID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ContentFingerprint: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}
~~~

- [ ] **Step 4: Implement Original Source and artifact values**

Create Sources/KnowledgeCore/OriginalSource.swift:

~~~swift
import Foundation

public enum OriginalSource: Hashable, Codable, Sendable {
    case webpage(URL)
    case pdfFile(URL)
}

public enum ExistingDocumentLocation: String, Hashable, Codable, Sendable {
    case library
    case trash
}
~~~

Create Sources/KnowledgeCore/SourceArtifact.swift:

~~~swift
import Foundation

public enum SourceArtifactKind: String, Hashable, Codable, Sendable {
    case webPackage
    case pdf
}

public struct SourceArtifactDescriptor: Hashable, Codable, Sendable {
    public let kind: SourceArtifactKind
    public let byteCount: UInt64
    public let contentHash: String

    public init(
        kind: SourceArtifactKind,
        byteCount: UInt64,
        contentHash: String
    ) {
        precondition(byteCount > 0)
        precondition(!contentHash.isEmpty)
        self.kind = kind
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}
~~~

- [ ] **Step 5: Implement the minimum Source Document graph**

Create Sources/KnowledgeCore/SourceDocument.swift:

~~~swift
import Foundation

public struct ImportedDocumentMetadata:
    Hashable,
    Codable,
    Sendable
{
    public let title: String
    public let author: String?

    public init(title: String, author: String?) {
        self.title = title
        self.author = author
    }
}

public struct SourceBlock: Hashable, Codable, Sendable {
    public let id: SourceBlockID
    public let canonicalText: String

    public init(id: SourceBlockID, canonicalText: String) {
        precondition(!canonicalText.isEmpty)
        self.id = id
        self.canonicalText = canonicalText
    }
}

public struct SourceStructure: Hashable, Codable, Sendable {
    public let orderedBlockIDs: [SourceBlockID]

    public init(orderedBlockIDs: [SourceBlockID]) {
        self.orderedBlockIDs = orderedBlockIDs
    }
}

public struct SourceRect: Hashable, Codable, Sendable {
    public let x: Double
    public let y: Double
    public let width: Double
    public let height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

public enum SourceEvidence: Hashable, Codable, Sendable {
    case web(locator: String)
    case pdf(page: Int, region: SourceRect)
}

public struct SourceDocumentContent:
    Hashable,
    Codable,
    Sendable
{
    public let documentID: SourceDocumentID
    public let importedMetadata: ImportedDocumentMetadata
    public let blocks: [SourceBlock]
    public let structure: SourceStructure
    public let evidence: [SourceBlockID: SourceEvidence]

    public init(
        documentID: SourceDocumentID,
        importedMetadata: ImportedDocumentMetadata,
        blocks: [SourceBlock],
        structure: SourceStructure,
        evidence: [SourceBlockID: SourceEvidence]
    ) {
        precondition(!blocks.isEmpty)
        precondition(Set(blocks.map(\.id)) == Set(structure.orderedBlockIDs))
        precondition(Set(blocks.map(\.id)) == Set(evidence.keys))
        self.documentID = documentID
        self.importedMetadata = importedMetadata
        self.blocks = blocks
        self.structure = structure
        self.evidence = evidence
    }
}

public struct SourceDocument: Hashable, Codable, Sendable {
    public let content: SourceDocumentContent
    public let artifact: SourceArtifactDescriptor

    public init(
        content: SourceDocumentContent,
        artifact: SourceArtifactDescriptor
    ) {
        self.content = content
        self.artifact = artifact
    }
}
~~~

- [ ] **Step 6: Implement durable Import Task values**

Create Sources/KnowledgeCore/ImportTask.swift:

~~~swift
import Foundation

public enum ImportTaskState: String, Hashable, Codable, Sendable {
    case accepted
    case working
    case publicationPending
    case completed
    case abandoned
}

public struct CheckpointEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data

    public init(codecVersion: UInt16, payload: Data) {
        self.codecVersion = codecVersion
        self.payload = payload
    }
}
~~~

- [ ] **Step 7: Run KnowledgeCore tests**

Run:

~~~bash
swift test --filter PublicationModelTests
swift test
~~~

Expected: both commands PASS with 0 failures.

- [ ] **Step 8: Commit the domain model**

~~~bash
git add Sources/KnowledgeCore Tests/KnowledgeCoreTests/PublicationModelTests.swift
git commit -m "feat: add local library publication domain values"
~~~

### Task 2: Add GRDB, schema migration, and durable task acceptance

**Files:**
- Modify: Package.swift
- Create: Package.resolved
- Create: Sources/LocalLibrary/LocalLibraryTypes.swift
- Replace: Sources/LocalLibrary/LocalLibrary.swift
- Create: Sources/LocalLibrary/ImportWorkspace.swift
- Create: Sources/LocalLibrary/Internal/Records.swift
- Create: Sources/LocalLibrary/Internal/SchemaMigrations.swift
- Create: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Create: Tests/LocalLibraryTests/LocalLibraryTestSupport.swift
- Create: Tests/LocalLibraryTests/ImportAcceptanceTests.swift

- [ ] **Step 1: Write the failing durable-acceptance test**

Create Tests/LocalLibraryTests/LocalLibraryTestSupport.swift:

~~~swift
import Foundation
import KnowledgeCore
@testable import LocalLibrary

func makeTemporaryLibraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PersonalKnowledgeNote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

func makeFixtureContent() -> SourceDocumentContent {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    return SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [block.id: .web(locator: "article > p")]
    )
}
~~~

Create Tests/LocalLibraryTests/ImportAcceptanceTests.swift:

~~~swift
import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func acceptedImportSurvivesLibraryReopen() async throws {
    let root = try makeTemporaryLibraryRoot()
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/article"))
    )

    let taskID = try await {
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(source)
        let snapshot = try await workspace.snapshot()

        #expect(snapshot.state == .accepted)
        #expect(snapshot.revision == 0)
        return workspace.taskID
    }()

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: taskID)
    )
    let snapshot = try await recovered.snapshot()

    #expect(snapshot.taskID == taskID)
    #expect(snapshot.state == .accepted)
}
~~~

- [ ] **Step 2: Run the test and verify LocalLibrary.open is missing**

Run:

~~~bash
swift test --filter acceptedImportSurvivesLibraryReopen
~~~

Expected: FAIL during compilation because LocalLibrary.open, ImportWorkspace, and DurableImportSnapshot do not exist.

- [ ] **Step 3: Add GRDB 7.11.1 and target dependency direction**

Modify Package.swift:

~~~swift
dependencies: [
    .package(
        url: "https://github.com/groue/GRDB.swift.git",
        exact: "7.11.1"
    ),
],
~~~

Change LocalLibrary target to:

~~~swift
.target(
    name: "LocalLibrary",
    dependencies: [
        "KnowledgeCore",
        .product(name: "GRDB", package: "GRDB.swift"),
    ]
),
~~~

Resolve and pin the dependency:

~~~bash
swift package resolve
~~~

Expected: Package.resolved records GRDB.swift 7.11.1.

- [ ] **Step 4: Add public Local Library capability types**

Create Sources/LocalLibrary/LocalLibraryTypes.swift:

~~~swift
import Foundation
import KnowledgeCore

public enum SourceArtifactInput: Sendable {
    case file(URL, descriptor: SourceArtifactDescriptor)
    case package(URL, descriptor: SourceArtifactDescriptor)
}

public struct StagedArtifact: Hashable, Sendable {
    package let rawValue: UUID
    public let descriptor: SourceArtifactDescriptor

    package init(
        rawValue: UUID,
        descriptor: SourceArtifactDescriptor
    ) {
        self.rawValue = rawValue
        self.descriptor = descriptor
    }
}

public struct PublicationCandidate: Sendable {
    public let fingerprint: ContentFingerprint
    public let artifact: StagedArtifact
    public let document: SourceDocumentContent
    public let originalSource: OriginalSource

    public init(
        fingerprint: ContentFingerprint,
        artifact: StagedArtifact,
        document: SourceDocumentContent,
        originalSource: OriginalSource
    ) {
        self.fingerprint = fingerprint
        self.artifact = artifact
        self.document = document
        self.originalSource = originalSource
    }
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

    public init(
        expectedRevision: UInt64,
        ordinal: UInt64,
        envelope: CheckpointEnvelope
    ) {
        self.expectedRevision = expectedRevision
        self.ordinal = ordinal
        self.envelope = envelope
    }
}

public enum PublicationOutcome: Hashable, Codable, Sendable {
    case published(documentID: SourceDocumentID)
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

public enum LocalLibraryError: Error, Equatable, Sendable {
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

- [ ] **Step 5: Add the private schema migration**

Create Sources/LocalLibrary/Internal/SchemaMigrations.swift:

~~~swift
import GRDB

enum SchemaMigrations {
    static func migrate(_ database: DatabaseQueue) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_local_library") { db in
            try db.create(table: "import_tasks") { table in
                table.column("task_id", .text).primaryKey()
                table.column("source_kind", .text).notNull()
                table.column("source_value", .text).notNull()
                table.column("attempt", .integer).notNull()
                table.column("revision", .integer).notNull()
                table.column("state", .text).notNull()
                table.column("checkpoint_ordinal", .integer)
                table.column("checkpoint_codec_version", .integer)
                table.column("checkpoint_payload", .blob)
                table.column("staged_artifact_id", .text)
                table.column("outcome_json", .blob)
            }

            try db.create(table: "staged_artifacts") { table in
                table.column("artifact_id", .text).primaryKey()
                table.column("task_id", .text)
                    .notNull()
                    .unique()
                    .references("import_tasks", onDelete: .cascade)
                table.column("descriptor_json", .blob).notNull()
                table.column("relative_path", .text).notNull()
            }

            try db.create(table: "source_documents") { table in
                table.column("document_id", .text).primaryKey()
                table.column("fingerprint", .text).notNull().unique()
                table.column("location", .text).notNull()
                table.column("visibility", .text).notNull()
                table.column("content_json", .blob).notNull()
                table.column("artifact_descriptor_json", .blob).notNull()
                table.column("managed_relative_path", .text).notNull()
            }

            try db.create(table: "source_provenance") { table in
                table.column("document_id", .text)
                    .notNull()
                    .references("source_documents", onDelete: .cascade)
                table.column("source_kind", .text).notNull()
                table.column("source_value", .text).notNull()
                table.primaryKey([
                    "document_id",
                    "source_kind",
                    "source_value",
                ])
            }

            try db.create(table: "publication_intents") { table in
                table.column("task_id", .text)
                    .primaryKey()
                    .references("import_tasks", onDelete: .cascade)
                table.column("document_id", .text).notNull()
                table.column("staged_artifact_id", .text).notNull()
                table.column("final_relative_path", .text).notNull()
            }
        }

        try migrator.migrate(database)
    }
}
~~~

- [ ] **Step 6: Add private records and source encoding**

Create Sources/LocalLibrary/Internal/Records.swift with GRDB records for every table. Use String UUIDs and JSON blobs only inside this file:

~~~swift
import Foundation
import GRDB
import KnowledgeCore

struct ImportTaskRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "import_tasks"

    var taskID: String
    var sourceKind: String
    var sourceValue: String
    var attempt: Int
    var revision: Int64
    var state: String
    var checkpointOrdinal: Int64?
    var checkpointCodecVersion: Int?
    var checkpointPayload: Data?
    var stagedArtifactID: String?
    var outcomeJSON: Data?
}

struct StagedArtifactRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "staged_artifacts"

    var artifactID: String
    var taskID: String
    var descriptorJSON: Data
    var relativePath: String
}

struct SourceDocumentRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "source_documents"

    var documentID: String
    var fingerprint: String
    var location: String
    var visibility: String
    var contentJSON: Data
    var artifactDescriptorJSON: Data
    var managedRelativePath: String
}

struct PublicationIntentRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "publication_intents"

    var taskID: String
    var documentID: String
    var stagedArtifactID: String
    var finalRelativePath: String
}

enum SourceColumns {
    static func encode(_ source: OriginalSource) -> (String, String) {
        switch source {
        case .webpage(let url):
            return ("webpage", url.absoluteString)
        case .pdfFile(let url):
            return ("pdf", url.absoluteString)
        }
    }

    static func decode(kind: String, value: String) throws -> OriginalSource {
        guard let url = URL(string: value) else {
            throw LocalLibraryError.unavailable
        }
        switch kind {
        case "webpage":
            return .webpage(url)
        case "pdf":
            return .pdfFile(url)
        default:
            throw LocalLibraryError.unavailable
        }
    }
}
~~~

- [ ] **Step 7: Implement durable task database operations**

Create Sources/LocalLibrary/Internal/LibraryDatabase.swift with DatabaseQueue initialization, migration, insert, task fetch, recoverable task fetch, and visible document fetch. The acceptance path must use one write transaction:

~~~swift
import Foundation
import GRDB
import KnowledgeCore

final class LibraryDatabase: @unchecked Sendable {
    let queue: DatabaseQueue

    init(url: URL) throws {
        queue = try DatabaseQueue(path: url.path)
        try SchemaMigrations.migrate(queue)
    }

    func insertAcceptedTask(
        id: ImportTaskID,
        source: OriginalSource
    ) throws {
        let columns = SourceColumns.encode(source)
        try queue.write { db in
            try ImportTaskRecord(
                taskID: id.rawValue.uuidString,
                sourceKind: columns.0,
                sourceValue: columns.1,
                attempt: 1,
                revision: 0,
                state: ImportTaskState.accepted.rawValue,
                checkpointOrdinal: nil,
                checkpointCodecVersion: nil,
                checkpointPayload: nil,
                stagedArtifactID: nil,
                outcomeJSON: nil
            ).insert(db)
        }
    }

    func task(id: ImportTaskID) throws -> ImportTaskRecord? {
        try queue.read { db in
            try ImportTaskRecord.fetchOne(
                db,
                key: id.rawValue.uuidString
            )
        }
    }

    func recoverableTasks() throws -> [ImportTaskRecord] {
        try queue.read { db in
            try ImportTaskRecord
                .filter(Column("state") != ImportTaskState.completed.rawValue)
                .fetchAll(db)
        }
    }
}
~~~

- [ ] **Step 8: Implement LocalLibrary and ImportWorkspace acceptance**

Replace Sources/LocalLibrary/LocalLibrary.swift:

~~~swift
import Foundation
import KnowledgeCore

public actor LocalLibrary {
    private let root: URL
    private let database: LibraryDatabase

    private init(root: URL, database: LibraryDatabase) {
        self.root = root
        self.database = database
    }

    public static func open(at root: URL) async throws -> LocalLibrary {
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: true
        )
        let database = try LibraryDatabase(
            url: root.appending(path: "library.sqlite")
        )
        return LocalLibrary(root: root, database: database)
    }

    public func accept(
        _ source: OriginalSource
    ) async throws -> ImportWorkspace {
        let taskID = ImportTaskID()
        try database.insertAcceptedTask(id: taskID, source: source)
        return ImportWorkspace(taskID: taskID, library: self)
    }

    public func recoverableImports()
        async throws -> [ImportWorkspace]
    {
        try database.recoverableTasks().map {
            ImportWorkspace(
                taskID: ImportTaskID(UUID(uuidString: $0.taskID)!),
                library: self
            )
        }
    }

    public func importWorkspace(
        id: ImportTaskID
    ) async throws -> ImportWorkspace? {
        guard try database.task(id: id) != nil else {
            return nil
        }
        return ImportWorkspace(taskID: id, library: self)
    }

    package func snapshot(
        taskID: ImportTaskID
    ) throws -> DurableImportSnapshot {
        guard let record = try database.task(id: taskID) else {
            throw LocalLibraryError.unavailable
        }
        return try record.snapshot()
    }
}
~~~

Create Sources/LocalLibrary/ImportWorkspace.swift:

~~~swift
import KnowledgeCore

public actor ImportWorkspace {
    public nonisolated let taskID: ImportTaskID
    private let library: LocalLibrary

    package init(taskID: ImportTaskID, library: LocalLibrary) {
        self.taskID = taskID
        self.library = library
    }

    public func snapshot() async throws -> DurableImportSnapshot {
        try await library.snapshot(taskID: taskID)
    }
}
~~~

Add snapshot decoding to Records.swift:

~~~swift
extension ImportTaskRecord {
    func snapshot(
        stagedArtifact: StagedArtifactRecord?
    ) throws -> DurableImportSnapshot {
        guard let id = UUID(uuidString: taskID),
              let decodedState = ImportTaskState(rawValue: state)
        else {
            throw LocalLibraryError.unavailable
        }

        let checkpoint: CheckpointEnvelope?
        if let version = checkpointCodecVersion,
           let payload = checkpointPayload
        {
            checkpoint = CheckpointEnvelope(
                codecVersion: UInt16(version),
                payload: payload
            )
        } else {
            checkpoint = nil
        }

        let artifact: StagedArtifact?
        if let stagedArtifact,
           let artifactID = UUID(uuidString: stagedArtifact.artifactID)
        {
            artifact = StagedArtifact(
                rawValue: artifactID,
                descriptor: try JSONDecoder().decode(
                    SourceArtifactDescriptor.self,
                    from: stagedArtifact.descriptorJSON
                )
            )
        } else {
            artifact = nil
        }

        return DurableImportSnapshot(
            taskID: ImportTaskID(id),
            attempt: UInt(attempt),
            revision: UInt64(revision),
            state: decodedState,
            checkpoint: checkpoint,
            stagedArtifact: artifact
        )
    }
}
~~~

Add a package initializer to DurableImportSnapshot matching the properties, and make LibraryDatabase.snapshot(taskID:) fetch the task and optional staged-artifact row in one database read before calling this decoder.

- [ ] **Step 9: Run acceptance and full tests**

Run:

~~~bash
swift test --filter acceptedImportSurvivesLibraryReopen
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 10: Commit durable acceptance**

~~~bash
git add Package.swift Package.resolved Sources/LocalLibrary Tests/LocalLibraryTests/LocalLibraryTestSupport.swift Tests/LocalLibraryTests/ImportAcceptanceTests.swift
git commit -m "feat: persist accepted import tasks"
~~~

### Task 3: Implement task-owned staging and PDF capture

**Files:**
- Create: Sources/LocalLibrary/Internal/ManagedArtifacts.swift
- Modify: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Modify: Sources/LocalLibrary/LocalLibrary.swift
- Modify: Sources/LocalLibrary/ImportWorkspace.swift
- Create: Tests/LocalLibraryTests/ArtifactStagingTests.swift

- [ ] **Step 1: Write failing PDF and Web staging tests**

Create Tests/LocalLibraryTests/ArtifactStagingTests.swift:

~~~swift
import Foundation
import KnowledgeCore
import Testing
import TestFixtures
@testable import LocalLibrary

@Test
func acceptingPDFCapturesBytesBeforeReturning() async throws {
    let root = try makeTemporaryLibraryRoot()
    let external = root.appending(path: "external.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: external
    )

    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let workspace = try await library.accept(.pdfFile(external))
    try FileManager.default.removeItem(at: external)

    let snapshot = try await workspace.snapshot()
    let artifact = try #require(snapshot.stagedArtifact)

    #expect(artifact.descriptor.kind == .pdf)
    #expect(artifact.descriptor.byteCount > 0)
}

@Test
func webPackageIsCopiedIntoTaskOwnedStaging() async throws {
    let root = try makeTemporaryLibraryRoot()
    let package = root.appending(path: "Article")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<article>Fixture</article>".utf8).write(
        to: package.appending(path: "index.html")
    )

    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com")))
    )
    let snapshot = try await workspace.snapshot()

    let descriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 26,
        contentHash: "caller-value-is-verified"
    )
    let artifact = try await workspace.stageArtifact(
        .package(package, descriptor: descriptor),
        expectedRevision: snapshot.revision
    )

    #expect(artifact.descriptor.kind == .webPackage)
}
~~~

- [ ] **Step 2: Run the staging tests and verify stageArtifact is missing**

Run:

~~~bash
swift test --filter ArtifactStagingTests
~~~

Expected: FAIL because PDF acceptance has no staged artifact and ImportWorkspace.stageArtifact does not exist.

- [ ] **Step 3: Implement managed staging**

Create Sources/LocalLibrary/Internal/ManagedArtifacts.swift with this implementation shape:

~~~swift
import CryptoKit
import Darwin
import Foundation
import KnowledgeCore

struct StagedArtifactPlacement: Sendable {
    let artifact: StagedArtifact
    let relativePath: String
}

final class ManagedArtifacts: @unchecked Sendable {
    private let root: URL
    private let stagingRoot: URL
    private let artifactsRoot: URL
    private let files = FileManager.default

    init(root: URL) throws {
        self.root = root
        stagingRoot = root.appending(path: "Staging")
        artifactsRoot = root.appending(path: "Artifacts")
        try files.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try files.createDirectory(
            at: artifactsRoot,
            withIntermediateDirectories: true
        )
    }

    func stage(
        _ input: SourceArtifactInput,
        taskID: ImportTaskID
    ) throws -> StagedArtifactPlacement {
        let artifactID = UUID()
        let relativePath = "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        let container = root.appending(path: relativePath)
        let payload = container.appending(path: "payload")
        try files.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )

        let expectedKind: SourceArtifactKind
        switch input {
        case .file(let source, let descriptor):
            expectedKind = .pdf
            guard descriptor.kind == expectedKind else {
                throw LocalLibraryError.artifactMissing
            }
            try files.copyItem(at: source, to: payload)

        case .package(let source, let descriptor):
            expectedKind = .webPackage
            guard descriptor.kind == expectedKind else {
                throw LocalLibraryError.artifactMissing
            }
            try files.copyItem(at: source, to: payload)
        }

        let verified = try descriptor(for: payload, kind: expectedKind)
        try synchronizePayload(payload)
        try synchronizeDirectory(container)

        return StagedArtifactPlacement(
            artifact: StagedArtifact(
                rawValue: artifactID,
                descriptor: verified
            ),
            relativePath: relativePath
        )
    }

    func finalRelativePath(documentID: SourceDocumentID) -> String {
        "Artifacts/\(documentID.rawValue.uuidString)"
    }

    func moveToFinal(
        stagedRelativePath: String,
        finalRelativePath: String
    ) throws {
        let staged = root.appending(path: stagedRelativePath)
        let final = root.appending(path: finalRelativePath)
        if files.fileExists(atPath: final.path) {
            return
        }
        try files.moveItem(at: staged, to: final)
        try synchronizeDirectory(artifactsRoot)
    }

    func exists(relativePath: String) -> Bool {
        files.fileExists(atPath: root.appending(path: relativePath).path)
    }

    func remove(relativePath: String) throws {
        let url = root.appending(path: relativePath)
        if files.fileExists(atPath: url.path) {
            try files.removeItem(at: url)
        }
    }

    private func descriptor(
        for payload: URL,
        kind: SourceArtifactKind
    ) throws -> SourceArtifactDescriptor {
        var isDirectory: ObjCBool = false
        files.fileExists(atPath: payload.path, isDirectory: &isDirectory)

        var hasher = SHA256()
        var byteCount: UInt64 = 0

        if isDirectory.boolValue {
            let keys: Set<URLResourceKey> = [
                .isRegularFileKey,
                .isDirectoryKey,
            ]
            let entries = try files.contentsOfDirectory(
                at: payload,
                includingPropertiesForKeys: Array(keys)
            )
            let regularFiles = try entries.flatMap { entry -> [URL] in
                let values = try entry.resourceValues(forKeys: keys)
                if values.isRegularFile == true { return [entry] }
                if values.isDirectory == true {
                    return try recursiveFiles(at: entry)
                }
                return []
            }.sorted { $0.path < $1.path }

            for file in regularFiles {
                let relative = file.path.replacingOccurrences(
                    of: payload.path + "/",
                    with: ""
                )
                let data = try Data(contentsOf: file)
                hasher.update(data: Data(relative.utf8))
                hasher.update(data: data)
                byteCount += UInt64(data.count)
            }
        } else {
            let data = try Data(contentsOf: payload)
            hasher.update(data: data)
            byteCount = UInt64(data.count)
        }

        return SourceArtifactDescriptor(
            kind: kind,
            byteCount: byteCount,
            contentHash: hasher.finalize().map {
                String(format: "%02x", $0)
            }.joined()
        )
    }

    private func recursiveFiles(at directory: URL) throws -> [URL] {
        let enumerator = files.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey]
        )
        return (enumerator?.allObjects as? [URL] ?? []).filter {
            (try? $0.resourceValues(forKeys: [.isRegularFileKey]))
                ?.isRegularFile == true
        }
    }

    private func synchronizePayload(_ payload: URL) throws {
        var isDirectory: ObjCBool = false
        files.fileExists(atPath: payload.path, isDirectory: &isDirectory)
        if isDirectory.boolValue {
            for file in try recursiveFiles(at: payload) {
                try FileHandle(forUpdating: file).synchronize()
            }
        } else {
            try FileHandle(forUpdating: payload).synchronize()
        }
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY)
        guard descriptor >= 0 else { throw LocalLibraryError.unavailable }
        defer { Darwin.close(descriptor) }
        guard Darwin.fsync(descriptor) == 0 else {
            throw LocalLibraryError.unavailable
        }
    }
}
~~~

- [ ] **Step 4: Persist staged-artifact ownership atomically**

Add LibraryDatabase.attachStagedArtifact:

~~~swift
func attachStagedArtifact(
    taskID: ImportTaskID,
    expectedRevision: UInt64,
    placement: StagedArtifactPlacement
) throws {
    try queue.write { db in
        guard var task = try ImportTaskRecord.fetchOne(
            db,
            key: taskID.rawValue.uuidString
        ) else {
            throw LocalLibraryError.unavailable
        }
        guard task.revision == Int64(expectedRevision) else {
            throw LocalLibraryError.staleRevision(
                current: UInt64(task.revision)
            )
        }
        guard task.state != ImportTaskState.completed.rawValue,
              task.state != ImportTaskState.abandoned.rawValue
        else {
            throw LocalLibraryError.invalidTaskState
        }

        try StagedArtifactRecord(
            artifactID: placement.artifact.rawValue.uuidString,
            taskID: task.taskID,
            descriptorJSON: try JSONEncoder().encode(
                placement.artifact.descriptor
            ),
            relativePath: placement.relativePath
        ).insert(db)

        task.stagedArtifactID = placement.artifact.rawValue.uuidString
        task.state = ImportTaskState.working.rawValue
        task.revision += 1
        try task.update(db)
    }
}
~~~

If the transaction fails, LocalLibrary removes the copied staging directory.

- [ ] **Step 5: Add ImportWorkspace.stageArtifact and automatic PDF capture**

Add:

~~~swift
public func stageArtifact(
    _ input: SourceArtifactInput,
    expectedRevision: UInt64
) async throws -> StagedArtifact {
    try await library.stageArtifact(
        input,
        taskID: taskID,
        expectedRevision: expectedRevision
    )
}
~~~

For LocalLibrary.accept(.pdfFile), copy and verify the PDF first, then insert the task and staged-artifact record in one SQLite transaction. If database acceptance fails, delete the staging directory. Do not retain the external path as managed storage.

- [ ] **Step 6: Run staging and full tests**

Run:

~~~bash
swift test --filter ArtifactStagingTests
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit staging**

~~~bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/ArtifactStagingTests.swift
git commit -m "feat: add task-owned artifact staging"
~~~

### Task 4: Persist checkpoints, revisions, and abandonment

**Files:**
- Modify: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Modify: Sources/LocalLibrary/LocalLibrary.swift
- Modify: Sources/LocalLibrary/ImportWorkspace.swift
- Create: Tests/LocalLibraryTests/CheckpointTests.swift

- [ ] **Step 1: Write failing checkpoint tests**

Create Tests/LocalLibraryTests/CheckpointTests.swift:

~~~swift
@Test
func checkpointSurvivesReopenAndAdvancesRevision() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com")))
    )
    let initial = try await workspace.snapshot()
    let envelope = CheckpointEnvelope(
        codecVersion: 1,
        payload: Data("artifact-ready".utf8)
    )

    let updated = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 1,
            envelope: envelope
        )
    )

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: workspace.taskID)
    )
    let snapshot = try await recovered.snapshot()

    #expect(updated.revision == initial.revision + 1)
    #expect(snapshot.checkpoint == envelope)
}

@Test
func staleRevisionAndCheckpointRegressionAreRejected() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com")))
    )
    let initial = try await workspace.snapshot()
    let first = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 2,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("second".utf8)
            )
        )
    )

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: first.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(
                    codecVersion: 1,
                    payload: Data("first".utf8)
                )
            )
        )
        Issue.record("Expected checkpointRegression")
    } catch {
        #expect(error as? LocalLibraryError == .checkpointRegression)
    }

    do {
        _ = try await workspace.checkpoint(
            CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 3,
                envelope: CheckpointEnvelope(
                    codecVersion: 1,
                    payload: Data("stale".utf8)
                )
            )
        )
        Issue.record("Expected staleRevision")
    } catch {
        #expect(
            error as? LocalLibraryError ==
                .staleRevision(current: first.revision)
        )
    }
}

@Test
func abandonIsDurableAndIdempotent() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com")))
    )
    let initial = try await workspace.snapshot()
    try await workspace.abandon(expectedRevision: initial.revision)

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: workspace.taskID)
    )
    let abandoned = try await recovered.snapshot()
    #expect(abandoned.state == .abandoned)

    try await recovered.abandon(expectedRevision: initial.revision)
    #expect((try await recovered.snapshot()).state == .abandoned)
}
~~~

- [ ] **Step 2: Run tests and verify checkpoint/abandon methods are missing**

Run:

~~~bash
swift test --filter CheckpointTests
~~~

Expected: FAIL during compilation.

- [ ] **Step 3: Implement LibraryDatabase checkpoint transaction**

Add this LibraryDatabase transaction:

~~~swift
func checkpoint(
    taskID: ImportTaskID,
    update: CheckpointUpdate
) throws -> DurableImportSnapshot {
    try queue.write { db in
        guard var task = try ImportTaskRecord.fetchOne(
            db,
            key: taskID.rawValue.uuidString
        ) else {
            throw LocalLibraryError.unavailable
        }
        guard task.revision == Int64(update.expectedRevision) else {
            throw LocalLibraryError.staleRevision(
                current: UInt64(task.revision)
            )
        }
        guard task.state != ImportTaskState.completed.rawValue,
              task.state != ImportTaskState.abandoned.rawValue
        else {
            throw LocalLibraryError.invalidTaskState
        }
        guard update.envelope.payload.count <= 1_048_576 else {
            throw LocalLibraryError.invalidTaskState
        }
        if let currentOrdinal = task.checkpointOrdinal,
           Int64(update.ordinal) <= currentOrdinal
        {
            throw LocalLibraryError.checkpointRegression
        }

        task.checkpointOrdinal = Int64(update.ordinal)
        task.checkpointCodecVersion = Int(update.envelope.codecVersion)
        task.checkpointPayload = update.envelope.payload
        task.state = ImportTaskState.working.rawValue
        task.revision += 1
        try task.update(db)

        let staged = try task.stagedArtifactID.flatMap {
            try StagedArtifactRecord.fetchOne(db, key: $0)
        }
        return try task.snapshot(stagedArtifact: staged)
    }
}
~~~

- [ ] **Step 4: Implement durable idempotent abandon**

Add LibraryDatabase.abandon. It returns the staged relative path for post-commit cleanup:

~~~swift
func abandon(
    taskID: ImportTaskID,
    expectedRevision: UInt64
) throws -> String? {
    try queue.write { db in
        guard var task = try ImportTaskRecord.fetchOne(
            db,
            key: taskID.rawValue.uuidString
        ) else {
            throw LocalLibraryError.unavailable
        }
        if task.state == ImportTaskState.abandoned.rawValue {
            return try task.stagedArtifactID.flatMap {
                try StagedArtifactRecord.fetchOne(db, key: $0)?.relativePath
            }
        }
        guard task.revision == Int64(expectedRevision) else {
            throw LocalLibraryError.staleRevision(
                current: UInt64(task.revision)
            )
        }
        guard task.state != ImportTaskState.completed.rawValue else {
            throw LocalLibraryError.invalidTaskState
        }

        let relativePath = try task.stagedArtifactID.flatMap {
            try StagedArtifactRecord.fetchOne(db, key: $0)?.relativePath
        }
        task.state = ImportTaskState.abandoned.rawValue
        task.revision += 1
        try task.update(db)
        return relativePath
    }
}
~~~

LocalLibrary.abandon calls this transaction, then removes the returned staged directory. Leftover staging after a file-removal failure is safe for startup cleanup.

- [ ] **Step 5: Wire ImportWorkspace methods**

~~~swift
public func checkpoint(
    _ update: CheckpointUpdate
) async throws -> DurableImportSnapshot {
    try await library.checkpoint(update, taskID: taskID)
}

public func abandon(expectedRevision: UInt64) async throws {
    try await library.abandon(
        taskID: taskID,
        expectedRevision: expectedRevision
    )
}
~~~

- [ ] **Step 6: Run checkpoint and full tests**

Run:

~~~bash
swift test --filter CheckpointTests
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit task state handling**

~~~bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/CheckpointTests.swift
git commit -m "feat: persist import checkpoints"
~~~

### Task 5: Publish one complete Source Document atomically

**Files:**
- Create: Sources/LocalLibrary/Internal/PublicationCoordinator.swift
- Modify: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Modify: Sources/LocalLibrary/Internal/ManagedArtifacts.swift
- Modify: Sources/LocalLibrary/LocalLibrary.swift
- Modify: Sources/LocalLibrary/ImportWorkspace.swift
- Create: Tests/LocalLibraryTests/ImportPublicationTests.swift

- [ ] **Step 1: Write the failing publication test**

Create Tests/LocalLibraryTests/ImportPublicationTests.swift:

~~~swift
import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func publishesArtifactAndDocumentAsOneVisibleResult() async throws {
    let root = try makeTemporaryLibraryRoot()
    let package = root.appending(path: "Article")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    let bytes = Data("<article>Fixture</article>".utf8)
    try bytes.write(to: package.appending(path: "index.html"))

    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/article"))
    )
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let workspace = try await library.accept(source)
    let accepted = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: UInt64(bytes.count),
                contentHash: "verified-by-library"
            )
        ),
        expectedRevision: accepted.revision
    )
    let current = try await workspace.snapshot()
    let content = makeFixtureContent()

    let outcome = try await workspace.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("fixture-fingerprint"),
            artifact: artifact,
            document: content,
            originalSource: source
        ),
        expectedRevision: current.revision
    )

    #expect(outcome == .published(documentID: content.documentID))

    let loaded = try #require(
        try await library.sourceDocument(id: content.documentID)
    )
    #expect(loaded.document.content == content)
    #expect(loaded.location == .library)
}
~~~

- [ ] **Step 2: Run the test and verify finish/sourceDocument are missing**

Run:

~~~bash
swift test --filter publishesArtifactAndDocumentAsOneVisibleResult
~~~

Expected: FAIL during compilation.

- [ ] **Step 3: Add database prepare/finalize operations**

Implement LibraryDatabase.preparePublication in one write transaction:

- validate task, revision, source equality, artifact ownership, and candidate document ID;
- query source_documents by fingerprint;
- when duplicate exists, return duplicate metadata without changing files;
- otherwise insert source_documents with visibility hidden;
- insert publication_intents;
- set task state publicationPending and increment revision.

Implement finalizePublication in one write transaction:

- verify hidden document and matching intent;
- set visibility visible;
- insert provenance;
- encode/store PublicationOutcome.published in import_tasks.outcome_json;
- set task completed and increment revision;
- delete publication_intents;
- delete staged_artifacts row.

Implement sourceDocument(id:) to query only visibility visible, verify the managed artifact through ManagedArtifacts, decode content/descriptor, and return LocatedSourceDocument. Missing/mismatched final bytes throw corruptLibrary with a fresh diagnostic ID.

- [ ] **Step 4: Implement PublicationCoordinator new-document path**

Create PublicationCoordinator with this exact order:

~~~swift
func finish(
    taskID: ImportTaskID,
    candidate: PublicationCandidate,
    expectedRevision: UInt64
) throws -> PublicationOutcome {
    if let stored = try database.storedOutcome(taskID: taskID) {
        return stored
    }

    let prepared = try database.preparePublication(
        taskID: taskID,
        candidate: candidate,
        expectedRevision: expectedRevision,
        finalRelativePath: artifacts.finalRelativePath(
            documentID: candidate.document.documentID
        )
    )

    switch prepared {
    case .duplicate(let duplicate):
        return try database.completeDuplicate(
            taskID: taskID,
            candidate: candidate,
            duplicate: duplicate
        )

    case .newDocument(let intent):
        try artifacts.moveToFinal(intent)
        return try database.finalizePublication(
            taskID: taskID,
            candidate: candidate,
            intent: intent
        )
    }
}
~~~

The actual implementation is actor-isolated through LocalLibrary. Do not expose PublicationCoordinator.

- [ ] **Step 5: Wire finish and visible document loading**

Add ImportWorkspace.finish and LocalLibrary.sourceDocument according to the approved design.

- [ ] **Step 6: Run publication and full tests**

Run:

~~~bash
swift test --filter ImportPublicationTests
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit publication**

~~~bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/ImportPublicationTests.swift
git commit -m "feat: publish source documents atomically"
~~~

### Task 6: Resolve duplicates, trash location, and provenance atomically

**Files:**
- Modify: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Modify: Sources/LocalLibrary/Internal/PublicationCoordinator.swift
- Create: Sources/LocalLibrary/Internal/PublicationFaultInjector.swift
- Create: Tests/LocalLibraryTests/DuplicateResolutionTests.swift

- [ ] **Step 1: Write duplicate and provenance tests**

Create Tests/LocalLibraryTests/DuplicateResolutionTests.swift:

~~~swift
import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

private enum SimulatedCrash: Error {
    case injected
}

private struct PreparedImport {
    let workspace: ImportWorkspace
    let candidate: PublicationCandidate
}

private func prepareImport(
    library: LocalLibrary,
    root: URL,
    source: OriginalSource,
    fingerprint: ContentFingerprint
) async throws -> PreparedImport {
    let package = root.appending(path: UUID().uuidString)
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    let bytes = Data("<article>Fixture</article>".utf8)
    try bytes.write(to: package.appending(path: "index.html"))

    let workspace = try await library.accept(source)
    let accepted = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: UInt64(bytes.count),
                contentHash: "verified-by-library"
            )
        ),
        expectedRevision: accepted.revision
    )
    return PreparedImport(
        workspace: workspace,
        candidate: PublicationCandidate(
            fingerprint: fingerprint,
            artifact: artifact,
            document: makeFixtureContent(),
            originalSource: source
        )
    )
}

private func finish(
    _ prepared: PreparedImport
) async throws -> PublicationOutcome {
    let snapshot = try await prepared.workspace.snapshot()
    return try await prepared.workspace.finish(
        prepared.candidate,
        expectedRevision: snapshot.revision
    )
}

@Test
func duplicateReturnsExistingDocumentAndAddsNewProvenance() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let fingerprint = ContentFingerprint("same-content")
    let first = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://a.example"))),
        fingerprint: fingerprint
    )
    let firstOutcome = try await finish(first)
    guard case .published(let existingID) = firstOutcome else {
        Issue.record("Expected first publication")
        return
    }

    let second = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://b.example"))),
        fingerprint: fingerprint
    )
    let outcome = try await finish(second)

    #expect(
        outcome == .alreadyImported(
            documentID: existingID,
            location: .library,
            provenanceAdded: true
        )
    )
    let duplicateDocument = try await library.sourceDocument(
        id: second.candidate.document.documentID
    )
    #expect(duplicateDocument?.document.content.documentID == nil)
}

@Test
func repeatedSameProvenanceReportsNotAdded() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://same.example"))
    )
    let fingerprint = ContentFingerprint("same-provenance")
    let first = try await prepareImport(
        library: library,
        root: root,
        source: source,
        fingerprint: fingerprint
    )
    guard case .published(let existingID) = try await finish(first) else {
        Issue.record("Expected first publication")
        return
    }

    let second = try await prepareImport(
        library: library,
        root: root,
        source: source,
        fingerprint: fingerprint
    )
    #expect(
        try await finish(second) == .alreadyImported(
            documentID: existingID,
            location: .library,
            provenanceAdded: false
        )
    )
}

@Test
func duplicateInTrashReportsTrashLocation() async throws {
    let root = try makeTemporaryLibraryRoot()
    let library = try await LocalLibrary.open(at: root)
    let fingerprint = ContentFingerprint("trash-content")
    let first = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://a.example"))),
        fingerprint: fingerprint
    )
    guard case .published(let existingID) = try await finish(first) else {
        Issue.record("Expected first publication")
        return
    }
    try await LocalLibraryTestDriver.setLocation(
        .trash,
        documentID: existingID,
        library: library
    )

    let second = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://b.example"))),
        fingerprint: fingerprint
    )
    #expect(
        try await finish(second) == .alreadyImported(
            documentID: existingID,
            location: .trash,
            provenanceAdded: true
        )
    )
}

@Test
func provenanceFailureRollsBackDuplicateCompletion() async throws {
    let root = try makeTemporaryLibraryRoot()
    let injector = PublicationFaultInjector { point in
        if point == .beforeDuplicateProvenanceInsert {
            throw SimulatedCrash.injected
        }
    }
    let library = try await LocalLibrary.openForTesting(
        at: root,
        faultInjector: injector
    )
    let fingerprint = ContentFingerprint("rollback-provenance")
    let first = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://a.example"))),
        fingerprint: fingerprint
    )
    _ = try await finish(first)

    let second = try await prepareImport(
        library: library,
        root: root,
        source: .webpage(try #require(URL(string: "https://b.example"))),
        fingerprint: fingerprint
    )
    do {
        _ = try await finish(second)
        Issue.record("Expected injected provenance failure")
    } catch {
        #expect(error is SimulatedCrash)
    }

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: second.workspace.taskID)
    )
    let snapshot = try await recovered.snapshot()
    let outcome = try await recovered.finish(
        second.candidate,
        expectedRevision: snapshot.revision
    )

    guard case .alreadyImported(_, _, let provenanceAdded) = outcome else {
        Issue.record("Expected duplicate outcome")
        return
    }
    #expect(provenanceAdded)
}
~~~

- [ ] **Step 2: Run tests and verify duplicate path/test hooks are missing**

Run:

~~~bash
swift test --filter DuplicateResolutionTests
~~~

Expected: FAIL.

- [ ] **Step 3: Implement duplicate completion transaction**

LibraryDatabase.completeDuplicate must perform in one write transaction:

- re-fetch the matching fingerprint and location;
- insert provenance with insert-on-conflict-do-nothing;
- calculate provenanceAdded from the inserted row count;
- store PublicationOutcome.alreadyImported;
- complete the Import Task;
- remove staged-artifact ownership record;
- commit all changes together.

The actual staged directory is removed after transaction commit.

- [ ] **Step 4: Add package-only fault injection and trash setup**

Create:

~~~swift
package enum PublicationFaultPoint: Equatable, Sendable {
    case beforeDuplicateProvenanceInsert
    case afterIntentCommit
    case afterArtifactMove
    case beforeVisibilityCommit
    case afterVisibilityCommit
}

package struct PublicationFaultInjector: Sendable {
    package var hit: @Sendable (PublicationFaultPoint) throws -> Void

    package static let none = PublicationFaultInjector { _ in }
}
~~~

Add package-only LocalLibrary.openForTesting(at:faultInjector:) and LocalLibraryTestDriver.setLocation. Neither appears in the public interface.

- [ ] **Step 5: Run duplicate and full tests**

Run:

~~~bash
swift test --filter DuplicateResolutionTests
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 6: Commit duplicate handling**

~~~bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/DuplicateResolutionTests.swift
git commit -m "feat: resolve duplicate publications atomically"
~~~

### Task 7: Recover every publication crash point

**Files:**
- Create: Sources/LocalLibrary/Internal/PublicationRecovery.swift
- Modify: Sources/LocalLibrary/Internal/PublicationCoordinator.swift
- Modify: Sources/LocalLibrary/Internal/LibraryDatabase.swift
- Modify: Sources/LocalLibrary/LocalLibrary.swift
- Create: Tests/LocalLibraryTests/PublicationRecoveryTests.swift

- [ ] **Step 1: Write the failing crash matrix**

Create PublicationRecoveryTests with one parameterized loop over:

~~~swift
let points: [PublicationFaultPoint] = [
    .afterIntentCommit,
    .afterArtifactMove,
    .beforeVisibilityCommit,
    .afterVisibilityCommit,
]
~~~

For each point:

1. create a fresh temporary root;
2. accept/stage a Web package;
3. open LocalLibrary with an injector that throws SimulatedCrash at that point;
4. call finish and assert SimulatedCrash;
5. reopen normally;
6. call sourceDocument(documentID);
7. recreate the workspace with importWorkspace(id:);
8. retry finish.

Expected outcomes:

- afterIntentCommit: no visible document immediately after reopen; recovery rolls back the hidden intent to a retryable task, and retry finish publishes once.
- afterArtifactMove: recovery finishes publication; sourceDocument returns one complete document; retry finish returns the stored published outcome.
- beforeVisibilityCommit: same as afterArtifactMove.
- afterVisibilityCommit: document is already complete and retry returns the stored outcome.

In every case the first candidate document ID is the only visible document.

- [ ] **Step 2: Run recovery tests and verify reopen does not reconcile intents**

Run:

~~~bash
swift test --filter PublicationRecoveryTests
~~~

Expected: FAIL.

- [ ] **Step 3: Implement database recovery queries**

Add:

- publicationIntents()
- rollbackIntent(taskID:)
- finalizeRecoveredIntent(intent:)
- storedOutcome(taskID:)
- visibleDocument(id:)

rollbackIntent deletes hidden Source Document rows and the intent/fingerprint reservation, sets task state working, and leaves the staged artifact owned by the task.

finalizeRecoveredIntent verifies the final artifact before using the same visibility transaction as normal finish.

- [ ] **Step 4: Implement PublicationRecovery**

Create PublicationRecovery.run before LocalLibrary.open returns:

~~~swift
for intent in try database.publicationIntents() {
    if try artifacts.finalArtifactIsValid(intent) {
        try database.finalizeRecoveredIntent(intent)
    } else if try artifacts.stagedArtifactExists(intent) {
        try database.rollbackIntent(taskID: intent.taskID)
    } else {
        try artifacts.quarantineInvalidFinalArtifact(intent)
        try database.rollbackIntent(taskID: intent.taskID)
    }
}

try artifacts.removeUnownedStaging(
    ownedRelativePaths: database.ownedStagingPaths()
)
~~~

Recovery must be idempotent and may be interrupted. Database transactions remain the only visibility decisions.

- [ ] **Step 5: Hit every fault point in PublicationCoordinator**

Call the injector exactly:

- after preparePublication commits;
- after atomic artifact move and parent sync;
- immediately before visibility transaction;
- immediately after visibility transaction;
- before duplicate provenance insertion inside its transaction.

Do not catch SimulatedCrash in production code; the test deliberately leaves durable intermediate state.

- [ ] **Step 6: Run recovery and full tests**

Run:

~~~bash
swift test --filter PublicationRecoveryTests
swift test
~~~

Expected: PASS with 0 failures.

- [ ] **Step 7: Commit recovery**

~~~bash
git add Sources/LocalLibrary Tests/LocalLibraryTests/PublicationRecoveryTests.swift
git commit -m "feat: recover interrupted publications"
~~~

### Task 8: Verify encapsulation, document the seam, and complete T02

**Files:**
- Modify: README.md
- Modify: docs/superpowers/specs/2026-08-05-t02-local-library-publication-seam-design.md

- [ ] **Step 1: Document GRDB and Local Library verification**

Add README sections describing:

- LocalLibrary -> KnowledgeCore dependency;
- GRDB 7.11.1 as LocalLibrary-only implementation dependency;
- public capability types and hidden schema/layout;
- swift test and xcodebuild commands;
- first clean dependency resolution requires network, while the running empty Import Center does not.

Use concrete commands already used by T01.

- [ ] **Step 2: Mark the design implementation-tracked**

Change the design header to:

~~~markdown
> Status: approved; implementation tracked by the T02 Local Library publication seam plan
~~~

- [ ] **Step 3: Verify forbidden leakage**

Run:

~~~bash
if rg -n '^import (GRDB|SQLite3)$' Sources/KnowledgeCore Sources/AppSupport; then
  exit 1
fi

if rg -n 'import (SwiftUI|Observation)' Sources/KnowledgeCore Sources/LocalLibrary; then
  exit 1
fi

rg -n 'public .*relativePath|public .*managed.*URL|public .*Database' Sources/LocalLibrary
~~~

Expected: the first two commands exit 0 with no matches. The final search returns no public schema/path/database surface.

- [ ] **Step 4: Run complete package and app verification**

Run:

~~~bash
swift test
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t02 \
  build
~~~

Expected: all tests pass and BUILD SUCCEEDED.

- [ ] **Step 5: Verify a clean exported checkout**

Run:

~~~bash
clean_checkout="$(mktemp -d)"
git archive HEAD | tar -x -C "$clean_checkout"
swift test --package-path "$clean_checkout"
xcodebuild \
  -project "$clean_checkout/PersonalKnowledgeNote.xcodeproj" \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath "$clean_checkout/.build/xcode" \
  build
~~~

Expected: the archived checkout resolves the pinned dependency, passes all tests, and builds the app.

- [ ] **Step 6: Review against GitHub issue #3**

Confirm with command evidence:

- focused Local Library interface is documented and approved;
- accepted task survives reopen;
- staged artifact and records publish all-or-nothing;
- every injected publication point exposes zero or one complete Source Document;
- duplicate outcome distinguishes library/trash;
- provenance is atomic and truthful;
- tests use real temporary SQLite and directories;
- schema and file layout do not cross the public interface.

- [ ] **Step 7: Run the project code-review workflow**

Invoke .agents/skills/code-review/SKILL.md against main...HEAD, address blocking findings, rerun affected verification, and only then declare T02 complete.
