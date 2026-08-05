import Foundation
import GRDB
import KnowledgeCore

package enum LocalLibraryTestDriver {
    package enum AbandonedCleanupCorruption: Sendable {
        case artifactsScope
        case anotherTask(ImportTaskID)
        case artifactIDMismatch
    }

    package struct ManagedArtifactProbe: Sendable {
        fileprivate let relativePath: String
    }

    package static func corruptAbandonedCleanupPath(
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
                guard UUID(uuidString: target.artifactID) != nil else {
                    throw LocalLibraryError.unavailable
                }
                let finalPath = "Artifacts/\(target.artifactID)"
                let managedArtifacts = try ManagedArtifacts(root: root)
                try managedArtifacts.moveToFinal(
                    stagedRelativePath: target.relativePath,
                    finalRelativePath: finalPath
                )
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

    package static func managedArtifactExists(
        at root: URL,
        probe: ManagedArtifactProbe
    ) throws -> Bool {
        try ManagedArtifacts(root: root).exists(
            relativePath: probe.relativePath
        )
    }

    package static func markPublicationPending(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.state = ImportTaskState.publicationPending.rawValue
        }
    }

    package static func corruptCheckpointWithOversizedPayload(
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

    package static func corruptCheckpointWithNegativeOrdinal(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try updateTask(at: root, taskID: taskID) { task in
            task.checkpointOrdinal = -1
            task.checkpointCodecVersion = 1
            task.checkpointPayload = Data("checkpoint".utf8)
        }
    }

    package static func corruptCheckpointWithOversizedCodecVersion(
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
}
