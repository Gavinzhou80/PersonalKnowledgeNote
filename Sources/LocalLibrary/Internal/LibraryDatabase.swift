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
        source: OriginalSource
    ) throws {
        let sourceColumns = SourceColumns.encode(source)
        try queue.write { db in
            try ImportTaskRecord(
                taskID: id.rawValue.uuidString,
                sourceKind: sourceColumns.kind,
                sourceValue: sourceColumns.value,
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

    private func stagedArtifact(
        for task: ImportTaskRecord,
        in db: Database
    ) throws -> StagedArtifactRecord? {
        try StagedArtifactRecord
            .filter(Column("task_id") == task.taskID)
            .fetchOne(db)
    }
}
