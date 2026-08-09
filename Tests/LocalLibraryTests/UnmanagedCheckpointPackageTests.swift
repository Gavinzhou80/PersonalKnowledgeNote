import Foundation
import Testing

@testable import LocalLibrary

@Test
func securelyLoadsAndDescribesAnUnmanagedCheckpointPackage() throws {
    let package = FileManager.default.temporaryDirectory.appending(
        path: "UnmanagedCheckpoint-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: package) }
    try Data("metadata".utf8).write(
        to: package.appending(path: "metadata.json")
    )
    try Data("payload".utf8).write(
        to: package.appending(path: "payload.bin")
    )

    let verified = try LocalLibrary.loadUnmanagedCheckpointPackage(at: package)

    #expect(
        verified.files == [
            "metadata.json": Data("metadata".utf8),
            "payload.bin": Data("payload".utf8),
        ])
    #expect(verified.directories.isEmpty)
    #expect(verified.descriptor.byteCount == 15)
    #expect(verified.descriptor.contentHash.count == 64)
}

@Test
func unmanagedCheckpointLoaderReportsSecurelyTraversedDirectories() throws {
    let package = FileManager.default.temporaryDirectory.appending(
        path: "UnmanagedCheckpoint-\(UUID().uuidString)"
    )
    let nested = package.appending(path: "nested")
    try FileManager.default.createDirectory(
        at: nested,
        withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: package) }
    try Data("payload".utf8).write(to: nested.appending(path: "payload.bin"))

    let verified = try LocalLibrary.loadUnmanagedCheckpointPackage(at: package)

    #expect(verified.directories == ["nested"])
    #expect(verified.files == ["nested/payload.bin": Data("payload".utf8)])
}

@Test
func unmanagedCheckpointLoaderRejectsSymlinks() throws {
    let package = FileManager.default.temporaryDirectory.appending(
        path: "UnmanagedCheckpoint-\(UUID().uuidString)"
    )
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: false
    )
    defer { try? FileManager.default.removeItem(at: package) }
    let external = FileManager.default.temporaryDirectory.appending(
        path: "UnmanagedCheckpointExternal-\(UUID().uuidString)"
    )
    try Data("external".utf8).write(to: external)
    defer { try? FileManager.default.removeItem(at: external) }
    try FileManager.default.createSymbolicLink(
        at: package.appending(path: "payload.bin"),
        withDestinationURL: external
    )

    #expect(throws: LocalLibraryError.artifactMissing) {
        try LocalLibrary.loadUnmanagedCheckpointPackage(at: package)
    }
}
