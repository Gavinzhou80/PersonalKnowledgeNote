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
