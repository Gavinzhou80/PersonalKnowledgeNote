import CryptoKit
import Darwin
import Foundation
import KnowledgeCore

struct StagedArtifactPlacement {
    let artifact: StagedArtifact
    let relativePath: String
}

struct ManagedArtifacts {
    private let root: URL
    private let stagingRoot: URL
    private let artifactsRoot: URL

    init(root: URL) throws {
        self.root = root
        stagingRoot = root.appending(path: "Staging", directoryHint: .isDirectory)
        artifactsRoot = root.appending(path: "Artifacts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: artifactsRoot,
            withIntermediateDirectories: true
        )
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

    func finalRelativePath(for artifact: StagedArtifact) -> String {
        "Artifacts/\(artifact.rawValue.uuidString)/payload"
    }

    func moveToFinal(
        _ placement: StagedArtifactPlacement
    ) throws -> String {
        let finalPath = finalRelativePath(for: placement.artifact)
        let sourceContainer = url(for: placement.relativePath)
            .deletingLastPathComponent()
        let finalContainer = url(for: finalPath)
            .deletingLastPathComponent()
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: finalContainer.path) {
            if fileManager.fileExists(atPath: sourceContainer.path) {
                try fileManager.removeItem(at: sourceContainer)
            }
            try synchronizeDirectory(artifactsRoot)
            return finalPath
        }
        guard fileManager.fileExists(atPath: sourceContainer.path) else {
            throw LocalLibraryError.artifactMissing
        }

        try fileManager.moveItem(at: sourceContainer, to: finalContainer)
        try synchronizeDirectory(artifactsRoot)
        return finalPath
    }

    func exists(at relativePath: String) -> Bool {
        FileManager.default.fileExists(atPath: url(for: relativePath).path)
    }

    func remove(_ placement: StagedArtifactPlacement) throws {
        try remove(at: placement.relativePath)
    }

    func remove(at relativePath: String) throws {
        let container = url(for: relativePath).deletingLastPathComponent()
        guard FileManager.default.fileExists(atPath: container.path) else {
            return
        }
        try FileManager.default.removeItem(at: container)
    }

    private func copyToStaging(
        source: URL,
        kind: SourceArtifactKind,
        expectsDirectory: Bool,
        taskID: ImportTaskID
    ) throws -> StagedArtifactPlacement {
        try validateSource(source, expectsDirectory: expectsDirectory)

        let artifactID = UUID()
        let relativePath = "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)/payload"
        let payload = url(for: relativePath)
        let container = payload.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: container,
            withIntermediateDirectories: true
        )

        var completed = false
        defer {
            if !completed {
                try? FileManager.default.removeItem(at: container)
            }
        }

        try FileManager.default.copyItem(at: source, to: payload)
        let verification = try verifyAndSynchronize(
            payload: payload,
            isDirectory: expectsDirectory
        )
        guard verification.byteCount > 0 else {
            throw LocalLibraryError.artifactMissing
        }
        try synchronizeDirectory(container)

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
    ) throws {
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
    }

    private func verifyAndSynchronize(
        payload: URL,
        isDirectory: Bool
    ) throws -> (byteCount: UInt64, contentHash: String) {
        let files: [(relativePath: String, url: URL)]
        if isDirectory {
            files = try regularFiles(in: payload, relativePath: "")
                .sorted {
                    $0.relativePath.utf8.lexicographicallyPrecedes(
                        $1.relativePath.utf8
                    )
                }
        } else {
            files = [(relativePath: "", url: payload)]
        }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        for file in files {
            if isDirectory {
                hasher.update(data: Data(file.relativePath.utf8))
            }
            let data = try Data(contentsOf: file.url)
            guard let fileByteCount = UInt64(exactly: data.count),
                  byteCount <= UInt64.max - fileByteCount
            else {
                throw LocalLibraryError.artifactMissing
            }
            byteCount += fileByteCount
            hasher.update(data: data)
            try synchronizeFile(file.url)
        }

        let digest = hasher.finalize()
        return (
            byteCount,
            digest.map { String(format: "%02x", $0) }.joined()
        )
    }

    private func regularFiles(
        in directory: URL,
        relativePath: String
    ) throws -> [(relativePath: String, url: URL)] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        var files: [(relativePath: String, url: URL)] = []
        for child in children {
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                throw LocalLibraryError.artifactMissing
            }
            let childPath = relativePath.isEmpty
                ? child.lastPathComponent
                : "\(relativePath)/\(child.lastPathComponent)"
            if values.isDirectory == true {
                files.append(contentsOf: try regularFiles(
                    in: child,
                    relativePath: childPath
                ))
            } else if values.isRegularFile == true {
                files.append((childPath, child))
            } else {
                throw LocalLibraryError.artifactMissing
            }
        }
        return files
    }

    private func synchronizeFile(_ file: URL) throws {
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(directory.path, O_RDONLY | O_DIRECTORY)
        guard descriptor >= 0 else {
            throw posixError()
        }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw posixError()
        }
    }

    private func url(for relativePath: String) -> URL {
        root.appending(path: relativePath)
    }

    private func posixError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }
}
