import Foundation
import GRDB
import KnowledgeCore

enum PublicationPreparation: Sendable {
    case new(PublicationIntent)
    case duplicate(DuplicatePublication)
}

struct DuplicatePublication: Sendable {
    let existingDocument: StoredSourceDocument
    let candidateIntent: PublicationIntent
}

struct DuplicateCompletion: Sendable {
    let outcome: PublicationOutcome
    let stagedPlacement: StagedArtifactPlacement
    let checkpointCleanup: CheckpointArtifactCleanup?
}

struct PublicationCompletion: Sendable {
    let outcome: PublicationOutcome
    let checkpointCleanup: CheckpointArtifactCleanup?
}

struct FailedTaskTransition: Sendable {
    let mutation: DurableQueueMutation
    let checkpointCleanup: CheckpointArtifactCleanup?
}

struct CancellationCompletion: Sendable {
    let snapshot: DurableImportSnapshot
    let stagedCleanup: AbandonedStagedArtifactCleanup?
    let checkpointCleanup: CheckpointArtifactCleanup?
}

struct RetryTransition: Sendable {
    let snapshot: DurableImportSnapshot
    let checkpointCleanup: CheckpointArtifactCleanup?
}

struct RecoveredPublicationIntent: Sendable {
    let intent: PublicationIntent
    let candidate: PublicationCandidate
}

struct CheckpointArtifactMutation: Sendable {
    let replacement: CheckpointArtifactReplacement
    let oldCleanup: CheckpointArtifactCleanup?
}

struct CheckpointArtifactRemoval: Sendable {
    let snapshot: DurableImportSnapshot
    let cleanup: CheckpointArtifactCleanup
}

private struct PublicationStateBundle {
    let task: ImportTaskRecord
    let stagedArtifact: StagedArtifactRecord?
    let checkpointArtifact: CheckpointArtifactRecord?
    let snapshot: DurableImportSnapshot
    let outcome: PublicationOutcome?
}

private struct PreparedPublicationTask {
    let task: ImportTaskRecord
    let stagedArtifact: StagedArtifactRecord?
    let checkpointArtifact: CheckpointArtifactRecord?
    let intent: PublicationIntentRecord?
    let snapshot: DurableImportSnapshot
    let outcome: PublicationOutcome?
    let state: ImportTaskState
    let associatedDocumentID: String?
}

private struct DecodedPublicationDocument {
    let record: SourceDocumentRecord
    let stored: StoredSourceDocument
}

private struct PublicationSourceKey: Hashable {
    let kind: String
    let value: String
}

private struct DecodedPublicationProvenance {
    let record: SourceProvenanceRecord
    let stored: StoredSourceProvenance
}

private struct DecodedPublicationProvenanceCollection {
    let bySource: [PublicationSourceKey: DecodedPublicationProvenance]

    var isEmpty: Bool { bySource.isEmpty }
}

private struct PublicationAssociationBatch {
    let stagedArtifactsByTaskID: [String: StagedArtifactRecord]
    let checkpointArtifactsByTaskID: [String: CheckpointArtifactRecord]
    let intentsByTaskID: [String: PublicationIntentRecord]
    var documentsByID: [String: SourceDocumentRecord] = [:]
    var provenanceByDocumentID: [String: [SourceProvenanceRecord]] = [:]
    var loadedDocumentIDs: Set<String> = []
    var decodedDocumentsByID: [String: DecodedPublicationDocument] = [:]
    var decodedProvenanceByDocumentID:
        [String: DecodedPublicationProvenanceCollection] = [:]

    init(taskIDs: [String], in db: Database) throws {
        stagedArtifactsByTaskID = try uniqueRecords(
            try StagedArtifactRecord
                .filter(taskIDs.contains(Column("task_id")))
                .fetchAll(db),
            keyedBy: \.taskID
        )
        checkpointArtifactsByTaskID = try uniqueRecords(
            try CheckpointArtifactRecord
                .filter(taskIDs.contains(Column("task_id")))
                .fetchAll(db),
            keyedBy: \.taskID
        )
        intentsByTaskID = try uniqueRecords(
            try PublicationIntentRecord
                .filter(taskIDs.contains(Column("task_id")))
                .fetchAll(db),
            keyedBy: \.taskID
        )
    }

    mutating func loadDocuments(
        ids: Set<String>,
        in db: Database
    ) throws {
        let missingIDs = Array(ids.subtracting(loadedDocumentIDs))
        guard !missingIDs.isEmpty else {
            return
        }
        let documents = try SourceDocumentRecord
            .filter(missingIDs.contains(Column("document_id")))
            .fetchAll(db)
        for (id, record) in try uniqueRecords(
            documents,
            keyedBy: \.documentID
        ) {
            documentsByID[id] = record
        }
        let provenance = try SourceProvenanceRecord
            .filter(missingIDs.contains(Column("document_id")))
            .fetchAll(db)
        for (documentID, records) in Dictionary(
            grouping: provenance,
            by: \.documentID
        ) {
            provenanceByDocumentID[documentID] = records
        }
        loadedDocumentIDs.formUnion(missingIDs)
    }

    mutating func document(
        id: String
    ) throws -> DecodedPublicationDocument? {
        if let decoded = decodedDocumentsByID[id] {
            return decoded
        }
        guard let record = documentsByID[id] else {
            return nil
        }
        let decoded = DecodedPublicationDocument(
            record: record,
            stored: try record.decoded()
        )
        decodedDocumentsByID[id] = decoded
        return decoded
    }

    mutating func provenance(
        documentID: String
    ) throws -> DecodedPublicationProvenanceCollection {
        if let decoded = decodedProvenanceByDocumentID[documentID] {
            return decoded
        }
        var bySource: [
            PublicationSourceKey: DecodedPublicationProvenance
        ] = [:]
        for record in provenanceByDocumentID[documentID] ?? [] {
            let key = PublicationSourceKey(
                kind: record.sourceKind,
                value: record.sourceValue
            )
            guard bySource.updateValue(
                DecodedPublicationProvenance(
                    record: record,
                    stored: try record.decoded()
                ),
                forKey: key
            ) == nil else {
                throw corruptLibraryError()
            }
        }
        let decoded = DecodedPublicationProvenanceCollection(
            bySource: bySource
        )
        decodedProvenanceByDocumentID[documentID] = decoded
        return decoded
    }
}

final class LibraryDatabase: Sendable {
    private let queue: DatabaseQueue

    init(url: URL) throws {
        var configuration = Configuration()
        configuration.journalMode = .wal
        queue = try DatabaseQueue(
            path: url.path,
            configuration: configuration
        )
        try SchemaMigrations.migrate(queue)
    }

    func insertAcceptedTask(
        id: ImportTaskID,
        source: OriginalSource,
        placement: StagedArtifactPlacement? = nil
    ) throws {
        _ = try insertAcceptedTaskReturningRetained(
            id: id,
            source: source,
            placement: placement
        )
    }

    func insertAcceptedTaskReturningRetained(
        id: ImportTaskID,
        source: OriginalSource,
        placement: StagedArtifactPlacement? = nil,
        afterInsert: () throws -> Void = {}
    ) throws -> [DurableImportSnapshot] {
        let sourceColumns = try SourceColumns.encode(source)
        return try queue.write { db in
            let sequence = try allocateQueueSequence(in: db)
            try ImportTaskRecord(
                taskID: id.rawValue.uuidString,
                sourceKind: sourceColumns.kind,
                sourceValue: sourceColumns.value,
                attempt: 1,
                revision: 0,
                state: ImportTaskState.queued.rawValue,
                journalSequence: sequence,
                queueSequence: sequence,
                failureCodecVersion: nil,
                failurePayload: nil,
                cancellationRequested: false,
                checkpointOrdinal: nil,
                checkpointCodecVersion: nil,
                checkpointPayload: nil,
                stagedArtifactID: placement?.artifact.rawValue.uuidString,
                outcomeJSON: nil
            ).insert(db)
            if let placement {
                try stagedArtifactRecord(
                    taskID: id,
                    placement: placement
                ).insert(db)
            }
            try afterInsert()
            return try retainedImports(in: db)
        }
    }

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
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            let managedCheckpointArtifact = try checkpointArtifact(
                for: task,
                in: db
            )
            _ = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: managedCheckpointArtifact
            )
            guard let currentRevision = UInt64(exactly: task.revision) else {
                throw corruptLibraryError()
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(current: currentRevision)
            }
            guard let state = ImportTaskState(rawValue: task.state),
                  state.isValidDurableState
            else {
                throw corruptLibraryError()
            }
            guard state == .queued || state == .running else {
                throw LocalLibraryError.invalidTaskState
            }
            guard task.stagedArtifactID == nil else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }

            try stagedArtifactRecord(
                taskID: taskID,
                placement: placement
            ).insert(db)
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.stagedArtifactID = placement.artifact.rawValue.uuidString
            task.state = ImportTaskState.running.rawValue
            task.revision += 1
            try task.update(db)
        }
    }

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
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            let managedCheckpointArtifact = try checkpointArtifact(
                for: task,
                in: db
            )
            _ = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: managedCheckpointArtifact
            )
            guard let currentRevision = UInt64(exactly: task.revision) else {
                throw corruptLibraryError()
            }
            guard currentRevision == update.expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard let state = ImportTaskState(rawValue: task.state),
                  state.isValidDurableState
            else {
                throw corruptLibraryError()
            }
            guard state == .queued || state == .running else {
                throw LocalLibraryError.invalidTaskState
            }
            guard managedCheckpointArtifact == nil else {
                throw LocalLibraryError.invalidTaskState
            }
            guard update.envelope.payload.count <= 1_048_576 else {
                throw LocalLibraryError.invalidTaskState
            }
            if let storedOrdinal = task.checkpointOrdinal {
                guard let currentOrdinal = UInt64(exactly: storedOrdinal)
                else {
                    throw corruptLibraryError()
                }
                guard update.ordinal > currentOrdinal else {
                    throw LocalLibraryError.checkpointRegression
                }
            }
            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }
            guard let checkpointOrdinal = Int64(exactly: update.ordinal)
            else {
                throw LocalLibraryError.invalidTaskState
            }

            task.checkpointOrdinal = checkpointOrdinal
            task.checkpointCodecVersion = Int64(
                update.envelope.codecVersion
            )
            task.checkpointPayload = update.envelope.payload
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.state = ImportTaskState.running.rawValue
            task.revision += 1
            try task.update(db)

            return try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: nil
            )
        }
    }

    func replaceCheckpointArtifact(
        taskID: ImportTaskID,
        placement: CheckpointArtifactPlacement,
        update: CheckpointUpdate,
        faultInjector: CheckpointArtifactFaultInjector
    ) throws -> CheckpointArtifactMutation {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            let existing = try checkpointArtifact(for: task, in: db)
            _ = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: existing
            )
            guard placement.taskID == taskID,
                  placement.path == .checkpoint(
                    taskID: taskID,
                    artifactID: placement.artifact.rawValue
                  ),
                  task.taskID == taskID.rawValue.uuidString,
                  let currentRevision = UInt64(exactly: task.revision)
            else {
                throw corruptLibraryError()
            }
            guard currentRevision == update.expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard let state = ImportTaskState(rawValue: task.state),
                  state == .queued || state == .running
            else {
                throw LocalLibraryError.invalidTaskState
            }
            guard update.envelope.payload.count <= 1_048_576,
                  let checkpointOrdinal = Int64(exactly: update.ordinal)
            else {
                throw LocalLibraryError.invalidTaskState
            }
            if let storedOrdinal = task.checkpointOrdinal {
                guard let currentOrdinal = UInt64(exactly: storedOrdinal)
                else {
                    throw corruptLibraryError()
                }
                guard update.ordinal > currentOrdinal else {
                    throw LocalLibraryError.checkpointRegression
                }
            }
            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }

            let oldCleanup = try existing.map {
                CheckpointArtifactCleanup(
                    placement: try checkpointPlacement($0)
                )
            }
            if let existing {
                guard try existing.delete(db) else {
                    throw corruptLibraryError()
                }
            }
            let record = try checkpointArtifactRecord(
                taskID: taskID,
                placement: placement
            )
            try record.insert(db)
            try faultInjector.hit(
                .afterCheckpointArtifactRowMutationBeforeTaskUpdate
            )
            task.checkpointOrdinal = checkpointOrdinal
            task.checkpointCodecVersion = Int64(
                update.envelope.codecVersion
            )
            task.checkpointPayload = update.envelope.payload
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.state = ImportTaskState.running.rawValue
            task.revision += 1
            try task.update(db)
            let snapshot = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: record
            )
            guard snapshot.checkpointArtifact == placement.artifact,
                  snapshot.checkpoint == update.envelope
            else {
                throw corruptLibraryError()
            }
            return CheckpointArtifactMutation(
                replacement: CheckpointArtifactReplacement(
                    artifact: placement.artifact,
                    snapshot: snapshot
                ),
                oldCleanup: oldCleanup
            )
        }
    }

    func removeCheckpointArtifact(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> CheckpointArtifactRemoval {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            let existing = try checkpointArtifact(for: task, in: db)
            _ = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: existing
            )
            guard let currentRevision = UInt64(exactly: task.revision) else {
                throw corruptLibraryError()
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard let state = ImportTaskState(rawValue: task.state),
                  state == .queued || state == .running
            else {
                throw LocalLibraryError.invalidTaskState
            }
            guard let existing else {
                throw LocalLibraryError.invalidTaskState
            }
            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }
            let cleanup = CheckpointArtifactCleanup(
                placement: try checkpointPlacement(existing)
            )
            guard try existing.delete(db) else {
                throw corruptLibraryError()
            }
            task.checkpointOrdinal = nil
            task.checkpointCodecVersion = nil
            task.checkpointPayload = nil
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.state = ImportTaskState.running.rawValue
            task.revision += 1
            try task.update(db)
            let snapshot = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: nil
            )
            guard snapshot.checkpoint == nil,
                  snapshot.checkpointArtifact == nil
            else {
                throw corruptLibraryError()
            }
            return CheckpointArtifactRemoval(
                snapshot: snapshot,
                cleanup: cleanup
            )
        }
    }

    func abandon(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> AbandonedStagedArtifactCleanup? {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            _ = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: try checkpointArtifact(
                    for: task,
                    in: db
                )
            )
            guard let state = ImportTaskState(rawValue: task.state),
                  let currentRevision = UInt64(exactly: task.revision)
            else {
                throw corruptLibraryError()
            }

            if state == .abandoned {
                return try abandonedCleanup(
                    task: task,
                    stagedArtifact: stagedArtifact
                )
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard state != .completed, state != .publicationPending else {
                throw LocalLibraryError.invalidTaskState
            }
            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }

            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.state = ImportTaskState.abandoned.rawValue
            task.revision += 1
            try task.update(db)
            return try abandonedCleanup(
                task: task,
                stagedArtifact: stagedArtifact
            )
        }
    }

    func snapshot(
        taskID: ImportTaskID
    ) throws -> DurableImportSnapshot? {
        try queue.read { db in
            let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            )
            let bundles = try publicationStateBundles(
                for: task.map { [$0] } ?? [],
                in: db
            )
            return bundles.first?.snapshot
        }
    }

    func recoverableTasks() throws -> [DurableImportSnapshot] {
        try queue.read { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            return try publicationStateBundles(for: tasks, in: db)
                .map(\.snapshot)
                .filter {
                    $0.state != .completed && $0.state != .abandoned
                }
        }
    }

    func retainedImports() throws -> [DurableImportSnapshot] {
        try queue.read { db in
            try retainedImports(in: db)
        }
    }

    func retainedImportStatementCountForTesting() throws -> Int {
        try queue.read { db in
            var statementCount = 0
            db.trace(options: .statement) { event in
                if case .statement = event {
                    statementCount += 1
                }
            }
            defer { db.trace(options: []) }
            _ = try retainedImports(in: db)
            return statementCount
        }
    }

    func reconcileInterruptedRunners() throws {
        try queue.write { db in
            let interrupted = try ImportTaskRecord
                .filter(
                    Column("state")
                        == ImportTaskState.running.rawValue
                )
                .order(Column("journal_sequence"))
                .fetchAll(db)
            for var task in interrupted {
                guard task.queueSequence == nil,
                      task.revision < Int64.max
                else {
                    throw corruptLibraryError()
                }
                task.queueSequence = try allocateQueueSequence(in: db)
                task.state = ImportTaskState.queued.rawValue
                task.revision += 1
                try task.update(db)
            }
        }
    }

    func recordFailure(
        taskID: ImportTaskID,
        expectedRevision: UInt64,
        failure: ImportTaskFailureEnvelope,
        retainCheckpoint: Bool
    ) throws -> FailedTaskTransition {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard var task = tasks.first(where: {
                $0.taskID == taskID.rawValue.uuidString
            }) else {
                throw LocalLibraryError.unavailable
            }
            guard let currentRevision = UInt64(exactly: task.revision)
            else {
                throw corruptLibraryError()
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard let state = ImportTaskState(rawValue: task.state),
                  state == .queued || state == .running
            else {
                throw LocalLibraryError.invalidTaskState
            }
            guard task.revision < Int64.max,
                  failure.payload.count <= 1_048_576
            else {
                throw LocalLibraryError.invalidTaskState
            }

            var checkpointCleanup: CheckpointArtifactCleanup?
            if !retainCheckpoint {
                if let record = try checkpointArtifact(for: task, in: db) {
                    checkpointCleanup = CheckpointArtifactCleanup(
                        placement: try checkpointPlacement(record)
                    )
                    guard try record.delete(db) else {
                        throw corruptLibraryError()
                    }
                }
                task.checkpointOrdinal = nil
                task.checkpointCodecVersion = nil
                task.checkpointPayload = nil
            }

            var shifted: [ImportTaskRecord] = []
            if let removedSequence = task.queueSequence {
                shifted = tasks
                    .filter {
                        $0.state == ImportTaskState.queued.rawValue
                            && ($0.queueSequence ?? Int64.min)
                                > removedSequence
                    }
                    .sorted(by: queueRecordOrdering)
                for index in shifted.indices {
                    guard shifted[index].revision < Int64.max else {
                        throw corruptLibraryError()
                    }
                    shifted[index].revision += 1
                    try shifted[index].update(db)
                }
            }

            task.queueSequence = nil
            task.state = ImportTaskState.failed.rawValue
            task.failureCodecVersion = Int64(failure.codecVersion)
            task.failurePayload = failure.payload
            task.revision += 1
            try task.update(db)

            let bundles = try publicationStateBundles(
                for: [task] + shifted,
                in: db,
                associations: &associations
            )
            guard let primary = bundles.first?.snapshot else {
                throw corruptLibraryError()
            }
            return FailedTaskTransition(
                mutation: DurableQueueMutation(
                    primary: primary,
                    queueUpdates: bundles.dropFirst().map(\.snapshot)
                ),
                checkpointCleanup: checkpointCleanup
            )
        }
    }

    func claimNextRunnable() throws -> DurableQueueClaim? {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard !tasks.contains(where: {
                $0.state == ImportTaskState.running.rawValue
                    || $0.state == ImportTaskState.cancelling.rawValue
                    || $0.state
                        == ImportTaskState.publicationPending.rawValue
            }) else {
                return nil
            }
            let queued = tasks
                .filter { task in
                    task.state == ImportTaskState.queued.rawValue
                }
                .sorted(by: queueRecordOrdering)
            guard var claimed = queued.first,
                  let claimedSequence = claimed.queueSequence,
                  let previousQueueSequence = UInt64(
                    exactly: claimedSequence
                  )
            else {
                return nil
            }
            guard claimed.revision < Int64.max else {
                throw corruptLibraryError()
            }

            claimed.queueSequence = nil
            claimed.state = ImportTaskState.running.rawValue
            claimed.revision += 1
            try claimed.update(db)

            var shifted = tasks
                .filter {
                    $0.state == ImportTaskState.queued.rawValue
                        && ($0.queueSequence ?? Int64.min) > claimedSequence
                }
                .sorted(by: queueRecordOrdering)
            for index in shifted.indices {
                guard shifted[index].revision < Int64.max else {
                    throw corruptLibraryError()
                }
                shifted[index].revision += 1
                try shifted[index].update(db)
            }

            let bundles = try publicationStateBundles(
                for: [claimed] + shifted,
                in: db,
                associations: &associations
            )
            guard let claimedSnapshot = bundles.first?.snapshot else {
                throw corruptLibraryError()
            }
            return DurableQueueClaim(
                claimed: claimedSnapshot,
                queueUpdates: bundles.dropFirst().map(\.snapshot),
                previousQueueSequence: previousQueueSequence
            )
        }
    }

    func rollbackClaim(
        taskID: ImportTaskID,
        expectedRevision: UInt64,
        previousQueueSequence: UInt64
    ) throws -> DurableQueueMutation {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard var claimed = tasks.first(where: {
                $0.taskID == taskID.rawValue.uuidString
            }), let currentRevision = UInt64(exactly: claimed.revision),
                  let restoredSequence = Int64(
                    exactly: previousQueueSequence
                  ), restoredSequence > 0
            else {
                throw LocalLibraryError.unavailable
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard claimed.state == ImportTaskState.running.rawValue,
                  claimed.queueSequence == nil,
                  !tasks.contains(where: {
                    $0.taskID != claimed.taskID
                        && $0.queueSequence == restoredSequence
                  }),
                  claimed.revision < Int64.max
            else {
                throw LocalLibraryError.invalidTaskState
            }

            var shifted = tasks
                .filter {
                    $0.state == ImportTaskState.queued.rawValue
                        && ($0.queueSequence ?? Int64.min)
                            > restoredSequence
                }
                .sorted(by: queueRecordOrdering)
            for index in shifted.indices {
                guard shifted[index].revision < Int64.max else {
                    throw corruptLibraryError()
                }
                shifted[index].revision += 1
                try shifted[index].update(db)
            }
            claimed.state = ImportTaskState.queued.rawValue
            claimed.queueSequence = restoredSequence
            claimed.revision += 1
            try claimed.update(db)

            let bundles = try publicationStateBundles(
                for: [claimed] + shifted,
                in: db,
                associations: &associations
            )
            guard let primary = bundles.first?.snapshot else {
                throw corruptLibraryError()
            }
            return DurableQueueMutation(
                primary: primary,
                queueUpdates: bundles.dropFirst().map(\.snapshot)
            )
        }
    }

    func requestCancellation(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> DurableQueueMutation {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard var task = tasks.first(where: {
                $0.taskID == taskID.rawValue.uuidString
            }) else {
                throw LocalLibraryError.unavailable
            }
            guard let currentRevision = UInt64(exactly: task.revision),
                  let state = ImportTaskState(rawValue: task.state)
            else {
                throw corruptLibraryError()
            }

            switch state {
            case .cancelling, .cancelled:
                let bundles = try publicationStateBundles(
                    for: [task],
                    in: db,
                    associations: &associations
                )
                guard let primary = bundles.first?.snapshot else {
                    throw corruptLibraryError()
                }
                return DurableQueueMutation(
                    primary: primary,
                    queueUpdates: []
                )
            case .queued, .running:
                guard currentRevision == expectedRevision,
                      task.revision < Int64.max
                else {
                    if currentRevision != expectedRevision {
                        throw LocalLibraryError.staleRevision(
                            current: currentRevision
                        )
                    }
                    throw corruptLibraryError()
                }

                var shifted: [ImportTaskRecord] = []
                if let removedSequence = task.queueSequence {
                    shifted = tasks
                        .filter {
                            $0.state
                                == ImportTaskState.queued.rawValue
                                && ($0.queueSequence ?? Int64.min)
                                    > removedSequence
                        }
                        .sorted(by: queueRecordOrdering)
                    for index in shifted.indices {
                        guard shifted[index].revision < Int64.max else {
                            throw corruptLibraryError()
                        }
                        shifted[index].revision += 1
                        try shifted[index].update(db)
                    }
                }

                task.queueSequence = nil
                task.cancellationRequested = true
                task.state = ImportTaskState.cancelling.rawValue
                task.revision += 1
                try task.update(db)

                let bundles = try publicationStateBundles(
                    for: [task] + shifted,
                    in: db,
                    associations: &associations
                )
                guard let primary = bundles.first?.snapshot else {
                    throw corruptLibraryError()
                }
                return DurableQueueMutation(
                    primary: primary,
                    queueUpdates: bundles.dropFirst().map(\.snapshot)
                )
            case .completed, .publicationPending, .failed,
                 .abandoned, .accepted, .working:
                throw LocalLibraryError.invalidTaskState
            }
        }
    }

    func finishCancellation(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> CancellationCompletion {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard var task = tasks.first(where: {
                $0.taskID == taskID.rawValue.uuidString
            }), let currentRevision = UInt64(exactly: task.revision)
            else {
                throw LocalLibraryError.unavailable
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard task.state == ImportTaskState.cancelling.rawValue,
                  task.queueSequence == nil,
                  task.outcomeJSON == nil,
                  task.revision < Int64.max
            else {
                throw LocalLibraryError.invalidTaskState
            }

            let stagedRecord = try stagedArtifact(for: task, in: db)
            let stagedCleanup = try abandonedCleanup(
                task: task,
                stagedArtifact: stagedRecord
            )
            if let stagedRecord {
                guard try stagedRecord.delete(db) else {
                    throw corruptLibraryError()
                }
            }
            task.stagedArtifactID = nil
            let checkpointCleanup = try removeCheckpointOwnership(
                task: &task,
                in: db
            )

            task.state = ImportTaskState.cancelled.rawValue
            task.revision += 1
            try task.update(db)

            let bundles = try publicationStateBundles(
                for: [task],
                in: db,
                associations: &associations
            )
            guard let snapshot = bundles.first?.snapshot else {
                throw corruptLibraryError()
            }
            return CancellationCompletion(
                snapshot: snapshot,
                stagedCleanup: stagedCleanup,
                checkpointCleanup: checkpointCleanup
            )
        }
    }

    func retryImport(
        taskID: ImportTaskID,
        expectedRevision: UInt64,
        checkpointDisposition: RetryCheckpointDisposition
    ) throws -> RetryTransition {
        try queue.write { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            try validateJournalSequences(tasks)
            try validatePublicationAssociationRoots(in: db)
            var associations = try PublicationAssociationBatch(
                taskIDs: tasks.map(\.taskID),
                in: db
            )
            _ = try publicationStateBundles(
                for: tasks,
                in: db,
                associations: &associations
            )
            guard var task = tasks.first(where: {
                $0.taskID == taskID.rawValue.uuidString
            }), let currentRevision = UInt64(exactly: task.revision),
                  let state = ImportTaskState(rawValue: task.state),
                  state == .failed || state == .cancelled
            else {
                if try ImportTaskRecord.fetchOne(
                    db,
                    key: taskID.rawValue.uuidString
                ) == nil {
                    throw LocalLibraryError.unavailable
                }
                throw LocalLibraryError.invalidTaskState
            }
            guard currentRevision == expectedRevision,
                  task.attempt < Int64.max,
                  task.revision < Int64.max
            else {
                if currentRevision != expectedRevision {
                    guard let exact = UInt64(exactly: task.revision) else {
                        throw corruptLibraryError()
                    }
                    throw LocalLibraryError.staleRevision(current: exact)
                }
                throw corruptLibraryError()
            }

            var checkpointCleanup: CheckpointArtifactCleanup?
            switch checkpointDisposition {
            case .retainVerified:
                break
            case .clear:
                checkpointCleanup = try removeCheckpointOwnership(
                    task: &task,
                    in: db
                )
            }

            task.attempt += 1
            task.failureCodecVersion = nil
            task.failurePayload = nil
            task.cancellationRequested = false
            task.queueSequence = try allocateQueueSequence(in: db)
            task.state = ImportTaskState.queued.rawValue
            task.revision += 1
            try task.update(db)

            let bundles = try publicationStateBundles(
                for: [task],
                in: db,
                associations: &associations
            )
            guard let snapshot = bundles.first?.snapshot else {
                throw corruptLibraryError()
            }
            return RetryTransition(
                snapshot: snapshot,
                checkpointCleanup: checkpointCleanup
            )
        }
    }

    func abandonedStagedArtifactCleanups() throws
        -> [AbandonedStagedArtifactCleanup]
    {
        try queue.read { db in
            let tasks = try ImportTaskRecord
                .filter(
                    Column("state")
                        == ImportTaskState.abandoned.rawValue
                )
                .fetchAll(db)

            return try publicationStateBundles(for: tasks, in: db)
                .compactMap { bundle in
                    try abandonedCleanup(
                        task: bundle.task,
                        stagedArtifact: bundle.stagedArtifact
                    )
                }
        }
    }

    func publicationIntents() throws -> [RecoveredPublicationIntent] {
        try queue.read { db in
            let tasks = try ImportTaskRecord
                .order(Column("task_id"))
                .fetchAll(db)
            _ = try publicationStateBundles(for: tasks, in: db)
            let intentCount = try PublicationIntentRecord.fetchCount(db)
            let pendingTaskCount = tasks.filter {
                $0.state == ImportTaskState.publicationPending.rawValue
            }.count
            let distinctIntentDocumentCount = try Int.fetchOne(
                db,
                sql: "SELECT COUNT(DISTINCT document_id) FROM publication_intents"
            )
            guard intentCount == pendingTaskCount,
                  distinctIntentDocumentCount == intentCount
            else {
                throw corruptLibraryError()
            }
            return try tasks.compactMap { task in
                guard task.state
                    == ImportTaskState.publicationPending.rawValue
                else {
                    return nil
                }
                return try recoveredPublicationIntent(task: task, in: db)
            }
        }
    }

    func rollbackIntent(
        taskID: ImportTaskID,
        preserveStagedOwnership: Bool
    ) throws {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw corruptLibraryError()
            }
            _ = try publicationStateBundles(for: [task], in: db)
            guard task.state
                    == ImportTaskState.publicationPending.rawValue,
                  let intent = try PublicationIntentRecord.fetchOne(
                    db,
                    key: task.taskID
                  ),
                  let document = try SourceDocumentRecord.fetchOne(
                    db,
                    key: intent.documentID
                  ),
                  document.visibility
                    == SourceDocumentVisibility.hidden.rawValue,
                  task.revision < Int64.max
            else {
                throw corruptLibraryError()
            }
            let staged = try stagedArtifact(for: task, in: db)
            guard !preserveStagedOwnership || staged != nil else {
                throw corruptLibraryError()
            }

            guard try SourceDocumentRecord.deleteOne(
                db,
                key: document.documentID
            ), try PublicationIntentRecord.deleteOne(
                db,
                key: intent.taskID
            ) else {
                throw corruptLibraryError()
            }
            if !preserveStagedOwnership {
                if let staged {
                    guard try staged.delete(db) else {
                        throw corruptLibraryError()
                    }
                }
                task.stagedArtifactID = nil
            }
            task.state = ImportTaskState.running.rawValue
            task.revision += 1
            try task.update(db)
        }
    }

    func finalizeRecoveredIntent(
        _ recovered: RecoveredPublicationIntent,
        verifiedDescriptor: SourceArtifactDescriptor
    ) throws -> PublicationCompletion {
        try finalizePublication(
            candidate: recovered.candidate,
            verifiedPlacement: VerifiedPublicationPlacement(
                intent: recovered.intent,
                descriptor: verifiedDescriptor
            )
        )
    }

    func ownedStagingPaths() throws -> Set<ManagedArtifactPath> {
        try queue.read { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            let bundles = try publicationStateBundles(for: tasks, in: db)
            let paths = try bundles.compactMap {
                bundle -> ManagedArtifactPath? in
                guard let staged = bundle.stagedArtifact,
                      let taskID = UUID(uuidString: bundle.task.taskID),
                      let artifactID = UUID(uuidString: staged.artifactID)
                else {
                    if bundle.stagedArtifact == nil {
                        return nil
                    }
                    throw corruptLibraryError()
                }
                let expected = ManagedArtifactPath.staging(
                    taskID: ImportTaskID(taskID),
                    artifactID: artifactID
                )
                guard try ManagedArtifactPath.parse(
                    staged.relativePath
                ) == expected else {
                    throw corruptLibraryError()
                }
                return expected
            }
            let owned = Set(paths)
            guard owned.count == paths.count else {
                throw corruptLibraryError()
            }
            return owned
        }
    }

    func ownedCheckpointPaths() throws -> Set<ManagedArtifactPath> {
        try queue.read { db in
            let tasks = try ImportTaskRecord.fetchAll(db)
            let bundles = try publicationStateBundles(for: tasks, in: db)
            let paths = try bundles.compactMap { bundle in
                try bundle.checkpointArtifact.map {
                    try checkpointPlacement($0).path
                }
            }
            let owned = Set(paths)
            guard owned.count == paths.count else {
                throw corruptLibraryError()
            }
            return owned
        }
    }

    func ownedStagedArtifactPlacement(
        taskID: ImportTaskID,
        artifact: StagedArtifact
    ) throws -> StagedArtifactPlacement {
        try queue.read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            guard task.stagedArtifactID == artifact.rawValue.uuidString else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            guard let record = try stagedArtifact(for: task, in: db),
                  record.artifactID == artifact.rawValue.uuidString
            else {
                throw corruptLibraryError()
            }
            let storedArtifact = StagedArtifact(
                rawValue: artifact.rawValue,
                descriptor: try DomainJSON.decode(
                    SourceArtifactDescriptor.self,
                    from: record.descriptorJSON
                )
            )
            guard storedArtifact == artifact else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            return try StagedArtifactPlacement(
                artifact: storedArtifact,
                relativePath: record.relativePath
            )
        }
    }

    func ownedCheckpointArtifactPlacement(
        taskID: ImportTaskID,
        artifact: ManagedCheckpointArtifact
    ) throws -> CheckpointArtifactPlacement {
        try queue.read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let staged = try stagedArtifact(for: task, in: db)
            let record = try checkpointArtifact(for: task, in: db)
            _ = try task.snapshot(
                stagedArtifact: staged,
                checkpointArtifact: record
            )
            guard let record,
                  record.artifactID == artifact.rawValue.uuidString
            else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            let placement = try checkpointPlacement(record)
            guard placement.taskID == taskID,
                  placement.artifact == artifact
            else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            return placement
        }
    }

    func storedOutcome(taskID: ImportTaskID) throws -> PublicationOutcome? {
        try queue.read { db in
            let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            )
            let bundles = try publicationStateBundles(
                for: task.map { [$0] } ?? [],
                in: db
            )
            guard let bundle = bundles.first else {
                throw LocalLibraryError.unavailable
            }
            return bundle.outcome
        }
    }

    func preflightPublication(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> StagedArtifactPlacement {
        try queue.read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedRecord = try stagedArtifact(for: task, in: db)
            return try publicationPlacement(
                task: task,
                stagedRecord: stagedRecord,
                checkpointRecord: try checkpointArtifact(
                    for: task,
                    in: db
                ),
                taskID: taskID,
                candidate: candidate,
                expectedRevision: expectedRevision
            )
        }
    }

    func preparePublication(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> PublicationPreparation {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedRecord = try stagedArtifact(for: task, in: db)
            let placement = try publicationPlacement(
                task: task,
                stagedRecord: stagedRecord,
                checkpointRecord: try checkpointArtifact(
                    for: task,
                    in: db
                ),
                taskID: taskID,
                candidate: candidate,
                expectedRevision: expectedRevision
            )
            guard let stagedRecord,
                  let persistedTaskID = UUID(uuidString: task.taskID)
            else {
                throw corruptLibraryError()
            }
            let storedDescriptor = placement.artifact.descriptor
            let fingerprintJSON = try DomainJSON.encode(
                candidate.fingerprint
            )
            guard try DomainJSON.decode(
                ContentFingerprint.self,
                from: fingerprintJSON
            ) == candidate.fingerprint else {
                throw corruptLibraryError()
            }

            let documentID = candidate.document.documentID
            let finalPath = ManagedArtifactPath.artifacts(
                documentID: documentID
            )
            let intent = try PublicationIntent(
                taskID: ImportTaskID(persistedTaskID),
                documentID: documentID,
                artifact: placement.artifact,
                stagedPath: placement.path,
                finalPath: finalPath
            )

            if let duplicate = try SourceDocumentRecord
                .filter(
                    Column("fingerprint")
                        == candidate.fingerprint.rawValue
                )
                .filter(
                    Column("visibility")
                        == SourceDocumentVisibility.visible.rawValue
                )
                .fetchOne(db)
            {
                return .duplicate(DuplicatePublication(
                    existingDocument: try duplicate.decoded(),
                    candidateIntent: intent
                ))
            }

            guard task.revision < Int64.max else {
                throw corruptLibraryError()
            }

            try SourceDocumentRecord.hidden(
                candidate: candidate,
                descriptor: storedDescriptor,
                managedRelativePath: finalPath.relativePath
            ).insert(db)
            try PublicationIntentRecord(
                taskID: task.taskID,
                documentID: documentID.rawValue.uuidString,
                stagedArtifactID: stagedRecord.artifactID,
                finalRelativePath: finalPath.relativePath
            ).insert(db)
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.state = ImportTaskState.publicationPending.rawValue
            task.revision += 1
            try task.update(db)
            return .new(intent)
        }
    }

    func completeDuplicate(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64,
        faultInjector: PublicationFaultInjector
    ) throws -> DuplicateCompletion {
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedRecord = try stagedArtifact(for: task, in: db)
            let placement = try publicationPlacement(
                task: task,
                stagedRecord: stagedRecord,
                checkpointRecord: try checkpointArtifact(
                    for: task,
                    in: db
                ),
                taskID: taskID,
                candidate: candidate,
                expectedRevision: expectedRevision
            )
            guard let stagedRecord else {
                throw corruptLibraryError()
            }
            guard let duplicateRecord = try SourceDocumentRecord
                .filter(
                    Column("fingerprint")
                        == candidate.fingerprint.rawValue
                )
                .filter(
                    Column("visibility")
                        == SourceDocumentVisibility.visible.rawValue
                )
                .fetchOne(db)
            else {
                throw LocalLibraryError.publicationFailed(retryable: true)
            }
            let duplicate = try duplicateRecord.decoded()
            guard duplicate.fingerprint == candidate.fingerprint,
                  duplicate.visibility == .visible,
                  task.revision < Int64.max
            else {
                throw corruptLibraryError()
            }
            let source = try SourceColumns.decode(
                kind: task.sourceKind,
                value: task.sourceValue
            )
            let sourceColumns = try SourceColumns.encode(source)
            guard source == candidate.originalSource,
                  sourceColumns.kind == task.sourceKind,
                  sourceColumns.value == task.sourceValue
            else {
                throw LocalLibraryError.artifactOwnershipViolation
            }

            try faultInjector.hit(.beforeDuplicateProvenanceInsert)
            try db.execute(
                sql: """
                    INSERT INTO source_provenance (
                        document_id,
                        source_kind,
                        source_value
                    ) VALUES (?, ?, ?)
                    ON CONFLICT DO NOTHING
                    """,
                arguments: [
                    duplicateRecord.documentID,
                    sourceColumns.kind,
                    sourceColumns.value,
                ]
            )
            let provenanceAdded = db.changesCount == 1
            try faultInjector.hit(.afterDuplicateProvenanceInsert)
            let outcome = PublicationOutcome.alreadyImported(
                documentID: duplicate.documentID,
                location: duplicate.location,
                provenanceAdded: provenanceAdded
            )
            let checkpointCleanup = try removeCheckpointOwnership(
                task: &task,
                in: db
            )
            try removeFromActiveQueueIfNeeded(task: &task, in: db)
            task.outcomeJSON = try DomainJSON.encode(outcome)
            task.state = ImportTaskState.completed.rawValue
            task.stagedArtifactID = nil
            task.revision += 1
            try task.update(db)
            _ = try stagedRecord.delete(db)
            return DuplicateCompletion(
                outcome: outcome,
                stagedPlacement: placement,
                checkpointCleanup: checkpointCleanup
            )
        }
    }

    private func recoveredPublicationIntent(
        task: ImportTaskRecord,
        in db: Database
    ) throws -> RecoveredPublicationIntent {
        guard let staged = try stagedArtifact(for: task, in: db),
              let intent = try PublicationIntentRecord.fetchOne(
                db,
                key: task.taskID
              ),
              let documentRecord = try SourceDocumentRecord.fetchOne(
                db,
                key: intent.documentID
              ),
              let taskID = UUID(uuidString: task.taskID),
              let artifactID = UUID(uuidString: staged.artifactID),
              let documentID = UUID(uuidString: documentRecord.documentID)
        else {
            throw corruptLibraryError()
        }
        let descriptor = try DomainJSON.decode(
            SourceArtifactDescriptor.self,
            from: staged.descriptorJSON
        )
        let publicationIntent = try PublicationIntent(
            taskID: ImportTaskID(taskID),
            documentID: SourceDocumentID(documentID),
            artifact: StagedArtifact(
                rawValue: artifactID,
                descriptor: descriptor
            ),
            stagedRelativePath: staged.relativePath,
            finalRelativePath: intent.finalRelativePath
        )
        let document = try documentRecord.decoded()
        let source = try SourceColumns.decode(
            kind: task.sourceKind,
            value: task.sourceValue
        )
        guard document.visibility == .hidden,
              document.documentID == publicationIntent.documentID,
              document.descriptor == descriptor,
              document.managedRelativePath
                == publicationIntent.finalRelativePath
        else {
            throw corruptLibraryError()
        }
        return RecoveredPublicationIntent(
            intent: publicationIntent,
            candidate: PublicationCandidate(
                fingerprint: document.fingerprint,
                artifact: publicationIntent.artifact,
                document: document.content,
                originalSource: source
            )
        )
    }

    func finalizePublication(
        candidate: PublicationCandidate,
        verifiedPlacement: VerifiedPublicationPlacement
    ) throws -> PublicationCompletion {
        try queue.write { db in
            let expectedIntent = verifiedPlacement.intent
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: expectedIntent.taskID.rawValue.uuidString
            ), let stagedRecord = try stagedArtifact(for: task, in: db),
                  var document = try SourceDocumentRecord.fetchOne(
                    db,
                    key: expectedIntent.documentID.rawValue.uuidString
                  ), let intentRecord = try PublicationIntentRecord.fetchOne(
                    db,
                    key: expectedIntent.taskID.rawValue.uuidString
                  )
            else {
                throw corruptLibraryError()
            }
            _ = try task.snapshot(
                stagedArtifact: stagedRecord,
                checkpointArtifact: try checkpointArtifact(
                    for: task,
                    in: db
                )
            )
            guard task.state == ImportTaskState.publicationPending.rawValue,
                  task.stagedArtifactID == stagedRecord.artifactID,
                  task.stagedArtifactID
                    == candidate.artifact.rawValue.uuidString,
                  stagedRecord.taskID == task.taskID,
                  stagedRecord.artifactID
                    == expectedIntent.artifact.rawValue.uuidString,
                  stagedRecord.relativePath
                    == expectedIntent.stagedRelativePath,
                  try DomainJSON.decode(
                    SourceArtifactDescriptor.self,
                    from: stagedRecord.descriptorJSON
                  ) == candidate.artifact.descriptor,
                  try SourceColumns.decode(
                    kind: task.sourceKind,
                    value: task.sourceValue
                  ) == candidate.originalSource,
                  intentRecord.taskID == task.taskID,
                  intentRecord.documentID == document.documentID,
                  intentRecord.documentID
                    == candidate.document.documentID.rawValue.uuidString,
                  intentRecord.stagedArtifactID == stagedRecord.artifactID,
                  intentRecord.finalRelativePath
                    == expectedIntent.finalRelativePath,
                  verifiedPlacement.descriptor
                    == candidate.artifact.descriptor
            else {
                throw corruptLibraryError()
            }
            let storedDocument = try document.decoded()
            guard storedDocument.documentID == expectedIntent.documentID,
                  storedDocument.fingerprint == candidate.fingerprint,
                  storedDocument.location == .library,
                  storedDocument.visibility == .hidden,
                  storedDocument.content == candidate.document,
                  storedDocument.descriptor == candidate.artifact.descriptor,
                  storedDocument.managedRelativePath
                    == expectedIntent.finalRelativePath,
                  task.revision < Int64.max
            else {
                throw corruptLibraryError()
            }

            let sourceColumns = try SourceColumns.encode(
                candidate.originalSource
            )
            try SourceProvenanceRecord(
                documentID: document.documentID,
                sourceKind: sourceColumns.kind,
                sourceValue: sourceColumns.value
            ).insert(db)
            let outcome = PublicationOutcome.published(
                documentID: expectedIntent.documentID
            )
            document.visibility = SourceDocumentVisibility.visible.rawValue
            try document.update(db)
            let checkpointCleanup = try removeCheckpointOwnership(
                task: &task,
                in: db
            )
            task.outcomeJSON = try DomainJSON.encode(outcome)
            task.state = ImportTaskState.completed.rawValue
            task.stagedArtifactID = nil
            task.revision += 1
            try task.update(db)
            _ = try intentRecord.delete(db)
            _ = try stagedRecord.delete(db)
            return PublicationCompletion(
                outcome: outcome,
                checkpointCleanup: checkpointCleanup
            )
        }
    }

    func visibleSourceDocument(
        id: SourceDocumentID
    ) throws -> StoredSourceDocument? {
        try queue.read { db in
            _ = try publicationStateBundles(for: [], in: db)
            guard let record = try SourceDocumentRecord
                .filter(Column("document_id") == id.rawValue.uuidString)
                .filter(
                    Column("visibility")
                        == SourceDocumentVisibility.visible.rawValue
                )
                .fetchOne(db)
            else {
                return nil
            }
            let decoded = try record.decoded()
            guard decoded.visibility == .visible else {
                throw corruptLibraryError()
            }
            return decoded
        }
    }

    private func stagedArtifact(
        for task: ImportTaskRecord,
        in db: Database
    ) throws -> StagedArtifactRecord? {
        try StagedArtifactRecord
            .filter(Column("task_id") == task.taskID)
            .fetchOne(db)
    }

    private func checkpointArtifact(
        for task: ImportTaskRecord,
        in db: Database
    ) throws -> CheckpointArtifactRecord? {
        try CheckpointArtifactRecord
            .filter(Column("task_id") == task.taskID)
            .fetchOne(db)
    }

    private func publicationPlacement(
        task: ImportTaskRecord,
        stagedRecord: StagedArtifactRecord?,
        checkpointRecord: CheckpointArtifactRecord?,
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> StagedArtifactPlacement {
        _ = try task.snapshot(
            stagedArtifact: stagedRecord,
            checkpointArtifact: checkpointRecord
        )
        guard let persistedTaskID = UUID(uuidString: task.taskID),
              ImportTaskID(persistedTaskID) == taskID,
              let currentRevision = UInt64(exactly: task.revision)
        else {
            throw corruptLibraryError()
        }
        guard currentRevision == expectedRevision else {
            throw LocalLibraryError.staleRevision(current: currentRevision)
        }
        guard let state = ImportTaskState(rawValue: task.state) else {
            throw corruptLibraryError()
        }
        guard state == .queued || state == .running,
              let stagedRecord
        else {
            throw LocalLibraryError.invalidTaskState
        }
        let storedSource = try SourceColumns.decode(
            kind: task.sourceKind,
            value: task.sourceValue
        )
        guard storedSource == candidate.originalSource,
              task.stagedArtifactID
                == candidate.artifact.rawValue.uuidString,
              stagedRecord.taskID == task.taskID,
              stagedRecord.artifactID
                == candidate.artifact.rawValue.uuidString
        else {
            throw LocalLibraryError.artifactOwnershipViolation
        }
        let storedDescriptor = try DomainJSON.decode(
            SourceArtifactDescriptor.self,
            from: stagedRecord.descriptorJSON
        )
        guard storedDescriptor == candidate.artifact.descriptor,
              let persistedArtifactID = UUID(
                uuidString: stagedRecord.artifactID
              )
        else {
            throw LocalLibraryError.artifactOwnershipViolation
        }
        return try StagedArtifactPlacement(
            artifact: StagedArtifact(
                rawValue: persistedArtifactID,
                descriptor: storedDescriptor
            ),
            relativePath: stagedRecord.relativePath
        )
    }

    private func publicationStateBundles(
        for tasks: [ImportTaskRecord],
        in db: Database
    ) throws -> [PublicationStateBundle] {
        try validatePublicationAssociationRoots(in: db)
        var associations = try PublicationAssociationBatch(
            taskIDs: tasks.map(\.taskID),
            in: db
        )
        return try publicationStateBundles(
            for: tasks,
            in: db,
            associations: &associations
        )
    }

    private func validatePublicationAssociationRoots(
        in db: Database
    ) throws {
        try validateJournalSequenceTable(in: db)
        let orphanedHiddenDocumentCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM source_documents AS document
                LEFT JOIN publication_intents AS intent
                    ON intent.document_id = document.document_id
                WHERE document.visibility = ?
                    AND intent.document_id IS NULL
                """,
            arguments: [SourceDocumentVisibility.hidden.rawValue]
        )
        guard orphanedHiddenDocumentCount == 0 else {
            throw corruptLibraryError()
        }
        let orphanedCheckpointArtifactCount = try Int.fetchOne(
            db,
            sql: """
                SELECT COUNT(*)
                FROM checkpoint_artifacts AS artifact
                LEFT JOIN import_tasks AS task
                    ON task.task_id = artifact.task_id
                WHERE task.task_id IS NULL
                """
        )
        guard orphanedCheckpointArtifactCount == 0 else {
            throw corruptLibraryError()
        }
    }

    private func publicationStateBundles(
        for tasks: [ImportTaskRecord],
        in db: Database,
        associations: inout PublicationAssociationBatch
    ) throws -> [PublicationStateBundle] {
        var prepared: [PreparedPublicationTask] = []
        prepared.reserveCapacity(tasks.count)
        var associatedDocumentIDs: Set<String> = []
        for task in tasks {
            let stagedArtifact = associations
                .stagedArtifactsByTaskID[task.taskID]
            let checkpointArtifact = associations
                .checkpointArtifactsByTaskID[task.taskID]
            let intent = associations.intentsByTaskID[task.taskID]
            let snapshot = try task.snapshot(
                stagedArtifact: stagedArtifact,
                checkpointArtifact: checkpointArtifact
            )
            let outcome = try task.storedOutcome()
            guard let state = ImportTaskState(rawValue: task.state) else {
                throw corruptLibraryError()
            }
            let associatedDocumentID: String?
            if let outcome {
                switch outcome {
                case .published(let documentID),
                     .alreadyImported(let documentID, _, _):
                    associatedDocumentID = documentID.rawValue.uuidString
                }
            } else {
                associatedDocumentID = intent?.documentID
            }
            if let associatedDocumentID {
                associatedDocumentIDs.insert(associatedDocumentID)
            }
            prepared.append(
                PreparedPublicationTask(
                    task: task,
                    stagedArtifact: stagedArtifact,
                    checkpointArtifact: checkpointArtifact,
                    intent: intent,
                    snapshot: snapshot,
                    outcome: outcome,
                    state: state,
                    associatedDocumentID: associatedDocumentID
                )
            )
        }
        try associations.loadDocuments(ids: associatedDocumentIDs, in: db)

        var bundles: [PublicationStateBundle] = []
        bundles.reserveCapacity(tasks.count)
        for item in prepared {
            let document: DecodedPublicationDocument?
            let provenance: DecodedPublicationProvenanceCollection
            if let associatedDocumentID = item.associatedDocumentID {
                document = try associations.document(
                    id: associatedDocumentID
                )
                provenance = try associations.provenance(
                    documentID: associatedDocumentID
                )
            } else {
                document = nil
                provenance = DecodedPublicationProvenanceCollection(
                    bySource: [:]
                )
            }
            try validateStoredPublicationState(
                task: item.task,
                state: item.state,
                stagedArtifact: item.stagedArtifact,
                intent: item.intent,
                document: document,
                provenance: provenance,
                outcome: item.outcome
            )
            bundles.append(
                PublicationStateBundle(
                    task: item.task,
                    stagedArtifact: item.stagedArtifact,
                    checkpointArtifact: item.checkpointArtifact,
                    snapshot: item.snapshot.withPublicationIssues(
                        item.state == .completed
                            ? document?.stored.content.issues
                            : nil
                    ),
                    outcome: item.outcome
                )
            )
        }
        return bundles
    }

    private func retainedImports(
        in db: Database
    ) throws -> [DurableImportSnapshot] {
        let tasks = try ImportTaskRecord.fetchAll(db)
        try validateJournalSequences(tasks)
        return try publicationStateBundles(for: tasks, in: db)
            .map(\.snapshot)
            .filter { $0.state != .abandoned }
            .sorted(by: retainedImportOrdering)
    }

    private func validateStoredPublicationState(
        task: ImportTaskRecord,
        state: ImportTaskState,
        stagedArtifact: StagedArtifactRecord?,
        intent: PublicationIntentRecord?,
        document: DecodedPublicationDocument?,
        provenance: DecodedPublicationProvenanceCollection,
        outcome: PublicationOutcome?
    ) throws {
        switch state {
        case .completed:
            guard let outcome,
                  task.stagedArtifactID == nil,
                  stagedArtifact == nil,
                  intent == nil,
                  let document
            else {
                throw corruptLibraryError()
            }
            let documentRecord = document.record
            let storedDocument = document.stored
            let taskSource = try SourceColumns.decode(
                kind: task.sourceKind,
                value: task.sourceValue
            )
            let taskSourceColumns = try SourceColumns.encode(taskSource)
            let storedProvenance = provenance.bySource[
                PublicationSourceKey(
                    kind: task.sourceKind,
                    value: task.sourceValue
                )
            ]
            guard taskSourceColumns.kind == task.sourceKind,
                  taskSourceColumns.value == task.sourceValue,
                  storedDocument.visibility == .visible,
                  let storedProvenance,
                  storedProvenance.record.documentID
                    == documentRecord.documentID,
                  storedProvenance.record.sourceKind == task.sourceKind,
                  storedProvenance.record.sourceValue == task.sourceValue,
                  storedProvenance.stored.documentID
                    == storedDocument.documentID,
                  storedProvenance.stored.source == taskSource
            else {
                throw corruptLibraryError()
            }
            switch outcome {
            case .published(let documentID):
                guard storedDocument.documentID == documentID else {
                    throw corruptLibraryError()
                }
            case .alreadyImported(
                let documentID,
                _,
                _
            ):
                guard storedDocument.documentID == documentID else {
                    throw corruptLibraryError()
                }
            }
        case .publicationPending:
            guard outcome == nil,
                  let stagedArtifact,
                  let intent,
                  let document,
                  task.stagedArtifactID == stagedArtifact.artifactID,
                  intent.taskID == task.taskID,
                  intent.stagedArtifactID == stagedArtifact.artifactID,
                  intent.documentID == document.record.documentID,
                  let rawTaskID = UUID(uuidString: task.taskID),
                  let rawArtifactID = UUID(
                    uuidString: stagedArtifact.artifactID
                  ),
                  let rawDocumentID = UUID(
                    uuidString: document.record.documentID
                  )
            else {
                throw corruptLibraryError()
            }
            let descriptor = try DomainJSON.decode(
                SourceArtifactDescriptor.self,
                from: stagedArtifact.descriptorJSON
            )
            let publicationIntent = try PublicationIntent(
                taskID: ImportTaskID(rawTaskID),
                documentID: SourceDocumentID(rawDocumentID),
                artifact: StagedArtifact(
                    rawValue: rawArtifactID,
                    descriptor: descriptor
                ),
                stagedRelativePath: stagedArtifact.relativePath,
                finalRelativePath: intent.finalRelativePath
            )
            let storedDocument = document.stored
            guard storedDocument.documentID
                    == publicationIntent.documentID,
                  storedDocument.location == .library,
                  storedDocument.visibility == .hidden,
                  storedDocument.descriptor == descriptor,
                  storedDocument.managedRelativePath
                    == publicationIntent.finalRelativePath,
                  provenance.isEmpty
            else {
                throw corruptLibraryError()
            }
        case .queued, .running, .cancelling, .failed, .cancelled,
             .abandoned:
            guard outcome == nil, intent == nil else {
                throw corruptLibraryError()
            }
        case .accepted, .working:
            throw corruptLibraryError()
        }
    }

    private func allocateQueueSequence(in db: Database) throws -> Int64 {
        try validateJournalSequenceTable(in: db)
        let rows = try Row.fetchAll(
            db,
            sql: """
                SELECT singleton, last_sequence
                FROM import_queue_clock
                """
        )
        guard rows.count == 1 else {
            throw corruptLibraryError()
        }
        let singleton = try rows[0].decode(
            Int64.self,
            forColumn: "singleton"
        )
        let lastSequence = try rows[0].decode(
            Int64.self,
            forColumn: "last_sequence"
        )
        let maximumJournalSequence = try Int64.fetchOne(
            db,
            sql: "SELECT MAX(journal_sequence) FROM import_tasks"
        ) ?? 0
        guard singleton == 1,
              lastSequence >= 0,
              maximumJournalSequence >= 0,
              lastSequence >= maximumJournalSequence,
              lastSequence < Int64.max
        else {
            throw corruptLibraryError()
        }
        let nextSequence = lastSequence + 1
        try db.execute(
            sql: """
                UPDATE import_queue_clock
                SET last_sequence = ?
                WHERE singleton = 1
                """,
            arguments: [nextSequence]
        )
        return nextSequence
    }

    private func removeFromActiveQueueIfNeeded(
        task: inout ImportTaskRecord,
        in db: Database
    ) throws {
        guard let removedSequence = task.queueSequence else {
            return
        }
        guard task.state == ImportTaskState.queued.rawValue else {
            throw corruptLibraryError()
        }
        var shifted = try ImportTaskRecord
            .filter(Column("state") == ImportTaskState.queued.rawValue)
            .filter(Column("queue_sequence") > removedSequence)
            .order(Column("queue_sequence"))
            .fetchAll(db)
        for index in shifted.indices {
            guard shifted[index].revision < Int64.max else {
                throw corruptLibraryError()
            }
            shifted[index].revision += 1
            try shifted[index].update(db)
        }
        task.queueSequence = nil
    }

    private func validateJournalSequences(
        _ tasks: [ImportTaskRecord]
    ) throws {
        let sequences = tasks.compactMap(\.journalSequence)
        guard sequences.count == tasks.count,
              sequences.allSatisfy({ $0 > 0 }),
              Set(sequences).count == sequences.count
        else {
            throw corruptLibraryError()
        }
    }

    private func validateJournalSequenceTable(in db: Database) throws {
        guard let stats = try Row.fetchOne(
            db,
            sql: """
                SELECT
                    COUNT(*) AS total_count,
                    COUNT(journal_sequence) AS present_count,
                    COUNT(DISTINCT journal_sequence) AS unique_count,
                    MIN(journal_sequence) AS minimum_sequence
                FROM import_tasks
                """
        ) else {
            throw corruptLibraryError()
        }
        let totalCount = try stats.decode(
            Int64.self,
            forColumn: "total_count"
        )
        let presentCount = try stats.decode(
            Int64.self,
            forColumn: "present_count"
        )
        let uniqueCount = try stats.decode(
            Int64.self,
            forColumn: "unique_count"
        )
        let minimumSequence = try stats.decode(
            Int64?.self,
            forColumn: "minimum_sequence"
        )
        guard totalCount == presentCount,
              totalCount == uniqueCount,
              totalCount == 0 || (minimumSequence ?? 0) > 0
        else {
            throw corruptLibraryError()
        }
    }

    private func stagedArtifactRecord(
        taskID: ImportTaskID,
        placement: StagedArtifactPlacement
    ) throws -> StagedArtifactRecord {
        StagedArtifactRecord(
            artifactID: placement.artifact.rawValue.uuidString,
            taskID: taskID.rawValue.uuidString,
            descriptorJSON: try DomainJSON.encode(
                placement.artifact.descriptor
            ),
            relativePath: placement.relativePath
        )
    }

    private func checkpointArtifactRecord(
        taskID: ImportTaskID,
        placement: CheckpointArtifactPlacement
    ) throws -> CheckpointArtifactRecord {
        guard placement.taskID == taskID else {
            throw corruptLibraryError()
        }
        return CheckpointArtifactRecord(
            artifactID: placement.artifact.rawValue.uuidString,
            taskID: taskID.rawValue.uuidString,
            descriptorJSON: try DomainJSON.encode(
                placement.artifact.descriptor
            ),
            relativePath: placement.relativePath
        )
    }

    private func removeCheckpointOwnership(
        task: inout ImportTaskRecord,
        in db: Database
    ) throws -> CheckpointArtifactCleanup? {
        guard let record = try checkpointArtifact(for: task, in: db) else {
            task.checkpointOrdinal = nil
            task.checkpointCodecVersion = nil
            task.checkpointPayload = nil
            return nil
        }
        let cleanup = CheckpointArtifactCleanup(
            placement: try checkpointPlacement(record)
        )
        guard try record.delete(db) else {
            throw corruptLibraryError()
        }
        task.checkpointOrdinal = nil
        task.checkpointCodecVersion = nil
        task.checkpointPayload = nil
        return cleanup
    }

    private func checkpointPlacement(
        _ record: CheckpointArtifactRecord
    ) throws -> CheckpointArtifactPlacement {
        guard let taskUUID = UUID(uuidString: record.taskID),
              taskUUID.uuidString == record.taskID,
              let artifactUUID = UUID(uuidString: record.artifactID),
              artifactUUID.uuidString == record.artifactID
        else {
            throw corruptLibraryError()
        }
        let descriptor = try DomainJSON.decode(
            CheckpointArtifactDescriptor.self,
            from: record.descriptorJSON
        )
        return try CheckpointArtifactPlacement(
            taskID: ImportTaskID(taskUUID),
            artifact: ManagedCheckpointArtifact(
                rawValue: artifactUUID,
                descriptor: descriptor
            ),
            relativePath: record.relativePath
        )
    }

    private func abandonedCleanup(
        task: ImportTaskRecord,
        stagedArtifact: StagedArtifactRecord?
    ) throws -> AbandonedStagedArtifactCleanup? {
        guard let stagedArtifact else {
            return nil
        }
        guard let taskUUID = UUID(uuidString: task.taskID),
              let artifactUUID = UUID(uuidString: stagedArtifact.artifactID)
        else {
            throw corruptLibraryError()
        }
        let expectedPath = ManagedArtifactPath.staging(
            taskID: ImportTaskID(taskUUID),
            artifactID: artifactUUID
        )
        guard try ManagedArtifactPath.parse(
            stagedArtifact.relativePath
        ) == expectedPath else {
            throw corruptLibraryError()
        }
        return AbandonedStagedArtifactCleanup(path: expectedPath)
    }
}

private func uniqueRecords<Record, Key: Hashable>(
    _ records: [Record],
    keyedBy keyPath: KeyPath<Record, Key>
) throws -> [Key: Record] {
    var result: [Key: Record] = [:]
    result.reserveCapacity(records.count)
    for record in records {
        guard result.updateValue(
            record,
            forKey: record[keyPath: keyPath]
        ) == nil else {
            throw corruptLibraryError()
        }
    }
    return result
}

private func corruptLibraryError() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}

private func queueRecordOrdering(
    _ lhs: ImportTaskRecord,
    _ rhs: ImportTaskRecord
) -> Bool {
    (lhs.queueSequence ?? Int64.max) < (rhs.queueSequence ?? Int64.max)
}

private func retainedImportOrdering(
    _ lhs: DurableImportSnapshot,
    _ rhs: DurableImportSnapshot
) -> Bool {
    let lhsRank = retainedImportRank(lhs.state)
    let rhsRank = retainedImportRank(rhs.state)
    guard lhsRank == rhsRank else {
        return lhsRank < rhsRank
    }
    if lhs.state == .queued, rhs.state == .queued {
        return (lhs.queueSequence ?? UInt64.max)
            < (rhs.queueSequence ?? UInt64.max)
    }
    return lhs.journalSequence < rhs.journalSequence
}

private func retainedImportRank(_ state: ImportTaskState) -> Int {
    switch state {
    case .running, .cancelling, .publicationPending:
        return 0
    case .queued:
        return 1
    case .failed, .cancelled, .completed:
        return 2
    case .abandoned:
        return 3
    case .accepted, .working:
        return 4
    }
}
