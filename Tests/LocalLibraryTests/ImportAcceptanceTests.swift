import Foundation
import KnowledgeCore
import Testing
@testable import LocalLibrary

@Test
func acceptedImportSurvivesLibraryReopen() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let source = OriginalSource.webpage(
        try #require(URL(string: "https://example.com/article"))
    )

    let accepted = try await acceptInReleasedScope(
        source,
        at: root
    )

    #expect(accepted.library.value == nil)
    #expect(accepted.workspace.value == nil)

    let reopened = try await LocalLibrary.open(at: root)
    let recovered = try #require(
        try await reopened.importWorkspace(id: accepted.taskID)
    )
    let snapshot = try await recovered.snapshot()
    let recoverableTaskIDs = try await reopened
        .recoverableImports()
        .map(\.taskID)

    #expect(snapshot.taskID == accepted.taskID)
    #expect(snapshot.state == .queued)
    #expect(recoverableTaskIDs.contains(accepted.taskID))
}

@Test
func openingMalformedDatabaseReportsCorruptLibrary() async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    try Data("not a sqlite database".utf8).write(
        to: root.appending(path: "library.sqlite")
    )

    do {
        _ = try await LocalLibrary.open(at: root)
        Issue.record("Expected malformed SQLite to be rejected")
    } catch let error as LocalLibraryError {
        guard case .corruptLibrary = error else {
            Issue.record("Expected corruptLibrary, got \(error)")
            return
        }
    } catch {
        Issue.record("Expected LocalLibraryError, got \(error)")
    }
}

@Test(arguments: [
    InvalidOriginalSource(
        source: .webpage(URL(string: "relative/path")!),
        label: "relative webpage"
    ),
    InvalidOriginalSource(
        source: .webpage(URL(string: "ftp://example.com/article")!),
        label: "ftp webpage"
    ),
    InvalidOriginalSource(
        source: .webpage(URL(fileURLWithPath: "/tmp/article.html")),
        label: "file webpage"
    ),
    InvalidOriginalSource(
        source: .webpage(URL(string: "https:///article")!),
        label: "hostless webpage"
    ),
    InvalidOriginalSource(
        source: .pdfFile(URL(string: "https://example.com/file.pdf")!),
        label: "remote pdf"
    ),
    InvalidOriginalSource(
        source: .pdfFile(URL(string: "file:relative.pdf")!),
        label: "relative file pdf"
    ),
    InvalidOriginalSource(
        source: .pdfFile(
            URL(string: "file://remote-host/tmp/file.pdf")!
        ),
        label: "remote-host file pdf"
    ),
])
func acceptingInvalidOriginalSourceDoesNotPersistTask(
    invalid: InvalidOriginalSource
) async throws {
    let root = try makeTemporaryLibraryRoot()
    defer { removeTemporaryLibraryRoot(root) }
    let library = try await LocalLibrary.open(at: root)

    do {
        _ = try await library.accept(invalid.source)
        Issue.record("Expected \(invalid.label) to be rejected")
    } catch let error as LocalLibraryError {
        #expect(error == .unavailable)
    }

    #expect(try await library.recoverableImports().isEmpty)
    #expect(try LocalLibraryTestDriver.taskCount(at: root) == 0)
}

struct InvalidOriginalSource: Sendable {
    let source: OriginalSource
    let label: String
}

private struct ReleasedAcceptance: Sendable {
    let taskID: ImportTaskID
    let library: WeakReference<LocalLibrary>
    let workspace: WeakReference<ImportWorkspace>
}

private final class WeakReference<Value: AnyObject>: @unchecked Sendable {
    weak var value: Value?

    init(_ value: Value) {
        self.value = value
    }
}

@inline(never)
private func acceptInReleasedScope(
    _ source: OriginalSource,
    at root: URL
) async throws -> ReleasedAcceptance {
    let library = try await LocalLibrary.open(at: root)
    let workspace = try await library.accept(source)
    let snapshot = try await workspace.snapshot()

    #expect(snapshot.state == .queued)
    #expect(snapshot.revision == 0)

    return ReleasedAcceptance(
        taskID: workspace.taskID,
        library: WeakReference(library),
        workspace: WeakReference(workspace)
    )
}
