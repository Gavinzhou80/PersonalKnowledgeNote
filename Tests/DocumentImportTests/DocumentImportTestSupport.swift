import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

func makeTemporaryDocumentImportRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "DocumentImport-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

func removeTemporaryDocumentImportRoot(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

actor GatedFixtureWebAcquirer: WebAcquiring {
    private let html: Data
    private var hasStarted = false
    private var hasBeenReleased = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init() throws {
        html = try Data(contentsOf: FixtureCatalog.webArticleURL)
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        hasStarted = true
        let waiters = startWaiters
        startWaiters.removeAll()
        for waiter in waiters {
            waiter.resume()
        }

        if !hasBeenReleased {
            await withCheckedContinuation { continuation in
                if hasBeenReleased {
                    continuation.resume()
                } else {
                    releaseWaiter = continuation
                }
            }
        }

        return AcquiredWebPage(sourceURL: url, html: html)
    }

    func waitUntilStarted() async {
        guard !hasStarted else {
            return
        }
        await withCheckedContinuation { continuation in
            startWaiters.append(continuation)
        }
    }

    func release() {
        guard !hasBeenReleased else {
            return
        }
        hasBeenReleased = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}

enum FixtureWebAcquisitionError: Error {
    case unavailable
}

struct ThrowingWebAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        throw FixtureWebAcquisitionError.unavailable
    }
}

struct ThrowingFixtureWebAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        throw WebAcquisitionError.networkUnavailable
    }
}

actor SelectiveWorkspaceSnapshotLoader {
    enum Failure: Error {
        case injected
    }

    private let failingCalls: Set<Int>
    private var callCount = 0

    init(failingCalls: Set<Int>) {
        self.failingCalls = failingCalls
    }

    func load(
        _ workspace: ImportWorkspace
    ) async throws -> DurableImportSnapshot {
        callCount += 1
        if failingCalls.contains(callCount) {
            throw Failure.injected
        }
        return try await workspace.snapshot()
    }
}

enum DurableQueueTestError: Error {
    case timeout
    case injectedBootstrapFailure
}

actor DeterministicRunnerGate {
    private(set) var startedIDs: [ImportTaskID] = []
    private(set) var maximumConcurrentRuns = 0
    private var runningIDs: Set<ImportTaskID> = []
    private var releasedIDs: Set<ImportTaskID> = []

    func run(_ workspace: ImportWorkspace) async throws {
        let taskID = workspace.taskID
        startedIDs.append(taskID)
        runningIDs.insert(taskID)
        maximumConcurrentRuns = max(maximumConcurrentRuns, runningIDs.count)

        let deadline = ContinuousClock.now + .seconds(1)
        while !releasedIDs.contains(taskID) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        let snapshot = try await workspace.snapshot()
        try await workspace.abandon(expectedRevision: snapshot.revision)
        runningIDs.remove(taskID)
    }

    func waitUntilStarted(_ taskID: ImportTaskID) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !startedIDs.contains(taskID) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func waitUntilStopped(_ taskID: ImportTaskID) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while runningIDs.contains(taskID) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func release(_ taskID: ImportTaskID) {
        releasedIDs.insert(taskID)
    }

    func isStillRunning(_ taskID: ImportTaskID) -> Bool {
        runningIDs.contains(taskID)
    }
}

struct DurableQueueHarness {
    let root: URL
    let library: LocalLibrary
    let importer: DocumentImport
    let runner: DeterministicRunnerGate

    static func make(
        preacceptedURLs: [URL] = []
    ) async throws -> DurableQueueHarness {
        let root = try makeTemporaryDocumentImportRoot()
        let library = try await LocalLibrary.open(
            at: root.appending(path: "Library")
        )
        for url in preacceptedURLs {
            _ = try await library.accept(.webpage(url))
        }
        let runner = DeterministicRunnerGate()
        let importer = DocumentImport(
            library: library,
            webAcquirer: ThrowingWebAcquirer(),
            importRunner: { workspace in
                try await runner.run(workspace)
            }
        )
        return DurableQueueHarness(
            root: root,
            library: library,
            importer: importer,
            runner: runner
        )
    }

    func url(_ path: String) -> URL {
        URL(string: "https://fixture.invalid\(path)")!
    }
}

func latestSnapshot(
    _ handle: ImportTaskHandle
) async throws -> ImportTaskSnapshot {
    var iterator = handle.updates().makeAsyncIterator()
    return try #require(await iterator.next())
}

func currentQueuedPosition(
    _ handle: ImportTaskHandle
) async throws -> Int {
    let snapshot = try await latestSnapshot(handle)
    guard case .queued(let position) = snapshot.state else {
        Issue.record("Expected queued task, got \(snapshot.state)")
        throw DurableQueueTestError.timeout
    }
    return position
}

actor BootstrapLoadProbe {
    private let library: LocalLibrary
    private var remainingFailures: Int
    private(set) var callCount = 0

    init(library: LocalLibrary, failures: Int = 0) {
        self.library = library
        remainingFailures = failures
    }

    func load() async throws -> [DurableImportSnapshot] {
        callCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw DurableQueueTestError.injectedBootstrapFailure
        }
        return try await library.retainedImports()
    }

    func waitForCallCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while callCount < expected {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

actor SuspendedBootstrapLoader {
    private let library: LocalLibrary
    private var released = false
    private(set) var callCount = 0

    init(library: LocalLibrary) {
        self.library = library
    }

    func load() async throws -> [DurableImportSnapshot] {
        callCount += 1
        let deadline = ContinuousClock.now + .seconds(1)
        while !released {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await library.retainedImports()
    }

    func release() {
        released = true
    }
}

actor TaskListEmissionProbe {
    private(set) var emissions: [[ImportTaskSnapshot]] = []

    func record(_ snapshots: [ImportTaskSnapshot]) {
        emissions.append(snapshots)
    }

    func waitForEmissionCount(_ expected: Int) async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while emissions.count < expected {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }
}

actor TransientClaimProbe {
    private let library: LocalLibrary
    private var remainingFailures: Int
    private(set) var callCount = 0

    init(library: LocalLibrary, failures: Int = 1) {
        self.library = library
        remainingFailures = failures
    }

    func claim() async throws -> DurableQueueClaim? {
        callCount += 1
        if remainingFailures > 0 {
            remainingFailures -= 1
            throw DurableQueueClaimError.transientDatabaseContention
        }
        return try await library.claimNextRunnable()
    }
}

actor NonTransientClaimProbe {
    private(set) var callCount = 0

    func claim() throws -> DurableQueueClaim? {
        callCount += 1
        throw LocalLibraryError.unavailable
    }

    func waitUntilCalled() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while callCount == 0 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func verifyCallCountRemains(
        _ expected: Int,
        for duration: Duration
    ) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard callCount == expected else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

actor RootRemovalClaimProbe {
    private let library: LocalLibrary
    private var secondClaimReleased = false
    private var secondClaimCompleted = false
    private(set) var callCount = 0

    init(library: LocalLibrary) {
        self.library = library
    }

    func claim() async throws -> DurableQueueClaim? {
        callCount += 1
        guard callCount == 2 else {
            return try await library.claimNextRunnable()
        }
        defer { secondClaimCompleted = true }
        let deadline = ContinuousClock.now + .seconds(1)
        while !secondClaimReleased {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
        return try await library.claimNextRunnable()
    }

    func waitUntilSecondClaimRequested() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while callCount < 2 {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func releaseSecondClaim() {
        secondClaimReleased = true
    }

    func waitUntilSecondClaimCompleted() async throws {
        let deadline = ContinuousClock.now + .seconds(1)
        while !secondClaimCompleted {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func verifyCallCountRemains(
        _ expected: Int,
        for duration: Duration
    ) async throws {
        let deadline = ContinuousClock.now + duration
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            guard callCount == expected else {
                throw DurableQueueTestError.timeout
            }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}
