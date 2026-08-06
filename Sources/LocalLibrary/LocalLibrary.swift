import Foundation
import GRDB
import KnowledgeCore

public actor LocalLibrary {
    private let database: LibraryDatabase
    private let managedArtifacts: ManagedArtifacts
    private let publicationCoordinator: PublicationCoordinator
    private let checkpointArtifactFaultInjector:
        CheckpointArtifactFaultInjector

    private init(
        database: LibraryDatabase,
        managedArtifacts: ManagedArtifacts,
        faultInjector: PublicationFaultInjector,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector
    ) {
        self.database = database
        self.managedArtifacts = managedArtifacts
        publicationCoordinator = PublicationCoordinator(
            database: database,
            managedArtifacts: managedArtifacts,
            faultInjector: faultInjector
        )
        self.checkpointArtifactFaultInjector = checkpointArtifactFaultInjector
    }

    public static func open(at root: URL) async throws -> LocalLibrary {
        try open(
            at: root,
            faultInjector: .none,
            checkpointArtifactFaultInjector: .none
        )
    }

    package static func describeWebPackage(
        at packageURL: URL
    ) throws -> SourceArtifactDescriptor {
        try withLocalLibraryErrorTranslation {
            guard packageURL.isFileURL,
                  FileManager.default.fileExists(atPath: packageURL.path)
            else {
                throw LocalLibraryError.artifactMissing
            }
            let values = try packageURL.resourceValues(forKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ])
            guard values.isDirectory == true,
                  values.isSymbolicLink != true
            else {
                throw LocalLibraryError.artifactMissing
            }
            let verification = try ManagedArtifactPayload
                .verifyAndSynchronize(
                    payload: packageURL,
                    isDirectory: true
                )
            guard verification.byteCount > 0 else {
                throw LocalLibraryError.artifactMissing
            }
            return SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: verification.byteCount,
                contentHash: verification.contentHash
            )
        }
    }

    static func openForTesting(
        at root: URL,
        faultInjector: PublicationFaultInjector = .none,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector = .none
    ) async throws -> LocalLibrary {
        try open(
            at: root,
            faultInjector: faultInjector,
            checkpointArtifactFaultInjector: checkpointArtifactFaultInjector
        )
    }

    private static func open(
        at root: URL,
        faultInjector: PublicationFaultInjector,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector
    ) throws -> LocalLibrary {
        try withLocalLibraryErrorTranslation {
            try FileManager.default.createDirectory(
                at: root,
                withIntermediateDirectories: true
            )
            let database = try LibraryDatabase(
                url: root.appending(path: "library.sqlite")
            )
            let managedArtifacts = try ManagedArtifacts(
                root: root,
                checkpointArtifactFaultInjector:
                    checkpointArtifactFaultInjector
            )
            try PublicationRecovery(
                database: database,
                managedArtifacts: managedArtifacts
            ).run()
            for cleanup in try database.abandonedStagedArtifactCleanups()
            {
                try managedArtifacts.removeAbandonedStagedArtifact(cleanup)
            }
            try managedArtifacts.removeUnownedStaging(
                ownedPaths: database.ownedStagingPaths()
            )
            try managedArtifacts.removeUnownedCheckpoints(
                ownedPaths: database.ownedCheckpointPaths()
            )
            return LocalLibrary(
                database: database,
                managedArtifacts: managedArtifacts,
                faultInjector: faultInjector,
                checkpointArtifactFaultInjector:
                    checkpointArtifactFaultInjector
            )
        }
    }

    public func accept(
        _ source: OriginalSource
    ) async throws -> ImportWorkspace {
        try withLocalLibraryErrorTranslation {
            _ = try SourceColumns.encode(source)
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
                    try rethrow(
                        error,
                        afterBestEffortRemovalOf: placement
                    )
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

    package func retainedImports() throws -> [DurableImportSnapshot] {
        try withLocalLibraryErrorTranslation {
            try database.retainedImports()
        }
    }

    package func claimNextRunnable() throws -> DurableQueueClaim? {
        try withLocalLibraryErrorTranslation {
            try database.claimNextRunnable()
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

    public func sourceDocument(
        id: SourceDocumentID
    ) async throws -> LocatedSourceDocument? {
        try withLocalLibraryErrorTranslation {
            guard let stored = try database.visibleSourceDocument(id: id)
            else {
                return nil
            }
            do {
                let verifiedDescriptor = try managedArtifacts
                    .verifyFinalArtifact(
                        documentID: stored.documentID,
                        descriptor: stored.descriptor,
                        managedRelativePath: stored.managedRelativePath
                    )
                return LocatedSourceDocument(
                    document: SourceDocument(
                        content: stored.content,
                        artifact: verifiedDescriptor
                    ),
                    location: stored.location
                )
            } catch {
                guard isFinalArtifactCorruption(error) else {
                    throw error
                }
                throw LocalLibraryError.corruptLibrary(diagnosticID: UUID())
            }
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
                try rethrow(
                    error,
                    afterBestEffortRemovalOf: placement
                )
            }
            return placement.artifact
        }
    }

    package func checkpoint(
        taskID: ImportTaskID,
        update: CheckpointUpdate
    ) throws -> DurableImportSnapshot {
        try withLocalLibraryErrorTranslation {
            try database.checkpoint(taskID: taskID, update: update)
        }
    }

    package func replaceCheckpointArtifact(
        packageURL: URL,
        taskID: ImportTaskID,
        update: CheckpointUpdate
    ) throws -> CheckpointArtifactReplacement {
        try withLocalLibraryErrorTranslation {
            let placement = try managedArtifacts.copyCheckpointPackage(
                at: packageURL,
                for: taskID
            )
            let mutation: CheckpointArtifactMutation
            do {
                try checkpointArtifactFaultInjector.hit(
                    .afterNewCopyBeforeDatabaseMutation
                )
                mutation = try database.replaceCheckpointArtifact(
                    taskID: taskID,
                    placement: placement,
                    update: update,
                    faultInjector: checkpointArtifactFaultInjector
                )
            } catch {
                try? managedArtifacts.removeCheckpointArtifact(
                    CheckpointArtifactCleanup(placement: placement)
                )
                throw error
            }
            try checkpointArtifactFaultInjector.hit(
                .afterDatabaseCommitBeforeOldRemoval
            )
            if let oldCleanup = mutation.oldCleanup {
                try managedArtifacts.removeCheckpointArtifact(oldCleanup)
            }
            return mutation.replacement
        }
    }

    package func loadCheckpointArtifact(
        _ artifact: ManagedCheckpointArtifact,
        taskID: ImportTaskID
    ) throws -> VerifiedCheckpointPackage {
        try withLocalLibraryErrorTranslation {
            let placement = try database.ownedCheckpointArtifactPlacement(
                taskID: taskID,
                artifact: artifact
            )
            return try managedArtifacts.loadCheckpointPackage(placement)
        }
    }

    package func removeCheckpointArtifact(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws -> DurableImportSnapshot {
        let removal = try withLocalLibraryErrorTranslation {
            try database.removeCheckpointArtifact(
                taskID: taskID,
                expectedRevision: expectedRevision
            )
        }
        try withLocalLibraryErrorTranslation {
            try managedArtifacts.removeCheckpointArtifact(removal.cleanup)
        }
        return removal.snapshot
    }

    package func finish(
        taskID: ImportTaskID,
        candidate: PublicationCandidate,
        expectedRevision: UInt64
    ) throws -> PublicationOutcome {
        do {
            return try withLocalLibraryErrorTranslation {
                try publicationCoordinator.finish(
                    taskID: taskID,
                    candidate: candidate,
                    expectedRevision: expectedRevision
                )
            }
        } catch let injected as InjectedPublicationFault {
            throw injected.underlying
        }
    }

    package func abandon(
        taskID: ImportTaskID,
        expectedRevision: UInt64
    ) throws {
        let cleanup = try withLocalLibraryErrorTranslation {
            try database.abandon(
                taskID: taskID,
                expectedRevision: expectedRevision
            )
        }
        if let cleanup {
            try withLocalLibraryErrorTranslation {
                try managedArtifacts.removeAbandonedStagedArtifact(cleanup)
            }
        }
    }

    package func verifyManagedArtifact(
        _ artifact: StagedArtifact,
        taskID: ImportTaskID
    ) throws -> SourceArtifactDescriptor {
        try withLocalLibraryErrorTranslation {
            let placement = try database.ownedStagedArtifactPlacement(
                taskID: taskID,
                artifact: artifact
            )
            return try managedArtifacts.verify(placement)
        }
    }

    package func stagedArtifactCount(
        taskID: ImportTaskID
    ) throws -> Int {
        try withLocalLibraryErrorTranslation {
            try managedArtifacts.stagedArtifactCount(for: taskID)
        }
    }

    package func checkpointArtifactCount(
        taskID: ImportTaskID
    ) throws -> Int {
        try withLocalLibraryErrorTranslation {
            try managedArtifacts.checkpointArtifactCount(for: taskID)
        }
    }

    private func rethrow(
        _ primaryError: Error,
        afterBestEffortRemovalOf placement: StagedArtifactPlacement
    ) throws -> Never {
        try? managedArtifacts.remove(placement)
        throw primaryError
    }
}

func isFinalArtifactCorruption(_ error: Error) -> Bool {
    guard let error = error as? LocalLibraryError else {
        return false
    }
    switch error {
    case .artifactMissing,
         .artifactOwnershipViolation,
         .corruptLibrary:
        return true
    case .unavailable,
         .insufficientDiskSpace,
         .staleRevision,
         .invalidTaskState,
         .checkpointRegression,
         .publicationFailed:
        return false
    }
}

private func withLocalLibraryErrorTranslation<Value>(
    _ operation: () throws -> Value
) throws -> Value {
    do {
        return try operation()
    } catch let error as LocalLibraryError {
        throw error
    } catch let error as InjectedPublicationFault {
        throw error
    } catch is RowDecodingError {
        throw LocalLibraryError.corruptLibrary(diagnosticID: UUID())
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
