import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

private enum RecoveryCrash: Error, Equatable, Sendable {
    case at(PublicationFaultPoint)
}

private struct InterruptedPublication: Sendable {
    let libraryRoot: URL
    let taskID: ImportTaskID
    let candidate: PublicationCandidate
    let publicationRevision: UInt64
    let releaseProbe: ReleasedHandleProbe
}

@MainActor
private final class ReleasedHandleProbe {
    weak var library: LocalLibrary?
    weak var workspace: ImportWorkspace?

    var handlesAreReleased: Bool {
        library == nil && workspace == nil
    }
}

@Test(arguments: [
    PublicationFaultPoint.afterIntentCommit,
    .afterArtifactMove,
    .beforeVisibilityCommit,
    .afterVisibilityCommit,
])
func startupRecoversInterruptedPublicationAtEveryCrashBoundary(
    point: PublicationFaultPoint
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: point,
        label: "matrix-\(String(describing: point))"
    )
    #expect(await interrupted.releaseProbe.handlesAreReleased)

    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let workspace = try #require(
        try await reopened.importWorkspace(id: interrupted.taskID)
    )
    let recovered = try await workspace.snapshot()

    if point == .afterIntentCommit {
        #expect(recovered.state == .working)
        #expect(recovered.revision > interrupted.publicationRevision)
        #expect(recovered.stagedArtifact == interrupted.candidate.artifact)
        #expect(
            try await reopened.sourceDocument(
                id: interrupted.candidate.document.documentID
            ) == nil
        )
        #expect(
            try await reopened.recoverableImports().contains {
                $0.taskID == interrupted.taskID
            }
        )
        let outcome = try await workspace.finish(
            interrupted.candidate,
            expectedRevision: recovered.revision
        )
        #expect(
            outcome == .published(
                documentID: interrupted.candidate.document.documentID
            )
        )
    } else {
        #expect(recovered.state == .completed)
        #expect(recovered.stagedArtifact == nil)
        let outcome = try await workspace.finish(
            interrupted.candidate,
            expectedRevision: interrupted.publicationRevision
        )
        #expect(
            outcome == .published(
                documentID: interrupted.candidate.document.documentID
            )
        )
    }

    let located = try #require(
        try await reopened.sourceDocument(
            id: interrupted.candidate.document.documentID
        )
    )
    #expect(located.document.content == interrupted.candidate.document)
    #expect(
        located.document.artifact
            == interrupted.candidate.artifact.descriptor
    )
    #expect(located.location == .library)
    #expect(
        try LocalLibraryTestDriver.sourceDocumentCount(
            at: interrupted.libraryRoot
        ) == 1
    )
    #expect(
        try LocalLibraryTestDriver.visibleSourceDocumentCount(
            at: interrupted.libraryRoot
        ) == 1
    )
    #expect(
        try await reopened.recoverableImports().contains {
            $0.taskID == interrupted.taskID
        } == false
    )
}

@Test
func rollbackRecoveryReleasesFingerprintReservation() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fingerprint = ContentFingerprint("released-recovery-fingerprint")
    let interrupted = try await interruptPublication(
        at: root,
        point: .afterIntentCommit,
        label: "fingerprint-owner",
        fingerprint: fingerprint
    )
    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let secondSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/fingerprint-second"))
    )
    let secondWorkspace = try await reopened.accept(secondSource)
    let secondStaged = try await stageRecoveryPackage(
        for: secondWorkspace,
        at: root,
        label: "fingerprint-second"
    )
    let secondContent = makeFixtureContent()

    let outcome = try await secondWorkspace.finish(
        PublicationCandidate(
            fingerprint: fingerprint,
            artifact: secondStaged.artifact,
            document: secondContent,
            originalSource: secondSource
        ),
        expectedRevision: secondStaged.revision
    )

    #expect(outcome == .published(documentID: secondContent.documentID))
    #expect(
        try await reopened.sourceDocument(
            id: interrupted.candidate.document.documentID
        ) == nil
    )
}

@Test
func invalidMovedFinalWithoutStagingRollsBackAndCanRestage() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: .afterArtifactMove,
        label: "invalid-final"
    )
    try LocalLibraryTestDriver.tamperFinalArtifactPayload(
        at: interrupted.libraryRoot,
        documentID: interrupted.candidate.document.documentID
    )

    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let workspace = try #require(
        try await reopened.importWorkspace(id: interrupted.taskID)
    )
    let recovered = try await workspace.snapshot()
    #expect(recovered.state == .working)
    #expect(recovered.stagedArtifact == nil)
    #expect(
        try await reopened.sourceDocument(
            id: interrupted.candidate.document.documentID
        ) == nil
    )
    #expect(
        try LocalLibraryTestDriver.finalArtifactExists(
            at: interrupted.libraryRoot,
            documentID: interrupted.candidate.document.documentID
        ) == false
    )

    let restaged = try await stageRecoveryPackage(
        for: workspace,
        at: root,
        label: "invalid-final-restaged"
    )
    let replacement = PublicationCandidate(
        fingerprint: interrupted.candidate.fingerprint,
        artifact: restaged.artifact,
        document: interrupted.candidate.document,
        originalSource: interrupted.candidate.originalSource
    )
    #expect(
        try await workspace.finish(
            replacement,
            expectedRevision: restaged.revision
        ) == .published(documentID: replacement.document.documentID)
    )
}

@Test
func invalidFinalWithValidStagingIsQuarantinedAndKeepsOwnership()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: .afterIntentCommit,
        label: "invalid-final-with-staging"
    )
    let stagedContainer = interrupted.libraryRoot.appending(
        path: ManagedArtifactPath.staging(
            taskID: interrupted.taskID,
            artifactID: interrupted.candidate.artifact.rawValue
        ).relativePath
    )
    let finalContainer = interrupted.libraryRoot.appending(
        path: ManagedArtifactPath.artifacts(
            documentID: interrupted.candidate.document.documentID
        ).relativePath
    )
    try FileManager.default.copyItem(
        at: stagedContainer,
        to: finalContainer
    )
    try LocalLibraryTestDriver.tamperFinalArtifactPayload(
        at: interrupted.libraryRoot,
        documentID: interrupted.candidate.document.documentID
    )

    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let workspace = try #require(
        try await reopened.importWorkspace(id: interrupted.taskID)
    )
    let recovered = try await workspace.snapshot()
    #expect(recovered.state == .working)
    #expect(recovered.stagedArtifact == interrupted.candidate.artifact)
    #expect(
        try LocalLibraryTestDriver.finalArtifactExists(
            at: interrupted.libraryRoot,
            documentID: interrupted.candidate.document.documentID
        ) == false
    )
    #expect(
        try await workspace.finish(
            interrupted.candidate,
            expectedRevision: recovered.revision
        ) == .published(
            documentID: interrupted.candidate.document.documentID
        )
    )
}

@Test
func missingFinalAndStagingClearsOwnershipForRestaging() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: .afterIntentCommit,
        label: "both-artifacts-missing"
    )
    try FileManager.default.removeItem(
        at: interrupted.libraryRoot.appending(
            path: ManagedArtifactPath.staging(
                taskID: interrupted.taskID,
                artifactID: interrupted.candidate.artifact.rawValue
            ).relativePath
        )
    )

    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let workspace = try #require(
        try await reopened.importWorkspace(id: interrupted.taskID)
    )
    let recovered = try await workspace.snapshot()
    #expect(recovered.state == .working)
    #expect(recovered.stagedArtifact == nil)
    let restaged = try await stageRecoveryPackage(
        for: workspace,
        at: root,
        label: "both-artifacts-restaged"
    )
    #expect(restaged.artifact != interrupted.candidate.artifact)
}

@Test
func recoveryRejectsSymlinkedFinalWithoutTouchingDestination()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: .afterArtifactMove,
        label: "symlinked-final"
    )
    let finalContainer = interrupted.libraryRoot.appending(
        path: ManagedArtifactPath.artifacts(
            documentID: interrupted.candidate.document.documentID
        ).relativePath
    )
    let victim = root.appending(path: "SymlinkVictim")
    try FileManager.default.createDirectory(
        at: victim,
        withIntermediateDirectories: true
    )
    let sentinel = victim.appending(path: "sentinel")
    try Data("safe".utf8).write(to: sentinel)
    try FileManager.default.removeItem(at: finalContainer)
    try FileManager.default.createSymbolicLink(
        at: finalContainer,
        withDestinationURL: victim
    )

    await expectCorruptRecoveryOpen(interrupted.libraryRoot)
    #expect(try Data(contentsOf: sentinel) == Data("safe".utf8))
}

@Test
func testingFinishStillTranslatesProductionDatabaseErrors() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        faultInjector: .none
    )
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/testing-translation"))
    )
    let workspace = try await library.accept(source)
    let staged = try await stageRecoveryPackage(
        for: workspace,
        at: root,
        label: "testing-translation"
    )
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("testing-translation"),
        artifact: staged.artifact,
        document: makeFixtureContent(),
        originalSource: source
    )
    try LocalLibraryTestDriver.dropSourceDocumentsTable(at: libraryRoot)

    do {
        _ = try await workspace.finish(
            candidate,
            expectedRevision: staged.revision
        )
        Issue.record("Expected translated production database failure")
    } catch let error as LocalLibraryError {
        #expect(error == .unavailable)
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}

@Test
func startupRemovesCommittedDuplicateOrphanButKeepsOwnedStaging()
    async throws
{
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptCommittedDuplicateCleanup(at: root)
    #expect(
        try LocalLibraryTestDriver.stagingContainerExists(
            at: interrupted.libraryRoot,
            taskID: interrupted.duplicateTaskID,
            artifact: interrupted.duplicateCandidate.artifact
        )
    )
    #expect(
        try LocalLibraryTestDriver.stagingContainerExists(
            at: interrupted.libraryRoot,
            taskID: interrupted.ownedTaskID,
            artifact: interrupted.ownedArtifact
        )
    )

    let reopened = try await LocalLibrary.open(at: interrupted.libraryRoot)

    #expect(
        try LocalLibraryTestDriver.stagingContainerExists(
            at: interrupted.libraryRoot,
            taskID: interrupted.duplicateTaskID,
            artifact: interrupted.duplicateCandidate.artifact
        ) == false
    )
    #expect(
        try LocalLibraryTestDriver.stagingContainerExists(
            at: interrupted.libraryRoot,
            taskID: interrupted.ownedTaskID,
            artifact: interrupted.ownedArtifact
        )
    )
    let retryWorkspace = try #require(
        try await reopened.importWorkspace(id: interrupted.duplicateTaskID)
    )
    #expect(
        try await retryWorkspace.finish(
            interrupted.duplicateCandidate,
            expectedRevision: interrupted.duplicateRevision
        ) == interrupted.outcome
    )
}

@Test
func publicationRecoveryIsIdempotentAcrossRepeatedColdOpens() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let interrupted = try await interruptPublication(
        at: root,
        point: .beforeVisibilityCommit,
        label: "idempotent-recovery"
    )

    try await assertCompletedAfterReleasedOpen(interrupted)
    try await assertCompletedAfterReleasedOpen(interrupted)
    #expect(
        try LocalLibraryTestDriver.sourceDocumentCount(
            at: interrupted.libraryRoot
        ) == 1
    )
}

@MainActor @inline(never)
private func interruptPublication(
    at root: URL,
    point: PublicationFaultPoint,
    label: String,
    fingerprint: ContentFingerprint? = nil
) async throws -> InterruptedPublication {
    let libraryRoot = root.appending(path: "Library")
    let probe = ReleasedHandleProbe()
    let library = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        faultInjector: PublicationFaultInjector { hitPoint in
            if hitPoint == point {
                throw RecoveryCrash.at(hitPoint)
            }
        }
    )
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/\(label)"))
    )
    let workspace = try await library.accept(source)
    let staged = try await stageRecoveryPackage(
        for: workspace,
        at: root,
        label: label
    )
    let candidate = PublicationCandidate(
        fingerprint: fingerprint ?? ContentFingerprint(label),
        artifact: staged.artifact,
        document: makeFixtureContent(),
        originalSource: source
    )
    probe.library = library
    probe.workspace = workspace

    do {
        _ = try await workspace.finish(
            candidate,
            expectedRevision: staged.revision
        )
        Issue.record("Expected simulated crash at \(point)")
    } catch let error as RecoveryCrash {
        #expect(error == .at(point))
    } catch {
        Issue.record("Expected RecoveryCrash, got \(error)")
    }

    return InterruptedPublication(
        libraryRoot: libraryRoot,
        taskID: workspace.taskID,
        candidate: candidate,
        publicationRevision: staged.revision,
        releaseProbe: probe
    )
}

private func stageRecoveryPackage(
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
    return (artifact, try await workspace.snapshot().revision)
}

private struct InterruptedDuplicateCleanup: Sendable {
    let libraryRoot: URL
    let duplicateTaskID: ImportTaskID
    let duplicateCandidate: PublicationCandidate
    let duplicateRevision: UInt64
    let outcome: PublicationOutcome
    let ownedTaskID: ImportTaskID
    let ownedArtifact: StagedArtifact
}

@inline(never)
private func interruptCommittedDuplicateCleanup(
    at root: URL
) async throws -> InterruptedDuplicateCleanup {
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        faultInjector: PublicationFaultInjector { point in
            if point == .beforeCommittedStagingCleanup {
                throw RecoveryCrash.at(point)
            }
        }
    )
    let fingerprint = ContentFingerprint("duplicate-cleanup")
    let originalSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/duplicate-original"))
    )
    let originalWorkspace = try await library.accept(originalSource)
    let originalStaged = try await stageRecoveryPackage(
        for: originalWorkspace,
        at: root,
        label: "duplicate-original"
    )
    let originalContent = makeFixtureContent()
    _ = try await originalWorkspace.finish(
        PublicationCandidate(
            fingerprint: fingerprint,
            artifact: originalStaged.artifact,
            document: originalContent,
            originalSource: originalSource
        ),
        expectedRevision: originalStaged.revision
    )

    let ownedSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/owned-staging"))
    )
    let ownedWorkspace = try await library.accept(ownedSource)
    let owned = try await stageRecoveryPackage(
        for: ownedWorkspace,
        at: root,
        label: "owned-staging"
    )

    let duplicateSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/duplicate-later"))
    )
    let duplicateWorkspace = try await library.accept(duplicateSource)
    let duplicateStaged = try await stageRecoveryPackage(
        for: duplicateWorkspace,
        at: root,
        label: "duplicate-later"
    )
    let candidate = PublicationCandidate(
        fingerprint: fingerprint,
        artifact: duplicateStaged.artifact,
        document: makeFixtureContent(),
        originalSource: duplicateSource
    )
    let expectedOutcome = PublicationOutcome.alreadyImported(
        documentID: originalContent.documentID,
        location: .library,
        provenanceAdded: true
    )

    do {
        _ = try await duplicateWorkspace.finish(
            candidate,
            expectedRevision: duplicateStaged.revision
        )
        Issue.record("Expected committed-staging cleanup crash")
    } catch let error as RecoveryCrash {
        #expect(error == .at(.beforeCommittedStagingCleanup))
    } catch {
        Issue.record("Expected RecoveryCrash, got \(error)")
    }

    return InterruptedDuplicateCleanup(
        libraryRoot: libraryRoot,
        duplicateTaskID: duplicateWorkspace.taskID,
        duplicateCandidate: candidate,
        duplicateRevision: duplicateStaged.revision,
        outcome: expectedOutcome,
        ownedTaskID: ownedWorkspace.taskID,
        ownedArtifact: owned.artifact
    )
}

@inline(never)
private func assertCompletedAfterReleasedOpen(
    _ interrupted: InterruptedPublication
) async throws {
    let library = try await LocalLibrary.open(at: interrupted.libraryRoot)
    let workspace = try #require(
        try await library.importWorkspace(id: interrupted.taskID)
    )
    #expect(try await workspace.snapshot().state == .completed)
    #expect(
        try await library.sourceDocument(
            id: interrupted.candidate.document.documentID
        ) != nil
    )
}

private func expectCorruptRecoveryOpen(_ libraryRoot: URL) async {
    do {
        _ = try await LocalLibrary.open(at: libraryRoot)
        Issue.record("Expected corrupt recovery state")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}
