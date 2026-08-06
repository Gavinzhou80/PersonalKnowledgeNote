import Darwin
import CryptoKit
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
    let expectedPDF = try Data(contentsOf: externalPDF)

    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(.pdfFile(externalPDF))

    try FileManager.default.removeItem(at: externalPDF)
    let snapshot = try await workspace.snapshot()
    let artifact = try #require(snapshot.stagedArtifact)
    let verifiedDescriptor = try await workspace.verifyManagedArtifact(
        artifact
    )

    #expect(artifact.descriptor.kind == .pdf)
    #expect(artifact.descriptor.byteCount == UInt64(expectedPDF.count))
    #expect(artifact.descriptor.contentHash == sha256Hex(expectedPDF))
    #expect(verifiedDescriptor == artifact.descriptor)
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
    let indexContents = Data("<html><body>Fixture</body></html>".utf8)
    try indexContents.write(to: package.appending(path: "index.html"))
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
    try FileManager.default.removeItem(at: package)
    let verifiedDescriptor = try await workspace.verifyManagedArtifact(
        artifact
    )
    let stagedSnapshot = try await workspace.snapshot()
    #expect(verifiedDescriptor == artifact.descriptor)
    #expect(
        verifiedDescriptor.contentHash
            == singleFilePackageHash(
                relativePath: "index.html",
                contents: indexContents
            )
    )
    #expect(stagedSnapshot.stagedArtifact == artifact)
    #expect(stagedSnapshot.state == .working)
    #expect(stagedSnapshot.revision == snapshot.revision + 1)
}

@Test
func describedWebPackageMatchesStagedDescriptorAuthority() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let package = temporaryRoot.appending(path: "WebPackage")
    let assets = package.appending(path: "assets")
    try FileManager.default.createDirectory(
        at: assets,
        withIntermediateDirectories: true
    )
    try Data("<html><body><img src=\"assets/hero.svg\"></body></html>".utf8)
        .write(to: package.appending(path: "index.html"))
    try Data("<svg xmlns=\"http://www.w3.org/2000/svg\"></svg>".utf8)
        .write(to: assets.appending(path: "hero.svg"))

    let described = try LocalLibrary.describeWebPackage(at: package)
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/article")))
    )
    let snapshot = try await workspace.snapshot()

    let staged = try await workspace.stageArtifact(
        .package(package, descriptor: described),
        expectedRevision: snapshot.revision
    )

    #expect(staged.descriptor == described)
}

@Test
func webPackageHashUsesUnambiguousManifestBoundaries() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let packageA = temporaryRoot.appending(path: "PackageA")
    let packageB = temporaryRoot.appending(path: "PackageB")
    try FileManager.default.createDirectory(
        at: packageA,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: packageB,
        withIntermediateDirectories: true
    )
    try Data("bc".utf8).write(to: packageA.appending(path: "a"))
    try Data("c".utf8).write(to: packageB.appending(path: "ab"))
    let callerDescriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 1,
        contentHash: "unverified"
    )
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )

    let artifactA = try managedArtifacts.stage(
        .package(packageA, descriptor: callerDescriptor),
        for: ImportTaskID()
    ).artifact
    let artifactB = try managedArtifacts.stage(
        .package(packageB, descriptor: callerDescriptor),
        for: ImportTaskID()
    ).artifact

    #expect(
        artifactA.descriptor.contentHash
            != artifactB.descriptor.contentHash
    )
}

@Test
func acceptingReadOnlyPDFCapturesManagedBytes() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let externalPDF = temporaryRoot.appending(path: "read-only.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )
    try #require(chmod(externalPDF.path, 0o444) == 0)
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )

    let workspace = try await library.accept(.pdfFile(externalPDF))
    let artifact = try #require(
        try await workspace.snapshot().stagedArtifact
    )

    #expect(artifact.descriptor.kind == .pdf)
}

@Test
func readOnlyWebPackageFileCanBeStaged() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "ReadOnlyPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    let index = package.appending(path: "index.html")
    try Data("read only".utf8).write(to: index)
    try #require(chmod(index.path, 0o444) == 0)
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/read-only")))
    )
    let snapshot = try await workspace.snapshot()

    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: snapshot.revision
    )

    #expect(artifact.descriptor.kind == .webPackage)
}

@Test
func managedRelativePathCannotEscapeLibraryRoot() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot
        .appending(path: "Outer")
        .appending(path: "Library")
    let victim = temporaryRoot.appending(path: "victim")
    try FileManager.default.createDirectory(
        at: victim,
        withIntermediateDirectories: true
    )
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)

    do {
        try managedArtifacts.remove(relativePath: "../../victim/payload")
        Issue.record("Expected traversal outside managed roots to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactMissing)
    }

    #expect(FileManager.default.fileExists(atPath: victim.path))
}

@Test
func managedRelativePathCannotFollowSymlinkOutsideManagedRoot() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let victim = temporaryRoot.appending(path: "victim")
    try FileManager.default.createDirectory(
        at: victim,
        withIntermediateDirectories: true
    )
    try Data("victim".utf8).write(to: victim.appending(path: "payload"))
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)
    let taskID = ImportTaskID()
    let artifactID = UUID()
    try FileManager.default.createDirectory(
        at: victim.appending(path: artifactID.uuidString),
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: libraryRoot.appending(
            path: "Staging/\(taskID.rawValue.uuidString)"
        ),
        withDestinationURL: victim
    )

    do {
        _ = try managedArtifacts.exists(
            relativePath: "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        )
        Issue.record("Expected symlink escape to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactMissing)
    }
}

@Test
func libraryRootCannotBeStagedAsPackage() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)
    let descriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 1,
        contentHash: "unverified"
    )

    do {
        _ = try managedArtifacts.stage(
            .package(libraryRoot, descriptor: descriptor),
            for: ImportTaskID()
        )
        Issue.record("Expected the library root to be rejected as input")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactMissing)
    } catch {
        Issue.record("Expected artifactMissing, got \(error)")
    }
}

@Test
func finalArtifactPathUsesDocumentIdentity() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )
    let documentID = SourceDocumentID()

    let relativePath = managedArtifacts.finalRelativePath(
        documentID: documentID
    )

    #expect(
        relativePath == "Artifacts/\(documentID.rawValue.uuidString)"
    )
}

@Test
func managedArtifactPathRoundTripsCanonicalStrongIdentities() throws {
    let taskID = ImportTaskID()
    let artifactID = UUID()
    let documentID = SourceDocumentID()
    let staging = ManagedArtifactPath.staging(
        taskID: taskID,
        artifactID: artifactID
    )
    let final = ManagedArtifactPath.artifacts(documentID: documentID)

    #expect(
        staging.relativePath
            == "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
    )
    #expect(
        final.relativePath
            == "Artifacts/\(documentID.rawValue.uuidString)"
    )
    #expect(try ManagedArtifactPath.parse(staging.relativePath) == staging)
    #expect(try ManagedArtifactPath.parse(final.relativePath) == final)
}

@Test
func managedArtifactPathStrictlyRejectsNoncanonicalRawStrings() {
    let taskID = ImportTaskID().rawValue.uuidString
    let artifactID = UUID().uuidString
    let documentID = SourceDocumentID().rawValue.uuidString
    let malformed = [
        "",
        "/Staging/\(taskID)/\(artifactID)",
        "Staging/./\(artifactID)",
        "Staging/\(taskID)//\(artifactID)",
        "Staging/\(taskID)/\(artifactID)/payload",
        "Staging/\(taskID.lowercased())/\(artifactID)",
        "Artifacts/\(documentID.lowercased())",
        "Artifacts/\(documentID)/payload",
        "Unknown/\(documentID)",
    ]

    for raw in malformed {
        do {
            _ = try ManagedArtifactPath.parse(raw)
            Issue.record("Expected noncanonical path rejection: \(raw)")
        } catch let error as LocalLibraryError {
            guard case .corruptLibrary = error else {
                Issue.record("Expected corruptLibrary, got \(error)")
                continue
            }
        } catch {
            Issue.record("Expected LocalLibraryError, got \(error)")
        }
    }
}

@Test
func finalMoveDoesNotDeleteStagingWhenDestinationExists() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let package = temporaryRoot.appending(path: "Package")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("source".utf8).write(to: package.appending(path: "index.html"))
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)
    let taskID = ImportTaskID()
    let placement = try managedArtifacts.stage(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        for: taskID
    )
    let documentID = SourceDocumentID()
    let intent = try PublicationIntent(
        taskID: taskID,
        documentID: documentID,
        artifact: placement.artifact,
        stagedRelativePath: placement.relativePath,
        finalRelativePath: managedArtifacts.finalRelativePath(
            documentID: documentID
        )
    )
    try FileManager.default.createDirectory(
        at: libraryRoot.appending(path: intent.finalRelativePath),
        withIntermediateDirectories: true
    )

    do {
        _ = try managedArtifacts.moveToFinal(intent)
        Issue.record("Expected an existing destination to conflict")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }

    #expect(
        try managedArtifacts.exists(relativePath: placement.relativePath)
    )
}

@Test
func managedArtifactVerificationEnforcesTaskOwnership() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "OwnedPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("owned".utf8).write(to: package.appending(path: "index.html"))
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )
    let owner = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/owner")))
    )
    let other = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/other")))
    )
    let artifact = try await owner.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: 0
    )

    do {
        _ = try await other.verifyManagedArtifact(artifact)
        Issue.record("Expected task ownership to be enforced")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }
}

@Test
func staleRevisionIsPreservedAndCopiedOrphanIsRemoved() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let package = temporaryRoot.appending(path: "StalePackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("stale".utf8).write(to: package.appending(path: "index.html"))
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/stale")))
    )

    do {
        _ = try await workspace.stageArtifact(
            .package(
                package,
                descriptor: SourceArtifactDescriptor(
                    kind: .webPackage,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            expectedRevision: 1
        )
        Issue.record("Expected stale revision to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .staleRevision(current: 0))
    }

    #expect(try await workspace.stagedArtifactCount() == 0)
}

@Test
func repeatedStagingKeepsFirstOwnedArtifact() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let firstPackage = temporaryRoot.appending(path: "FirstPackage")
    let secondPackage = temporaryRoot.appending(path: "SecondPackage")
    try FileManager.default.createDirectory(
        at: firstPackage,
        withIntermediateDirectories: true
    )
    try FileManager.default.createDirectory(
        at: secondPackage,
        withIntermediateDirectories: true
    )
    try Data("first".utf8).write(
        to: firstPackage.appending(path: "index.html")
    )
    try Data("second".utf8).write(
        to: secondPackage.appending(path: "index.html")
    )
    let descriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 1,
        contentHash: "unverified"
    )
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/repeated")))
    )
    let first = try await workspace.stageArtifact(
        .package(firstPackage, descriptor: descriptor),
        expectedRevision: 0
    )

    do {
        _ = try await workspace.stageArtifact(
            .package(secondPackage, descriptor: descriptor),
            expectedRevision: 1
        )
        Issue.record("Expected repeated staging to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }

    let snapshot = try await workspace.snapshot()
    #expect(snapshot.stagedArtifact == first)
    #expect(try await workspace.stagedArtifactCount() == 1)
}

@Test
func sourceArtifactInputKindMustMatchShape() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let file = temporaryRoot.appending(path: "file.pdf")
    let package = temporaryRoot.appending(path: "Package")
    try Data("pdf".utf8).write(to: file)
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("web".utf8).write(to: package.appending(path: "index.html"))
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )

    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.stage(
            .file(
                file,
                descriptor: SourceArtifactDescriptor(
                    kind: .webPackage,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            for: ImportTaskID()
        )
    }
    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.stage(
            .package(
                package,
                descriptor: SourceArtifactDescriptor(
                    kind: .pdf,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            for: ImportTaskID()
        )
    }
}

@Test
func webPackageContainingSymlinkIsRejected() async throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "SymlinkPackage")
    let external = temporaryRoot.appending(path: "external.txt")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("external".utf8).write(to: external)
    try FileManager.default.createSymbolicLink(
        at: package.appending(path: "linked.txt"),
        withDestinationURL: external
    )
    let library = try await LocalLibrary.open(
        at: temporaryRoot.appending(path: "Library")
    )
    let workspace = try await library.accept(
        .webpage(try #require(URL(string: "https://example.com/symlink")))
    )

    do {
        _ = try await workspace.stageArtifact(
            .package(
                package,
                descriptor: SourceArtifactDescriptor(
                    kind: .webPackage,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            expectedRevision: 0
        )
        Issue.record("Expected package symlink to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactMissing)
    }
}

@Test
func managedRelativePathRejectsMalformedComponents() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )
    let taskID = UUID().uuidString
    let artifactID = UUID().uuidString
    let malformedPaths = [
        "/Staging/\(taskID)/\(artifactID)",
        "Staging/./\(artifactID)",
        "Staging/\(taskID)//\(artifactID)",
    ]

    for relativePath in malformedPaths {
        #expect(throws: LocalLibraryError.artifactMissing) {
            _ = try managedArtifacts.exists(relativePath: relativePath)
        }
    }
}

@Test
func managedRootCannotBeStagedAsPackage() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)

    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.stage(
            .package(
                libraryRoot.appending(path: "Staging"),
                descriptor: SourceArtifactDescriptor(
                    kind: .webPackage,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            for: ImportTaskID()
        )
    }
}

@Test
func emptyWebPackageIsRejected() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "EmptyPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )

    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.stage(
            .package(
                package,
                descriptor: SourceArtifactDescriptor(
                    kind: .webPackage,
                    byteCount: 1,
                    contentHash: "unverified"
                )
            ),
            for: ImportTaskID()
        )
    }
}

@Test
func completedFinalMoveIsIdempotent() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let package = temporaryRoot.appending(path: "MovePackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("move".utf8).write(to: package.appending(path: "index.html"))
    let managedArtifacts = try ManagedArtifacts(
        root: temporaryRoot.appending(path: "Library")
    )
    let taskID = ImportTaskID()
    let placement = try managedArtifacts.stage(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        for: taskID
    )
    let documentID = SourceDocumentID()
    let intent = try PublicationIntent(
        taskID: taskID,
        documentID: documentID,
        artifact: placement.artifact,
        stagedRelativePath: placement.relativePath,
        finalRelativePath: managedArtifacts.finalRelativePath(
            documentID: documentID
        )
    )

    _ = try managedArtifacts.moveToFinal(intent)
    _ = try managedArtifacts.moveToFinal(intent)

    #expect(try managedArtifacts.exists(relativePath: intent.finalRelativePath))
}

@Test
func managedScopeRootSymlinkIsRejected() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let artifactsRoot = libraryRoot.appending(path: "Artifacts")
    try FileManager.default.createDirectory(
        at: artifactsRoot,
        withIntermediateDirectories: true
    )
    try FileManager.default.createSymbolicLink(
        at: libraryRoot.appending(path: "Staging"),
        withDestinationURL: artifactsRoot
    )

    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try ManagedArtifacts(root: libraryRoot)
    }
}

@Test
func crossTaskSymlinkCannotRedirectManagedOperations() throws {
    let temporaryRoot = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(temporaryRoot) }
    let libraryRoot = temporaryRoot.appending(path: "Library")
    let package = temporaryRoot.appending(path: "Package")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("owned".utf8).write(to: package.appending(path: "index.html"))
    let managedArtifacts = try ManagedArtifacts(root: libraryRoot)
    let descriptor = SourceArtifactDescriptor(
        kind: .webPackage,
        byteCount: 1,
        contentHash: "unverified"
    )

    func makeAlias() throws -> (
        original: StagedArtifactPlacement,
        alias: StagedArtifactPlacement,
        aliasTaskID: ImportTaskID
    ) {
        let ownerTaskID = ImportTaskID()
        let aliasTaskID = ImportTaskID()
        let original = try managedArtifacts.stage(
            .package(package, descriptor: descriptor),
            for: ownerTaskID
        )
        try FileManager.default.createSymbolicLink(
            at: libraryRoot.appending(
                path: "Staging/\(aliasTaskID.rawValue.uuidString)"
            ),
            withDestinationURL: libraryRoot.appending(
                path: "Staging/\(ownerTaskID.rawValue.uuidString)"
            )
        )
        return (
            original,
            try StagedArtifactPlacement(
                artifact: original.artifact,
                relativePath: "Staging/\(aliasTaskID.rawValue.uuidString)/\(original.artifact.rawValue.uuidString)"
            ),
            aliasTaskID
        )
    }

    let existsCase = try makeAlias()
    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.exists(
            relativePath: existsCase.alias.relativePath
        )
    }
    #expect(
        try managedArtifacts.exists(
            relativePath: existsCase.original.relativePath
        )
    )

    let verifyCase = try makeAlias()
    #expect(throws: LocalLibraryError.artifactMissing) {
        _ = try managedArtifacts.verify(verifyCase.alias)
    }
    #expect(
        try managedArtifacts.exists(
            relativePath: verifyCase.original.relativePath
        )
    )

    let removeCase = try makeAlias()
    #expect(throws: LocalLibraryError.artifactMissing) {
        try managedArtifacts.remove(
            relativePath: removeCase.alias.relativePath
        )
    }
    #expect(
        try managedArtifacts.exists(
            relativePath: removeCase.original.relativePath
        )
    )

    let moveCase = try makeAlias()
    #expect(throws: LocalLibraryError.artifactMissing) {
        let documentID = SourceDocumentID()
        let intent = try PublicationIntent(
            taskID: moveCase.aliasTaskID,
            documentID: documentID,
            artifact: moveCase.alias.artifact,
            stagedRelativePath: moveCase.alias.relativePath,
            finalRelativePath: managedArtifacts.finalRelativePath(
                documentID: documentID
            )
        )
        _ = try managedArtifacts.moveToFinal(intent)
    }
    #expect(
        try managedArtifacts.exists(
            relativePath: moveCase.original.relativePath
        )
    )
}

private func sha256Hex(_ data: Data) -> String {
    SHA256.hash(data: data)
        .map { String(format: "%02x", $0) }
        .joined()
}

private func singleFilePackageHash(
    relativePath: String,
    contents: Data
) -> String {
    let path = Data(relativePath.utf8)
    var manifest = Data([1])
    manifest.append(fixedWidthBytes(UInt64(path.count)))
    manifest.append(path)
    manifest.append(fixedWidthBytes(UInt64(contents.count)))
    manifest.append(contents)
    return sha256Hex(manifest)
}

private func fixedWidthBytes(_ value: UInt64) -> Data {
    var encoded = value.bigEndian
    return withUnsafeBytes(of: &encoded) { Data($0) }
}
