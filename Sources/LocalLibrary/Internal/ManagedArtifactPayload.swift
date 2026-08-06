import CryptoKit
import Darwin
import Foundation

enum ManagedArtifactPayload {
    private enum ManifestEntryKind: UInt8 {
        case directory = 0
        case file = 1
    }

    private struct ManifestEntry {
        let kind: ManifestEntryKind
        let relativePath: String
        let url: URL
    }

    static func verifyAndSynchronize(
        payload: URL,
        isDirectory: Bool
    ) throws -> (byteCount: UInt64, contentHash: String) {
        if !isDirectory {
            let data = try Data(contentsOf: payload)
            guard let byteCount = UInt64(exactly: data.count) else {
                throw LocalLibraryError.artifactMissing
            }
            var hasher = SHA256()
            hasher.update(data: data)
            try synchronizeFile(payload)
            return (byteCount, hashString(hasher.finalize()))
        }

        let entries = try manifestEntries(in: payload, relativePath: "")
            .sorted {
                $0.relativePath.utf8.lexicographicallyPrecedes(
                    $1.relativePath.utf8
                )
            }
        var hasher = SHA256()
        var byteCount: UInt64 = 0
        for entry in entries {
            let path = Data(entry.relativePath.utf8)
            guard let pathByteCount = UInt64(exactly: path.count) else {
                throw LocalLibraryError.artifactMissing
            }
            hasher.update(data: Data([entry.kind.rawValue]))
            updateHash(&hasher, with: pathByteCount)
            hasher.update(data: path)

            guard entry.kind == .file else {
                continue
            }
            let data = try Data(contentsOf: entry.url)
            guard let fileByteCount = UInt64(exactly: data.count),
                  byteCount <= UInt64.max - fileByteCount
            else {
                throw LocalLibraryError.artifactMissing
            }
            updateHash(&hasher, with: fileByteCount)
            byteCount += fileByteCount
            hasher.update(data: data)
            try synchronizeFile(entry.url)
        }

        let directories = entries
            .filter { $0.kind == .directory }
            .map(\.url)
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for directory in directories {
            try synchronizeDirectory(directory)
        }
        try synchronizeDirectory(payload)
        return (byteCount, hashString(hasher.finalize()))
    }

    static func verifyCheckpointPackage(
        payload: URL,
        loadFiles: Bool
    ) throws -> (
        descriptor: CheckpointArtifactDescriptor,
        files: [String: Data]
    ) {
        let rootValues = try payload.resourceValues(forKeys: [
            .isDirectoryKey,
            .isSymbolicLinkKey,
        ])
        guard rootValues.isDirectory == true,
              rootValues.isSymbolicLink != true
        else {
            throw LocalLibraryError.artifactMissing
        }
        let entries = try checkpointManifestEntries(in: payload).sorted {
            $0.relativePath.utf8.lexicographicallyPrecedes(
                $1.relativePath.utf8
            )
        }
        let fileCount = entries.lazy.filter { $0.kind == .file }.count
        let directoryCount = entries.count - fileCount
        guard fileCount > 0,
              fileCount <= CheckpointPackageLimits.maximumFileCount,
              directoryCount <= CheckpointPackageLimits.maximumDirectoryCount
        else {
            throw LocalLibraryError.artifactMissing
        }

        var hasher = SHA256()
        var byteCount: UInt64 = 0
        var files: [String: Data] = [:]
        if loadFiles {
            files.reserveCapacity(fileCount)
        }
        for entry in entries {
            let path = Data(entry.relativePath.utf8)
            guard let pathByteCount = UInt64(exactly: path.count) else {
                throw LocalLibraryError.artifactMissing
            }
            hasher.update(data: Data([entry.kind.rawValue]))
            updateHash(&hasher, with: pathByteCount)
            hasher.update(data: path)
            guard entry.kind == .file else {
                continue
            }

            let values = try entry.url.resourceValues(forKeys: [
                .fileSizeKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isRegularFile == true,
                  values.isSymbolicLink != true,
                  let rawFileSize = values.fileSize,
                  let expectedFileSize = UInt64(exactly: rawFileSize),
                  expectedFileSize <= UInt64(
                    CheckpointPackageLimits.maximumFileByteCount
                  ),
                  byteCount <= UInt64(
                    CheckpointPackageLimits.maximumAggregateByteCount
                  ) - expectedFileSize
            else {
                throw LocalLibraryError.artifactMissing
            }
            let data = try Data(contentsOf: entry.url)
            guard UInt64(data.count) == expectedFileSize else {
                throw LocalLibraryError.artifactMissing
            }
            updateHash(&hasher, with: expectedFileSize)
            byteCount += expectedFileSize
            hasher.update(data: data)
            if loadFiles {
                guard files.updateValue(
                    data,
                    forKey: entry.relativePath
                ) == nil else {
                    throw LocalLibraryError.artifactMissing
                }
            }
            try synchronizeFile(entry.url)
        }
        guard byteCount > 0,
              let descriptorByteCount = Int64(exactly: byteCount)
        else {
            throw LocalLibraryError.artifactMissing
        }

        let directories = entries
            .filter { $0.kind == .directory }
            .map(\.url)
            .sorted { $0.pathComponents.count > $1.pathComponents.count }
        for directory in directories {
            try synchronizeDirectory(directory)
        }
        try synchronizeDirectory(payload)
        return (
            try CheckpointArtifactDescriptor(
                byteCount: descriptorByteCount,
                contentHash: hashString(hasher.finalize())
            ),
            files
        )
    }

    static func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = open(
            directory.path,
            O_RDONLY | O_DIRECTORY | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            throw posixError()
        }
        guard fsync(descriptor) == 0 else {
            let error = posixError()
            _ = close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw posixError()
        }
    }

    private static func manifestEntries(
        in directory: URL,
        relativePath: String
    ) throws -> [ManifestEntry] {
        let children = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ]
        )
        var entries: [ManifestEntry] = []
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
                entries.append(ManifestEntry(
                    kind: .directory,
                    relativePath: childPath,
                    url: child
                ))
                entries.append(contentsOf: try manifestEntries(
                    in: child,
                    relativePath: childPath
                ))
            } else if values.isRegularFile == true {
                entries.append(ManifestEntry(
                    kind: .file,
                    relativePath: childPath,
                    url: child
                ))
            } else {
                throw LocalLibraryError.artifactMissing
            }
        }
        return entries
    }

    private static func checkpointManifestEntries(
        in directory: URL
    ) throws -> [ManifestEntry] {
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ],
            options: [],
            errorHandler: { _, error in
                enumerationError = error
                return false
            }
        ) else {
            throw LocalLibraryError.artifactMissing
        }
        let rootComponents = directory.standardizedFileURL.pathComponents
        var entries: [ManifestEntry] = []
        var fileCount = 0
        var directoryCount = 0
        while let child = enumerator.nextObject() as? URL {
            let childComponents = child.standardizedFileURL.pathComponents
            guard childComponents.count > rootComponents.count,
                  childComponents.prefix(rootComponents.count)
                    .elementsEqual(rootComponents)
            else {
                throw LocalLibraryError.artifactMissing
            }
            let relativeComponents = childComponents.dropFirst(
                rootComponents.count
            )
            guard relativeComponents.count
                    <= CheckpointPackageLimits.maximumDepth,
                  relativeComponents.allSatisfy(
                    isCanonicalCheckpointName
                  )
            else {
                throw LocalLibraryError.artifactMissing
            }
            let childPath = relativeComponents.joined(separator: "/")
            guard childPath.utf8.count
                    <= CheckpointPackageLimits.maximumRelativePathByteCount
            else {
                throw LocalLibraryError.artifactMissing
            }
            let values = try child.resourceValues(forKeys: [
                .isDirectoryKey,
                .isRegularFileKey,
                .isSymbolicLinkKey,
            ])
            guard values.isSymbolicLink != true else {
                enumerator.skipDescendants()
                throw LocalLibraryError.artifactMissing
            }
            if values.isDirectory == true {
                directoryCount += 1
                guard directoryCount
                        <= CheckpointPackageLimits.maximumDirectoryCount
                else {
                    throw LocalLibraryError.artifactMissing
                }
                entries.append(ManifestEntry(
                    kind: .directory,
                    relativePath: childPath,
                    url: child
                ))
            } else if values.isRegularFile == true {
                fileCount += 1
                guard fileCount <= CheckpointPackageLimits.maximumFileCount
                else {
                    throw LocalLibraryError.artifactMissing
                }
                entries.append(ManifestEntry(
                    kind: .file,
                    relativePath: childPath,
                    url: child
                ))
            } else {
                throw LocalLibraryError.artifactMissing
            }
        }
        if let enumerationError {
            throw enumerationError
        }
        return entries
    }

    private static func isCanonicalCheckpointName(_ name: String) -> Bool {
        !name.isEmpty
            && name != "."
            && name != ".."
            && !name.contains("/")
            && !name.contains("\\")
            && !name.unicodeScalars.contains(where: {
                CharacterSet.controlCharacters.contains($0)
            })
            && name.precomposedStringWithCanonicalMapping == name
            && name.utf8.count <= 255
    }

    private static func synchronizeFile(_ file: URL) throws {
        let descriptor = open(file.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw posixError()
        }
        guard fsync(descriptor) == 0 else {
            let error = posixError()
            _ = close(descriptor)
            throw error
        }
        guard close(descriptor) == 0 else {
            throw posixError()
        }
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }

    private static func updateHash(
        _ hasher: inout SHA256,
        with value: UInt64
    ) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private static func hashString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}
