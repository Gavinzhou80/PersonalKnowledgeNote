import Foundation
import GRDB
import KnowledgeCore
import TestFixtures
import Testing
@testable import LocalLibrary

@Test
func acceptedTasksReceiveDurableFIFOSequence() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(
        .webpage(URL(string: "https://example.test/1")!)
    )
    let second = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )
    let third = try await library.accept(
        .webpage(URL(string: "https://example.test/3")!)
    )

    let retained = try await library.retainedImports()
    #expect(
        retained.map(\.taskID)
            == [first.taskID, second.taskID, third.taskID]
    )
    #expect(retained.compactMap(\.queueSequence) == [1, 2, 3])
    #expect(retained.allSatisfy { $0.queueSequence != nil })
    #expect(retained.allSatisfy { $0.state == .queued })
}

@Test
func claimNextRunnableIsExclusiveAndDurable() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(
        .webpage(URL(string: "https://example.test/1")!)
    )
    _ = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )

    let claimed = try #require(try await library.claimNextRunnable())
    #expect(claimed.claimed.taskID == first.taskID)
    #expect(claimed.claimed.state == .running)
    #expect(claimed.queueUpdates.count == 1)
    #expect(try await library.claimNextRunnable()?.claimed.taskID == nil)

    let reopened = try await LocalLibrary.open(at: root)
    let retained = try await reopened.retainedImports()
    #expect(retained.first?.taskID == first.taskID)
    #expect(retained.first?.state == .running)
}

@Test
func migratesV1ImportTasksIntoDurableQueue() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let fixture = try ImportQueueTestDriver.createV1Fixture(at: root)

    let library = try await LocalLibrary.open(at: root)
    let retained = try await library.retainedImports()
    let migrated = try ImportQueueTestDriver.importRows(at: root)

    #expect(
        retained.map(\.taskID)
            == [fixture.accepted, fixture.working, fixture.completed]
    )
    #expect(retained.map(\.state) == [.queued, .queued, .completed])
    #expect(retained.compactMap(\.queueSequence) == [1, 3])
    #expect(migrated.map(\.journalSequence) == [1, 2, 3, 4])
    #expect(Set(migrated.map(\.journalSequence)).count == 4)
    #expect(migrated.allSatisfy { $0.journalSequence > 0 })
    #expect(
        migrated.map(\.state)
            == [.queued, .completed, .queued, .abandoned]
    )
    #expect(retained.contains { $0.taskID == fixture.abandoned } == false)

    let appended = try await library.accept(
        .webpage(URL(string: "https://example.test/appended")!)
    )
    let appendedSnapshot = try #require(
        try await library.retainedImports().first {
            $0.taskID == appended.taskID
        }
    )
    #expect(appendedSnapshot.journalSequence == 5)
    #expect(appendedSnapshot.queueSequence == 5)
    #expect(try ImportQueueTestDriver.clock(at: root) == 5)
}

@Test
func malformedV1TaskIdentifierIsCorruptDuringMigration() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    try ImportQueueTestDriver.createMalformedV1TaskIdentifierFixture(at: root)

    do {
        _ = try await LocalLibrary.open(at: root)
        Issue.record("Expected malformed v1 task identifier corruption")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    }
}

@Test
func claimRevisesClaimedAndShiftedQueuedTasksOnce() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(
        .webpage(URL(string: "https://example.test/1")!)
    )
    let second = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )
    let third = try await library.accept(
        .webpage(URL(string: "https://example.test/3")!)
    )

    let mutation = try #require(try await library.claimNextRunnable())

    #expect(mutation.claimed.taskID == first.taskID)
    #expect(mutation.claimed.revision == 1)
    #expect(mutation.claimed.queueSequence == nil)
    #expect(mutation.queueUpdates.map(\.taskID) == [second.taskID, third.taskID])
    #expect(mutation.queueUpdates.map(\.revision) == [1, 1])
    #expect(mutation.queueUpdates.compactMap(\.queueSequence) == [2, 3])
}

@Test
func tailAcceptanceDoesNotReviseExistingQueuedTasks() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let first = try await library.accept(
        .webpage(URL(string: "https://example.test/1")!)
    )
    let second = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )
    _ = try await library.accept(
        .webpage(URL(string: "https://example.test/3")!)
    )

    let retained = try await library.retainedImports()
    #expect(retained.first { $0.taskID == first.taskID }?.revision == 0)
    #expect(retained.first { $0.taskID == second.taskID }?.revision == 0)
}

@Test
func directPDFPublicationRemovesQueueEntryAndRevisesShiftedTasks() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let externalPDF = root.appending(path: "external.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let pdf = try await library.accept(.pdfFile(externalPDF))
    let second = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )
    let third = try await library.accept(
        .webpage(URL(string: "https://example.test/3")!)
    )
    let accepted = try await pdf.snapshot()
    let artifact = try #require(accepted.stagedArtifact)
    let content = makeFixtureContent()

    _ = try await pdf.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("direct-pdf-queue"),
            artifact: artifact,
            document: content,
            originalSource: .pdfFile(externalPDF)
        ),
        expectedRevision: accepted.revision
    )

    let retained = try await library.retainedImports()
    #expect(retained.first { $0.taskID == pdf.taskID }?.state == .completed)
    #expect(retained.first { $0.taskID == pdf.taskID }?.queueSequence == nil)
    #expect(retained.first { $0.taskID == second.taskID }?.revision == 1)
    #expect(retained.first { $0.taskID == third.taskID }?.revision == 1)
}

@Test(arguments: QueueBlockingState.allCases)
func claimIsNilWhileExclusiveStateExists(
    blockingState: QueueBlockingState
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)

    switch blockingState {
    case .running:
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/running")!)
        )
        _ = try #require(try await library.claimNextRunnable())
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/queued")!)
        )
    case .cancelling:
        let running = try await library.accept(
            .webpage(URL(string: "https://example.test/cancelling")!)
        )
        _ = try #require(try await library.claimNextRunnable())
        try ImportQueueTestDriver.setState(
            .cancelling,
            at: root,
            taskID: running.taskID,
            cancellationRequested: true
        )
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/queued")!)
        )
    case .publicationPending:
        let pending = try await makePreparedPublication(at: root, library: library)
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/queued")!)
        )
        #expect(
            try await pending.snapshot().state == .publicationPending
        )
    }

    #expect(try await library.claimNextRunnable()?.claimed.taskID == nil)
}

@Test
func queueClockDoesNotReuseClearedActiveSequence() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    _ = try await library.accept(
        .webpage(URL(string: "https://example.test/1")!)
    )
    let firstClaim = try #require(try await library.claimNextRunnable())
    #expect(firstClaim.claimed.journalSequence == 1)
    #expect(firstClaim.claimed.queueSequence == nil)

    let second = try await library.accept(
        .webpage(URL(string: "https://example.test/2")!)
    )
    let secondSnapshot = try #require(
        try await library.retainedImports().first {
            $0.taskID == second.taskID
        }
    )
    #expect(secondSnapshot.journalSequence == 2)
    #expect(secondSnapshot.queueSequence == 2)
    #expect(try ImportQueueTestDriver.clock(at: root) == 2)
}

@Test
func queueClockOverflowIsRejectedWithoutPersistingTask() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    try ImportQueueTestDriver.setClock(Int64.max, at: root)

    do {
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/overflow")!)
        )
        Issue.record("Expected queue clock overflow rejection")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    }

    #expect(try LocalLibraryTestDriver.taskCount(at: root) == 0)
    #expect(try ImportQueueTestDriver.clock(at: root) == UInt64(Int64.max))
}

@Test
func staleQueueClockRejectsAcceptanceAndRollsBack() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    _ = try await library.accept(
        .webpage(URL(string: "https://example.test/clock-1")!)
    )
    _ = try await library.accept(
        .webpage(URL(string: "https://example.test/clock-2")!)
    )
    let before = try await library.retainedImports()
    try ImportQueueTestDriver.setClock(1, at: root)

    await expectCorruptOperation("stale queue clock acceptance") {
        _ = try await library.accept(
            .webpage(URL(string: "https://example.test/clock-3")!)
        )
    }

    let after = try await library.retainedImports()
    #expect(after.map(\.taskID) == before.map(\.taskID))
    #expect(after.map(\.journalSequence) == before.map(\.journalSequence))
    #expect(after.map(\.revision) == before.map(\.revision))
    #expect(try LocalLibraryTestDriver.taskCount(at: root) == 2)
    #expect(try ImportQueueTestDriver.clock(at: root) == 1)
}

@Test(arguments: WrongDurableStorageType.allCases)
func wrongDurableStorageTypesAreCorruptAcrossReadPaths(
    corruption: WrongDurableStorageType
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/wrong-storage")!)
    )
    try ImportQueueTestDriver.corruptStorageType(
        corruption,
        at: root,
        taskID: workspace.taskID
    )

    await expectCorruptOperation("workspace snapshot") {
        _ = try await workspace.snapshot()
    }
    await expectCorruptOperation("import workspace lookup") {
        _ = try await library.importWorkspace(id: workspace.taskID)
    }
    await expectCorruptOperation("retained imports") {
        _ = try await library.retainedImports()
    }
}

@Test(arguments: InvalidDurableQueueRow.allCases)
func invalidV2ImportTaskRowsAreCorrupt(
    corruption: InvalidDurableQueueRow
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/corrupt")!)
    )
    try ImportQueueTestDriver.corrupt(
        corruption,
        at: root,
        taskID: workspace.taskID
    )

    await expectCorruptRetainedImports(library)
}

@Test
func duplicateJournalSequenceCorruptsSingleTaskSnapshot() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/snapshot-corruption")!)
    )
    try ImportQueueTestDriver.corrupt(
        .duplicateJournalSequence,
        at: root,
        taskID: workspace.taskID
    )

    do {
        _ = try await workspace.snapshot()
        Issue.record("Expected duplicate journal sequence corruption")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    }
}

@Test
func retainedCompletedHistoryUsesConstantAssociationQueryCount() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let externalPDF = root.appending(path: "history.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )
    let libraryRoot = root.appending(path: "Library")
    let library = try await LocalLibrary.open(at: libraryRoot)
    let workspace = try await library.accept(.pdfFile(externalPDF))
    let accepted = try await workspace.snapshot()
    let artifact = try #require(accepted.stagedArtifact)
    let content = makeFixtureContent()
    _ = try await workspace.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("query-count-history"),
            artifact: artifact,
            document: content,
            originalSource: .pdfFile(externalPDF)
        ),
        expectedRevision: accepted.revision
    )
    let singleCount = try ImportQueueTestDriver
        .retainedImportStatementCount(at: libraryRoot)
    try ImportQueueTestDriver.insertCompletedDuplicateHistory(
        count: 12,
        documentID: content.documentID,
        at: libraryRoot
    )

    let manyCount = try ImportQueueTestDriver
        .retainedImportStatementCount(at: libraryRoot)

    #expect(manyCount == singleCount)
}

@Test
func retainedCompletedProjectionIncludesValidatedSourceOutcomeAndIssues() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let externalPDF = root.appending(path: "projection.pdf")
    try FileManager.default.copyItem(
        at: FixtureCatalog.minimalPDFURL,
        to: externalPDF
    )
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let workspace = try await library.accept(.pdfFile(externalPDF))
    let accepted = try await workspace.snapshot()
    let artifact = try #require(accepted.stagedArtifact)
    let base = makeFixtureContent()
    let relatedBlockID = try #require(base.blocks.first?.id)
    let issue = KnowledgeCore.ImportIssue(
        code: .optionalWebImageUnavailable,
        relatedBlockID: relatedBlockID
    )
    let content = SourceDocumentContent(
        documentID: base.documentID,
        importedMetadata: base.importedMetadata,
        blocks: base.blocks,
        structure: base.structure,
        evidence: base.evidence,
        issues: [issue]
    )
    let outcome = try await workspace.finish(
        PublicationCandidate(
            fingerprint: ContentFingerprint("durable-history-projection"),
            artifact: artifact,
            document: content,
            originalSource: .pdfFile(externalPDF)
        ),
        expectedRevision: accepted.revision
    )

    let retained = try await library.retainedImports()
    let completed = try #require(retained.first { $0.taskID == workspace.taskID })
    #expect(completed.originalSource == .pdfFile(externalPDF))
    #expect(completed.outcome == outcome)
    #expect(completed.publicationIssues == [issue])
}

@Test
func onlySQLiteBusyAndLockedAreTransientQueueClaimErrors() {
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_BUSY
    )) == .transientDatabaseContention)
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_BUSY_TIMEOUT
    )) == .transientDatabaseContention)
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_LOCKED
    )) == .transientDatabaseContention)
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_LOCKED_SHAREDCACHE
    )) == .transientDatabaseContention)
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_IOERR
    )) == nil)
    #expect(transientDurableQueueClaimError(for: DatabaseError(
        resultCode: .SQLITE_CORRUPT
    )) == nil)
}

@Test
func nullJournalSequenceIsCorruptAcrossPublicReadPaths() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(
        .webpage(URL(string: "https://example.test/null-journal")!)
    )
    try ImportQueueTestDriver.clearJournalSequence(
        at: root,
        taskID: workspace.taskID
    )

    await expectCorruptOperation("workspace snapshot") {
        _ = try await workspace.snapshot()
    }
    await expectCorruptOperation("import workspace lookup") {
        _ = try await library.importWorkspace(id: workspace.taskID)
    }
    await expectCorruptOperation("retained imports") {
        _ = try await library.retainedImports()
    }
}

@Test(arguments: CancellationFlagCase.all)
func cancellationRequestedMatchesDurableState(
    testCase: CancellationFlagCase
) throws {
    let record = try makeCancellationFlagRecord(testCase)

    do {
        let snapshot = try record.snapshot(stagedArtifact: nil)
        if testCase.isValid {
            #expect(snapshot.state == testCase.state)
        } else {
            Issue.record("Expected invalid cancellation flag for \(testCase.state)")
        }
    } catch let error as LocalLibraryError {
        if testCase.isValid {
            Issue.record("Expected valid cancellation flag, got \(error)")
        } else {
            guard case .corruptLibrary = error else {
                Issue.record("Expected corruptLibrary, got \(error)")
                return
            }
        }
    }
}

enum QueueBlockingState: CaseIterable, Sendable {
    case running
    case cancelling
    case publicationPending
}

enum InvalidDurableQueueRow: CaseIterable, Sendable {
    case zeroJournalSequence
    case duplicateJournalSequence
    case queuedWithoutQueueSequence
    case nonqueuedWithQueueSequence
    case failedWithoutFailure
    case failedWithPartialFailure
    case failedWithInvalidFailureCodec
    case nonfailedWithFailure
    case cancellationRequested
}

enum WrongDurableStorageType: CaseIterable, Sendable {
    case journalSequence
    case failurePayload
}

struct CancellationFlagCase: Sendable {
    let state: ImportTaskState
    let cancellationRequested: Bool
    let isValid: Bool

    static let all: [CancellationFlagCase] = [
        .init(state: .cancelling, cancellationRequested: true, isValid: true),
        .init(state: .cancelled, cancellationRequested: true, isValid: true),
        .init(state: .cancelling, cancellationRequested: false, isValid: false),
        .init(state: .cancelled, cancellationRequested: false, isValid: false),
        .init(state: .queued, cancellationRequested: false, isValid: true),
        .init(state: .running, cancellationRequested: false, isValid: true),
        .init(state: .failed, cancellationRequested: false, isValid: true),
        .init(state: .completed, cancellationRequested: false, isValid: true),
        .init(
            state: .publicationPending,
            cancellationRequested: false,
            isValid: true
        ),
        .init(state: .abandoned, cancellationRequested: false, isValid: true),
        .init(state: .queued, cancellationRequested: true, isValid: false),
        .init(state: .running, cancellationRequested: true, isValid: false),
        .init(state: .failed, cancellationRequested: true, isValid: false),
        .init(state: .completed, cancellationRequested: true, isValid: false),
        .init(
            state: .publicationPending,
            cancellationRequested: true,
            isValid: false
        ),
        .init(state: .accepted, cancellationRequested: true, isValid: false),
        .init(state: .working, cancellationRequested: true, isValid: false),
        .init(state: .abandoned, cancellationRequested: true, isValid: false),
    ]
}

private func makeCancellationFlagRecord(
    _ testCase: CancellationFlagCase
) throws -> ImportTaskRecord {
    let failureVersion: Int64? = testCase.state == .failed ? 1 : nil
    let failurePayload = testCase.state == .failed ? Data("failure".utf8) : nil
    let outcome = testCase.state == .completed
        ? try DomainJSON.encode(
            PublicationOutcome.published(documentID: SourceDocumentID())
        )
        : nil
    return ImportTaskRecord(
        taskID: UUID().uuidString,
        sourceKind: "webpage",
        sourceValue: "https://example.test/cancellation-matrix",
        attempt: 1,
        revision: 0,
        state: testCase.state.rawValue,
        journalSequence: 1,
        queueSequence: testCase.state == .queued ? 1 : nil,
        failureCodecVersion: failureVersion,
        failurePayload: failurePayload,
        cancellationRequested: testCase.cancellationRequested,
        checkpointOrdinal: nil,
        checkpointCodecVersion: nil,
        checkpointPayload: nil,
        stagedArtifactID: nil,
        outcomeJSON: outcome
    )
}

private func makePreparedPublication(
    at root: URL,
    library: LocalLibrary
) async throws -> ImportWorkspace {
    let package = FileManager.default.temporaryDirectory.appending(
        path: "PendingPackage-\(UUID().uuidString)"
    )
    defer { try? FileManager.default.removeItem(at: package) }
    try FileManager.default.createDirectory(
        at: package,
        withIntermediateDirectories: true
    )
    try Data("pending".utf8).write(to: package.appending(path: "index.html"))
    let source = OriginalSource.webpage(
        URL(string: "https://example.test/pending")!
    )
    let workspace = try await library.accept(source)
    let accepted = try await workspace.snapshot()
    let artifact = try await workspace.stageArtifact(
        .package(
            package,
            descriptor: SourceArtifactDescriptor(
                kind: .webPackage,
                byteCount: 1,
                contentHash: "pending"
            )
        ),
        expectedRevision: accepted.revision
    )
    let snapshot = try await workspace.snapshot()
    try LocalLibraryTestDriver.prepareHiddenPublication(
        at: root,
        taskID: workspace.taskID,
        candidate: PublicationCandidate(
            fingerprint: ContentFingerprint("pending"),
            artifact: artifact,
            document: makeFixtureContent(),
            originalSource: source
        ),
        expectedRevision: snapshot.revision
    )
    return workspace
}

private func expectCorruptRetainedImports(_ library: LocalLibrary) async {
    do {
        _ = try await library.retainedImports()
        Issue.record("Expected corrupt durable import row")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}

private func expectCorruptOperation(
    _ label: String,
    operation: () async throws -> Void
) async {
    do {
        try await operation()
        Issue.record("Expected corrupt \(label)")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary from \(label), got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError from \(label), got \(error)")
    }
}

private enum ImportQueueTestDriver {
    struct V1Fixture {
        let accepted: ImportTaskID
        let completed: ImportTaskID
        let working: ImportTaskID
        let abandoned: ImportTaskID
    }

    struct ImportRow {
        let taskID: ImportTaskID
        let state: ImportTaskState
        let journalSequence: UInt64
        let queueSequence: UInt64?
    }

    static func createV1Fixture(at root: URL) throws -> V1Fixture {
        let queue = try DatabaseQueue(
            path: root.appending(path: "library.sqlite").path
        )
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_library") { db in
            try createV1Schema(in: db)
        }
        try migrator.migrate(queue)

        let accepted = ImportTaskID()
        let completed = ImportTaskID()
        let working = ImportTaskID()
        let abandoned = ImportTaskID()
        let completedContent = makeFixtureContent()
        let descriptor = SourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: 1,
            contentHash: "migrated"
        )
        let sourceURL = "https://example.test/completed"
        try queue.write { db in
            try insertLegacyTask(
                accepted,
                sourceValue: "https://example.test/accepted",
                state: .accepted,
                outcome: nil,
                in: db
            )
            try insertLegacyTask(
                completed,
                sourceValue: sourceURL,
                state: .completed,
                outcome: DomainJSON.encode(
                    PublicationOutcome.published(
                        documentID: completedContent.documentID
                    )
                ),
                in: db
            )
            try insertLegacyTask(
                working,
                sourceValue: "https://example.test/working",
                state: .working,
                outcome: nil,
                in: db
            )
            try insertLegacyTask(
                abandoned,
                sourceValue: "https://example.test/abandoned",
                state: .abandoned,
                outcome: nil,
                in: db
            )
            try SourceDocumentRecord(
                documentID: completedContent.documentID.rawValue.uuidString,
                fingerprint: "migrated",
                location: ExistingDocumentLocation.library.rawValue,
                visibility: SourceDocumentVisibility.visible.rawValue,
                contentJSON: DomainJSON.encode(completedContent),
                artifactDescriptorJSON: DomainJSON.encode(descriptor),
                managedRelativePath: "artifacts/migrated"
            ).insert(db)
            try SourceProvenanceRecord(
                documentID: completedContent.documentID.rawValue.uuidString,
                sourceKind: "webpage",
                sourceValue: sourceURL
            ).insert(db)
        }
        return V1Fixture(
            accepted: accepted,
            completed: completed,
            working: working,
            abandoned: abandoned
        )
    }

    static func createMalformedV1TaskIdentifierFixture(
        at root: URL
    ) throws {
        let queue = try DatabaseQueue(
            path: root.appending(path: "library.sqlite").path
        )
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1_local_library") { db in
            try createV1Schema(in: db)
        }
        try migrator.migrate(queue)
        try queue.write { db in
            try db.execute(
                sql: """
                    INSERT INTO import_tasks (
                        task_id, source_kind, source_value, attempt, revision,
                        state, checkpoint_ordinal, checkpoint_codec_version,
                        checkpoint_payload, staged_artifact_id, outcome_json
                    ) VALUES (
                        X'80', 'webpage', 'https://example.test/malformed-v1',
                        1, 0, 'accepted', NULL, NULL, NULL, NULL, NULL
                    )
                    """
            )
        }
    }

    static func importRows(at root: URL) throws -> [ImportRow] {
        try databaseQueue(at: root).read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT task_id, state, journal_sequence, queue_sequence
                    FROM import_tasks
                    ORDER BY rowid
                    """
            )
            return try rows.map { row in
                guard let taskUUID = UUID(uuidString: row["task_id"]),
                      let state = ImportTaskState(rawValue: row["state"]),
                      let journalSequence = UInt64(
                        exactly: row["journal_sequence"] as Int64
                      )
                else {
                    throw LocalLibraryError.unavailable
                }
                let rawQueueSequence: Int64? = row["queue_sequence"]
                return ImportRow(
                    taskID: ImportTaskID(taskUUID),
                    state: state,
                    journalSequence: journalSequence,
                    queueSequence: rawQueueSequence.flatMap(UInt64.init(exactly:))
                )
            }
        }
    }

    static func clock(at root: URL) throws -> UInt64 {
        try databaseQueue(at: root).read { db in
            guard let value = try Int64.fetchOne(
                db,
                sql: "SELECT last_sequence FROM import_queue_clock WHERE singleton = 1"
            ), let decoded = UInt64(exactly: value) else {
                throw LocalLibraryError.unavailable
            }
            return decoded
        }
    }

    static func setClock(_ value: Int64, at root: URL) throws {
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    UPDATE import_queue_clock
                    SET last_sequence = ?
                    WHERE singleton = 1
                    """,
                arguments: [value]
            )
        }
    }

    static func setState(
        _ state: ImportTaskState,
        at root: URL,
        taskID: ImportTaskID,
        cancellationRequested: Bool = false
    ) throws {
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    UPDATE import_tasks
                    SET state = ?, cancellation_requested = ?
                    WHERE task_id = ?
                    """,
                arguments: [
                    state.rawValue,
                    cancellationRequested,
                    taskID.rawValue.uuidString,
                ]
            )
        }
    }

    static func clearJournalSequence(
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try databaseQueue(at: root).write { db in
            try db.execute(
                sql: """
                    UPDATE import_tasks
                    SET journal_sequence = NULL
                    WHERE task_id = ?
                    """,
                arguments: [taskID.rawValue.uuidString]
            )
        }
    }

    static func corruptStorageType(
        _ corruption: WrongDurableStorageType,
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try databaseQueue(at: root).write { db in
            let assignment: String
            switch corruption {
            case .journalSequence:
                assignment = "journal_sequence = 'wrong-type'"
            case .failurePayload:
                assignment = "failure_payload = 42"
            }
            try db.execute(
                sql: "UPDATE import_tasks SET \(assignment) WHERE task_id = ?",
                arguments: [taskID.rawValue.uuidString]
            )
        }
    }

    static func retainedImportStatementCount(at root: URL) throws -> Int {
        try LibraryDatabase(
            url: root.appending(path: "library.sqlite")
        ).retainedImportStatementCountForTesting()
    }

    static func insertCompletedDuplicateHistory(
        count: Int,
        documentID: SourceDocumentID,
        at root: URL
    ) throws {
        try databaseQueue(at: root).write { db in
            let currentMaximum = try Int64.fetchOne(
                db,
                sql: "SELECT MAX(journal_sequence) FROM import_tasks"
            ) ?? 0
            for offset in 1...count {
                let sourceValue = "https://example.test/history-\(offset)"
                let outcome = try DomainJSON.encode(
                    PublicationOutcome.alreadyImported(
                        documentID: documentID,
                        location: .library,
                        provenanceAdded: true
                    )
                )
                try db.execute(
                    sql: """
                        INSERT INTO import_tasks (
                            task_id, source_kind, source_value, attempt,
                            revision, state, checkpoint_ordinal,
                            checkpoint_codec_version, checkpoint_payload,
                            staged_artifact_id, outcome_json, journal_sequence,
                            queue_sequence, failure_codec_version,
                            failure_payload, cancellation_requested
                        ) VALUES (
                            ?, 'webpage', ?, 1, 1, 'completed',
                            NULL, NULL, NULL, NULL, ?, ?, NULL, NULL, NULL, 0
                        )
                        """,
                    arguments: [
                        UUID().uuidString,
                        sourceValue,
                        outcome,
                        currentMaximum + Int64(offset),
                    ]
                )
                try SourceProvenanceRecord(
                    documentID: documentID.rawValue.uuidString,
                    sourceKind: "webpage",
                    sourceValue: sourceValue
                ).insert(db)
            }
            try db.execute(
                sql: """
                    UPDATE import_queue_clock
                    SET last_sequence = ?
                    WHERE singleton = 1
                    """,
                arguments: [currentMaximum + Int64(count)]
            )
        }
    }

    static func corrupt(
        _ corruption: InvalidDurableQueueRow,
        at root: URL,
        taskID: ImportTaskID
    ) throws {
        try databaseQueue(at: root).write { db in
            let id = taskID.rawValue.uuidString
            switch corruption {
            case .zeroJournalSequence:
                try db.execute(
                    sql: "UPDATE import_tasks SET journal_sequence = 0 WHERE task_id = ?",
                    arguments: [id]
                )
            case .duplicateJournalSequence:
                try db.execute(sql: "DROP INDEX import_tasks_journal_sequence")
                try db.execute(
                    sql: """
                        INSERT INTO import_tasks (
                            task_id, source_kind, source_value, attempt,
                            revision, state, checkpoint_ordinal,
                            checkpoint_codec_version, checkpoint_payload,
                            staged_artifact_id, outcome_json, journal_sequence,
                            queue_sequence, failure_codec_version,
                            failure_payload, cancellation_requested
                        )
                        SELECT ?, source_kind, ?, attempt, revision, state,
                            checkpoint_ordinal, checkpoint_codec_version,
                            checkpoint_payload, staged_artifact_id, outcome_json,
                            journal_sequence, queue_sequence + 1,
                            failure_codec_version, failure_payload,
                            cancellation_requested
                        FROM import_tasks WHERE task_id = ?
                        """,
                    arguments: [
                        UUID().uuidString,
                        "https://example.test/duplicate",
                        id,
                    ]
                )
            case .queuedWithoutQueueSequence:
                try update(
                    "queue_sequence = NULL",
                    id: id,
                    in: db
                )
            case .nonqueuedWithQueueSequence:
                try update(
                    "state = 'running'",
                    id: id,
                    in: db
                )
            case .failedWithoutFailure:
                try update(
                    "state = 'failed', queue_sequence = NULL",
                    id: id,
                    in: db
                )
            case .failedWithPartialFailure:
                try update(
                    "state = 'failed', queue_sequence = NULL, failure_codec_version = 1",
                    id: id,
                    in: db
                )
            case .failedWithInvalidFailureCodec:
                try update(
                    "state = 'failed', queue_sequence = NULL, failure_codec_version = 65536, failure_payload = X'01'",
                    id: id,
                    in: db
                )
            case .nonfailedWithFailure:
                try update(
                    "failure_codec_version = 1, failure_payload = X'01'",
                    id: id,
                    in: db
                )
            case .cancellationRequested:
                try update(
                    "cancellation_requested = 1",
                    id: id,
                    in: db
                )
            }
        }
    }

    private static func update(
        _ assignments: String,
        id: String,
        in db: Database
    ) throws {
        try db.execute(
            sql: "UPDATE import_tasks SET \(assignments) WHERE task_id = ?",
            arguments: [id]
        )
    }

    private static func insertLegacyTask(
        _ taskID: ImportTaskID,
        sourceValue: String,
        state: ImportTaskState,
        outcome: Data?,
        in db: Database
    ) throws {
        try db.execute(
            sql: """
                INSERT INTO import_tasks (
                    task_id, source_kind, source_value, attempt, revision,
                    state, checkpoint_ordinal, checkpoint_codec_version,
                    checkpoint_payload, staged_artifact_id, outcome_json
                ) VALUES (?, 'webpage', ?, 1, 0, ?, NULL, NULL, NULL, NULL, ?)
                """,
            arguments: [
                taskID.rawValue.uuidString,
                sourceValue,
                state.rawValue,
                outcome,
            ]
        )
    }

    private static func createV1Schema(in db: Database) throws {
        try db.create(table: "import_tasks") { table in
            table.column("task_id", .text).primaryKey()
            table.column("source_kind", .text).notNull()
            table.column("source_value", .text).notNull()
            table.column("attempt", .integer).notNull()
            table.column("revision", .integer).notNull()
            table.column("state", .text).notNull()
            table.column("checkpoint_ordinal", .integer)
            table.column("checkpoint_codec_version", .integer)
            table.column("checkpoint_payload", .blob)
            table.column("staged_artifact_id", .text)
            table.column("outcome_json", .blob)
        }
        try db.create(table: "staged_artifacts") { table in
            table.column("artifact_id", .text).primaryKey()
            table.column("task_id", .text)
                .notNull().unique()
                .references("import_tasks", onDelete: .cascade)
            table.column("descriptor_json", .blob).notNull()
            table.column("relative_path", .text).notNull()
        }
        try db.create(table: "source_documents") { table in
            table.column("document_id", .text).primaryKey()
            table.column("fingerprint", .text).notNull().unique()
            table.column("location", .text).notNull()
            table.column("visibility", .text).notNull()
            table.column("content_json", .blob).notNull()
            table.column("artifact_descriptor_json", .blob).notNull()
            table.column("managed_relative_path", .text).notNull()
        }
        try db.create(table: "source_provenance") { table in
            table.column("document_id", .text)
                .notNull()
                .references("source_documents", onDelete: .cascade)
            table.column("source_kind", .text).notNull()
            table.column("source_value", .text).notNull()
            table.primaryKey(["document_id", "source_kind", "source_value"])
        }
        try db.create(table: "publication_intents") { table in
            table.column("task_id", .text)
                .primaryKey()
                .references("import_tasks", onDelete: .cascade)
            table.column("document_id", .text).notNull()
            table.column("staged_artifact_id", .text).notNull()
            table.column("final_relative_path", .text).notNull()
        }
    }

    private static func databaseQueue(at root: URL) throws -> DatabaseQueue {
        try DatabaseQueue(path: root.appending(path: "library.sqlite").path)
    }
}
