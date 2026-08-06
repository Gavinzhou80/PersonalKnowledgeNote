import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func duplicateReturnsExistingDocumentAndAddsNewProvenance() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeDuplicateFixture(at: root)

    let outcome = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )

    #expect(
        outcome == .alreadyImported(
            documentID: fixture.existingContent.documentID,
            location: .library,
            provenanceAdded: true
        )
    )
    #expect(
        try await fixture.library.sourceDocument(
            id: fixture.duplicateContent.documentID
        ) == nil
    )
    #expect(
        try LocalLibraryTestDriver.sourceDocumentExists(
            at: fixture.libraryRoot,
            documentID: fixture.duplicateContent.documentID
        ) == false
    )
    let completed = try await fixture.duplicateWorkspace.snapshot()
    #expect(completed.state == .completed)
    #expect(completed.revision == fixture.duplicateRevision + 1)
    #expect(completed.stagedArtifact == nil)
    #expect(
        try LocalLibraryTestDriver.hasStagedOwnership(
            at: fixture.libraryRoot,
            taskID: fixture.duplicateWorkspace.taskID
        ) == false
    )
    #expect(
        try await fixture.duplicateWorkspace.stagedArtifactCount() == 0
    )
    #expect(
        try LocalLibraryTestDriver.provenanceCount(
            at: fixture.libraryRoot,
            documentID: fixture.existingContent.documentID,
            source: fixture.duplicateSource
        ) == 1
    )
    let existing = try #require(
        try await fixture.library.sourceDocument(
            id: fixture.existingContent.documentID
        )
    )
    #expect(existing.document.content == fixture.existingContent)
    #expect(existing.location == .library)
    #expect(
        try await fixture.library.recoverableImports().contains {
            $0.taskID == fixture.duplicateWorkspace.taskID
        } == false
    )
}

@Test
func repeatedSameProvenanceReportsNotAdded() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeDuplicateFixture(
        at: root,
        duplicateSourceMatchesExisting: true
    )

    let outcome = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )

    #expect(
        outcome == .alreadyImported(
            documentID: fixture.existingContent.documentID,
            location: .library,
            provenanceAdded: false
        )
    )
    #expect(
        try LocalLibraryTestDriver.provenanceCount(
            at: fixture.libraryRoot,
            documentID: fixture.existingContent.documentID,
            source: fixture.duplicateSource
        ) == 1
    )
}

@Test
func duplicateInTrashReportsTrashLocation() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeDuplicateFixture(at: root)
    try LocalLibraryTestDriver.setLocation(
        at: fixture.libraryRoot,
        documentID: fixture.existingContent.documentID,
        location: .trash
    )

    let outcome = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )

    #expect(
        outcome == .alreadyImported(
            documentID: fixture.existingContent.documentID,
            location: .trash,
            provenanceAdded: true
        )
    )
    let existing = try #require(
        try await fixture.library.sourceDocument(
            id: fixture.existingContent.documentID
        )
    )
    #expect(existing.location == .trash)
}

@Test(arguments: [
    PublicationFaultPoint.beforeDuplicateProvenanceInsert,
    .afterDuplicateProvenanceInsert,
])
func provenanceFailureRollsBackDuplicateCompletion(
    point: PublicationFaultPoint
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let failed = try await failDuplicateProvenanceTransaction(
        at: root,
        point: point
    )

    let reopened = try await LocalLibrary.open(at: failed.libraryRoot)
    let retryWorkspace = try #require(
        try await reopened.importWorkspace(id: failed.taskID)
    )
    let outcome = try await retryWorkspace.finish(
        failed.candidate,
        expectedRevision: failed.expectedRevision
    )

    #expect(
        outcome == .alreadyImported(
            documentID: failed.existingDocumentID,
            location: .library,
            provenanceAdded: true
        )
    )
    #expect(
        try LocalLibraryTestDriver.provenanceCount(
            at: failed.libraryRoot,
            documentID: failed.existingDocumentID,
            source: failed.candidate.originalSource
        ) == 1
    )
}

@Test
func committedDuplicateRetryReturnsStoredExactOutcomeAfterReopen() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let committed = try await commitDuplicateInReleasedScope(at: root)
    let reopened = try await LocalLibrary.open(at: committed.libraryRoot)
    let workspace = try #require(
        try await reopened.importWorkspace(id: committed.taskID)
    )

    let retry = try await workspace.finish(
        committed.candidate,
        expectedRevision: committed.oldRevision
    )

    #expect(retry == committed.outcome)
    #expect(
        try await reopened.recoverableImports().contains {
            $0.taskID == committed.taskID
        } == false
    )
}

@Test
func publishedRetrySurvivesLaterMoveToTrash() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let published = try await publishSingleDocument(at: root)
    try LocalLibraryTestDriver.setLocation(
        at: published.libraryRoot,
        documentID: published.documentID,
        location: .trash
    )

    #expect(try await published.workspace.snapshot().state == .completed)
    let workspace = try #require(
        try await published.library.importWorkspace(
            id: published.workspace.taskID
        )
    )
    #expect(
        try await workspace.finish(
            published.candidate,
            expectedRevision: published.oldRevision
        ) == .published(documentID: published.documentID)
    )
    let current = try #require(
        try await published.library.sourceDocument(
            id: published.documentID
        )
    )
    #expect(current.location == .trash)
}

@Test
func duplicateRetryKeepsHistoricalLocationAfterLaterMoveToTrash() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeDuplicateFixture(at: root)
    let originalOutcome = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )
    #expect(
        originalOutcome == .alreadyImported(
            documentID: fixture.existingContent.documentID,
            location: .library,
            provenanceAdded: true
        )
    )
    try LocalLibraryTestDriver.setLocation(
        at: fixture.libraryRoot,
        documentID: fixture.existingContent.documentID,
        location: .trash
    )

    #expect(
        try await fixture.duplicateWorkspace.snapshot().state == .completed
    )
    let workspace = try #require(
        try await fixture.library.importWorkspace(
            id: fixture.duplicateWorkspace.taskID
        )
    )
    #expect(
        try await workspace.finish(
            fixture.duplicateCandidate,
            expectedRevision: fixture.duplicateRevision
        ) == originalOutcome
    )
    let current = try #require(
        try await fixture.library.sourceDocument(
            id: fixture.existingContent.documentID
        )
    )
    #expect(current.location == .trash)
}

@Test(arguments: [ProvenanceCorruption.missing, .corrupt])
func publishedCompletionRejectsInvalidProvenance(
    corruption: ProvenanceCorruption
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let published = try await publishSingleDocument(at: root)
    try corruptProvenance(
        corruption,
        at: published.libraryRoot,
        documentID: published.documentID,
        source: published.source
    )

    await expectProvenanceCorruption(
        library: published.library,
        workspace: published.workspace,
        candidate: published.candidate,
        expectedRevision: published.oldRevision
    )
}

@Test(arguments: [ProvenanceCorruption.missing, .corrupt])
func duplicateCompletionRejectsInvalidProvenance(
    corruption: ProvenanceCorruption
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try await makeDuplicateFixture(at: root)
    _ = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )
    try corruptProvenance(
        corruption,
        at: fixture.libraryRoot,
        documentID: fixture.existingContent.documentID,
        source: fixture.duplicateSource
    )

    await expectProvenanceCorruption(
        library: fixture.library,
        workspace: fixture.duplicateWorkspace,
        candidate: fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )
}

private enum SimulatedCrash: Error, Equatable, Sendable {
    case beforeDuplicateProvenanceInsert
    case afterDuplicateProvenanceInsert

    init(point: PublicationFaultPoint) {
        switch point {
        case .beforeDuplicateProvenanceInsert:
            self = .beforeDuplicateProvenanceInsert
        case .afterDuplicateProvenanceInsert:
            self = .afterDuplicateProvenanceInsert
        case .afterIntentCommit,
             .afterArtifactMove,
             .beforeVisibilityCommit,
             .afterVisibilityCommit,
             .beforeCommittedStagingCleanup:
            preconditionFailure("Not a duplicate transaction fault point")
        }
    }
}

enum ProvenanceCorruption: Sendable {
    case missing
    case corrupt
}

private struct DuplicateFixture: Sendable {
    let libraryRoot: URL
    let library: LocalLibrary
    let existingSource: OriginalSource
    let existingContent: SourceDocumentContent
    let duplicateSource: OriginalSource
    let duplicateWorkspace: ImportWorkspace
    let duplicateRevision: UInt64
    let duplicateContent: SourceDocumentContent
    let duplicateCandidate: PublicationCandidate
}

private func makeDuplicateFixture(
    at root: URL,
    duplicateSourceMatchesExisting: Bool = false,
    library suppliedLibrary: LocalLibrary? = nil
) async throws -> DuplicateFixture {
    let libraryRoot = root.appending(path: "Library")
    let library: LocalLibrary
    if let suppliedLibrary {
        library = suppliedLibrary
    } else {
        library = try await LocalLibrary.open(at: libraryRoot)
    }
    let existingSource = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/duplicate-existing"))
    )
    let existingWorkspace = try await library.accept(existingSource)
    let existingStaged = try await stageDuplicatePackage(
        for: existingWorkspace,
        at: root,
        label: "duplicate-existing"
    )
    let existingContent = makeFixtureContent()
    let fingerprint = ContentFingerprint("duplicate-resolution")
    _ = try await existingWorkspace.finish(
        PublicationCandidate(
            fingerprint: fingerprint,
            artifact: existingStaged.artifact,
            document: existingContent,
            originalSource: existingSource
        ),
        expectedRevision: existingStaged.revision
    )

    let duplicateSource: OriginalSource = duplicateSourceMatchesExisting
        ? existingSource
        : .webpage(
            try #require(
                URL(string: "https://example.com/duplicate-new-source")
            )
        )
    let duplicateWorkspace = try await library.accept(duplicateSource)
    let duplicateStaged = try await stageDuplicatePackage(
        for: duplicateWorkspace,
        at: root,
        label: "duplicate-candidate"
    )
    let duplicateContent = makeFixtureContent()
    let candidate = PublicationCandidate(
        fingerprint: fingerprint,
        artifact: duplicateStaged.artifact,
        document: duplicateContent,
        originalSource: duplicateSource
    )
    return DuplicateFixture(
        libraryRoot: libraryRoot,
        library: library,
        existingSource: existingSource,
        existingContent: existingContent,
        duplicateSource: duplicateSource,
        duplicateWorkspace: duplicateWorkspace,
        duplicateRevision: duplicateStaged.revision,
        duplicateContent: duplicateContent,
        duplicateCandidate: candidate
    )
}

private func stageDuplicatePackage(
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

private struct FailedDuplicate: Sendable {
    let libraryRoot: URL
    let taskID: ImportTaskID
    let existingDocumentID: SourceDocumentID
    let candidate: PublicationCandidate
    let expectedRevision: UInt64
}

@inline(never)
private func failDuplicateProvenanceTransaction(
    at root: URL,
    point: PublicationFaultPoint
) async throws -> FailedDuplicate {
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.openForTesting(
        at: libraryRoot,
        faultInjector: PublicationFaultInjector { hitPoint in
            if hitPoint == point {
                throw SimulatedCrash(point: hitPoint)
            }
        }
    )
    let fixture = try await makeDuplicateFixture(
        at: root,
        library: library
    )

    do {
        _ = try await fixture.duplicateWorkspace.finish(
            fixture.duplicateCandidate,
            expectedRevision: fixture.duplicateRevision
        )
        Issue.record("Expected injected duplicate provenance failure")
    } catch let error as SimulatedCrash {
        #expect(error == SimulatedCrash(point: point))
    } catch {
        Issue.record("Expected SimulatedCrash, got \(error)")
    }

    let afterFailure = try await fixture.duplicateWorkspace.snapshot()
    #expect(afterFailure.state == .running)
    #expect(afterFailure.revision == fixture.duplicateRevision)
    #expect(afterFailure.stagedArtifact == fixture.duplicateCandidate.artifact)
    #expect(
        try LocalLibraryTestDriver.hasStagedOwnership(
            at: fixture.libraryRoot,
            taskID: fixture.duplicateWorkspace.taskID
        )
    )
    #expect(
        try LocalLibraryTestDriver.hasStoredOutcome(
            at: fixture.libraryRoot,
            taskID: fixture.duplicateWorkspace.taskID
        ) == false
    )
    #expect(
        try await fixture.duplicateWorkspace.stagedArtifactCount() == 1
    )
    #expect(
        try LocalLibraryTestDriver.provenanceCount(
            at: fixture.libraryRoot,
            documentID: fixture.existingContent.documentID,
            source: fixture.duplicateSource
        ) == 0
    )
    #expect(
        try LocalLibraryTestDriver.sourceDocumentExists(
            at: fixture.libraryRoot,
            documentID: fixture.duplicateContent.documentID
        ) == false
    )
    return FailedDuplicate(
        libraryRoot: fixture.libraryRoot,
        taskID: fixture.duplicateWorkspace.taskID,
        existingDocumentID: fixture.existingContent.documentID,
        candidate: fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )
}

private struct CommittedDuplicate: Sendable {
    let libraryRoot: URL
    let taskID: ImportTaskID
    let candidate: PublicationCandidate
    let oldRevision: UInt64
    let outcome: PublicationOutcome
}

@inline(never)
private func commitDuplicateInReleasedScope(
    at root: URL
) async throws -> CommittedDuplicate {
    let fixture = try await makeDuplicateFixture(at: root)
    let outcome = try await fixture.duplicateWorkspace.finish(
        fixture.duplicateCandidate,
        expectedRevision: fixture.duplicateRevision
    )
    return CommittedDuplicate(
        libraryRoot: fixture.libraryRoot,
        taskID: fixture.duplicateWorkspace.taskID,
        candidate: fixture.duplicateCandidate,
        oldRevision: fixture.duplicateRevision,
        outcome: outcome
    )
}

private struct PublishedSingle: Sendable {
    let libraryRoot: URL
    let library: LocalLibrary
    let workspace: ImportWorkspace
    let source: OriginalSource
    let documentID: SourceDocumentID
    let candidate: PublicationCandidate
    let oldRevision: UInt64
}

private func publishSingleDocument(
    at root: URL
) async throws -> PublishedSingle {
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/provenance-published"))
    )
    let workspace = try await library.accept(source)
    let staged = try await stageDuplicatePackage(
        for: workspace,
        at: root,
        label: "provenance-published"
    )
    let content = makeFixtureContent()
    let candidate = PublicationCandidate(
        fingerprint: ContentFingerprint("provenance-published"),
        artifact: staged.artifact,
        document: content,
        originalSource: source
    )
    _ = try await workspace.finish(
        candidate,
        expectedRevision: staged.revision
    )
    return PublishedSingle(
        libraryRoot: libraryRoot,
        library: library,
        workspace: workspace,
        source: source,
        documentID: content.documentID,
        candidate: candidate,
        oldRevision: staged.revision
    )
}

private func corruptProvenance(
    _ corruption: ProvenanceCorruption,
    at libraryRoot: URL,
    documentID: SourceDocumentID,
    source: OriginalSource
) throws {
    switch corruption {
    case .missing:
        try LocalLibraryTestDriver.removeProvenance(
            at: libraryRoot,
            documentID: documentID,
            source: source
        )
    case .corrupt:
        try LocalLibraryTestDriver.corruptProvenance(
            at: libraryRoot,
            documentID: documentID,
            source: source
        )
    }
}

private func expectProvenanceCorruption(
    library: LocalLibrary,
    workspace: ImportWorkspace,
    candidate: PublicationCandidate,
    expectedRevision: UInt64
) async {
    await expectCorruptProvenance("snapshot") {
        _ = try await workspace.snapshot()
    }
    await expectCorruptProvenance("importWorkspace") {
        _ = try await library.importWorkspace(id: workspace.taskID)
    }
    await expectCorruptProvenance("recoverableImports") {
        _ = try await library.recoverableImports()
    }
    await expectCorruptProvenance("storedOutcome") {
        _ = try await workspace.finish(
            candidate,
            expectedRevision: expectedRevision
        )
    }
}

private func expectCorruptProvenance(
    _ operationName: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected \(operationName) to reject provenance corruption")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}
