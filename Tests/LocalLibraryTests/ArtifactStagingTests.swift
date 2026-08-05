import Foundation
import KnowledgeCore
import TestFixtures
import Testing
@testable import LocalLibrary

@Test
func acceptingPDFCapturesBytesBeforeReturning() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let externalPDF = temporaryRoot.appending(path: "external.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )

    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(.pdfFile(externalPDF))

    try FileManager.default.removeItem(at: externalPDF)
    let snapshot = try await workspace.snapshot()
    let artifact = try #require(snapshot.stagedArtifact)

    #expect(artifact.descriptor.kind == .pdf)
    #expect(artifact.descriptor.byteCount > 0)
}

@Test
func webPackageIsCopiedIntoTaskOwnedStaging() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let package = temporaryRoot.appending(path: "WebPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<html><body>Fixture</body></html>".utf8).write(
        to: package.appending(path: "index.html")
    )
    let callerDescriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 1,
        contentHash: "caller-supplied"
    )

    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/article")))
    )
    let snapshot = try await workspace.snapshot()

    let artifact = try await workspace.stageArtifact(
        .package(package, descriptor: callerDescriptor),
        expectedRevision: snapshot.revision
    )

    #expect(artifact.descriptor.kind == .webPackage)
    #expect(artifact.descriptor.byteCount != callerDescriptor.byteCount)
    #expect(artifact.descriptor.contentHash != callerDescriptor.contentHash)
    let stagedSnapshot = try await workspace.snapshot()
    #expect(stagedSnapshot.stagedArtifact == artifact)
    #expect(stagedSnapshot.state == .working)
    #expect(stagedSnapshot.revision == snapshot.revision + 1)
}
