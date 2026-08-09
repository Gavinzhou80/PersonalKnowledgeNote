import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

/// Gates every acquisition until released one at a time, letting the test
/// pin exactly which task is acquiring.
private actor LifecycleGatedAcquirer: WebAcquiring {
    private let html: Data
    private let overrides: [URL: Data]
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var releaseCredits = 0

    init(html: Data, overrides: [URL: Data] = [:]) {
        self.html = html
        self.overrides = overrides
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        if releaseCredits > 0 {
            releaseCredits -= 1
        } else {
            await withCheckedContinuation { waiters.append($0) }
        }
        return AcquiredWebPage(sourceURL: url, html: overrides[url] ?? html)
    }

    func releaseOne() {
        if waiters.isEmpty {
            releaseCredits += 1
        } else {
            waiters.removeFirst().resume()
        }
    }
}

/// Fails the first acquisition of `failingURL` with a retryable network
/// error, serves `servedURL`, and rejects every other acquisition: the
/// crashed task must resume from its managed checkpoint without
/// reacquiring.
private actor CheckpointReuseAcquirer: WebAcquiring {
    private let html: Data
    private let overrides: [URL: Data]
    private let failingURL: URL
    private let servedURL: URL
    private var hasFailedOnce = false
    private(set) var acquiredURLs: [URL] = []

    init(
        html: Data,
        failingURL: URL,
        servedURL: URL,
        overrides: [URL: Data] = [:]
    ) {
        self.html = html
        self.failingURL = failingURL
        self.servedURL = servedURL
        self.overrides = overrides
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        acquiredURLs.append(url)
        if url == servedURL {
            return AcquiredWebPage(sourceURL: url, html: overrides[url] ?? html)
        }
        guard url == failingURL else {
            Issue.record("Unexpected reacquisition for \(url)")
            throw WebAcquisitionError.networkUnavailable
        }
        guard hasFailedOnce else {
            hasFailedOnce = true
            throw WebAcquisitionError.networkUnavailable
        }
        return AcquiredWebPage(sourceURL: url, html: overrides[url] ?? html)
    }
}

private func isRunning(_ snapshot: ImportTaskSnapshot) -> Bool {
    if case .running = snapshot.state { return true }
    return false
}

private func observeList(
    _ importer: DocumentImport,
    until predicate: ([ImportTaskSnapshot]) -> Bool
) async throws -> [ImportTaskSnapshot] {
    let deadline = ContinuousClock.now + .seconds(5)
    while true {
        var iterator = importer.observeTasks(.all).makeAsyncIterator()
        if let list = await iterator.next(), predicate(list) {
            return list
        }
        guard ContinuousClock.now < deadline else {
            throw DurableQueueTestError.timeout
        }
        try await Task.sleep(for: .milliseconds(10))
    }
}

private func snapshot(
    for id: ImportTaskID,
    in list: [ImportTaskSnapshot]
) throws -> ImportTaskSnapshot {
    try #require(list.first { $0.id == id })
}

@Test(.timeLimit(.minutes(2)))
func publicLifecycleCoversAllDurableOutcomesAcrossRestart() async throws {
    let root = try makeTemporaryDocumentImportRoot()
    defer { removeTemporaryDocumentImportRoot(root) }
    let libraryRoot = root.appending(path: "Library")
    let fixtureHTML = try Data(contentsOf: FixtureCatalog.webArticleURL)
    // Duplicate detection keys on content, so the second submission must carry
    // distinct bytes or its retry would collapse into Already Imported.
    let betaHTML = Data(
        String(decoding: fixtureHTML, as: UTF8.self)
            .replacingOccurrences(
                of: "Deterministic offline content.",
                with: "Beta variant offline content."
            ).utf8
    )
    let server = try await LocalHTTPFixtureServer.start { _ in
        .init(
            headers: ["Content-Type": "text/html"],
            body: fixtureHTML
        )
    }
    defer { server.stop() }
    let urlA = server.baseURL.appending(path: "lifecycle/alpha")
    let urlB = server.baseURL.appending(path: "lifecycle/beta")
    let urlC = server.baseURL.appending(path: "lifecycle/gamma")

    // Phase A: three loopback submissions prove durable FIFO with exactly
    // one active runner, observer churn, cancellation, and retry queuing.
    let firstAcquirer = LifecycleGatedAcquirer(
        html: fixtureHTML,
        overrides: [urlB: betaHTML]
    )
    let crashInjector = ImportRunnerCrashInjector(
        crashPoint: .afterAcquiredCheckpoint,
        armed: false
    )
    let firstLibrary = try await LocalLibrary.open(at: libraryRoot)
    let firstImporter = DocumentImport(
        library: firstLibrary,
        webAcquirer: firstAcquirer,
        importRunnerBoundaryHook: { point in
            try crashInjector.hit(point)
        }
    )

    let handleA = try await firstImporter.submit(.webpage(urlA))
    let handleB = try await firstImporter.submit(.webpage(urlB))
    let handleC = try await firstImporter.submit(.webpage(urlC))

    let runningList = try await observeList(firstImporter) { list in
        list.contains { $0.id == handleA.id && isRunning($0) }
    }
    #expect(runningList.filter(isRunning).count == 1)
    #expect(
        try snapshot(for: handleB.id, in: runningList).state ==
            .queued(position: 1)
    )
    #expect(
        try snapshot(for: handleC.id, in: runningList).state ==
            .queued(position: 2)
    )

    // Dropping and recreating observers never disturbs durable work.
    let recreatedList = try await observeList(firstImporter) { list in
        Set(list.map(\.id)) == Set([handleA.id, handleB.id, handleC.id])
    }
    #expect(recreatedList.count == 3)

    try await firstImporter.cancel(taskID: handleB.id)
    let cancelledList = try await observeList(firstImporter) { list in
        guard let state = (try? snapshot(for: handleB.id, in: list))?.state
        else { return false }
        if case .cancelled = state { return true }
        return false
    }
    #expect(
        try snapshot(for: handleC.id, in: cancelledList).state ==
            .queued(position: 1)
    )

    await firstAcquirer.releaseOne()
    let terminalA = await handleA.value()
    guard case .success(.published(
        documentID: let documentA,
        issues: _
    )) = terminalA else {
        Issue.record("Expected the first task to publish")
        return
    }

    // The third task claims the runner slot; retrying the cancelled task
    // must enter the queue behind it.
    _ = try await observeList(firstImporter) { list in
        list.contains { $0.id == handleC.id && isRunning($0) }
    }
    try await firstImporter.retry(taskID: handleB.id)
    let retriedList = try await observeList(firstImporter) { list in
        (try? snapshot(for: handleB.id, in: list))?.state ==
            .queued(position: 1)
    }
    #expect(try isRunning(snapshot(for: handleC.id, in: retriedList)))

    // Terminate after the third task's acquisition checkpoint is durable.
    crashInjector.arm()
    await firstAcquirer.releaseOne()
    try await crashInjector.waitForInjectedTermination()

    // Phase B: reopening recovers the crashed task, which reuses its
    // acquired checkpoint without any network call.
    let secondLibrary = try await LocalLibrary.open(at: libraryRoot)
    let secondAcquirer = CheckpointReuseAcquirer(
        html: fixtureHTML,
        failingURL: urlB,
        servedURL: urlA,
        overrides: [urlB: betaHTML]
    )
    let secondImporter = DocumentImport(
        library: secondLibrary,
        webAcquirer: secondAcquirer
    )

    _ = try await observeList(secondImporter) { list in
        guard let state = (try? snapshot(for: handleC.id, in: list))?.state
        else { return false }
        if case .completed = state { return true }
        return false
    }
    // The crashed task resumed from its acquired checkpoint: no
    // reacquisition for its URL ever happens.
    #expect(await !secondAcquirer.acquiredURLs.contains(urlC))

    // The retried task fails once with a retryable acquisition failure.
    let failedList = try await observeList(secondImporter) { list in
        guard let state = (try? snapshot(for: handleB.id, in: list))?.state
        else { return false }
        if case .failed(let failure) = state {
            return failure.code == .networkUnavailable &&
                failure.recovery == .retryable
        }
        return false
    }
    let failedB = try snapshot(for: handleB.id, in: failedList)
    #expect(failedB.attempt == 2)

    try await secondImporter.retry(taskID: handleB.id)
    let recoveredB = try #require(
        try await secondImporter.task(id: handleB.id)
    )
    guard case .success(.published) = await recoveredB.value() else {
        Issue.record("Expected the retried task to publish after restart")
        return
    }
    #expect(recoveredB.id == handleB.id)
    #expect(
        await secondAcquirer.acquiredURLs.filter { $0 == urlB } == [urlB, urlB]
    )
    let retained = try await secondLibrary.retainedImports()
    let durableB = try #require(retained.first { $0.taskID == handleB.id })
    #expect(durableB.attempt == 3)
    #expect(durableB.state == .completed)

    // Resubmitting the published source finishes as Already Imported.
    let duplicate = try await secondImporter.submit(.webpage(urlA))
    guard case .success(.alreadyImported(
        documentID: let duplicateDocument,
        location: _,
        provenanceAdded: _
    )) = await duplicate.value() else {
        Issue.record("Expected the duplicate submission to detect the import")
        return
    }
    #expect(duplicateDocument == documentA)
}
