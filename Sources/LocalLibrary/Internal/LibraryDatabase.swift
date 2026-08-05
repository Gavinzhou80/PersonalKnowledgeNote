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

private struct PublicationStateBundle {
    let task: ImportTaskRecord
    let stagedArtifact: StagedArtifactRecord?
    let snapshot: DurableImportSnapshot
    let outcome: PublicationOutcome?
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
        let sourceColumns = try SourceColumns.encode(source)
        try queue.write { db in
            try ImportTaskRecord(
                taskID: id.rawValue.uuidString,
                sourceKind: sourceColumns.kind,
                sourceValue: sourceColumns.value,
                attempt: 1,
                revision: placement == nil ? 0 : 1,
                state: placement == nil
                    ? ImportTaskState.accepted.rawValue
                    : ImportTaskState.working.rawValue,
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
            guard let currentRevision = UInt64(exactly: task.revision) else {
                throw corruptLibraryError()
            }
            guard currentRevision == expectedRevision else {
                throw LocalLibraryError.staleRevision(current: currentRevision)
            }
            guard let state = ImportTaskState(rawValue: task.state) else {
                throw corruptLibraryError()
            }
            guard state != .completed, state != .abandoned else {
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
            task.stagedArtifactID = placement.artifact.rawValue.uuidString
            task.state = ImportTaskState.working.rawValue
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
            guard let currentRevision = UInt64(exactly: task.revision) else {
                throw corruptLibraryError()
            }
            guard currentRevision == update.expectedRevision else {
                throw LocalLibraryError.staleRevision(
                    current: currentRevision
                )
            }
            guard let state = ImportTaskState(rawValue: task.state) else {
                throw corruptLibraryError()
            }
            guard state != .completed,
                  state != .abandoned,
                  state != .publicationPending
            else {
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
            task.state = ImportTaskState.working.rawValue
            task.revision += 1
            try task.update(db)

            let stagedArtifact = try stagedArtifact(for: task, in: db)
            return try task.snapshot(stagedArtifact: stagedArtifact)
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
            _ = try task.snapshot(stagedArtifact: stagedArtifact)
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
            return StagedArtifactPlacement(
                artifact: storedArtifact,
                relativePath: record.relativePath
            )
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
            let finalRelativePath =
                "Artifacts/\(documentID.rawValue.uuidString)"
            let intent = try PublicationIntent(
                taskID: ImportTaskID(persistedTaskID),
                documentID: documentID,
                artifact: placement.artifact,
                stagedRelativePath: stagedRecord.relativePath,
                finalRelativePath: finalRelativePath
            )

            if let duplicate = try SourceDocumentRecord
                .filter(
                    Column("fingerprint")
                        == candidate.fingerprint.rawValue
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
                managedRelativePath: finalRelativePath
            ).insert(db)
            try PublicationIntentRecord(
                taskID: task.taskID,
                documentID: documentID.rawValue.uuidString,
                stagedArtifactID: stagedRecord.artifactID,
                finalRelativePath: finalRelativePath
            ).insert(db)
            task.state = ImportTaskState.publicationPending.rawValue
            task.revision += 1
            try task.update(db)
            return .new(intent)
        }
    }

    func finalizePublication(
        candidate: PublicationCandidate,
        verifiedPlacement: VerifiedPublicationPlacement
    ) throws -> PublicationOutcome {
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
            _ = try task.snapshot(stagedArtifact: stagedRecord)
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
            task.outcomeJSON = try DomainJSON.encode(outcome)
            task.state = ImportTaskState.completed.rawValue
            task.stagedArtifactID = nil
            task.revision += 1
            try task.update(db)
            _ = try intentRecord.delete(db)
            _ = try stagedRecord.delete(db)
            return outcome
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

    private func publicationPlacement(
        task: ImportTaskRecord,
        stagedRecord: StagedArtifactRecord?,
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> StagedArtifactPlacement {
        _ = try task.snapshot(stagedArtifact: stagedRecord)
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
        guard state == .accepted || state == .working,
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
        return StagedArtifactPlacement(
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

        return try tasks.map { task in
            let stagedArtifact = try stagedArtifact(for: task, in: db)
            let intent = try PublicationIntentRecord.fetchOne(
                db,
                key: task.taskID
            )
            let snapshot = try task.snapshot(
                stagedArtifact: stagedArtifact
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
            let document = try associatedDocumentID.flatMap {
                try SourceDocumentRecord.fetchOne(db, key: $0)
            }
            try validateStoredPublicationState(
                task: task,
                state: state,
                stagedArtifact: stagedArtifact,
                intent: intent,
                document: document,
                outcome: outcome
            )
            return PublicationStateBundle(
                task: task,
                stagedArtifact: stagedArtifact,
                snapshot: snapshot,
                outcome: outcome
            )
        }
    }

    private func validateStoredPublicationState(
        task: ImportTaskRecord,
        state: ImportTaskState,
        stagedArtifact: StagedArtifactRecord?,
        intent: PublicationIntentRecord?,
        document: SourceDocumentRecord?,
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
            let storedDocument = try document.decoded()
            guard storedDocument.visibility == .visible else {
                throw corruptLibraryError()
            }
            switch outcome {
            case .published(let documentID):
                guard storedDocument.documentID == documentID,
                      storedDocument.location == .library
                else {
                    throw corruptLibraryError()
                }
            case .alreadyImported(
                let documentID,
                let location,
                _
            ):
                guard storedDocument.documentID == documentID,
                      storedDocument.location == location
                else {
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
                  intent.documentID == document.documentID,
                  let rawTaskID = UUID(uuidString: task.taskID),
                  let rawArtifactID = UUID(
                    uuidString: stagedArtifact.artifactID
                  ),
                  let rawDocumentID = UUID(uuidString: document.documentID)
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
            let storedDocument = try document.decoded()
            guard storedDocument.documentID
                    == publicationIntent.documentID,
                  storedDocument.location == .library,
                  storedDocument.visibility == .hidden,
                  storedDocument.descriptor == descriptor,
                  storedDocument.managedRelativePath
                    == publicationIntent.finalRelativePath
            else {
                throw corruptLibraryError()
            }
        case .accepted, .working, .abandoned:
            guard outcome == nil, intent == nil else {
                throw corruptLibraryError()
            }
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
        return AbandonedStagedArtifactCleanup(
            taskID: ImportTaskID(taskUUID),
            artifactID: artifactUUID,
            payloadRelativePath: stagedArtifact.relativePath + "/payload"
        )
    }
}

private func corruptLibraryError() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}
