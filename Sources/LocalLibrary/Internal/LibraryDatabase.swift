import Foundation
import GRDB
import KnowledgeCore

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
        let sourceColumns = SourceColumns.encode(source)
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

    func task(id: ImportTaskID) throws -> ImportTaskRecord? {
        try queue.read { db in
            try ImportTaskRecord.fetchOne(
                db,
                key: id.rawValue.uuidString
            )
        }
    }

    func snapshot(
        taskID: ImportTaskID
    ) throws -> DurableImportSnapshot? {
        try queue.read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                return nil
            }
            let stagedArtifact = try stagedArtifact(
                for: task,
                in: db
            )
            return try task.snapshot(stagedArtifact: stagedArtifact)
        }
    }

    func recoverableTasks() throws -> [DurableImportSnapshot] {
        try queue.read { db in
            let terminalStates = [
                ImportTaskState.completed.rawValue,
                ImportTaskState.abandoned.rawValue,
            ]
            let tasks = try ImportTaskRecord
                .filter(!terminalStates.contains(Column("state")))
                .fetchAll(db)

            return try tasks.map { task in
                let stagedArtifact = try stagedArtifact(
                    for: task,
                    in: db
                )
                return try task.snapshot(stagedArtifact: stagedArtifact)
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

    private func stagedArtifact(
        for task: ImportTaskRecord,
        in db: Database
    ) throws -> StagedArtifactRecord? {
        try StagedArtifactRecord
            .filter(Column("task_id") == task.taskID)
            .fetchOne(db)
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
}

private func corruptLibraryError() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}
