import Foundation
import GRDB
import KnowledgeCore
@testable import LocalLibrary

enum LocalLibraryTestDriver {
    enum StagedArtifactCorruption: Sendable {
        case missing
        case tampered
    }

    enum CompletedPublicationCorruption: Sendable {
        case stagedOwnership
        case publicationIntent
        case missingDocument
        case hiddenDocument
    }

    enum NonterminalPublicationCorruption: Sendable {
        case missingIntent
        case missingDocument
        case workingWithIntent
        case workingWithHiddenReservation
    }

    enum AbandonedCleanupCorruption: Sendable {
        case artifactsScope
        case anotherTask(ImportTaskID)
        case artifactIDMismatch
    }

    struct ManagedArtifactProbe: Sendable {
        fileprivate let relativePath: String
    }

    static func corruptAbandonedCleanupPath(
        at root: URL,
        taskID: ImportTaskID,
        corruption: AbandonedCleanupCorruption
    ) throws -> ManagedArtifactProbe {
        let queue = try databaseQueue(at: root)
        return try queue.write { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ), task.state == ImportTaskState.abandoned.rawValue,
                  let target = try StagedArtifactRecord
                    .filter(Column("task_id") == task.taskID)
                    .fetchOne(db)
            else {
                throw LocalLibraryError.unavailable
            }

            let corruptedPath: String
            let probePath: String
            switch corruption {
            case .artifactsScope:
                guard let taskUUID = UUID(uuidString: task.taskID),
                      let artifactUUID = UUID(uuidString: target.artifactID)
                else {
                    throw LocalLibraryError.unavailable
                }
                let managedArtifacts = try ManagedArtifacts(root: root)
                let intent = try PublicationIntent(
                    taskID: ImportTaskID(taskUUID),
                    documentID: SourceDocumentID(artifactUUID),
                    artifact: StagedArtifact(
                        rawValue: artifactUUID,
                        descriptor: try DomainJSON.decode(
                            SourceArtifactDescriptor.self,
                            from: target.descriptorJSON
                        )
                    ),
                    stagedRelativePath: target.relativePath,
                    finalRelativePath: "Artifacts/\(target.artifactID)"
                )
                _ = try managedArtifacts.moveToFinal(intent)
                let finalPath = intent.finalRelativePath
                corruptedPath = finalPath
                probePath = finalPath
            case .anotherTask(let otherTaskID):
                guard let other = try StagedArtifactRecord
                    .filter(
                        Column("task_id")
                            == otherTaskID.rawValue.uuidString
                    )
                    .fetchOne(db)
                else {
                    throw LocalLibraryError.unavailable
                }
                corruptedPath = other.relativePath
                probePath = other.relativePath
            case .artifactIDMismatch:
                corruptedPath = "Staging/\(task.taskID)/\(UUID().uuidString)"
                probePath = target.relativePath
            }

            try db.execute(
                sql: """
                    UPDATE staged_artifacts
                    SET relative_path = ?
                    WHERE task_id = ?
                    """,
                arguments: [corruptedPath, task.taskID]
            )
            return ManagedArtifactProbe(relativePath: probePath)
        }
    }

    static func managedArtifactExists(
        at root: URL,
        probe: ManagedArtifactProbe
    ) throws -> Bool {
        try ManagedArtifacts(root: root).exists(
            relativePath: probe.relativePath
        )
    }

    static func taskCount(at root: URL) throws -> Int {
        try databaseQueue(at: root).read { db in
            try ImportTaskRecord.fetchCount(db)
        }
    }

    static func setLocation(
        at root: URL,
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation
    ) throws {
        try databaseQueue(at: root).write { db in
            guard try SourceDocumentRecord.fetchOne(
                db,
                key: documentID.rawValue.uuidString
            ) != nil else {
                throw LocalLibraryError.unavailable
            }
            try db.execute(
                sql: """
                    UPDATE source_documents
                    SET location = ?
                    WHERE document_id = ?
                    """,
                arguments: [
                    location.rawValue,
                    documentID.rawValue.uuidString,
                ]
            )
        }
    }

    static func provenanceCount(
        at root: URL,
        documentID: SourceDocumentID,
        source: OriginalSource
    ) throws -> Int {
        let columns = try SourceColumns.encode(source)
        return try databaseQueue(at: root).read { db in
            try SourceProvenanceRecord
                .filter(
                    Column("document_id")
                        == documentID.rawValue.uuidString
                )
                .filter(Column("source_kind") == columns.kind)
                .filter(Column("source_value") == columns.value)
                .fetchCount(db)
        }
    }

    static func removeProvenance(
        at root: URL,
        documentID: SourceDocumentID,
        source: OriginalSource
    ) throws {
        let columns = try SourceColumns.encode(source)
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    DELETE FROM source_provenance
                    WHERE document_id = ?
                        AND source_kind = ?
                        AND source_value = ?
                    """,
                arguments: [
                    documentID.rawValue.uuidString,
                    columns.kind,
                    columns.value,
                ]
            )
        }
    }

    static func corruptProvenance(
        at root: URL,
        documentID: SourceDocumentID,
        source: OriginalSource
    ) throws {
        let columns = try SourceColumns.encode(source)
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    UPDATE source_provenance
                    SET source_kind = 'invalid'
                    WHERE document_id = ?
                        AND source_kind = ?
                        AND source_value = ?
                    """,
                arguments: [
                    documentID.rawValue.uuidString,
                    columns.kind,
                    columns.value,
                ]
            )
            guard db.changesCount == 1 else {
                throw LocalLibraryError.unavailable
            }
        }
    }

    static func hasStagedOwnership(
        at root: URL,
        taskID: ImportTaskID
    ) throws -> Bool {
        try databaseQueue(at: root).read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let stagedCount = try StagedArtifactRecord
                .filter(Column("task_id") == task.taskID)
                .fetchCount(db)
            return task.stagedArtifactID != nil && stagedCount == 1
        }
    }

    static func hasStoredOutcome(
        at root: URL,
        taskID: ImportTaskID
    ) throws -> Bool {
        try databaseQueue(at: root).read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            return task.outcomeJSON != nil
        }
    }

    static func sourceDocumentExists(
        at root: URL,
        documentID: SourceDocumentID
    ) throws -> Bool {
        try databaseQueue(at: root).read { db in
            try SourceDocumentRecord.fetchOne(
                db,
                key: documentID.rawValue.uuidString
            ) != nil
        }
    }

    static func dropSourceDocumentsTable(at root: URL) throws {
        try databaseQueue(at: root).write { db in
            try db.execute(sql: "DROP TABLE source_documents")
        }
    }

    static func sourceDocumentCount(at root: URL) throws -> Int {
        try databaseQueue(at: root).read { db in
            try SourceDocumentRecord.fetchCount(db)
        }
    }

    static func visibleSourceDocumentCount(at root: URL) throws -> Int {
        try databaseQueue(at: root).read { db in
            try SourceDocumentRecord
                .filter(
                    Column("visibility")
                        == SourceDocumentVisibility.visible.rawValue
                )
                .fetchCount(db)
        }
    }

    static func finalArtifactExists(
        at root: URL,
        documentID: SourceDocumentID
    ) throws -> Bool {
        try ManagedArtifacts(root: root).exists(
            relativePath: "Artifacts/\(documentID.rawValue.uuidString)"
        )
    }

    static func stagingContainerExists(
        at root: URL,
        taskID: ImportTaskID,
        artifact: StagedArtifact
    ) throws -> Bool {
        try ManagedArtifacts(root: root).exists(
            relativePath:
                "Staging/\(taskID.rawValue.uuidString)/\(artifact.rawValue.uuidString)"
        )
    }

    static func corruptStagedArtifact(
        at root: URL,
        taskID: ImportTaskID,
        artifact: StagedArtifact,
        corruption: StagedArtifactCorruption
    ) throws {
        let payload = root.appending(
            path: "Staging/\(taskID.rawValue.uuidString)/\(artifact.rawValue.uuidString)/payload"
        )
        switch corruption {
        case .missing:
            try FileManager.default.removeItem(at: payload)
        case .tampered:
            try Data("tampered staging".utf8).write(
                to: payload.appending(path: "index.html")
            )
        }
    }

    static func prepareHiddenPublication(
        at root: URL,
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws {
        let database = try LibraryDatabase(
            url: root.appending(path: "library.sqlite")
        )
        switch try database.preparePublication(
            taskID: taskID,
            candidate: candidate,
            expectedRevision: expectedRevision
        ) {
        case .new:
            return
        case .duplicate:
            throw LocalLibraryError.unavailable
        }
    }

    static func movePreparedPublicationToFinal(
        at root: URL,
        taskID: ImportTaskID
    ) throws -> SourceArtifactDescriptor {
        let queue = try databaseQueue(at: root)
        let intent = try queue.read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ), let staged = try StagedArtifactRecord
                .filter(Column("task_id") == task.taskID)
                .fetchOne(db), let record = try PublicationIntentRecord
                .fetchOne(db, key: task.taskID),
                  let artifactID = UUID(uuidString: staged.artifactID),
                  let documentID = UUID(uuidString: record.documentID)
            else {
                throw LocalLibraryError.unavailable
            }
            return try PublicationIntent(
                taskID: taskID,
                documentID: SourceDocumentID(documentID),
                artifact: StagedArtifact(
                    rawValue: artifactID,
                    descriptor: try DomainJSON.decode(
                        SourceArtifactDescriptor.self,
                        from: staged.descriptorJSON
                    )
                ),
                stagedRelativePath: staged.relativePath,
                finalRelativePath: record.finalRelativePath
            )
        }
        return try ManagedArtifacts(root: root)
            .moveToFinal(intent)
            .descriptor
    }

    static func corruptCompletedPublication(
        at root: URL,
        taskID: ImportTaskID,
        artifact: StagedArtifact,
        documentID: SourceDocumentID,
        corruption: CompletedPublicationCorruption
    ) throws {
        let queue = try databaseQueue(at: root)
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ), task.state == ImportTaskState.completed.rawValue
            else {
                throw LocalLibraryError.unavailable
            }
            switch corruption {
            case .stagedOwnership:
                task.stagedArtifactID = artifact.rawValue.uuidString
                try task.update(db)
                try StagedArtifactRecord(
                    artifactID: artifact.rawValue.uuidString,
                    taskID: task.taskID,
                    descriptorJSON: try DomainJSON.encode(
                        artifact.descriptor
                    ),
                    relativePath:
                        "Staging/\(task.taskID)/\(artifact.rawValue.uuidString)"
                ).insert(db)
            case .publicationIntent:
                try PublicationIntentRecord(
                    taskID: task.taskID,
                    documentID: documentID.rawValue.uuidString,
                    stagedArtifactID: artifact.rawValue.uuidString,
                    finalRelativePath:
                        "Artifacts/\(documentID.rawValue.uuidString)"
                ).insert(db)
            case .missingDocument:
                _ = try SourceDocumentRecord.deleteOne(
                    db,
                    key: documentID.rawValue.uuidString
                )
            case .hiddenDocument:
                try db.execute(
                    sql: """
                        UPDATE source_documents
                        SET visibility = ?
                        WHERE document_id = ?
                        """,
                    arguments: [
                        SourceDocumentVisibility.hidden.rawValue,
                        documentID.rawValue.uuidString,
                    ]
                )
            }
        }
    }

    static func corruptNonterminalPublication(
        at root: URL,
        taskID: ImportTaskID,
        documentID: SourceDocumentID,
        corruption: NonterminalPublicationCorruption
    ) throws {
        let queue = try databaseQueue(at: root)
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ), task.state == ImportTaskState.publicationPending.rawValue
            else {
                throw LocalLibraryError.unavailable
            }
            switch corruption {
            case .missingIntent:
                _ = try PublicationIntentRecord.deleteOne(
                    db,
                    key: task.taskID
                )
            case .missingDocument:
                _ = try SourceDocumentRecord.deleteOne(
                    db,
                    key: documentID.rawValue.uuidString
                )
            case .workingWithIntent:
                task.state = ImportTaskState.working.rawValue
                try task.update(db)
            case .workingWithHiddenReservation:
                task.state = ImportTaskState.working.rawValue
                try task.update(db)
                _ = try PublicationIntentRecord.deleteOne(
                    db,
                    key: task.taskID
                )
            }
        }
    }

    static func corruptOriginalSource(
        at root: URL,
        taskID: ImportTaskID,
        kind: String,
        value: String
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.sourceKind = kind
            task.sourceValue = value
        }
    }

    static func removeFinalArtifactPayload(
        at root: URL,
        documentID: SourceDocumentID
    ) throws {
        try FileManager.default.removeItem(
            at: finalArtifactPayloadURL(
                at: root,
                documentID: documentID
            )
        )
    }

    static func tamperFinalArtifactPayload(
        at root: URL,
        documentID: SourceDocumentID
    ) throws {
        try Data("tampered".utf8).write(
            to: finalArtifactPayloadURL(
                at: root,
                documentID: documentID
            ).appending(path: "index.html")
        )
    }

    static func corruptCheckpointWithOversizedPayload(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.checkpointOrdinal = 1
            task.checkpointCodecVersion = 1
            task.checkpointPayload = Data(
                repeating: 0x41,
                count: 1_048_577
            )
        }
    }

    static func corruptCheckpointWithNegativeOrdinal(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.checkpointOrdinal = -1
            task.checkpointCodecVersion = 1
            task.checkpointPayload = Data("checkpoint".utf8)
        }
    }

    static func corruptCheckpointWithOversizedCodecVersion(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.checkpointOrdinal = 1
            task.checkpointCodecVersion = Int64(UInt16.max) + 1
            task.checkpointPayload = Data("checkpoint".utf8)
        }
    }

    private static func updateTask(
        at root: URL,
        taskID: ImportTaskID,
        mutation: (inout ImportTaskRecord) -> Void
    ) throws {
        let queue = try databaseQueue(at: root)
        try queue.write { db in
            guard var task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            mutation(&task)
            try task.update(db)
        }
    }

    private static func databaseQueue(at root: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: root.appending(path: "library.sqlite").path)
    }

    private static func finalArtifactPayloadURL(
        at root: URL,
        documentID: SourceDocumentID
    ) -> URL {
        root.appending(
            path: "Artifacts/\(documentID.rawValue.uuidString)/payload"
        )
    }
}
