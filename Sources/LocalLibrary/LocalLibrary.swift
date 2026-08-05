import Foundation
import GRDB
import KnowledgeCore

public actor LocalLibrary {
    private let database: LibraryDatabase
    private let managedArtifacts: ManagedArtifacts

    private init(
        database: LibraryDatabase,
        managedArtifacts: ManagedArtifacts
    ) {
        self.database = database
        self.managedArtifacts = managedArtifacts
    }

    public static func open(at root: URL) async throws -> LocalLibrary {
        try withLocalLibraryErrorTranslation {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let database = try LibraryDatabase(
                url: root.appending(path: "library.sqlite")
            )
            let managedArtifacts = try ManagedArtifacts(root: root)
            return LocalLibrary(
                database: database,
                managedArtifacts: managedArtifacts
            )
        }
    }

    public func accept(
        _ source: OriginalSource
    ) async throws -> ImportWorkspace {
        try withLocalLibraryErrorTranslation {
            let taskID = ImportTaskID()
            switch source {
            case .webpage:
                try database.insertAcceptedTask(id: taskID, source: source)
            case .pdfFile(let externalPDF):
                let placement = try managedArtifacts.capturePDF(
                    at: externalPDF,
                    for: taskID
                )
                do {
                    try database.insertAcceptedTask(
                        id: taskID,
                        source: source,
                        placement: placement
                    )
                } catch {
                    try managedArtifacts.remove(placement)
                    throw error
                }
            }
            return ImportWorkspace(taskID: taskID, library: self)
        }
    }

    public func recoverableImports()
        async throws -> [ImportWorkspace]
    {
        try withLocalLibraryErrorTranslation {
            return try database.recoverableTasks().map {
                ImportWorkspace(taskID: $0.taskID, library: self)
            }
        }
    }

    public func importWorkspace(
        id: ImportTaskID
    ) async throws -> ImportWorkspace? {
        try withLocalLibraryErrorTranslation {
            guard let snapshot = try database.snapshot(taskID: id),
                  snapshot.state != .abandoned
            else {
                return nil
            }
            return ImportWorkspace(taskID: id, library: self)
        }
    }

    package func snapshot(
        taskID: ImportTaskID
    ) throws -> DurableImportSnapshot {
        try withLocalLibraryErrorTranslation {
            guard let snapshot = try database.snapshot(taskID: taskID) else {
                throw LocalLibraryError.unavailable
            }
            return snapshot
        }
    }

    package func stageArtifact(
        _ input: SourceArtifactInput,
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> StagedArtifact {
        try withLocalLibraryErrorTranslation {
            let placement = try managedArtifacts.stage(input, for: taskID)
            do {
                try database.attachStagedArtifact(
                    taskID: taskID,
                    expectedRevision: expectedRevision,
                    placement: placement
                )
            } catch {
                try managedArtifacts.remove(placement)
                throw error
            }
            return placement.artifact
        }
    }
}

private func withLocalLibraryErrorTranslation<Value>(
    _ operation: () throws -> Value
) throws -> Value {
    do {
        return try operation()
    } catch let error as LocalLibraryError {
        throw error
    } catch let error as DatabaseError {
        switch error.resultCode {
        case .SQLITE_CORRUPT, .SQLITE_NOTADB:
            throw LocalLibraryError.corruptLibrary(diagnosticID: UUID())
        case .SQLITE_FULL:
            throw LocalLibraryError.insufficientDiskSpace
        default:
            throw LocalLibraryError.unavailable
        }
    } catch {
        if isOutOfSpace(error) {
            throw LocalLibraryError.insufficientDiskSpace
        }
        throw LocalLibraryError.unavailable
    }
}

private func isOutOfSpace(_ error: Error) -> Bool {
    let error = error as NSError
    if error.domain == NSCocoaErrorDomain,
       error.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
    {
        return true
    }
    if error.domain == NSPOSIXErrorDomain,
       error.code == POSIXError.Code.ENOSPC.rawValue
    {
        return true
    }
    guard let underlyingError = error.userInfo[NSUnderlyingErrorKey] as? Error
    else {
        return false
    }
    return isOutOfSpace(underlyingError)
}
