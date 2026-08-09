import AppSupport
import DocumentImport
import Foundation
import KnowledgeCore
import LocalLibrary
import SwiftUI

@main
struct PersonalKnowledgeNoteApp: App {
    var body: some Scene {
        WindowGroup("Reading Workbench") {
            ReadingWorkbenchRootView()
        }
        .defaultSize(width: 1100, height: 720)
    }
}

/// Opens the library asynchronously; surfaces a launch error if the
/// library cannot be opened instead of failing silently.
struct ReadingWorkbenchRootView: View {
    @State private var model: ReadingWorkbenchModel?
    @State private var launchError: String?

    var body: some View {
        Group {
            if let model {
                ReadingWorkbenchView(model: model)
            } else if let launchError {
                ContentUnavailableView(
                    "Library Unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(
                        "The local library could not be opened: \(launchError)"
                    )
                )
            } else {
                ProgressView("Opening library…")
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                model = try await ReadingWorkbenchModel.open()
            } catch {
                launchError = String(describing: error)
            }
        }
    }
}

/// Composition root: owns the library, importer, and the stores the
/// workbench views observe.
@MainActor
final class ReadingWorkbenchModel {
    let readingStore: ReadingWorkbenchStore
    let importTaskStore: ImportTaskStore
    let libraryPort: any ReadingLibraryPort

    private init(
        readingStore: ReadingWorkbenchStore,
        importTaskStore: ImportTaskStore,
        libraryPort: any ReadingLibraryPort
    ) {
        self.readingStore = readingStore
        self.importTaskStore = importTaskStore
        self.libraryPort = libraryPort
    }

    static func open() async throws -> ReadingWorkbenchModel {
        let library = try await LocalLibrary.open(at: libraryRoot())
        let importer = DocumentImport(library: library)
        let adapter = LocalLibraryReadingAdapter(
            library: library,
            importer: importer
        )
        let readingStore = ReadingWorkbenchStore(library: adapter)
        let importTaskStore = ImportTaskStore(importer: importer)
        await importTaskStore.start()
        await readingStore.loadDocumentList()
        return ReadingWorkbenchModel(
            readingStore: readingStore,
            importTaskStore: importTaskStore,
            libraryPort: adapter
        )
    }

    static func libraryRoot() throws -> URL {
        let applicationSupport = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return applicationSupport
            .appending(path: "PersonalKnowledgeNote")
            .appending(path: "Library")
    }
}

/// Bridges the library and importer onto the presentation port so the
/// workbench and scheme handler never touch concrete types.
struct LocalLibraryReadingAdapter: ReadingLibraryPort {
    let library: LocalLibrary
    let importer: DocumentImport

    func publishedDocumentSummaries()
        async throws -> [SourceDocumentSummary]
    {
        try await library.publishedDocumentSummaries()
    }

    func sourceDocument(
        id: SourceDocumentID
    ) async throws -> LocatedSourceDocument? {
        try await library.sourceDocument(id: id)
    }

    func artifactResource(
        documentID: SourceDocumentID,
        relativePath: String
    ) async throws -> ArtifactResource? {
        try await library.artifactResource(
            documentID: documentID,
            relativePath: relativePath
        )
    }

    func submitImport(_ source: OriginalSource) async throws {
        _ = try await importer.submit(source)
    }
}
