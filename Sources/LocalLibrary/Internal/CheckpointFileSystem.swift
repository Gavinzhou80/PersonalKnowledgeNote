import CryptoKit
import Darwin
import Foundation
import KnowledgeCore

final class CheckpointFileSystem: @unchecked Sendable {
    private enum EntryKind: UInt8 {
        case directory = 0
        case file = 1
    }

    private enum UnsafeFileSystemEntry: Error {
        case rejected
    }

    private final class FileDescriptor {
        let rawValue: Int32

        init(_ rawValue: Int32) {
            self.rawValue = rawValue
        }

        deinit {
            _ = close(rawValue)
        }
    }

    private struct TraversalState {
        var fileCount = 0
        var directoryCount = 0
        var byteCount: UInt64 = 0
        var manifestHasher = SHA256()
        var files: [String: Data] = [:]

        var entryCount: Int { fileCount + directoryCount }
    }

    private let libraryRoot: FileDescriptor
    private let checkpointsRoot: FileDescriptor
    private let faultInjector: CheckpointArtifactFaultInjector

    init(
        libraryRoot: URL,
        checkpointsRoot: URL,
        faultInjector: CheckpointArtifactFaultInjector
    ) throws {
        self.libraryRoot = try Self.openAbsoluteDirectory(libraryRoot)
        self.checkpointsRoot = try Self.openAbsoluteDirectory(checkpointsRoot)
        self.faultInjector = faultInjector
    }

    func copyPackage(
        at source: URL,
        taskID: ImportTaskID,
        artifactID: UUID
    ) throws -> CheckpointArtifactDescriptor {
        do {
            guard source.isFileURL, source.path.hasPrefix("/") else {
                throw UnsafeFileSystemEntry.rejected
            }
            let sourceRoot = try Self.openAbsoluteDirectory(source)
            try faultInjector.hit(
                .afterOpeningCheckpointSourceRootBeforeTraversal
            )
            guard try !directoriesOverlap(
                sourceRoot.rawValue,
                libraryRoot.rawValue
            ) else {
                throw UnsafeFileSystemEntry.rejected
            }

            let taskName = taskID.rawValue.uuidString
            let artifactName = artifactID.uuidString
            guard let task = try openManagedTask(
                named: taskName,
                createIfMissing: true
            ) else {
                throw UnsafeFileSystemEntry.rejected
            }
            guard mkdirat(
                task.rawValue,
                artifactName,
                S_IRWXU
            ) == 0 else {
                if errno == EEXIST {
                    throw LocalLibraryError.artifactOwnershipViolation
                }
                throw posixError()
            }
            let package = try openDirectory(
                at: task.rawValue,
                name: artifactName,
                allowMissing: false
            )!

            do {
                var state = TraversalState()
                try copyDirectory(
                    source: sourceRoot.rawValue,
                    destination: package.rawValue,
                    relativePath: "",
                    depth: 0,
                    state: &state
                )
                guard state.fileCount > 0,
                      let byteCount = Int64(exactly: state.byteCount)
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                try synchronize(package.rawValue)
                try synchronize(task.rawValue)
                try synchronize(checkpointsRoot.rawValue)
                return try CheckpointArtifactDescriptor(
                    byteCount: byteCount,
                    contentHash: hashString(
                        state.manifestHasher.finalize()
                    )
                )
            } catch {
                try? recursivelyRemoveEntry(
                    parent: task.rawValue,
                    name: artifactName
                )
                try? removeTaskIfEmpty(
                    task: task.rawValue,
                    taskName: taskName
                )
                throw error
            }
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.artifactMissing
        }
    }

    func loadPackage(
        taskID: ImportTaskID,
        artifactID: UUID,
        expectedDescriptor: CheckpointArtifactDescriptor
    ) throws -> VerifiedCheckpointPackage {
        do {
            let task = try openManagedTask(
                named: taskID.rawValue.uuidString,
                createIfMissing: false
            )
            guard let task else {
                throw UnsafeFileSystemEntry.rejected
            }
            try faultInjector.hit(.beforeOpeningManagedCheckpointChild)
            guard let package = try openDirectory(
                at: task.rawValue,
                name: artifactID.uuidString,
                allowMissing: true
            ) else {
                throw UnsafeFileSystemEntry.rejected
            }
            var state = TraversalState()
            state.files.reserveCapacity(
                CheckpointPackageLimits.maximumFileCount
            )
            try loadDirectory(
                directory: package.rawValue,
                relativePath: "",
                depth: 0,
                state: &state
            )
            guard state.fileCount > 0,
                  let byteCount = Int64(exactly: state.byteCount)
            else {
                throw UnsafeFileSystemEntry.rejected
            }
            let descriptor = try CheckpointArtifactDescriptor(
                byteCount: byteCount,
                contentHash: hashString(state.manifestHasher.finalize())
            )
            guard descriptor == expectedDescriptor else {
                throw UnsafeFileSystemEntry.rejected
            }
            return VerifiedCheckpointPackage(
                descriptor: descriptor,
                files: state.files
            )
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.artifactMissing
        }
    }

    func removePackage(
        taskID: ImportTaskID,
        artifactID: UUID
    ) throws {
        do {
            let taskName = taskID.rawValue.uuidString
            guard let task = try openManagedTask(
                named: taskName,
                createIfMissing: false
            ) else {
                return
            }
            try faultInjector.hit(.beforeOpeningManagedCheckpointChild)
            guard try entryExists(
                parent: task.rawValue,
                name: artifactID.uuidString
            ) else {
                return
            }
            try recursivelyRemoveEntry(
                parent: task.rawValue,
                name: artifactID.uuidString
            )
            try synchronize(task.rawValue)
            try removeTaskIfEmpty(
                task: task.rawValue,
                taskName: taskName
            )
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.artifactMissing
        }
    }

    func packageCount(taskID: ImportTaskID) throws -> Int {
        do {
            guard let task = try openManagedTask(
                named: taskID.rawValue.uuidString,
                createIfMissing: false
            ) else {
                return 0
            }
            let names = try directoryNames(
                task.rawValue,
                maximumCount: nil,
                validateCheckpointNames: true
            )
            for name in names {
                guard UUID(uuidString: name)?.uuidString == name,
                      try entryIsDirectory(
                        parent: task.rawValue,
                        name: name
                      )
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
            }
            return names.count
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.artifactMissing
        }
    }

    func packageExists(
        taskID: ImportTaskID,
        artifactID: UUID
    ) throws -> Bool {
        do {
            guard let task = try openManagedTask(
                named: taskID.rawValue.uuidString,
                createIfMissing: false
            ) else {
                return false
            }
            return try entryIsDirectory(
                parent: task.rawValue,
                name: artifactID.uuidString
            )
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.artifactMissing
        }
    }

    func removeUnownedPackages(
        ownedPaths: Set<ManagedArtifactPath>
    ) throws {
        do {
            var ownedByTask: [String: Set<String>] = [:]
            for path in ownedPaths {
                guard case .checkpoint(let taskID, let artifactID) = path
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                ownedByTask[
                    taskID.rawValue.uuidString,
                    default: []
                ].insert(artifactID.uuidString)
            }
            let taskNames = try directoryNames(
                checkpointsRoot.rawValue,
                maximumCount: nil,
                validateCheckpointNames: true
            )
            for taskName in taskNames {
                guard UUID(uuidString: taskName)?.uuidString == taskName else {
                    throw UnsafeFileSystemEntry.rejected
                }
                let ownedArtifacts = ownedByTask[taskName] ?? []
                let task: FileDescriptor
                do {
                    guard let opened = try openManagedTask(
                        named: taskName,
                        createIfMissing: false
                    ) else {
                        continue
                    }
                    task = opened
                } catch is UnsafeFileSystemEntry {
                    if ownedArtifacts.isEmpty {
                        guard unlinkat(
                            checkpointsRoot.rawValue,
                            taskName,
                            0
                        ) == 0 else {
                            throw UnsafeFileSystemEntry.rejected
                        }
                        continue
                    }
                    throw UnsafeFileSystemEntry.rejected
                }
                let artifactNames = try directoryNames(
                    task.rawValue,
                    maximumCount: nil,
                    validateCheckpointNames: true
                )
                for artifactName in artifactNames {
                    guard UUID(uuidString: artifactName)?.uuidString
                            == artifactName
                    else {
                        throw UnsafeFileSystemEntry.rejected
                    }
                    guard !ownedArtifacts.contains(artifactName) else {
                        continue
                    }
                    try recursivelyRemoveEntry(
                        parent: task.rawValue,
                        name: artifactName
                    )
                    try synchronize(task.rawValue)
                }
                try removeTaskIfEmpty(
                    task: task.rawValue,
                    taskName: taskName
                )
            }
            try synchronize(checkpointsRoot.rawValue)
        } catch is UnsafeFileSystemEntry {
            throw LocalLibraryError.corruptLibrary(diagnosticID: UUID())
        }
    }

    private func openManagedTask(
        named taskName: String,
        createIfMissing: Bool
    ) throws -> FileDescriptor? {
        guard UUID(uuidString: taskName)?.uuidString == taskName else {
            throw UnsafeFileSystemEntry.rejected
        }
        if createIfMissing,
           mkdirat(checkpointsRoot.rawValue, taskName, S_IRWXU) != 0,
           errno != EEXIST {
            throw posixError()
        }
        guard let task = try openDirectory(
            at: checkpointsRoot.rawValue,
            name: taskName,
            allowMissing: !createIfMissing
        ) else {
            return nil
        }
        try faultInjector.hit(
            .afterPinningManagedCheckpointTaskDirectory
        )
        guard try openedEntryStillMatches(
            parent: checkpointsRoot.rawValue,
            name: taskName,
            opened: task.rawValue
        ) else {
            throw UnsafeFileSystemEntry.rejected
        }
        return task
    }

    private func copyDirectory(
        source: Int32,
        destination: Int32,
        relativePath: String,
        depth: Int,
        state: inout TraversalState
    ) throws {
        let names = try boundedPackageNames(
            directory: source,
            state: state
        )
        for name in names {
            let childPath = try validatedChildPath(
                parent: relativePath,
                name: name,
                depth: depth + 1
            )
            try faultInjector.hit(.beforeOpeningCheckpointSourceChild)
            let child = try openNode(at: source, name: name)
            let status = try fileStatus(child.rawValue)
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                state.directoryCount += 1
                guard state.directoryCount
                        <= CheckpointPackageLimits.maximumDirectoryCount
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                updateManifest(
                    &state.manifestHasher,
                    kind: .directory,
                    path: childPath,
                    fileByteCount: nil,
                    fileDigest: nil
                )
                guard mkdirat(destination, name, S_IRWXU) == 0 else {
                    throw posixError()
                }
                let destinationChild = try openDirectory(
                    at: destination,
                    name: name,
                    allowMissing: false
                )!
                try copyDirectory(
                    source: child.rawValue,
                    destination: destinationChild.rawValue,
                    relativePath: childPath,
                    depth: depth + 1,
                    state: &state
                )
                try synchronize(destinationChild.rawValue)
            case S_IFREG:
                state.fileCount += 1
                guard state.fileCount
                        <= CheckpointPackageLimits.maximumFileCount
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                let destinationFile = try createFile(
                    at: destination,
                    name: name
                )
                try faultInjector.hit(
                    .afterOpeningCheckpointSourceFileBeforeRead
                )
                let result = try streamCopy(
                    source: child.rawValue,
                    destination: destinationFile.rawValue,
                    aggregateByteCount: state.byteCount
                )
                state.byteCount += result.byteCount
                updateManifest(
                    &state.manifestHasher,
                    kind: .file,
                    path: childPath,
                    fileByteCount: result.byteCount,
                    fileDigest: result.digest
                )
                try synchronize(destinationFile.rawValue)
            default:
                throw UnsafeFileSystemEntry.rejected
            }
        }
    }

    private func loadDirectory(
        directory: Int32,
        relativePath: String,
        depth: Int,
        state: inout TraversalState
    ) throws {
        let names = try boundedPackageNames(
            directory: directory,
            state: state
        )
        for name in names {
            let childPath = try validatedChildPath(
                parent: relativePath,
                name: name,
                depth: depth + 1
            )
            try faultInjector.hit(.beforeOpeningManagedCheckpointChild)
            let child = try openNode(at: directory, name: name)
            let status = try fileStatus(child.rawValue)
            switch status.st_mode & S_IFMT {
            case S_IFDIR:
                state.directoryCount += 1
                guard state.directoryCount
                        <= CheckpointPackageLimits.maximumDirectoryCount
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                updateManifest(
                    &state.manifestHasher,
                    kind: .directory,
                    path: childPath,
                    fileByteCount: nil,
                    fileDigest: nil
                )
                try loadDirectory(
                    directory: child.rawValue,
                    relativePath: childPath,
                    depth: depth + 1,
                    state: &state
                )
            case S_IFREG:
                state.fileCount += 1
                guard state.fileCount
                        <= CheckpointPackageLimits.maximumFileCount
                else {
                    throw UnsafeFileSystemEntry.rejected
                }
                let result = try streamLoad(
                    source: child.rawValue,
                    aggregateByteCount: state.byteCount
                )
                state.byteCount += result.byteCount
                guard state.files.updateValue(
                    result.data,
                    forKey: childPath
                ) == nil else {
                    throw UnsafeFileSystemEntry.rejected
                }
                updateManifest(
                    &state.manifestHasher,
                    kind: .file,
                    path: childPath,
                    fileByteCount: result.byteCount,
                    fileDigest: result.digest
                )
            default:
                throw UnsafeFileSystemEntry.rejected
            }
        }
    }

    private func boundedPackageNames(
        directory: Int32,
        state: TraversalState
    ) throws -> [String] {
        try directoryNames(
            directory,
            maximumCount: CheckpointPackageLimits.maximumFileCount
                + CheckpointPackageLimits.maximumDirectoryCount
                - state.entryCount,
            validateCheckpointNames: true
        )
    }

    private func validatedChildPath(
        parent: String,
        name: String,
        depth: Int
    ) throws -> String {
        guard depth <= CheckpointPackageLimits.maximumDepth,
              isCanonicalCheckpointName(name)
        else {
            throw UnsafeFileSystemEntry.rejected
        }
        let path = parent.isEmpty ? name : "\(parent)/\(name)"
        guard path.utf8.count
                <= CheckpointPackageLimits.maximumRelativePathByteCount
        else {
            throw UnsafeFileSystemEntry.rejected
        }
        return path
    }

    private func streamCopy(
        source: Int32,
        destination: Int32,
        aggregateByteCount: UInt64
    ) throws -> (byteCount: UInt64, digest: SHA256.Digest) {
        var fileByteCount: UInt64 = 0
        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remainingFile = UInt64(
                CheckpointPackageLimits.maximumFileByteCount
            ) - fileByteCount
            let remainingAggregate = UInt64(
                CheckpointPackageLimits.maximumAggregateByteCount
            ) - aggregateByteCount - fileByteCount
            let allowed = min(remainingFile, remainingAggregate)
            let requested = min(UInt64(buffer.count), allowed + 1)
            let count = try readChunk(
                descriptor: source,
                buffer: &buffer,
                count: Int(requested)
            )
            guard count > 0 else {
                break
            }
            guard UInt64(count) <= allowed else {
                throw UnsafeFileSystemEntry.rejected
            }
            try writeAll(
                descriptor: destination,
                buffer: buffer,
                count: count
            )
            let data = Data(buffer[0..<count])
            hasher.update(data: data)
            fileByteCount += UInt64(count)
        }
        return (fileByteCount, hasher.finalize())
    }

    private func streamLoad(
        source: Int32,
        aggregateByteCount: UInt64
    ) throws -> (
        byteCount: UInt64,
        digest: SHA256.Digest,
        data: Data
    ) {
        var fileByteCount: UInt64 = 0
        var hasher = SHA256()
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1_024)
        while true {
            let remainingFile = UInt64(
                CheckpointPackageLimits.maximumFileByteCount
            ) - fileByteCount
            let remainingAggregate = UInt64(
                CheckpointPackageLimits.maximumAggregateByteCount
            ) - aggregateByteCount - fileByteCount
            let allowed = min(remainingFile, remainingAggregate)
            let requested = min(UInt64(buffer.count), allowed + 1)
            let count = try readChunk(
                descriptor: source,
                buffer: &buffer,
                count: Int(requested)
            )
            guard count > 0 else {
                break
            }
            guard UInt64(count) <= allowed else {
                throw UnsafeFileSystemEntry.rejected
            }
            let chunk = Data(buffer[0..<count])
            data.append(chunk)
            hasher.update(data: chunk)
            fileByteCount += UInt64(count)
        }
        return (fileByteCount, hasher.finalize(), data)
    }

    private func recursivelyRemoveEntry(
        parent: Int32,
        name: String
    ) throws {
        do {
            let child = try openNode(at: parent, name: name)
            let status = try fileStatus(child.rawValue)
            if status.st_mode & S_IFMT == S_IFDIR {
                let children = try directoryNames(
                    child.rawValue,
                    maximumCount: nil,
                    validateCheckpointNames: false
                )
                for childName in children {
                    try faultInjector.hit(
                        .beforeOpeningManagedCheckpointChild
                    )
                    try recursivelyRemoveEntry(
                        parent: child.rawValue,
                        name: childName
                    )
                }
                try synchronize(child.rawValue)
                guard unlinkat(parent, name, AT_REMOVEDIR) == 0 else {
                    throw posixError()
                }
            } else {
                guard unlinkat(parent, name, 0) == 0 else {
                    throw posixError()
                }
            }
        } catch is UnsafeFileSystemEntry {
            guard unlinkat(parent, name, 0) == 0 else {
                throw UnsafeFileSystemEntry.rejected
            }
        }
    }

    private func removeTaskIfEmpty(
        task: Int32,
        taskName: String
    ) throws {
        guard try directoryIsEmpty(task) else {
            return
        }
        if unlinkat(
            checkpointsRoot.rawValue,
            taskName,
            AT_REMOVEDIR
        ) == 0 {
            try synchronize(checkpointsRoot.rawValue)
            return
        }
        guard errno == ENOTEMPTY || errno == ENOTDIR || errno == ENOENT
        else {
            throw posixError()
        }
    }

    private func directoryNames(
        _ descriptor: Int32,
        maximumCount: Int?,
        validateCheckpointNames: Bool
    ) throws -> [String] {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw posixError()
        }
        guard let directory = fdopendir(duplicate) else {
            let error = posixError()
            _ = close(duplicate)
            throw error
        }
        defer { _ = closedir(directory) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw posixError()
                }
                break
            }
            let name: String? = withUnsafePointer(
                to: entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(validatingCString: $0) }
            }
            guard let name else {
                throw UnsafeFileSystemEntry.rejected
            }
            guard name != "." && name != ".." else {
                continue
            }
            if validateCheckpointNames,
               !isCanonicalCheckpointName(name) {
                throw UnsafeFileSystemEntry.rejected
            }
            names.append(name)
            if let maximumCount, names.count > maximumCount {
                throw UnsafeFileSystemEntry.rejected
            }
        }
        return names.sorted {
            $0.utf8.lexicographicallyPrecedes($1.utf8)
        }
    }

    private func directoryIsEmpty(_ descriptor: Int32) throws -> Bool {
        let duplicate = dup(descriptor)
        guard duplicate >= 0 else {
            throw posixError()
        }
        guard let directory = fdopendir(duplicate) else {
            let error = posixError()
            _ = close(duplicate)
            throw error
        }
        defer { _ = closedir(directory) }
        while true {
            errno = 0
            guard let entry = readdir(directory) else {
                guard errno == 0 else {
                    throw posixError()
                }
                return true
            }
            let name = withUnsafePointer(
                to: entry.pointee.d_name
            ) { pointer in
                pointer.withMemoryRebound(
                    to: CChar.self,
                    capacity: Int(MAXNAMLEN) + 1
                ) { String(cString: $0) }
            }
            if name != "." && name != ".." {
                return false
            }
        }
    }

    private func openDirectory(
        at parent: Int32,
        name: String,
        allowMissing: Bool
    ) throws -> FileDescriptor? {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if allowMissing && errno == ENOENT {
                return nil
            }
            if errno == ELOOP || errno == ENOTDIR || errno == ENOENT {
                throw UnsafeFileSystemEntry.rejected
            }
            throw posixError()
        }
        let opened = FileDescriptor(descriptor)
        guard try fileStatus(descriptor).st_mode & S_IFMT == S_IFDIR else {
            throw UnsafeFileSystemEntry.rejected
        }
        return opened
    }

    private func openNode(at parent: Int32, name: String) throws -> FileDescriptor {
        let descriptor = openat(
            parent,
            name,
            O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOENT || errno == ENOTDIR
                || errno == ENXIO || errno == ENODEV {
                throw UnsafeFileSystemEntry.rejected
            }
            throw posixError()
        }
        return FileDescriptor(descriptor)
    }

    private func createFile(at parent: Int32, name: String) throws -> FileDescriptor {
        let descriptor = openat(
            parent,
            name,
            O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
            S_IRUSR | S_IWUSR
        )
        guard descriptor >= 0 else {
            throw posixError()
        }
        return FileDescriptor(descriptor)
    }

    private func openedEntryStillMatches(
        parent: Int32,
        name: String,
        opened: Int32
    ) throws -> Bool {
        var current = stat()
        guard fstat(opened, &current) == 0 else {
            throw posixError()
        }
        var named = stat()
        guard fstatat(
            parent,
            name,
            &named,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT || errno == ELOOP || errno == ENOTDIR {
                return false
            }
            throw posixError()
        }
        return named.st_mode & S_IFMT == S_IFDIR
            && current.st_dev == named.st_dev
            && current.st_ino == named.st_ino
    }

    private func entryExists(parent: Int32, name: String) throws -> Bool {
        var status = stat()
        guard fstatat(
            parent,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw posixError()
        }
        return true
    }

    private func entryIsDirectory(parent: Int32, name: String) throws -> Bool {
        var status = stat()
        guard fstatat(
            parent,
            name,
            &status,
            AT_SYMLINK_NOFOLLOW
        ) == 0 else {
            if errno == ENOENT {
                return false
            }
            throw posixError()
        }
        return status.st_mode & S_IFMT == S_IFDIR
    }

    private func directoriesOverlap(_ first: Int32, _ second: Int32) throws -> Bool {
        let firstStatus = try fileStatus(first)
        let secondStatus = try fileStatus(second)
        return try containsAncestor(
            startingAt: first,
            target: secondStatus
        ) || containsAncestor(
            startingAt: second,
            target: firstStatus
        )
    }

    private func containsAncestor(
        startingAt descriptor: Int32,
        target: stat
    ) throws -> Bool {
        let duplicated = dup(descriptor)
        guard duplicated >= 0 else {
            throw posixError()
        }
        var current = FileDescriptor(duplicated)
        while true {
            let currentStatus = try fileStatus(current.rawValue)
            if currentStatus.st_dev == target.st_dev,
               currentStatus.st_ino == target.st_ino {
                return true
            }
            let parent = try openDirectory(
                at: current.rawValue,
                name: "..",
                allowMissing: false
            )!
            let parentStatus = try fileStatus(parent.rawValue)
            if parentStatus.st_dev == currentStatus.st_dev,
               parentStatus.st_ino == currentStatus.st_ino {
                return false
            }
            current = parent
        }
    }

    private func fileStatus(_ descriptor: Int32) throws -> stat {
        var status = stat()
        guard fstat(descriptor, &status) == 0 else {
            throw posixError()
        }
        return status
    }

    private func readChunk(
        descriptor: Int32,
        buffer: inout [UInt8],
        count: Int
    ) throws -> Int {
        while true {
            let result = buffer.withUnsafeMutableBytes { bytes in
                read(descriptor, bytes.baseAddress, count)
            }
            if result >= 0 {
                return result
            }
            guard errno == EINTR else {
                throw posixError()
            }
        }
    }

    private func writeAll(
        descriptor: Int32,
        buffer: [UInt8],
        count: Int
    ) throws {
        var written = 0
        while written < count {
            let result = buffer.withUnsafeBytes { bytes in
                write(
                    descriptor,
                    bytes.baseAddress!.advanced(by: written),
                    count - written
                )
            }
            if result > 0 {
                written += result
            } else if result < 0 && errno == EINTR {
                continue
            } else {
                throw posixError()
            }
        }
    }

    private func updateManifest(
        _ hasher: inout SHA256,
        kind: EntryKind,
        path: String,
        fileByteCount: UInt64?,
        fileDigest: SHA256.Digest?
    ) {
        let pathData = Data(path.utf8)
        hasher.update(data: Data([kind.rawValue]))
        updateHash(&hasher, with: UInt64(pathData.count))
        hasher.update(data: pathData)
        if let fileByteCount, let fileDigest {
            updateHash(&hasher, with: fileByteCount)
            hasher.update(data: Data(fileDigest))
        }
    }

    private func updateHash(_ hasher: inout SHA256, with value: UInt64) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { bytes in
            hasher.update(data: Data(bytes))
        }
    }

    private func isCanonicalCheckpointName(_ name: String) -> Bool {
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

    private func synchronize(_ descriptor: Int32) throws {
        guard fsync(descriptor) == 0 else {
            throw posixError()
        }
    }

    private func hashString(_ digest: SHA256.Digest) -> String {
        digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func openAbsoluteDirectory(
        _ url: URL
    ) throws -> FileDescriptor {
        let descriptor = open(
            url.path,
            O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        )
        guard descriptor >= 0 else {
            if errno == ELOOP || errno == ENOTDIR || errno == ENOENT {
                throw LocalLibraryError.artifactMissing
            }
            throw posixError()
        }
        var status = stat()
        guard fstat(descriptor, &status) == 0,
              status.st_mode & S_IFMT == S_IFDIR
        else {
            let error = posixError()
            _ = close(descriptor)
            throw error
        }
        return FileDescriptor(descriptor)
    }

    private static func posixError() -> POSIXError {
        POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
    }

    private func posixError() -> POSIXError {
        Self.posixError()
    }
}
