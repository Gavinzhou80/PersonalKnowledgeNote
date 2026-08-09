import Darwin
import Foundation
import GRDB
import KnowledgeCore
import Testing
@testable import LocalLibrary

struct InvalidPersistedCheckpointDescriptor: Sendable {
    let byteCount: Int64
    let contentHash: String
}

private struct RawCheckpointArtifactDescriptor: Codable {
    let byteCount: Int64
    let contentHash: String
}

private final class CheckpointRaceController: @unchecked Sendable {
    private let lock = NSLock()
    private let target: CheckpointArtifactFaultPoint
    private let action: @Sendable () throws -> Void
    private var armed = false
    private var fired = false

    init(
        target: CheckpointArtifactFaultPoint,
        action: @escaping @Sendable () throws -> Void
    ) {
        self.target = target
        self.action = action
    }

    func arm() {
        lock.lock()
        armed = true
        lock.unlock()
    }

    func hit(_ point: CheckpointArtifactFaultPoint) throws {
        lock.lock()
        let shouldRun = armed && !fired && point == target
        if shouldRun {
            fired = true
        }
        lock.unlock()
        if shouldRun {
            try action()
        }
    }

    var injector: CheckpointArtifactFaultInjector {
        CheckpointArtifactFaultInjector { [self] point in
            try hit(point)
        }
    }
}

@Test
func sourceChildSymlinkSwapIsRejectedWithoutCopyingExternalBytes()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let package = try makeCheckpointPackage(body: Data("owned".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let external = root.appending(path: "external-source.bin")
    try Data("external-secret".utf8).write(to: external)
    let payload = package.appending(path: "payload.bin")
    let race = CheckpointRaceController(
        target: .beforeOpeningCheckpointSourceChild
    ) {
        try FileManager.default.removeItem(at: payload)
        try FileManager.default.createSymbolicLink(
            at: payload,
            withDestinationURL: external
        )
    }
    let library = try await LocalLibrary.openForTesting(
        at: root.appending(path: "Library"),
        checkpointArtifactFaultInjector: race.injector
    )
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/source-symlink-race")!)
    )
    let initial = try await workspace.snapshot()
    race.arm()

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }
    #expect(try Data(contentsOf: external) == Data("external-secret".utf8))
    #expect(try await workspace.checkpointArtifactCount() == 0)
    #expect(try await workspace.snapshot().revision == initial.revision)
}

@Test
func sourceChildSpecialFileSwapIsRejectedWithoutManagedBytes()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let package = try makeCheckpointPackage(body: Data("owned".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let payload = package.appending(path: "payload.bin")
    let race = CheckpointRaceController(
        target: .beforeOpeningCheckpointSourceChild
    ) {
        try FileManager.default.removeItem(at: payload)
        guard mkfifo(payload.path, S_IRUSR | S_IWUSR) == 0 else {
            throw POSIXError(POSIXError.Code(rawValue: errno) ?? .EIO)
        }
    }
    let library = try await LocalLibrary.openForTesting(
        at: root.appending(path: "Library"),
        checkpointArtifactFaultInjector: race.injector
    )
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/source-special-race")!)
    )
    let initial = try await workspace.snapshot()
    race.arm()

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }
    #expect(try await workspace.checkpointArtifactCount() == 0)
    #expect(try await workspace.snapshot().revision == initial.revision)
}

@Test
func growingSourceFileStopsAtOneOverLimitAndCleansPartialDestination()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let package = try makeCheckpointPackage(fileSizes: [
        "a.bin": Int(CheckpointPackageLimits.maximumFileByteCount),
    ])
    defer { try? FileManager.default.removeItem(at: package) }
    let growingFile = package.appending(path: "a.bin")
    let race = CheckpointRaceController(
        target: .afterOpeningCheckpointSourceFileBeforeRead
    ) {
        let handle = try FileHandle(forWritingTo: growingFile)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data([0x42]))
        try handle.synchronize()
    }
    let library = try await LocalLibrary.openForTesting(
        at: root.appending(path: "Library"),
        checkpointArtifactFaultInjector: race.injector
    )
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/source-growth-race")!)
    )
    let initial = try await workspace.snapshot()
    race.arm()

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }
    #expect(
        try FileManager.default.attributesOfItem(atPath: growingFile.path)[
            .size
        ] as? Int == Int(CheckpointPackageLimits.maximumFileByteCount) + 1
    )
    #expect(try await workspace.checkpointArtifactCount() == 0)
    #expect(try await workspace.snapshot().revision == initial.revision)
}

@Test
func managedArtifactDirectorySymlinkSwapCannotRedirectLoad()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/managed-artifact-race")!)
    )
    let package = try makeCheckpointPackage(body: Data("owned".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let attached = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
        )
    )
    let artifactDirectory = libraryRoot.appending(
        path: ManagedArtifactPath.checkpoint(
            taskID: workspace.taskID,
            artifactID: attached.artifact.rawValue
        ).relativePath
    )
    let parked = artifactDirectory.deletingLastPathComponent().appending(
        path: "\(attached.artifact.rawValue.uuidString)-PARKED"
    )
    let external = try makeCheckpointPackage(body: Data("external".utf8))
    defer { try? FileManager.default.removeItem(at: external) }
    let race = CheckpointRaceController(
        target: .beforeOpeningManagedCheckpointChild
    ) {
        try FileManager.default.moveItem(at: artifactDirectory, to: parked)
        try FileManager.default.createSymbolicLink(
            at: artifactDirectory,
            withDestinationURL: external
        )
    }
    let faulting = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        checkpointArtifactFaultInjector: race.injector
    )
    let faultingWorkspace = try #require(
        try await faulting.importWorkspace(id: workspace.taskID)
    )
    race.arm()

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await faultingWorkspace.loadCheckpointArtifact(
            attached.artifact
        )
    }
    #expect(try Data(contentsOf: external.appending(path: "payload.bin"))
        == Data("external".utf8))
    #expect(try await faultingWorkspace.snapshot().checkpointArtifact
        == attached.artifact)

    try FileManager.default.removeItem(at: artifactDirectory)
    try FileManager.default.moveItem(at: parked, to: artifactDirectory)
    #expect(
        try await faultingWorkspace.loadCheckpointArtifact(attached.artifact)
            .files["payload.bin"] == Data("owned".utf8)
    )
}

@Test
func managedTaskDirectorySymlinkSwapCannotDeleteExternalContent()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/managed-task-race")!)
    )
    let package = try makeCheckpointPackage(body: Data("owned".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let attached = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
        )
    )
    let taskDirectory = libraryRoot.appending(
        path: "Checkpoints/\(workspace.taskID.rawValue.uuidString)"
    )
    let parked = taskDirectory.deletingLastPathComponent().appending(
        path: "\(workspace.taskID.rawValue.uuidString)-PARKED"
    )
    let external = root.appending(path: "external-task")
    try FileManager.default.createDirectory(
        at: external,
        withIntermediateDirectories: true
    )
    let marker = external.appending(path: "do-not-delete.txt")
    try Data("external".utf8).write(to: marker)
    let race = CheckpointRaceController(
        target: .afterPinningManagedCheckpointTaskDirectory
    ) {
        try FileManager.default.moveItem(at: taskDirectory, to: parked)
        try FileManager.default.createSymbolicLink(
            at: taskDirectory,
            withDestinationURL: external
        )
    }
    let faulting = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        checkpointArtifactFaultInjector: race.injector
    )
    let faultingWorkspace = try #require(
        try await faulting.importWorkspace(id: workspace.taskID)
    )
    race.arm()

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await faultingWorkspace.removeCheckpointArtifact(
            expectedRevision: try await faultingWorkspace.snapshot().revision
        )
    }
    #expect(try Data(contentsOf: marker) == Data("external".utf8))
    let committed = try await faultingWorkspace.snapshot()
    #expect(committed.checkpoint == nil)
    #expect(committed.checkpointArtifact == nil)

    try FileManager.default.removeItem(at: taskDirectory)
    try FileManager.default.moveItem(at: parked, to: taskDirectory)
    let reopened = try await LocalLibrary.open(at: libraryRoot)
    let recovered = try #require(
        try await reopened.importWorkspace(id: workspace.taskID)
    )
    #expect(try await recovered.checkpointArtifactCount() == 0)
    #expect(try Data(contentsOf: marker) == Data("external".utf8))
}

@Test(arguments: [
    InvalidPersistedCheckpointDescriptor(
        byteCount: Int64.max,
        contentHash: String(repeating: "0", count: 64)
    ),
    InvalidPersistedCheckpointDescriptor(
        byteCount: CheckpointPackageLimits.maximumAggregateByteCount + 1,
        contentHash: String(repeating: "0", count: 64)
    ),
    InvalidPersistedCheckpointDescriptor(
        byteCount: 1,
        contentHash: String(repeating: "0", count: 63)
    ),
    InvalidPersistedCheckpointDescriptor(
        byteCount: 1,
        contentHash: String(repeating: "A", count: 64)
    ),
    InvalidPersistedCheckpointDescriptor(
        byteCount: 1,
        contentHash: String(repeating: "z", count: 64)
    ),
])
func persistedInvalidCheckpointDescriptorIsCorruptAcrossReadPaths(
    corruption: InvalidPersistedCheckpointDescriptor
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/descriptor-corruption")!)
    )
    let package = try makeCheckpointPackage(body: Data("valid".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    _ = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
        )
    )
    try CheckpointArtifactTestDriver.corruptDescriptor(
        at: root,
        taskID: workspace.taskID,
        byteCount: corruption.byteCount,
        contentHash: corruption.contentHash
    )

    await expectCorruptLibrary {
        _ = try await workspace.snapshot()
    }
    await expectCorruptLibrary {
        _ = try await library.retainedImports()
    }
    await expectCorruptLibrary {
        _ = try await LocalLibrary.open(at: root)
    }
}

@Test
func checkpointPackageByteLimitsAcceptExactBoundariesAndRejectOneOver()
    async throws
{
    let perFileLimit = Int(CheckpointPackageLimits.maximumFileByteCount)
    let aggregateLimit = Int(
        CheckpointPackageLimits.maximumAggregateByteCount
    )
    let metadataByteCount = Data(#"{"codecVersion":1}"#.utf8).count

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/file-boundary")!)
        )
        let package = try makeCheckpointPackage(
            fileSizes: ["payload.bin": perFileLimit]
        )
        defer { try? FileManager.default.removeItem(at: package) }
        let attached = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: try await workspace.snapshot().revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
        let loaded = try await workspace.loadCheckpointArtifact(
            attached.artifact
        )
        #expect(loaded.files["payload.bin"]?.count == perFileLimit)
    }

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/file-over")!)
        )
        let package = try makeCheckpointPackage(
            fileSizes: ["payload.bin": perFileLimit + 1]
        )
        defer { try? FileManager.default.removeItem(at: package) }
        await #expect(throws: LocalLibraryError.artifactMissing) {
            _ = try await workspace.replaceCheckpointArtifact(
                packageURL: package,
                update: CheckpointUpdate(
                    expectedRevision: try await workspace.snapshot().revision,
                    ordinal: 1,
                    envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
                )
            )
        }
    }

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/aggregate-boundary")!)
        )
        let package = try makeCheckpointPackage(fileSizes: [
            "payload.bin": perFileLimit,
            "remainder.bin": aggregateLimit
                - perFileLimit
                - metadataByteCount,
        ])
        defer { try? FileManager.default.removeItem(at: package) }
        let attached = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: try await workspace.snapshot().revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
        let loaded = try await workspace.loadCheckpointArtifact(
            attached.artifact
        )
        #expect(loaded.descriptor.byteCount == Int64(aggregateLimit))
    }

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/aggregate-over")!)
        )
        let package = try makeCheckpointPackage(fileSizes: [
            "payload.bin": perFileLimit,
            "remainder.bin": aggregateLimit
                - perFileLimit
                - metadataByteCount
                + 1,
        ])
        defer { try? FileManager.default.removeItem(at: package) }
        await #expect(throws: LocalLibraryError.artifactMissing) {
            _ = try await workspace.replaceCheckpointArtifact(
                packageURL: package,
                update: CheckpointUpdate(
                    expectedRevision: try await workspace.snapshot().revision,
                    ordinal: 1,
                    envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
                )
            )
        }
    }
}

@Test
func managedCheckpointLoadRejectsPerFileAndAggregateBoundaryTampering()
    async throws
{
    let perFileLimit = Int(CheckpointPackageLimits.maximumFileByteCount)
    let aggregateLimit = Int(
        CheckpointPackageLimits.maximumAggregateByteCount
    )
    let metadataByteCount = Data(#"{"codecVersion":1}"#.utf8).count

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/managed-file-over")!)
        )
        let package = try makeCheckpointPackage(
            fileSizes: ["payload.bin": 1]
        )
        defer { try? FileManager.default.removeItem(at: package) }
        let attached = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: try await workspace.snapshot().revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
        try CheckpointArtifactTestDriver.writeManagedFile(
            at: root,
            taskID: workspace.taskID,
            artifact: attached.artifact,
            name: "payload.bin",
            byteCount: perFileLimit + 1
        )
        await expectCheckpointCorruption {
            _ = try await workspace.loadCheckpointArtifact(attached.artifact)
        }
    }

    do {
        let root = try makeTemporaryLibraryRoot()
        defer { removeTemporaryLibraryRoot(root) }
        let library = try await LocalLibrary.open(at: root)
        let workspace = try await library.accept(
            .webpage(URL(string: "https://example.test/managed-aggregate-over")!)
        )
        let package = try makeCheckpointPackage(fileSizes: [
            "payload.bin": perFileLimit,
            "remainder.bin": aggregateLimit
                - perFileLimit
                - metadataByteCount,
        ])
        defer { try? FileManager.default.removeItem(at: package) }
        let attached = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: try await workspace.snapshot().revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
        try CheckpointArtifactTestDriver.writeManagedFile(
            at: root,
            taskID: workspace.taskID,
            artifact: attached.artifact,
            name: "remainder.bin",
            byteCount: aggregateLimit
                - perFileLimit
                - metadataByteCount
                + 1
        )
        await expectCheckpointCorruption {
            _ = try await workspace.loadCheckpointArtifact(attached.artifact)
        }
    }
}

@Test
func checkpointPackageIsTaskOwnedAndReplaceable() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/article")!)
    )
    let initial = try await workspace.snapshot()

    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    defer { try? FileManager.default.removeItem(at: firstPackage) }
    let first = try await workspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: initial.revision,
            ordinal: 2,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("first".utf8)
            )
        )
    )
    let verified = try await workspace.loadCheckpointArtifact(first.artifact)
    #expect(verified.descriptor.byteCount > 0)
    #expect(verified.files["metadata.json"] != nil)
    #expect(verified.files["payload.bin"] == Data("first".utf8))
    #expect(first.snapshot.checkpoint == CheckpointEnvelope(
        codecVersion: 1,
        payload: Data("first".utf8)
    ))
    #expect(first.snapshot.checkpointArtifact == first.artifact)
    #expect(first.snapshot.revision == initial.revision + 1)

    let secondPackage = try makeCheckpointPackage(body: Data("second".utf8))
    defer { try? FileManager.default.removeItem(at: secondPackage) }
    let second = try await workspace.replaceCheckpointArtifact(
        packageURL: secondPackage,
        update: CheckpointUpdate(
            expectedRevision: first.snapshot.revision,
            ordinal: 4,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("second".utf8)
            )
        )
    )

    #expect(second.artifact != first.artifact)
    #expect(second.snapshot.revision == first.snapshot.revision + 1)
    #expect(try await workspace.checkpointArtifactCount() == 1)
    await #expect(throws: LocalLibraryError.artifactOwnershipViolation) {
        _ = try await workspace.loadCheckpointArtifact(first.artifact)
    }
    let secondVerified = try await workspace.loadCheckpointArtifact(
        second.artifact
    )
    #expect(secondVerified.files["payload.bin"] == Data("second".utf8))
}

@Test
func crossTaskCheckpointArtifactIdentityIsRejectedWithoutTouchingVictim()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let victim = try await library.accept(
        .webpage(URL(string: "https://example.test/victim")!)
    )
    let attacker = try await library.accept(
        .webpage(URL(string: "https://example.test/attacker")!)
    )
    let package = try makeCheckpointPackage(body: Data("victim".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let attached = try await victim.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await victim.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("victim".utf8)
            )
        )
    )
    let forged = ManagedCheckpointArtifact(
        rawValue: attached.artifact.rawValue,
        descriptor: attached.artifact.descriptor
    )

    await #expect(throws: LocalLibraryError.artifactOwnershipViolation) {
        _ = try await attacker.loadCheckpointArtifact(forged)
    }
    #expect(try await victim.checkpointArtifactCount() == 1)
    #expect(
        try await victim.loadCheckpointArtifact(attached.artifact)
            .files["payload.bin"] == Data("victim".utf8)
    )
}

@Test
func checkpointPackageRejectsInputAndNestedSymlinks() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/symlink")!)
    )
    let initial = try await workspace.snapshot()
    let package = try makeCheckpointPackage(body: Data("safe".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let rootLink = package.deletingLastPathComponent()
        .appending(path: UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: rootLink) }
    try FileManager.default.createSymbolicLink(at: rootLink, withDestinationURL: package)

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: rootLink,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }

    let nestedTarget = package.deletingLastPathComponent()
        .appending(path: "outside-(UUID().uuidString).bin")
    defer { try? FileManager.default.removeItem(at: nestedTarget) }
    try Data("outside".utf8).write(to: nestedTarget)
    try FileManager.default.createSymbolicLink(
        at: package.appending(path: "linked.bin"),
        withDestinationURL: nestedTarget
    )
    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: package,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }
    #expect(try await workspace.checkpointArtifactCount() == 0)
}

@Test
func checkpointPackageRejectsUnsafeRelativeNamesAndExcessFiles() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/bounds")!)
    )
    let initial = try await workspace.snapshot()
    let unsafe = try makeCheckpointPackage(body: Data("safe".utf8))
    defer { try? FileManager.default.removeItem(at: unsafe) }
    try Data("unsafe".utf8).write(to: unsafe.appending(path: "back\\slash.bin"))

    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: unsafe,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }

    let excessive = try makeCheckpointPackage(body: Data("safe".utf8))
    defer { try? FileManager.default.removeItem(at: excessive) }
    for index in 0..<255 {
        try Data([UInt8(index % 255)]).write(
            to: excessive.appending(path: "entry-\(index).bin")
        )
    }
    await #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: excessive,
            update: CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 1,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data())
            )
        )
    }
    #expect(try await workspace.checkpointArtifactCount() == 0)
}

@Test
func tamperedCheckpointPackageIsReportedAsCorruptWithoutAPathValue()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/tamper")!)
    )
    let package = try makeCheckpointPackage(body: Data("original".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let replacement = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("db".utf8))
        )
    )
    try CheckpointArtifactTestDriver.tamper(
        at: root,
        taskID: workspace.taskID,
        artifact: replacement.artifact
    )

    await expectCheckpointCorruption {
        _ = try await workspace.loadCheckpointArtifact(replacement.artifact)
    }
}

@Test
func staleAndRegressingReplacementPreserveOldPairAndRemoveNewCopy()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/rollback")!)
    )
    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    defer { try? FileManager.default.removeItem(at: firstPackage) }
    let first = try await workspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 5,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("first-db".utf8))
        )
    )
    let before = try CheckpointArtifactTestDriver.state(
        at: root,
        taskID: workspace.taskID
    )

    for update in [
        CheckpointUpdate(
            expectedRevision: first.snapshot.revision - 1,
            ordinal: 6,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("stale".utf8))
        ),
        CheckpointUpdate(
            expectedRevision: first.snapshot.revision,
            ordinal: 5,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("regress".utf8))
        ),
    ] {
        let rejected = try makeCheckpointPackage(body: update.envelope.payload)
        defer { try? FileManager.default.removeItem(at: rejected) }
        do {
            _ = try await workspace.replaceCheckpointArtifact(
                packageURL: rejected,
                update: update
            )
            Issue.record("Expected replacement rejection")
        } catch let error as LocalLibraryError {
            #expect(
                error == .staleRevision(current: first.snapshot.revision)
                    || error == .checkpointRegression
            )
        }
        #expect(try await workspace.checkpointArtifactCount() == 1)
    }

    #expect(
        try CheckpointArtifactTestDriver.state(
            at: root,
            taskID: workspace.taskID
        ) == before
    )
    #expect(
        try await workspace.loadCheckpointArtifact(first.artifact)
            .files["payload.bin"] == Data("first".utf8)
    )
}

@Test
func faultBeforeCheckpointDatabaseMutationRemovesOnlyNewBytes()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let initialLibrary = try await LocalLibrary.open(at: root)
    let initialWorkspace = try await initialLibrary.accept(
        .webpage(URL(string: "https://example.test/precommit-fault")!)
    )
    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    defer { try? FileManager.default.removeItem(at: firstPackage) }
    let first = try await initialWorkspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: try await initialWorkspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("first".utf8))
        )
    )
    let faulting = try await LocalLibrary.openForTesting(
        at: root,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector { point in
            if point == .afterNewCopyBeforeDatabaseMutation {
                throw LocalLibraryError.unavailable
            }
        }
    )
    let workspace = try #require(
        try await faulting.importWorkspace(id: initialWorkspace.taskID)
    )
    let secondPackage = try makeCheckpointPackage(body: Data("second".utf8))
    defer { try? FileManager.default.removeItem(at: secondPackage) }

    await #expect(throws: LocalLibraryError.unavailable) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: secondPackage,
            update: CheckpointUpdate(
                expectedRevision: first.snapshot.revision,
                ordinal: 2,
                envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("second".utf8))
            )
        )
    }
    #expect(try await workspace.checkpointArtifactCount() == 1)
    #expect(try await workspace.snapshot().checkpointArtifact == first.artifact)
    #expect(
        try await workspace.loadCheckpointArtifact(first.artifact)
            .files["payload.bin"] == Data("first".utf8)
    )
}

@Test
func faultInsideCheckpointPairTransactionRollsBackOldPairAndNewCopy()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let initialLibrary = try await LocalLibrary.open(at: root)
    let initialWorkspace = try await initialLibrary.accept(
        .webpage(URL(string: "https://example.test/in-transaction-fault")!)
    )
    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    defer { try? FileManager.default.removeItem(at: firstPackage) }
    let first = try await initialWorkspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: try await initialWorkspace.snapshot().revision,
            ordinal: 3,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("old-envelope".utf8)
            )
        )
    )
    let faulting = try await LocalLibrary.openForTesting(
        at: root,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector { point in
            if point == .afterCheckpointArtifactRowMutationBeforeTaskUpdate {
                throw LocalLibraryError.unavailable
            }
        }
    )
    let workspace = try #require(
        try await faulting.importWorkspace(id: initialWorkspace.taskID)
    )
    let before = try CheckpointArtifactTestDriver.state(
        at: root,
        taskID: initialWorkspace.taskID
    )
    let reopenedRevision = try await workspace.snapshot().revision
    let secondPackage = try makeCheckpointPackage(body: Data("second".utf8))
    defer { try? FileManager.default.removeItem(at: secondPackage) }

    await #expect(throws: LocalLibraryError.unavailable) {
        _ = try await workspace.replaceCheckpointArtifact(
            packageURL: secondPackage,
            update: CheckpointUpdate(
                expectedRevision: reopenedRevision,
                ordinal: 4,
                envelope: CheckpointEnvelope(
                    codecVersion: 2,
                    payload: Data("new-envelope".utf8)
                )
            )
        )
    }

    #expect(
        try CheckpointArtifactTestDriver.state(
            at: root,
            taskID: workspace.taskID
        ) == before
    )
    let rolledBack = try await workspace.snapshot()
    #expect(rolledBack.revision == reopenedRevision)
    #expect(rolledBack.checkpointArtifact == first.artifact)
    #expect(rolledBack.checkpoint == CheckpointEnvelope(
        codecVersion: 1,
        payload: Data("old-envelope".utf8)
    ))
    #expect(try await workspace.checkpointArtifactCount() == 1)
    #expect(
        try await workspace.loadCheckpointArtifact(first.artifact)
            .files["payload.bin"] == Data("first".utf8)
    )
}

@Test
func postCommitCleanupFaultLeavesNewPairAndReopenRemovesOldOrphan()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/postcommit-fault")!)
    )
    let firstPackage = try makeCheckpointPackage(body: Data("first".utf8))
    defer { try? FileManager.default.removeItem(at: firstPackage) }
    let first = try await workspace.replaceCheckpointArtifact(
        packageURL: firstPackage,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("first-db".utf8))
        )
    )
    let faulting = try await LocalLibrary.openForTesting(
        at: root,
        checkpointArtifactFaultInjector: CheckpointArtifactFaultInjector { point in
            if point == .afterDatabaseCommitBeforeOldRemoval {
                throw LocalLibraryError.unavailable
            }
        }
    )
    let faultingWorkspace = try #require(
        try await faulting.importWorkspace(id: workspace.taskID)
    )
    let reopenedRevision = try await faultingWorkspace.snapshot().revision
    let secondPackage = try makeCheckpointPackage(body: Data("second".utf8))
    defer { try? FileManager.default.removeItem(at: secondPackage) }
    await #expect(throws: LocalLibraryError.unavailable) {
        _ = try await faultingWorkspace.replaceCheckpointArtifact(
            packageURL: secondPackage,
            update: CheckpointUpdate(
                expectedRevision: reopenedRevision,
                ordinal: 2,
                envelope: CheckpointEnvelope(codecVersion: 2, payload: Data("second-db".utf8))
            )
        )
    }

    let committed = try await faultingWorkspace.snapshot()
    let newArtifact = try #require(committed.checkpointArtifact)
    #expect(newArtifact != first.artifact)
    #expect(committed.checkpoint == CheckpointEnvelope(
        codecVersion: 2,
        payload: Data("second-db".utf8)
    ))
    #expect(try await faultingWorkspace.checkpointArtifactCount() == 2)

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(try await reopened.importWorkspace(id: workspace.taskID))
    #expect(try await recovered.checkpointArtifactCount() == 1)
    #expect(
        try await recovered.loadCheckpointArtifact(newArtifact)
            .files["payload.bin"] == Data("second".utf8)
    )
}

@Test
func removeCheckpointArtifactClearsPairAtomicallyAndRejectsStaleRevision()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/remove")!)
    )
    let package = try makeCheckpointPackage(body: Data("remove".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let attached = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("db".utf8))
        )
    )

    await #expect(throws: LocalLibraryError.staleRevision(current: attached.snapshot.revision)) {
        _ = try await workspace.removeCheckpointArtifact(
            expectedRevision: attached.snapshot.revision - 1
        )
    }
    #expect(try await workspace.snapshot().checkpointArtifact == attached.artifact)

    let removed = try await workspace.removeCheckpointArtifact(
        expectedRevision: attached.snapshot.revision
    )
    #expect(removed.revision == attached.snapshot.revision + 1)
    #expect(removed.checkpoint == nil)
    #expect(removed.checkpointArtifact == nil)
    #expect(try await workspace.checkpointArtifactCount() == 0)
    await #expect(throws: LocalLibraryError.artifactOwnershipViolation) {
        _ = try await workspace.loadCheckpointArtifact(attached.artifact)
    }
    await #expect(throws: LocalLibraryError.invalidTaskState) {
        _ = try await workspace.removeCheckpointArtifact(
            expectedRevision: removed.revision
        )
    }
}

@Test
func reopeningRemovesUnownedCheckpointPackageAndPreservesOwnedPackage()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/orphan")!)
    )
    let package = try makeCheckpointPackage(body: Data("owned".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    let attached = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: 1,
            envelope: CheckpointEnvelope(codecVersion: 1, payload: Data("owned".utf8))
        )
    )
    try CheckpointArtifactTestDriver.createOrphanPackage(
        at: root,
        taskID: workspace.taskID
    )
    #expect(try await workspace.checkpointArtifactCount() == 2)

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(try await reopened.importWorkspace(id: workspace.taskID))
    #expect(try await recovered.checkpointArtifactCount() == 1)
    #expect(
        try await recovered.loadCheckpointArtifact(attached.artifact)
            .files["payload.bin"] == Data("owned".utf8)
    )
}

@Test
func v2ToV3MigrationPreservesQueueJournalCheckpointAndClock() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let before = try await CheckpointArtifactTestDriver.makeV2State(at: root)

    let reopened = try await LocalLibrary.open(at: root)
    let retained = try await reopened.retainedImports()
    let running = try #require(
        before.snapshots.first { $0.queueSequence == nil }
    )
    let queued = try #require(
        before.snapshots.first { $0.queueSequence != nil }
    )

    #expect(retained.map(\.taskID) == [queued.taskID, running.taskID])
    #expect(
        retained.map(\.journalSequence)
            == [queued.journalSequence, running.journalSequence]
    )
    #expect(
        retained.map(\.queueSequence)
            == [queued.queueSequence, before.clock + 1]
    )
    #expect(
        retained.map(\.revision) == [queued.revision, running.revision + 1]
    )
    #expect(
        retained.map(\.checkpoint) == [queued.checkpoint, running.checkpoint]
    )
    #expect(try CheckpointArtifactTestDriver.clock(at: root) == before.clock + 1)
    #expect(try CheckpointArtifactTestDriver.hasCheckpointTable(at: root))
    #expect(
        FileManager.default.fileExists(
            atPath: root.appending(path: "Checkpoints").path
        )
    )
}

@Test
func checkpointArtifactAssociationKeepsRetainedQueryCountConstant()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    try await attachCheckpoint(toNewTaskIn: library, ordinal: 1)
    let single = try CheckpointArtifactTestDriver.retainedStatementCount(at: root)
    for ordinal in 2...13 {
        try await attachCheckpoint(toNewTaskIn: library, ordinal: UInt64(ordinal))
    }
    let many = try CheckpointArtifactTestDriver.retainedStatementCount(at: root)
    #expect(many == single)
}

@Test
func checkpointPathsRejectTraversalAndNoncanonicalUUIDSpellings() throws {
    let taskID = ImportTaskID()
    let artifactID = UUID()
    let path = ManagedArtifactPath.checkpoint(
        taskID: taskID,
        artifactID: artifactID
    )
    #expect(try ManagedArtifactPath.parse(path.relativePath) == path)
    for raw in [
        "Checkpoints/../\(artifactID.uuidString)",
        "Checkpoints/\(taskID.rawValue.uuidString.lowercased())/\(artifactID.uuidString)",
        "Checkpoints/\(taskID.rawValue.uuidString)/\(artifactID.uuidString.lowercased())",
        "Checkpoints//\(taskID.rawValue.uuidString)/\(artifactID.uuidString)",
        "Checkpoints/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)/extra",
    ] {
        #expect(throws: LocalLibraryError.self) {
            _ = try ManagedArtifactPath.parse(raw)
        }
    }
}

private func makeCheckpointPackage(body: Data) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data(#"{"codecVersion":1}"#.utf8).write(
        to: root.appending(path: "metadata.json"),
        options: .atomic
    )
    try body.write(
        to: root.appending(path: "payload.bin"),
        options: .atomic
    )
    return root
}

private func makeCheckpointPackage(
    fileSizes: [String: Int]
) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: UUID().uuidString, directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    try Data(#"{"codecVersion":1}"#.utf8).write(
        to: root.appending(path: "metadata.json"),
        options: .atomic
    )
    for (name, byteCount) in fileSizes {
        try Data(repeating: 0x41, count: byteCount).write(
            to: root.appending(path: name)
        )
    }
    return root
}

private func attachCheckpoint(
    toNewTaskIn library: LocalLibrary,
    ordinal: UInt64
) async throws {
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/query-\(ordinal)")!)
    )
    let package = try makeCheckpointPackage(body: Data("\(ordinal)".utf8))
    defer { try? FileManager.default.removeItem(at: package) }
    _ = try await workspace.replaceCheckpointArtifact(
        packageURL: package,
        update: CheckpointUpdate(
            expectedRevision: try await workspace.snapshot().revision,
            ordinal: ordinal,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data("\(ordinal)".utf8)
            )
        )
    )
}

private func expectCheckpointCorruption(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected checkpoint artifact corruption")
    } catch let error as LocalLibraryError {
        switch error {
        case .artifactMissing, .corruptLibrary:
            return
        default:
            Issue.record("Expected artifact/corrupt error, got \(error)")
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}

private func expectCorruptLibrary(
    _ operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected corrupt library")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}

private enum CheckpointArtifactTestDriver {
    struct State: Equatable {
        let revision: Int64
        let checkpointOrdinal: Int64?
        let checkpointCodecVersion: Int64?
        let checkpointPayload: Data?
        let artifactID: String?
        let relativePath: String?
    }

    struct V2State {
        let snapshots: [DurableImportSnapshot]
        let clock: UInt64
    }

    static func state(at root: URL, taskID: ImportTaskID) throws -> State {
        try databaseQueue(at: root).read { db in
            guard let task = try ImportTaskRecord.fetchOne(
                db,
                key: taskID.rawValue.uuidString
            ) else {
                throw LocalLibraryError.unavailable
            }
            let artifact = try CheckpointArtifactRecord
                .filter(Column("task_id") == task.taskID)
                .fetchOne(db)
            return State(
                revision: task.revision,
                checkpointOrdinal: task.checkpointOrdinal,
                checkpointCodecVersion: task.checkpointCodecVersion,
                checkpointPayload: task.checkpointPayload,
                artifactID: artifact?.artifactID,
                relativePath: artifact?.relativePath
            )
        }
    }

    static func tamper(
        at root: URL,
        taskID: ImportTaskID,
        artifact: ManagedCheckpointArtifact
    ) throws {
        try Data("tampered".utf8).write(
            to: root.appending(
                path: ManagedArtifactPath.checkpoint(
                    taskID: taskID,
                    artifactID: artifact.rawValue
                ).relativePath + "/payload.bin"
            )
        )
    }

    static func corruptDescriptor(
        at root: URL,
        taskID: ImportTaskID,
        byteCount: Int64,
        contentHash: String
    ) throws {
        let encoded = try JSONEncoder().encode(
            RawCheckpointArtifactDescriptor(
                byteCount: byteCount,
                contentHash: contentHash
            )
        )
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    UPDATE checkpoint_artifacts
                    SET descriptor_json = ?
                    WHERE task_id = ?
                    """,
                arguments: [
                    encoded,
                    taskID.rawValue.uuidString,
                ]
            )
            guard db.changesCount == 1 else {
                throw LocalLibraryError.unavailable
            }
        }
    }

    static func writeManagedFile(
        at root: URL,
        taskID: ImportTaskID,
        artifact: ManagedCheckpointArtifact,
        name: String,
        byteCount: Int
    ) throws {
        try Data(repeating: 0x42, count: byteCount).write(
            to: root.appending(
                path: ManagedArtifactPath.checkpoint(
                    taskID: taskID,
                    artifactID: artifact.rawValue
                ).relativePath + "/\(name)"
            )
        )
    }

    static func createOrphanPackage(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        let package = root.appending(
            path: ManagedArtifactPath.checkpoint(
                taskID: taskID,
                artifactID: UUID()
            ).relativePath
        )
        try FileManager.default.createDirectory(
            at: package,
            withIntermediateDirectories: true
        )
        try Data("orphan".utf8).write(to: package.appending(path: "payload.bin"))
    }

    static func retainedStatementCount(at root: URL) throws -> Int {
        try LibraryDatabase(
            url: root.appending(path: "library.sqlite")
        ).retainedImportStatementCountForTesting()
    }

    static func makeV2State(at root: URL) async throws -> V2State {
        let library = try await LocalLibrary.open(at: root)
        let first = try await library.accept(
            .webpage(URL(string: "https://example.test/migration-first")!)
        )
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/migration-second")!)
        )
        let initial = try await first.snapshot()
        _ = try await first.checkpoint(
            CheckpointUpdate(
                expectedRevision: initial.revision,
                ordinal: 7,
                envelope: CheckpointEnvelope(
                    codecVersion: 3,
                    payload: Data("legacy-checkpoint".utf8)
                )
            )
        )
        let snapshots = try await library.retainedImports()
        let storedClock = try clock(at: root)
        try await databaseQueue(at: root).write { db in
            try db.execute(sql: "DROP TABLE checkpoint_artifacts")
            try db.execute(
                sql: "DELETE FROM grdb_migrations WHERE identifier = ?",
                arguments: ["v3_import_checkpoint_artifacts"]
            )
        }
        try? FileManager.default.removeItem(at: root.appending(path: "Checkpoints"))
        return V2State(snapshots: snapshots, clock: storedClock)
    }

    static func clock(at root: URL) throws -> UInt64 {
        try databaseQueue(at: root).read { db in
            guard let raw = try Int64.fetchOne(
                db,
                sql: "SELECT last_sequence FROM import_queue_clock WHERE singleton = 1"
            ), let value = UInt64(exactly: raw) else {
                throw LocalLibraryError.unavailable
            }
            return value
        }
    }

    static func hasCheckpointTable(at root: URL) throws -> Bool {
        try databaseQueue(at: root).read { db in
            try db.tableExists("checkpoint_artifacts")
        }
    }

    private static func databaseQueue(at root: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: root.appending(path: "library.sqlite").path)
    }
}
