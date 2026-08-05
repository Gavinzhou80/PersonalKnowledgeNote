import Darwin
import Foundation
import KnowledgeCore

struct StagedArtifactPlacement: Sendable {
    let artifact: StagedArtifact
    let relativePath: String
}

struct AbandonedStagedArtifactCleanup: Sendable {
    let taskID: ImportTaskID
    let artifactID: UUID
    let payloadRelativePath: String
}

struct PublicationIntent: Equatable, Sendable {
    let taskID: ImportTaskID
    let documentID: SourceDocumentID
    let artifact: StagedArtifact
    let stagedRelativePath: String
    let finalRelativePath: String

    init(
        taskID: ImportTaskID,
        documentID: SourceDocumentID,
        artifact: StagedArtifact,
        stagedRelativePath: String,
        finalRelativePath: String
    ) throws {
        guard stagedRelativePath
            == "Staging/\(taskID.rawValue.uuidString)/\(artifact.rawValue.uuidString)",
              finalRelativePath
                == "Artifacts/\(documentID.rawValue.uuidString)"
        else {
            throw corruptManagedArtifactOwnership()
        }
        self.taskID = taskID
        self.documentID = documentID
        self.artifact = artifact
        self.stagedRelativePath = stagedRelativePath
        self.finalRelativePath = finalRelativePath
    }
}

struct VerifiedPublicationPlacement: Sendable {
    let intent: PublicationIntent
    let descriptor: SourceArtifactDescriptor
}

struct ManagedArtifacts {
    private enum Scope: String {
        case staging = "Staging"
        case artifacts = "Artifacts"
    }

    private let root: URL
    private let stagingRoot: URL
    private let artifactsRoot: URL

    init(root requestedRoot: URL) throws {
        let fileManager = FileManager.default
        let standardizedRoot = requestedRoot.standardizedFileURL
        try fileManager.createDirectory(
            at: standardizedRoot,
            withIntermediateDirectories: true
        )
        let resolvedRoot = standardizedRoot.resolvingSymlinksInPath()
        let requestedStagingRoot = resolvedRoot.appending(
            path: Scope.staging.rawValue,
            directoryHint: .isDirectory
        )
        let requestedArtifactsRoot = resolvedRoot.appending(
            path: Scope.artifacts.rawValue,
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
        guard try !Self.isSymbolicLink(requestedStagingRoot),
              try !Self.isSymbolicLink(requestedArtifactsRoot)
        else {
            throw LocalLibraryError.artifactMissing
        }
        let resolvedStagingRoot = requestedStagingRoot
            .resolvingSymlinksInPath()
        let resolvedArtifactsRoot = requestedArtifactsRoot
            .resolvingSymlinksInPath()
        guard resolvedStagingRoot == requestedStagingRoot.standardizedFileURL,
              resolvedArtifactsRoot
                == requestedArtifactsRoot.standardizedFileURL,
              resolvedStagingRoot != resolvedArtifactsRoot,
              Self.isStrictDescendant(
            resolvedStagingRoot,
            of: resolvedRoot
        ), Self.isStrictDescendant(
            resolvedArtifactsRoot,
            of: resolvedRoot
        ) else {
            throw LocalLibraryError.artifactMissing
        }

        root = resolvedRoot
        stagingRoot = resolvedStagingRoot
        artifactsRoot = resolvedArtifactsRoot
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

    func finalRelativePath(documentID: SourceDocumentID) -> String {
        "Artifacts/\(documentID.rawValue.uuidString)"
    }

    func moveToFinal(
        stagedRelativePath: String,
        finalRelativePath: String
    ) throws {
        let staged = try resolve(
            relativePath: stagedRelativePath,
            expectedScope: .staging
        )
        let final = try resolve(
            relativePath: finalRelativePath,
            expectedScope: .artifacts
        )
        let fileManager = FileManager.default
        let stagedExists = fileManager.fileExists(atPath: staged.path)
        let finalExists = fileManager.fileExists(atPath: final.path)
        let sourceParent = staged.deletingLastPathComponent()
        let destinationParent = final.deletingLastPathComponent()

        if finalExists {
            guard !stagedExists else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
            try ManagedArtifactPayload.synchronizeDirectory(sourceParent)
            try ManagedArtifactPayload.synchronizeDirectory(destinationParent)
            return
        }
        guard stagedExists else {
            throw LocalLibraryError.artifactMissing
        }

        try fileManager.moveItem(at: staged, to: final)
        try ManagedArtifactPayload.synchronizeDirectory(sourceParent)
        try ManagedArtifactPayload.synchronizeDirectory(destinationParent)
    }

    func moveToFinal(
        _ intent: PublicationIntent
    ) throws -> VerifiedPublicationPlacement {
        let staged = try resolve(
            relativePath: intent.stagedRelativePath,
            expectedScope: .staging
        )
        let final = try resolve(
            relativePath: intent.finalRelativePath,
            expectedScope: .artifacts
        )
        let fileManager = FileManager.default
        let stagedExists = fileManager.fileExists(atPath: staged.path)
        let finalExists = fileManager.fileExists(atPath: final.path)

        if finalExists {
            guard !stagedExists else {
                throw LocalLibraryError.artifactOwnershipViolation
            }
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

        guard stagedExists else {
            throw LocalLibraryError.artifactMissing
        }
        _ = try verify(StagedArtifactPlacement(
            artifact: intent.artifact,
            relativePath: intent.stagedRelativePath
        ))
        try moveToFinal(
            stagedRelativePath: intent.stagedRelativePath,
            finalRelativePath: intent.finalRelativePath
        )
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

    func verifyStagedArtifact(
        _ intent: PublicationIntent
    ) throws -> SourceArtifactDescriptor {
        try verify(StagedArtifactPlacement(
            artifact: intent.artifact,
            relativePath: intent.stagedRelativePath
        ))
    }

    func verifyFinalArtifact(
        documentID: SourceDocumentID,
        descriptor: SourceArtifactDescriptor,
        managedRelativePath: String
    ) throws -> SourceArtifactDescriptor {
        let expectedPath = finalRelativePath(documentID: documentID)
        guard managedRelativePath == expectedPath else {
            throw corruptManagedArtifactOwnership()
        }
        let container = try resolve(
            relativePath: managedRelativePath,
            expectedScope: .artifacts
        )
        return try verifyPayload(
            in: container,
            expectedDescriptor: descriptor
        )
    }

    func exists(relativePath: String) throws -> Bool {
        let managedURL = try resolve(relativePath: relativePath)
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
        try remove(relativePath: placement.relativePath)
    }

    func remove(relativePath: String) throws {
        let managedURL = try resolve(relativePath: relativePath)
        guard FileManager.default.fileExists(atPath: managedURL.path) else {
            return
        }
        let parent = managedURL.deletingLastPathComponent()
        try FileManager.default.removeItem(at: managedURL)
        try ManagedArtifactPayload.synchronizeDirectory(parent)
    }

    func removeAbandonedStagedArtifact(
        _ cleanup: AbandonedStagedArtifactCleanup
    ) throws {
        let components = cleanup.payloadRelativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard components == [
            Scope.staging.rawValue,
            cleanup.taskID.rawValue.uuidString,
            cleanup.artifactID.uuidString,
            "payload",
        ] else {
            throw corruptManagedArtifactOwnership()
        }

        let containerRelativePath = components
            .dropLast()
            .joined(separator: "/")
        let container: URL
        do {
            container = try resolve(
                relativePath: containerRelativePath,
                expectedScope: .staging
            )
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
        let container = try resolve(
            relativePath: placement.relativePath,
            expectedScope: .staging
        )
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
        let relativePath = "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        let requestedContainer = try resolve(
            relativePath: relativePath,
            expectedScope: .staging
        )
        try FileManager.default.createDirectory(
            at: requestedContainer,
            withIntermediateDirectories: true
        )
        let container = try resolve(
            relativePath: relativePath,
            expectedScope: .staging
        )
        let payload = container.appending(path: "payload")

        var completed = false
        defer {
            if !completed {
                try? remove(relativePath: relativePath)
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
        return StagedArtifactPlacement(
            artifact: StagedArtifact(
                rawValue: artifactID,
                descriptor: descriptor
            ),
            relativePath: relativePath
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

    private func resolve(
        relativePath: String,
        expectedScope: Scope? = nil
    ) throws -> URL {
        guard !relativePath.isEmpty,
              !relativePath.hasPrefix("/")
        else {
            throw LocalLibraryError.artifactMissing
        }
        let components = relativePath
            .split(separator: "/", omittingEmptySubsequences: false)
            .map(String.init)
        guard !components.contains(where: {
            $0.isEmpty || $0 == "." || $0 == ".."
        }), let scope = Scope(rawValue: components[0]),
              expectedScope == nil || expectedScope == scope
        else {
            throw LocalLibraryError.artifactMissing
        }

        switch scope {
        case .staging:
            guard components.count == 3,
                  UUID(uuidString: components[1]) != nil,
                  UUID(uuidString: components[2]) != nil
            else {
                throw LocalLibraryError.artifactMissing
            }
        case .artifacts:
            guard components.count == 2,
                  UUID(uuidString: components[1]) != nil
            else {
                throw LocalLibraryError.artifactMissing
            }
        }

        let scopeRoot = scope == .staging ? stagingRoot : artifactsRoot
        try rejectSymbolicLinks(
            from: scopeRoot,
            components: Array(components.dropFirst())
        )
        let standardized = components.dropFirst().reduce(scopeRoot) {
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
        if FileManager.default.fileExists(atPath: resolved.path) {
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
