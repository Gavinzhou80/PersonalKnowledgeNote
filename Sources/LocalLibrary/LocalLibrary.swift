import Foundation
import KnowledgeCore

public actor LocalLibrary {
    private let database: LibraryDatabase

    private init(database: LibraryDatabase) {
        self.database = database
    }

    public static func open(at root: URL) async throws -> LocalLibrary {
        do {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let database = try LibraryDatabase(
                url: root.appending(path: "library.sqlite")
            )
            return LocalLibrary(database: database)
        } catch let error as LocalLibraryError {
            throw error
        } catch {
            throw LocalLibraryError.unavailable
        }
    }

    public func accept(
        _ source: OriginalSource
    ) async throws -> ImportWorkspace {
        guard case .webpage = source else {
            throw LocalLibraryError.unavailable
        }

        let taskID = ImportTaskID()
        do {
            try database.insertAcceptedTask(id: taskID, source: source)
        } catch let error as LocalLibraryError {
            throw error
        } catch {
            throw LocalLibraryError.unavailable
        }
        return ImportWorkspace(taskID: taskID, library: self)
    }

    public func recoverableImports()
        async throws -> [ImportWorkspace]
    {
        do {
            return try database.recoverableTasks().map {
                ImportWorkspace(taskID: $0.taskID, library: self)
            }
        } catch let error as LocalLibraryError {
            throw error
        } catch {
            throw LocalLibraryError.unavailable
        }
    }

    public func importWorkspace(
        id: ImportTaskID
    ) async throws -> ImportWorkspace? {
        do {
            guard let snapshot = try database.snapshot(taskID: id),
                  snapshot.state != .abandoned
            else {
                return nil
            }
            return ImportWorkspace(taskID: id, library: self)
        } catch let error as LocalLibraryError {
            throw error
        } catch {
            throw LocalLibraryError.unavailable
        }
    }

    package func snapshot(
        taskID: ImportTaskID
    ) throws -> DurableImportSnapshot {
        do {
            guard let snapshot = try database.snapshot(taskID: taskID) else {
                throw LocalLibraryError.unavailable
            }
            return snapshot
        } catch let error as LocalLibraryError {
            throw error
        } catch {
            throw LocalLibraryError.unavailable
        }
    }
}
