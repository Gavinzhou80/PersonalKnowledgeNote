import AppSupport
import DocumentImport
import Foundation
import KnowledgeCore
import LocalLibrary
import Testing
import TestFixtures

@testable import DocumentImport

private enum StoreHarnessError: Error {
    case gateTimeout
    case missingTask
    case unexpectedAcquire
    case bootstrapFailure
}

private struct NeverCalledAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        throw StoreHarnessError.unexpectedAcquire
    }
}

actor StoreRunnerGate {
    private(set) var startedIDs: [ImportTaskID] = []
    private var runningIDs: Set<ImportTaskID> = []
    private var releasedIDs: Set<ImportTaskID> = []

    func run(_ workspace: ImportWorkspace) async throws {
        let taskID = workspace.taskID
        startedIDs.append(taskID)
        runningIDs.insert(taskID)
        defer { runningIDs.remove(taskID) }

        let deadline = ContinuousClock.now + .seconds(2)
        while !releasedIDs.contains(taskID) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw StoreHarnessError.gateTimeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }

        let snapshot = try await workspace.snapshot()
        try await workspace.abandon(expectedRevision: snapshot.revision)
    }

    func waitUntilStarted(_ taskID: ImportTaskID) async throws {
        let deadline = ContinuousClock.now + .seconds(2)
        while !startedIDs.contains(taskID) {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw StoreHarnessError.gateTimeout
            }
            try await Task.sleep(for: .milliseconds(2))
        }
    }

    func startedCount(of taskID: ImportTaskID) -> Int {
        startedIDs.filter { $0 == taskID }.count
    }

    func release(_ taskID: ImportTaskID) {
        releasedIDs.insert(taskID)
    }

    func isStillRunning(_ taskID: ImportTaskID) -> Bool {
        runningIDs.contains(taskID)
    }
}

struct ImportTaskStoreHarness {
    let root: URL
    let importer: DocumentImport
    let runner: StoreRunnerGate
    let articleURL: URL

    static func make() async throws -> ImportTaskStoreHarness {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "ImportTaskStoreHarness-\(UUID().uuidString)",
                isDirectory: true
            )
        let library = try await LocalLibrary.open(at: root)
        let runner = StoreRunnerGate()
        let importer = DocumentImport(
            library: library,
            webAcquirer: NeverCalledAcquirer(),
            importRunner: { workspace in
                try await runner.run(workspace)
            }
        )
        return ImportTaskStoreHarness(
            root: root,
            importer: importer,
            runner: runner,
            articleURL: URL(string: "https://store.example/article")!
        )
    }
}

@MainActor
private func waitForTaskID(
    in store: ImportTaskStore
) async throws -> ImportTaskID {
    let deadline = ContinuousClock.now + .seconds(2)
    while store.tasks.isEmpty {
        guard ContinuousClock.now < deadline else {
            throw StoreHarnessError.missingTask
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    return store.tasks[0].id
}

@MainActor
private func waitForTask(
    in store: ImportTaskStore,
    id taskID: ImportTaskID,
    matching predicate: @escaping (ImportTaskSnapshot) -> Bool
) async throws {
    let deadline = ContinuousClock.now + .seconds(2)
    while true {
        if let snapshot = store.tasks.first(where: { $0.id == taskID }),
           predicate(snapshot) {
            return
        }
        guard ContinuousClock.now < deadline else {
            throw StoreHarnessError.gateTimeout
        }
        try await Task.sleep(for: .milliseconds(5))
    }
}

@MainActor
@Test
func recreatingStoreDoesNotCancelDurableWork() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    var firstStore: ImportTaskStore? = ImportTaskStore(importer: harness.importer)
    await firstStore?.start()
    await firstStore?.submit(.webpage(harness.articleURL))
    let taskID = try await waitForTaskID(in: #require(firstStore))
    try await harness.runner.waitUntilStarted(taskID)

    firstStore?.stopObserving()
    firstStore = nil

    let secondStore = ImportTaskStore(importer: harness.importer)
    await secondStore.start()
    try await waitForTask(in: secondStore, id: taskID) { _ in true }
    #expect(await harness.runner.isStillRunning(taskID))
}

@MainActor
@Test
func cancelThroughStoreCancelsGatedRunner() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    let store = ImportTaskStore(importer: harness.importer)
    await store.start()
    await store.submit(.webpage(harness.articleURL))
    let taskID = try await waitForTaskID(in: store)
    try await harness.runner.waitUntilStarted(taskID)

    await store.cancel(id: taskID)

    try await waitForTask(in: store, id: taskID) { snapshot in
        if case .cancelled = snapshot.state { return true }
        return false
    }
    #expect(store.controlError == nil)
    #expect(store.availabilityError == nil)
    #expect(await !harness.runner.isStillRunning(taskID))
}

@MainActor
@Test
func cancelUnknownTaskSurfacesControlError() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    let store = ImportTaskStore(importer: harness.importer)
    await store.start()

    await store.cancel(id: ImportTaskID())

    #expect(store.controlError == .taskNotFound)
    #expect(store.availabilityError == nil)
}

@MainActor
@Test
func retryCancelledTaskRestartsRunner() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    let store = ImportTaskStore(importer: harness.importer)
    await store.start()
    await store.submit(.webpage(harness.articleURL))
    let taskID = try await waitForTaskID(in: store)
    try await harness.runner.waitUntilStarted(taskID)

    await store.cancel(id: taskID)
    try await waitForTask(in: store, id: taskID) { snapshot in
        if case .cancelled = snapshot.state { return true }
        return false
    }

    await store.retry(id: taskID)

    let deadline = ContinuousClock.now + .seconds(2)
    while await harness.runner.startedCount(of: taskID) < 2 {
        guard ContinuousClock.now < deadline else {
            throw StoreHarnessError.gateTimeout
        }
        try await Task.sleep(for: .milliseconds(5))
    }
    #expect(store.controlError == nil)
    await harness.runner.release(taskID)
}

@MainActor
@Test
func retryRunningTaskSurfacesControlError() async throws {
    let harness = try await ImportTaskStoreHarness.make()
    let store = ImportTaskStore(importer: harness.importer)
    await store.start()
    await store.submit(.webpage(harness.articleURL))
    let taskID = try await waitForTaskID(in: store)
    try await harness.runner.waitUntilStarted(taskID)

    await store.retry(id: taskID)

    #expect(store.controlError == .invalidState)
    #expect(store.availabilityError == nil)
    await harness.runner.release(taskID)
}

@MainActor
@Test
func startSurfacesAvailabilityErrorWhenBootstrapFails() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ImportTaskStoreHarness-unavailable-\(UUID().uuidString)",
            isDirectory: true
        )
    let library = try await LocalLibrary.open(at: root)
    let importer = DocumentImport(
        library: library,
        webAcquirer: NeverCalledAcquirer(),
        retainedImportsLoader: {
            throw StoreHarnessError.bootstrapFailure
        }
    )
    let store = ImportTaskStore(importer: importer)

    await store.start()

    #expect(store.availabilityError == .localLibraryUnavailable)
    #expect(store.tasks.isEmpty)
}

/// Serves the fixture article so the default runner drives an import to
/// publication.
private struct CompletingFixtureAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        let html = try Data(contentsOf: FixtureCatalog.webArticleURL)
        return AcquiredWebPage(sourceURL: url, html: html)
    }
}

@MainActor
@Test
func storeSurfacesCompletedTaskIDsAfterPublication() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent(
            "ImportTaskStoreCompletion-\(UUID().uuidString)",
            isDirectory: true
        )
    let library = try await LocalLibrary.open(at: root)
    let importer = DocumentImport(
        library: library,
        webAcquirer: CompletingFixtureAcquirer()
    )
    let store = ImportTaskStore(importer: importer)
    await store.start()
    await store.submit(
        .webpage(URL(string: "https://store.example/article")!)
    )

    let deadline = ContinuousClock.now + .seconds(5)
    while store.completedTaskIDs.isEmpty {
        guard ContinuousClock.now < deadline else {
            break
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    // The completion signal survives the unfinished-only display
    // filter, so views can refresh when a document publishes.
    #expect(store.completedTaskIDs.count == 1)
    #expect(store.tasks.isEmpty)
}
