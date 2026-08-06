import Foundation
import LocalLibrary
import TestFixtures
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
