import Darwin
import Foundation
import KnowledgeCore

enum CheckpointArtifactFaultPoint: Equatable, Sendable {
    case afterNewCopyBeforeDatabaseMutation
    case afterCheckpointArtifactRowMutationBeforeTaskUpdate
    case afterDatabaseCommitBeforeOldRemoval
}

struct CheckpointArtifactFaultInjector: Sendable {
    private let injection:
        @Sendable (CheckpointArtifactFaultPoint) throws -> Void

    init(
        _ injection: @escaping @Sendable (
            CheckpointArtifactFaultPoint
        ) throws -> Void
    ) {
        self.injection = injection
    }

    func hit(_ point: CheckpointArtifactFaultPoint) throws {
        try injection(point)
    }

    static let none = CheckpointArtifactFaultInjector { _ in }
}

struct CheckpointArtifactPlacement: Sendable {
    let taskID: ImportTaskID
    let artifact: ManagedCheckpointArtifact
    let path: ManagedArtifactPath

    var relativePath: String { path.relativePath }

    init(
        taskID: ImportTaskID,
        artifact: ManagedCheckpointArtifact,
        path: ManagedArtifactPath
    ) throws {
        guard artifact.descriptor.byteCount > 0,
              !artifact.descriptor.contentHash.isEmpty,
              path == .checkpoint(
                taskID: taskID,
                artifactID: artifact.rawValue
              )
        else {
            throw corruptManagedArtifactOwnership()
        }
        self.taskID = taskID
        self.artifact = artifact
        self.path = path
    }

    init(
        taskID: ImportTaskID,
        artifact: ManagedCheckpointArtifact,
        relativePath: String
    ) throws {
        try self.init(
            taskID: taskID,
            artifact: artifact,
            path: ManagedArtifactPath.parse(relativePath)
        )
    }
}

struct CheckpointArtifactCleanup: Sendable {
    let placement: CheckpointArtifactPlacement
}

struct StagedArtifactPlacement: Sendable {
    let artifact: StagedArtifact
    let path: ManagedArtifactPath

    var relativePath: String {
        path.relativePath
    }

    init(
        artifact: StagedArtifact,
        path: ManagedArtifactPath
    ) throws {
        guard case .staging(_, artifact.rawValue) = path else {
            throw corruptManagedArtifactOwnership()
        }
        self.artifact = artifact
        self.path = path
    }

    init(
        artifact: StagedArtifact,
        relativePath: String
    ) throws {
        try self.init(
            artifact: artifact,
            path: ManagedArtifactPath.parse(relativePath)
        )
    }
}

struct AbandonedStagedArtifactCleanup: Sendable {
    let path: ManagedArtifactPath
}

struct PublicationIntent: Equatable, Sendable {
    let taskID: ImportTaskID
    let documentID: SourceDocumentID
    let artifact: StagedArtifact
    let stagedPath: ManagedArtifactPath
    let finalPath: ManagedArtifactPath

    var stagedRelativePath: String {
        stagedPath.relativePath
    }

    var finalRelativePath: String {
        finalPath.relativePath
    }

    init(
        taskID: ImportTaskID,
        documentID: SourceDocumentID,
        artifact: StagedArtifact,
        stagedPath: ManagedArtifactPath,
        finalPath: ManagedArtifactPath
    ) throws {
        guard stagedPath == .staging(
            taskID: taskID,
            artifactID: artifact.rawValue
        ), finalPath == .artifacts(documentID: documentID) else {
            throw corruptManagedArtifactOwnership()
        }
        self.taskID = taskID
        self.documentID = documentID
        self.artifact = artifact
        self.stagedPath = stagedPath
        self.finalPath = finalPath
    }

    init(
        taskID: ImportTaskID,
        documentID: SourceDocumentID,
        artifact: StagedArtifact,
        stagedRelativePath: String,
        finalRelativePath: String
    ) throws {
        try self.init(
            taskID: taskID,
            documentID: documentID,
            artifact: artifact,
            stagedPath: ManagedArtifactPath.parse(stagedRelativePath),
            finalPath: ManagedArtifactPath.parse(finalRelativePath)
        )
    }
}

struct VerifiedPublicationPlacement: Sendable {
    let intent: PublicationIntent
    let descriptor: SourceArtifactDescriptor
}

enum ManagedArtifactStatus: Sendable {
    case absent
    case valid(SourceArtifactDescriptor)
    case invalid

    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }
}

struct ManagedArtifacts {
    private let root: URL
    private let stagingRoot: URL
    private let artifactsRoot: URL
    private let checkpointsRoot: URL
    private let quarantineRoot: URL

    init(root requestedRoot: URL) throws {
        let fileManager = FileManager.default
        let standardizedRoot = requestedRoot.standardizedFileURL
        try fileManager.createDirectory(
            at: standardizedRoot,
            withIntermediateDirectories: true
        )
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let requestedStagingRoot = resolvedRoot.appending(
            path: ManagedArtifactPath.Scope.staging.rawValue,
            directoryHint: .isDirectory
        )
        let requestedArtifactsRoot = resolvedRoot.appending(
            path: ManagedArtifactPath.Scope.artifacts.rawValue,
            directoryHint: .isDirectory
        )
        let requestedCheckpointsRoot = resolvedRoot.appending(
            path: ManagedArtifactPath.Scope.checkpoints.rawValue,
            directoryHint: .isDirectory
        )
        let requestedQuarantineRoot = resolvedRoot.appending(
            path: "Quarantine",
            directoryHint: .isDirectory
        )
        try fileManager.createDirectory(
            at: requestedStagingRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: requestedArtifactsRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: requestedCheckpointsRoot,
            withIntermediateDirectories: true
        )
        try fileManager.createDirectory(
            at: requestedQuarantineRoot,
            withIntermediateDirectories: true
        )
        guard try !Self.isSymbolicLink(requestedStagingRoot),
              try !Self.isSymbolicLink(requestedArtifactsRoot),
              try !Self.isSymbolicLink(requestedCheckpointsRoot),
              try !Self.isSymbolicLink(requestedQuarantineRoot)
        else {
            throw LocalLibraryError.artifactMissing
        }
        let resolvedStagingRoot = requestedStagingRoot
            .resolvingSymlinksInPath()
        let resolvedArtifactsRoot = requestedArtifactsRoot
            .resolvingSymlinksInPath()
        let resolvedCheckpointsRoot = requestedCheckpointsRoot
            .resolvingSymlinksInPath()
        let resolvedQuarantineRoot = requestedQuarantineRoot
            .resolvingSymlinksInPath()
        guard resolvedStagingRoot == requestedStagingRoot.standardizedFileURL,
              resolvedArtifactsRoot
                == requestedArtifactsRoot.standardizedFileURL,
              resolvedCheckpointsRoot
                == requestedCheckpointsRoot.standardizedFileURL,
              resolvedQuarantineRoot
                == requestedQuarantineRoot.standardizedFileURL,
              resolvedStagingRoot != resolvedArtifactsRoot,
              resolvedStagingRoot != resolvedCheckpointsRoot,
              resolvedStagingRoot != resolvedQuarantineRoot,
              resolvedArtifactsRoot != resolvedCheckpointsRoot,
              resolvedArtifactsRoot != resolvedQuarantineRoot,
              resolvedCheckpointsRoot != resolvedQuarantineRoot,
              Self.isStrictDescendant(
            resolvedStagingRoot,
            of: resolvedRoot
        ), Self.isStrictDescendant(
            resolvedArtifactsRoot,
            of: resolvedRoot
        ), Self.isStrictDescendant(
            resolvedCheckpointsRoot,
            of: resolvedRoot
        ), Self.isStrictDescendant(
            resolvedQuarantineRoot,
            of: resolvedRoot
        ) else {
            throw LocalLibraryError.artifactMissing
        }

        root = resolvedRoot
        stagingRoot = resolvedStagingRoot
        artifactsRoot = resolvedArtifactsRoot
        checkpointsRoot = resolvedCheckpointsRoot
        quarantineRoot = resolvedQuarantineRoot
        try ManagedArtifactPayload.synchronizeDirectory(resolvedRoot)
    }

    func stage(
        _ input: SourceArtifactInput,
        for taskID: ImportTaskID
    ) throws -> StagedArtifactPlacement {
        switch input {
        case .file(let source, let descriptor):
            guard descriptor.kind == .pdf else {
                throw LocalLibraryError.artifactMissing
            }
            return try copyToStaging(
                source: source,
                kind: .pdf,
                expectsDirectory: false,
                taskID: taskID
            )
        case .package(let source, let descriptor):
            guard descriptor.kind == .webPackage else {
                throw LocalLibraryError.artifactMissing
            }
            return try copyToStaging(
                source: source,
                kind: .webPackage,
                expectsDirectory: true,
                taskID: taskID
            )
        }
    }

    func capturePDF(
        at source: URL,
        for taskID: ImportTaskID
    ) throws -> StagedArtifactPlacement {
        try copyToStaging(
            source: source,
            kind: .pdf,
            expectsDirectory: false,
            taskID: taskID
        )
    }

    func copyCheckpointPackage(
        at source: URL,
        for taskID: ImportTaskID
    ) throws -> CheckpointArtifactPlacement {
        let verifiedSource = try validateSource(
            source,
            expectsDirectory: true
        )
        _ = try ManagedArtifactPayload.verifyCheckpointPackage(
            payload: verifiedSource,
            loadFiles: false
        )
        let artifactID = UUID()
        let path = ManagedArtifactPath.checkpoint(
            taskID: taskID,
            artifactID: artifactID
        )
        let container = try resolve(path)
        let taskDirectory = container.deletingLastPathComponent()
        guard !FileManager.default.fileExists(atPath: container.path) else {
            throw LocalLibraryError.artifactOwnershipViolation
        }
        try FileManager.default.createDirectory(
            at: taskDirectory,
            withIntermediateDirectories: true
        )

        var completed = false
        defer {
            if !completed {
                try? removeCheckpointPath(path)
            }
        }
        try FileManager.default.copyItem(at: verifiedSource, to: container)
        let verification = try ManagedArtifactPayload.verifyCheckpointPackage(
            payload: container,
            loadFiles: false
        )
        try ManagedArtifactPayload.synchronizeDirectory(taskDirectory)
        try ManagedArtifactPayload.synchronizeDirectory(checkpointsRoot)
        completed = true
        return try CheckpointArtifactPlacement(
            taskID: taskID,
            artifact: ManagedCheckpointArtifact(
                rawValue: artifactID,
                descriptor: verification.descriptor
            ),
            path: path
        )
    }

    func loadCheckpointPackage(
        _ placement: CheckpointArtifactPlacement
    ) throws -> VerifiedCheckpointPackage {
        let container = try resolve(placement.path)
        guard FileManager.default.fileExists(atPath: container.path) else {
            throw LocalLibraryError.artifactMissing
        }
        let verification = try ManagedArtifactPayload.verifyCheckpointPackage(
            payload: container,
            loadFiles: true
        )
        guard verification.descriptor == placement.artifact.descriptor else {
            throw LocalLibraryError.artifactMissing
        }
        return VerifiedCheckpointPackage(
            descriptor: verification.descriptor,
            files: verification.files
        )
    }

    func removeCheckpointArtifact(
        _ cleanup: CheckpointArtifactCleanup
    ) throws {
        try removeCheckpointPath(cleanup.placement.path)
    }

    func checkpointArtifactCount(for taskID: ImportTaskID) throws -> Int {
        let taskComponent = taskID.rawValue.uuidString
        try rejectSymbolicLinks(
            from: checkpointsRoot,
            components: [taskComponent]
        )
        let taskDirectory = checkpointsRoot
            .appending(path: taskComponent)
            .standardizedFileURL
        guard taskDirectory.resolvingSymlinksInPath() == taskDirectory else {
            throw LocalLibraryError.artifactMissing
        }
        guard FileManager.default.fileExists(atPath: taskDirectory.path) else {
            return 0
        }
        let entries = try FileManager.default.contentsOfDirectory(
            at: taskDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        for entry in entries {
            guard let artifactID = UUID(
                uuidString: entry.lastPathComponent
            ), artifactID.uuidString == entry.lastPathComponent,
                  try !Self.isSymbolicLink(entry),
                  entry.resolvingSymlinksInPath()
                    == entry.standardizedFileURL,
                  try entry.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ).isDirectory == true
            else {
                throw LocalLibraryError.artifactMissing
            }
        }
        return entries.count
    }

    func removeUnownedCheckpoints(
        ownedPaths: Set<ManagedArtifactPath>
    ) throws {
        for path in ownedPaths {
            guard case .checkpoint = path else {
                throw corruptManagedArtifactOwnership()
            }
        }
        let fileManager = FileManager.default
        let taskDirectories = try fileManager.contentsOfDirectory(
            at: checkpointsRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        for taskDirectory in taskDirectories {
            guard let taskUUID = UUID(
                uuidString: taskDirectory.lastPathComponent
            ), taskUUID.uuidString == taskDirectory.lastPathComponent,
                  try !Self.isSymbolicLink(taskDirectory),
                  taskDirectory.resolvingSymlinksInPath()
                    == taskDirectory.standardizedFileURL,
                  try taskDirectory.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ).isDirectory == true
            else {
                throw corruptManagedArtifactOwnership()
            }
            for container in try fileManager.contentsOfDirectory(
                at: taskDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            ) {
                guard let artifactID = UUID(
                    uuidString: container.lastPathComponent
                ), artifactID.uuidString == container.lastPathComponent,
                      try !Self.isSymbolicLink(container),
                      container.resolvingSymlinksInPath()
                        == container.standardizedFileURL,
                      try container.resourceValues(
                        forKeys: [.isDirectoryKey]
                      ).isDirectory == true
                else {
                    throw corruptManagedArtifactOwnership()
                }
                let path = ManagedArtifactPath.checkpoint(
                    taskID: ImportTaskID(taskUUID),
                    artifactID: artifactID
                )
                guard !ownedPaths.contains(path) else {
                    continue
                }
                do {
                    try fileManager.removeItem(at: container)
                    try ManagedArtifactPayload.synchronizeDirectory(
                        taskDirectory
                    )
                } catch {
                    continue
                }
            }
            let remaining = try fileManager.contentsOfDirectory(
                at: taskDirectory,
                includingPropertiesForKeys: nil
            )
            if remaining.isEmpty {
                do {
                    try fileManager.removeItem(at: taskDirectory)
                    try ManagedArtifactPayload.synchronizeDirectory(
                        checkpointsRoot
                    )
                } catch {
                    continue
                }
            }
        }
        try? ManagedArtifactPayload.synchronizeDirectory(checkpointsRoot)
    }

    func finalRelativePath(documentID: SourceDocumentID) -> String {
        ManagedArtifactPath.artifacts(
            documentID: documentID
        ).relativePath
    }

    func moveToFinal(
        _ intent: PublicationIntent
    ) throws -> VerifiedPublicationPlacement {
        try moveToFinalAtomically(intent)
        return try verifyFinalPublication(intent)
    }

    func moveToFinalAtomically(
        _ intent: PublicationIntent
    ) throws {
        let staged = try resolve(intent.stagedPath)
        let final = try resolve(intent.finalPath)
        let fileManager = FileManager.default
        let stagedExists = fileManager.fileExists(atPath: staged.path)
        let finalExists = fileManager.fileExists(atPath: final.path)

        if finalExists {
            guard !stagedExists else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            try synchronizePublicationMoveParents(
                staged: staged,
                final: final
            )
            return
        }

        guard stagedExists else {
            throw LocalLibraryError.artifactMissing
        }
        _ = try verify(StagedArtifactPlacement(
            artifact: intent.artifact,
            path: intent.stagedPath
        ))
        try fileManager.moveItem(at: staged, to: final)
        try synchronizePublicationMoveParents(
            staged: staged,
            final: final
        )
    }

    func verifyFinalPublication(
        _ intent: PublicationIntent
    ) throws -> VerifiedPublicationPlacement {
        let descriptor = try verifyFinalArtifact(
            documentID: intent.documentID,
            descriptor: intent.artifact.descriptor,
            managedRelativePath: intent.finalRelativePath
        )
        return VerifiedPublicationPlacement(
            intent: intent,
            descriptor: descriptor
        )
    }

    func finalArtifactStatus(
        _ intent: PublicationIntent
    ) throws -> ManagedArtifactStatus {
        try artifactStatus(
            path: intent.finalPath,
            descriptor: intent.artifact.descriptor
        )
    }

    func stagedArtifactStatus(
        _ intent: PublicationIntent
    ) throws -> ManagedArtifactStatus {
        try artifactStatus(
            path: intent.stagedPath,
            descriptor: intent.artifact.descriptor
        )
    }

    func quarantineInvalidFinalArtifact(
        _ intent: PublicationIntent
    ) throws {
        let final = try resolveForRecovery(
            intent.finalPath
        )
        guard FileManager.default.fileExists(atPath: final.path) else {
            return
        }
        try rejectSymbolicLinksRecursively(at: final)
        let quarantine = quarantineRoot.appending(
            path: UUID().uuidString
        ).standardizedFileURL
        guard Self.isStrictDescendant(quarantine, of: quarantineRoot),
              quarantine.resolvingSymlinksInPath() == quarantine
        else {
            throw corruptManagedArtifactOwnership()
        }
        try FileManager.default.moveItem(at: final, to: quarantine)
        try ManagedArtifactPayload.synchronizeDirectory(artifactsRoot)
        try ManagedArtifactPayload.synchronizeDirectory(quarantineRoot)
        try ManagedArtifactPayload.synchronizeDirectory(root)
    }

    func removeUnownedStaging(
        ownedPaths: Set<ManagedArtifactPath>
    ) throws {
        for path in ownedPaths {
            guard case .staging = path else {
                throw corruptManagedArtifactOwnership()
            }
        }
        let fileManager = FileManager.default
        let taskDirectories = try fileManager.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        for taskDirectory in taskDirectories {
            guard let taskUUID = UUID(
                uuidString: taskDirectory.lastPathComponent
            ), taskUUID.uuidString == taskDirectory.lastPathComponent,
                  try !Self.isSymbolicLink(taskDirectory),
                  taskDirectory.resolvingSymlinksInPath()
                    == taskDirectory.standardizedFileURL,
                  try taskDirectory.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ).isDirectory == true
            else {
                throw corruptManagedArtifactOwnership()
            }
            let containers = try fileManager.contentsOfDirectory(
                at: taskDirectory,
                includingPropertiesForKeys: [
                    .isDirectoryKey,
                    .isSymbolicLinkKey,
                ]
            )
            for container in containers {
                guard let artifactID = UUID(
                    uuidString: container.lastPathComponent
                ), artifactID.uuidString == container.lastPathComponent,
                      try !Self.isSymbolicLink(container),
                      container.resolvingSymlinksInPath()
                        == container.standardizedFileURL,
                      try container.resourceValues(
                        forKeys: [.isDirectoryKey]
                      ).isDirectory == true
                else {
                    throw corruptManagedArtifactOwnership()
                }
                let path = ManagedArtifactPath.staging(
                    taskID: ImportTaskID(taskUUID),
                    artifactID: artifactID
                )
                guard !ownedPaths.contains(path) else {
                    continue
                }
                do {
                    try fileManager.removeItem(at: container)
                    try ManagedArtifactPayload.synchronizeDirectory(
                        taskDirectory
                    )
                } catch {
                    continue
                }
            }
            let remaining = try fileManager.contentsOfDirectory(
                at: taskDirectory,
                includingPropertiesForKeys: nil
            )
            if remaining.isEmpty {
                do {
                    try fileManager.removeItem(at: taskDirectory)
                    try ManagedArtifactPayload.synchronizeDirectory(
                        stagingRoot
                    )
                } catch {
                    continue
                }
            }
        }
        try? ManagedArtifactPayload.synchronizeDirectory(stagingRoot)
    }

    func verifyStagedArtifact(
        _ intent: PublicationIntent
    ) throws -> SourceArtifactDescriptor {
        try verify(StagedArtifactPlacement(
            artifact: intent.artifact,
            path: intent.stagedPath
        ))
    }

    func verifyFinalArtifact(
        documentID: SourceDocumentID,
        descriptor: SourceArtifactDescriptor,
        managedRelativePath: String
    ) throws -> SourceArtifactDescriptor {
        let path = try ManagedArtifactPath.parse(managedRelativePath)
        guard path == .artifacts(documentID: documentID) else {
            throw corruptManagedArtifactOwnership()
        }
        let container = try resolve(path)
        return try verifyPayload(
            in: container,
            expectedDescriptor: descriptor
        )
    }

    func exists(relativePath: String) throws -> Bool {
        let path: ManagedArtifactPath
        do {
            path = try ManagedArtifactPath.parse(relativePath)
        } catch {
            throw LocalLibraryError.artifactMissing
        }
        return try exists(path)
    }

    func exists(_ path: ManagedArtifactPath) throws -> Bool {
        let managedURL = try resolve(path)
        return FileManager.default.fileExists(atPath: managedURL.path)
    }

    func stagedArtifactCount(for taskID: ImportTaskID) throws -> Int {
        let taskComponent = taskID.rawValue.uuidString
        try rejectSymbolicLinks(
            from: stagingRoot,
            components: [taskComponent]
        )
        let taskDirectory = stagingRoot
            .appending(path: taskComponent)
            .standardizedFileURL
        guard taskDirectory.resolvingSymlinksInPath() == taskDirectory else {
            throw LocalLibraryError.artifactMissing
        }
        guard FileManager.default.fileExists(atPath: taskDirectory.path) else {
            return 0
        }

        let entries = try FileManager.default.contentsOfDirectory(
            at: taskDirectory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        )
        for entry in entries {
            guard UUID(uuidString: entry.lastPathComponent) != nil,
                  try !Self.isSymbolicLink(entry),
                  entry.resolvingSymlinksInPath()
                    == entry.standardizedFileURL,
                  try entry.resourceValues(
                    forKeys: [.isDirectoryKey]
                  ).isDirectory == true
            else {
                throw LocalLibraryError.artifactMissing
            }
        }
        return entries.count
    }

    func remove(_ placement: StagedArtifactPlacement) throws {
        try remove(placement.path)
    }

    func remove(relativePath: String) throws {
        let path: ManagedArtifactPath
        do {
            path = try ManagedArtifactPath.parse(relativePath)
        } catch {
            throw LocalLibraryError.artifactMissing
        }
        try remove(path)
    }

    private func remove(_ path: ManagedArtifactPath) throws {
        let managedURL = try resolve(path)
        guard FileManager.default.fileExists(atPath: managedURL.path) else {
            return
        }
        let parent = managedURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: managedURL)
        try ManagedArtifactPayload.synchronizeDirectory(parent)
    }

    private func removeCheckpointPath(_ path: ManagedArtifactPath) throws {
        guard case .checkpoint = path else {
            throw corruptManagedArtifactOwnership()
        }
        let managedURL = try resolve(path)
        let taskDirectory = managedURL.deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: managedURL.path) else {
            return
        }
        try FileManager.default.removeItem(at: managedURL)
        try ManagedArtifactPayload.synchronizeDirectory(taskDirectory)
        let remaining = try FileManager.default.contentsOfDirectory(
            at: taskDirectory,
            includingPropertiesForKeys: nil
        )
        if remaining.isEmpty {
            try FileManager.default.removeItem(at: taskDirectory)
            try ManagedArtifactPayload.synchronizeDirectory(checkpointsRoot)
        }
    }

    func removeAbandonedStagedArtifact(
        _ cleanup: AbandonedStagedArtifactCleanup
    ) throws {
        guard case .staging = cleanup.path else {
            throw corruptManagedArtifactOwnership()
        }
        let container: URL
        do {
            container = try resolve(cleanup.path)
        } catch LocalLibraryError.artifactMissing {
            throw corruptManagedArtifactOwnership()
        }

        guard FileManager.default.fileExists(atPath: container.path) else {
            return
        }
        let parent = container.deletingLastPathComponent()
        do {
            try FileManager.default.removeItem(at: container)
            try ManagedArtifactPayload.synchronizeDirectory(parent)
        } catch {
            return
        }
    }

    func verify(
        _ placement: StagedArtifactPlacement
    ) throws -> SourceArtifactDescriptor {
        let container = try resolve(placement.path)
        return try verifyPayload(
            in: container,
            expectedDescriptor: placement.artifact.descriptor
        )
    }

    private func verifyPayload(
        in container: URL,
        expectedDescriptor: SourceArtifactDescriptor
    ) throws -> SourceArtifactDescriptor {
        guard FileManager.default.fileExists(atPath: container.path) else {
            throw LocalLibraryError.artifactMissing
        }
        let payload = container.appending(path: "payload")
        guard FileManager.default.fileExists(atPath: payload.path) else {
            throw LocalLibraryError.artifactMissing
        }
        let expectedKind = expectedDescriptor.kind
        let values = try payload.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true,
              (expectedKind == .webPackage && values.isDirectory == true)
                || (expectedKind == .pdf && values.isRegularFile == true)
        else {
            throw LocalLibraryError.artifactMissing
        }
        let verification = try ManagedArtifactPayload.verifyAndSynchronize(
            payload: payload,
            isDirectory: expectedKind == .webPackage
        )
        guard verification.byteCount > 0 else {
            throw LocalLibraryError.artifactMissing
        }
        let verifiedDescriptor = SourceArtifactDescriptor(
            kind: expectedKind,
            byteCount: verification.byteCount,
            contentHash: verification.contentHash
        )
        guard verifiedDescriptor == expectedDescriptor else {
            throw LocalLibraryError.artifactMissing
        }
        return verifiedDescriptor
    }

    private func artifactStatus(
        path: ManagedArtifactPath,
        descriptor: SourceArtifactDescriptor
    ) throws -> ManagedArtifactStatus {
        let container = try resolveForRecovery(path)
        guard FileManager.default.fileExists(atPath: container.path) else {
            return .absent
        }
        try rejectSymbolicLinksRecursively(at: container)
        do {
            return .valid(try verifyPayload(
                in: container,
                expectedDescriptor: descriptor
            ))
        } catch LocalLibraryError.artifactMissing {
            return .invalid
        }
    }

    private func resolveForRecovery(
        _ path: ManagedArtifactPath
    ) throws -> URL {
        do {
            return try resolve(path)
        } catch LocalLibraryError.artifactMissing {
            throw corruptManagedArtifactOwnership()
        }
    }

    private func rejectSymbolicLinksRecursively(at url: URL) throws {
        guard try !Self.isSymbolicLink(url) else {
            throw corruptManagedArtifactOwnership()
        }
        let values = try url.resourceValues(forKeys: [.isDirectoryKey])
        guard values.isDirectory == true else {
            return
        }
        for child in try FileManager.default.contentsOfDirectory(
            at: url,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isSymbolicLinkKey,
            ]
        ) {
            try rejectSymbolicLinksRecursively(at: child)
        }
    }

    private func synchronizePublicationMoveParents(
        staged: URL,
        final: URL
    ) throws {
        try synchronizeNearestExistingDirectory(
            staged.deletingLastPathComponent(),
            within: stagingRoot
        )
        try synchronizeNearestExistingDirectory(
            final.deletingLastPathComponent(),
            within: artifactsRoot
        )
    }

    private func synchronizeNearestExistingDirectory(
        _ requestedDirectory: URL,
        within scopeRoot: URL
    ) throws {
        var directory = requestedDirectory.standardizedFileURL
        guard directory == scopeRoot
                || Self.isStrictDescendant(directory, of: scopeRoot)
        else {
            throw corruptManagedArtifactOwnership()
        }
        while !FileManager.default.fileExists(atPath: directory.path) {
            guard directory != scopeRoot else {
                throw LocalLibraryError.artifactMissing
            }
            directory = directory.deletingLastPathComponent()
        }
        try ManagedArtifactPayload.synchronizeDirectory(directory)
    }

    private func copyToStaging(
        source: URL,
        kind: SourceArtifactKind,
        expectsDirectory: Bool,
        taskID: ImportTaskID
    ) throws -> StagedArtifactPlacement {
        let verifiedSource = try validateSource(
            source,
            expectsDirectory: expectsDirectory
        )
        let artifactID = UUID()
        let path = ManagedArtifactPath.staging(
            taskID: taskID,
            artifactID: artifactID
        )
        let requestedContainer = try resolve(path)
        try FileManager.default.createDirectory(
            at: requestedContainer,
            withIntermediateDirectories: true
        )
        let container = try resolve(path)
        let payload = container.appending(path: "payload")

        var completed = false
        defer {
            if !completed {
                try? remove(path)
            }
        }

        try FileManager.default.copyItem(at: verifiedSource, to: payload)
        let verification = try ManagedArtifactPayload.verifyAndSynchronize(
            payload: payload,
            isDirectory: expectsDirectory
        )
        guard verification.byteCount > 0 else {
            throw LocalLibraryError.artifactMissing
        }
        let taskDirectory = container.deletingLastPathComponent()
        try ManagedArtifactPayload.synchronizeDirectory(container)
        try ManagedArtifactPayload.synchronizeDirectory(taskDirectory)
        try ManagedArtifactPayload.synchronizeDirectory(stagingRoot)

        let descriptor = SourceArtifactDescriptor(
            kind: kind,
            byteCount: verification.byteCount,
            contentHash: verification.contentHash
        )
        completed = true
        return try StagedArtifactPlacement(
            artifact: StagedArtifact(
                rawValue: artifactID,
                descriptor: descriptor
            ),
            path: path
        )
    }

    private func validateSource(
        _ source: URL,
        expectsDirectory: Bool
    ) throws -> URL {
        guard source.isFileURL,
              FileManager.default.fileExists(atPath: source.path)
        else {
            throw LocalLibraryError.artifactMissing
        }
        let values = try source.resourceValues(forKeys: [
            .isDirectoryKey,
            .isRegularFileKey,
            .isSymbolicLinkKey,
        ])
        guard values.isSymbolicLink != true else {
            throw LocalLibraryError.artifactMissing
        }
        if expectsDirectory {
            guard values.isDirectory == true else {
                throw LocalLibraryError.artifactMissing
            }
        } else {
            guard values.isRegularFile == true else {
                throw LocalLibraryError.artifactMissing
            }
        }

        let resolvedSource = source.standardizedFileURL
            .resolvingSymlinksInPath()
        guard !Self.pathsOverlap(resolvedSource, root) else {
            throw LocalLibraryError.artifactMissing
        }
        return resolvedSource
    }

    private func resolve(_ path: ManagedArtifactPath) throws -> URL {
        let scopeRoot: URL
        switch path.scope {
        case .staging:
            scopeRoot = stagingRoot
        case .artifacts:
            scopeRoot = artifactsRoot
        case .checkpoints:
            scopeRoot = checkpointsRoot
        }
        let components = path.identityComponents
        try rejectSymbolicLinks(
            from: scopeRoot,
            components: components
        )
        let standardized = components.reduce(scopeRoot) {
            $0.appending(path: $1)
        }.standardizedFileURL
        guard Self.isStrictDescendant(standardized, of: scopeRoot) else {
            throw LocalLibraryError.artifactMissing
        }
        let resolved = standardized.resolvingSymlinksInPath()
        guard resolved == standardized,
              Self.isStrictDescendant(resolved, of: scopeRoot)
        else {
            throw LocalLibraryError.artifactMissing
        }
        try rejectSymbolicLinks(from: scopeRoot, components: [])
        let payload = resolved.appending(path: "payload")
        if path.scope != .checkpoints,
           FileManager.default.fileExists(atPath: resolved.path) {
            guard try !Self.isSymbolicLink(payload),
                  payload.resolvingSymlinksInPath()
                    == payload.standardizedFileURL
            else {
                throw LocalLibraryError.artifactMissing
            }
        }
        return resolved
    }

    private func rejectSymbolicLinks(
        from scopeRoot: URL,
        components: [String]
    ) throws {
        var current = scopeRoot
        guard try !Self.isSymbolicLink(current) else {
            throw LocalLibraryError.artifactMissing
        }
        for component in components {
            current.append(path: component)
            guard try !Self.isSymbolicLink(current) else {
                throw LocalLibraryError.artifactMissing
            }
        }
    }

    private static func isSymbolicLink(_ url: URL) throws -> Bool {
        var information = stat()
        guard lstat(url.path, &information) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
        return information.st_mode & S_IFMT == S_IFLNK
    }

    private static func pathsOverlap(_ first: URL, _ second: URL) -> Bool {
        first == second
            || isStrictDescendant(first, of: second)
            || isStrictDescendant(second, of: first)
    }

    private static func isStrictDescendant(
        _ candidate: URL,
        of parent: URL
    ) -> Bool {
        let candidateComponents = candidate.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        guard candidateComponents.count > parentComponents.count else {
            return false
        }
        return candidateComponents.prefix(parentComponents.count)
            .elementsEqual(parentComponents)
    }
}

private func corruptManagedArtifactOwnership() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}
