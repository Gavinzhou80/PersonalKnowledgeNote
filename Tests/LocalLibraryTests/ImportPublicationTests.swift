import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func publishesArtifactAndDocumentAsOneVisibleResult() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let package = root.appending(path: "WebPackage")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<article>Fixture</article>".utf8).write(
        to: package.appending(path: "index.html")
    )
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/published"))
    )
    let content = makeFixtureContent()
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(source)
    let accepted = try await workspace.snapshot()
    let staged = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: accepted.revision
    )
    try FileManager.default.removeItem(at: package)
    let stagedSnapshot = try await workspace.snapshot()
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("fixture-publication"),
        artifact: staged,
        document: content,
        originalSource: source
    )

    let outcome = try await workspace.finish(
        candidate,
        expectedRevision: stagedSnapshot.revision
    )

    #expect(outcome == .published(documentID: content.documentID))
    let located = try #require(
        try await library.sourceDocument(id: content.documentID)
    )
    #expect(located.document.content == content)
    #expect(located.document.artifact == staged.descriptor)
    #expect(located.location == .library)
    let completed = try await workspace.snapshot()
    #expect(completed.state == .completed)
    #expect(
        try await workspace.finish(
            candidate,
            expectedRevision: stagedSnapshot.revision
        ) == outcome
    )
    #expect(
        try await library.recoverableImports().contains {
            $0.taskID == workspace.taskID
        } == false
    )
}

@Test
func publicationRejectsCandidateFromWrongOriginalSource() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "owned-source"
    )
    let wrongSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/wrong-source"))
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("wrong-source"),
        artifact: fixture.artifact,
        document: fixture.content,
        originalSource: wrongSource
    )

    do {
        _ = try await fixture.workspace.finish(
            candidate,
            expectedRevision: fixture.revision
        )
        Issue.record("Expected source ownership rejection")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }

    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        ) == nil
    )
}

@Test
func publicationRejectsArtifactOwnedByAnotherTask() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "artifact-owner"
    )
    let otherWorkspace = try await fixture.library.accept(
        .webpage(
            try #require(URL(string: "https://example.com/other-task"))
        )
    )
    let otherArtifact = try await stageWebPackage(
        for: otherWorkspace,
        at: root,
        label: "other-task"
    ).artifact
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("other-task-artifact"),
        artifact: otherArtifact,
        document: fixture.content,
        originalSource: fixture.source
    )

    do {
        _ = try await fixture.workspace.finish(
            candidate,
            expectedRevision: fixture.revision
        )
        Issue.record("Expected task artifact ownership rejection")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }

    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        ) == nil
    )
}

@Test
func publicationRejectsStaleRevisionWithoutVisibility() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "stale-publication"
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("stale-publication"),
        artifact: fixture.artifact,
        document: fixture.content,
        originalSource: fixture.source
    )

    do {
        _ = try await fixture.workspace.finish(
            candidate,
            expectedRevision: fixture.revision - 1
        )
        Issue.record("Expected stale publication revision rejection")
    } catch let error as LocalLibraryError {
        #expect(error == .staleRevision(current: fixture.revision))
    }

    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        ) == nil
    )
}

@Test
func publicationRejectsForgedCandidateArtifactDescriptor() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "forged-descriptor"
    )
    let forgedArtifact = StagedArtifact(
        rawValue: fixture.artifact.rawValue,
        descriptor: SourceArtifactDescriptor(
            kind: fixture.artifact.descriptor.kind,
            byteCount: fixture.artifact.descriptor.byteCount + 1,
            contentHash: fixture.artifact.descriptor.contentHash + "-forged"
        )
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("forged-descriptor"),
        artifact: forgedArtifact,
        document: fixture.content,
        originalSource: fixture.source
    )

    do {
        _ = try await fixture.workspace.finish(
            candidate,
            expectedRevision: fixture.revision
        )
        Issue.record("Expected descriptor ownership rejection")
    } catch let error as LocalLibraryError {
        #expect(error == .artifactOwnershipViolation)
    }

    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        ) == nil
    )
}

@Test
func sourceDocumentReturnsNilForUnknownIdentity() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )

    #expect(
        try await library.sourceDocument(id: SourceDocumentID()) == nil
    )
}

@Test
func sourceDocumentDoesNotRevealPreparedHiddenDocument() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "hidden-document"
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("hidden-document"),
        artifact: fixture.artifact,
        document: fixture.content,
        originalSource: fixture.source
    )

    try LocalLibraryTestDriver.prepareHiddenPublication(
        at: root.appending(path: "Library"),
        taskID: fixture.workspace.taskID,
        candidate: candidate,
        expectedRevision: fixture.revision
    )

    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        ) == nil
    )
    #expect(try await fixture.workspace.snapshot().state == .publicationPending)
}

@Test
func sourceDocumentReportsCorruptionWhenFinalBytesAreDeleted() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "deleted-final"
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("deleted-final"),
        artifact: fixture.artifact,
        document: fixture.content,
        originalSource: fixture.source
    )
    _ = try await fixture.workspace.finish(
        candidate,
        expectedRevision: fixture.revision
    )
    try LocalLibraryTestDriver.removeFinalArtifactPayload(
        at: root.appending(path: "Library"),
        documentID: fixture.content.documentID
    )

    do {
        _ = try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        )
        Issue.record("Expected missing final bytes to report corruption")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    }
}

@Test
func sourceDocumentReportsCorruptionWhenFinalBytesAreTampered() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "tampered-final"
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("tampered-final"),
        artifact: fixture.artifact,
        document: fixture.content,
        originalSource: fixture.source
    )
    _ = try await fixture.workspace.finish(
        candidate,
        expectedRevision: fixture.revision
    )
    try LocalLibraryTestDriver.tamperFinalArtifactPayload(
        at: root.appending(path: "Library"),
        documentID: fixture.content.documentID
    )

    do {
        _ = try await fixture.library.sourceDocument(
            id: fixture.content.documentID
        )
        Issue.record("Expected tampered final bytes to report corruption")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    }
}

@Test
func duplicateFingerprintDefersCompletionWithoutPublishingCandidate() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let first = try await makeStagedPublicationFixture(
        at: root,
        sourcePath: "duplicate-first"
    )
    let fingerprint = ContentFingerprint("duplicate-fingerprint")
    _ = try await first.workspace.finish(
        PublicationCandidate(
            fingerprint: fingerprint,
            artifact: first.artifact,
            document: first.content,
            originalSource: first.source
        ),
        expectedRevision: first.revision
    )
    let secondSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/duplicate-second"))
    )
    let secondWorkspace = try await first.library.accept(secondSource)
    let secondStaged = try await stageWebPackage(
        for: secondWorkspace,
        at: root,
        label: "duplicate-second"
    )
    let secondContent = makeFixtureContent()

    do {
        _ = try await secondWorkspace.finish(
            PublicationCandidate(
                fingerprint: fingerprint,
                artifact: secondStaged.artifact,
                document: secondContent,
                originalSource: secondSource
            ),
            expectedRevision: secondStaged.revision
        )
        Issue.record("Expected duplicate completion to remain deferred")
    } catch let error as LocalLibraryError {
        #expect(error == .publicationFailed(retryable: true))
    }

    #expect(
        try await first.library.sourceDocument(
            id: secondContent.documentID
        ) == nil
    )
    #expect(try await secondWorkspace.snapshot().state == .working)
}

private struct StagedPublicationFixture: Sendable {
    let library: LocalLibrary
    let workspace: ImportWorkspace
    let source: OriginalSource
    let artifact: StagedArtifact
    let revision: UInt64
    let content: SourceDocumentContent
}

private func makeStagedPublicationFixture(
    at root: URL,
    sourcePath: String
) async throws -> StagedPublicationFixture {
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/\(sourcePath)"))
    )
    let workspace = try await library.accept(source)
    let package = root.appending(path: "Package-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<article>\(sourcePath)</article>".utf8).write(
        to: package.appending(path: "index.html")
    )
    let accepted = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: accepted.revision
    )
    try FileManager.default.removeItem(at: package)
    let staged = try await workspace.snapshot()
    return StagedPublicationFixture(
        library: library,
        workspace: workspace,
        source: source,
        artifact: artifact,
        revision: staged.revision,
        content: makeFixtureContent()
    )
}

private func stageWebPackage(
    for workspace: ImportWorkspace,
    at root: URL,
    label: String
) async throws -> (artifact: StagedArtifact, revision: UInt64) {
    let package = root.appending(path: "Package-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("<article>\(label)</article>".utf8).write(
        to: package.appending(path: "index.html")
    )
    let initial = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "unverified"
            )
        ),
        expectedRevision: initial.revision
    )
    try FileManager.default.removeItem(at: package)
    return (artifact, try await workspace.snapshot().revision)
}
