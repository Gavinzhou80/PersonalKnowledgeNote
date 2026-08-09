import Foundation
import KnowledgeCore
import LocalLibrary
import Observation

/// The read-only seam the reading workbench needs from the local library.
///
/// Production wires the real `LocalLibrary` and import submission through
/// this port; tests inject an in-memory double so presentation logic runs
/// without a durable store.
public protocol ReadingLibraryPort: Sendable {
    func publishedDocumentSummaries() async throws
        -> [SourceDocumentSummary]
    func sourceDocument(
        id: SourceDocumentID
    ) async throws -> LocatedSourceDocument?
    func artifactResource(
        documentID: SourceDocumentID,
        relativePath: String
    ) async throws -> ArtifactResource?
    func submitImport(_ source: OriginalSource) async throws
}

public struct ReadingOutlineNode: Hashable, Sendable {
    /// Positional index of the heading block in reading order.
    public let blockIndex: Int
    public let level: Int
    public let text: String

    public init(blockIndex: Int, level: Int, text: String) {
        self.blockIndex = blockIndex
        self.level = level
        self.text = text
    }
}

public enum ReadingImportState: Hashable, Sendable {
    case idle
    case submitted
    case invalidURL
    case libraryUnavailable
}

/// Parsed form of a `pkn-reading://document/<id>/<path>` request, the
/// URL shape the artifact scheme handler serves.
public struct ReadingArtifactRequest: Hashable, Sendable {
    public static let scheme = "pkn-reading"
    private static let documentHost = "document"

    public let documentID: SourceDocumentID
    public let relativePath: String

    init(documentID: SourceDocumentID, relativePath: String) {
        self.documentID = documentID
        self.relativePath = relativePath
    }

    /// Returns nil for any URL that is not a well-formed artifact
    /// request: wrong scheme or host, unparsable document ID, or a
    /// missing resource path.
    public static func parse(_ url: URL) -> ReadingArtifactRequest? {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.scheme == scheme,
            components.host == documentHost
        else {
            return nil
        }
        let segments = components.path
            .split(separator: "/")
            .map(String.init)
        guard segments.count >= 2,
              let uuid = UUID(uuidString: segments[0])
        else {
            return nil
        }
        let relativePath = segments.dropFirst().joined(separator: "/")
        guard !relativePath.isEmpty else {
            return nil
        }
        return ReadingArtifactRequest(
            documentID: SourceDocumentID(uuid),
            relativePath: relativePath
        )
    }
}

public enum ReadingNavigationDisposition: Hashable, Sendable {
    case allow
    case cancel
    case openInBrowser
}

/// Pure navigation decision for the reading web view: external web
/// links hand off to the default browser, the current document URL is
/// the only allowed navigation, and everything else is cancelled.
public enum ReadingNavigationPolicy {
    public static func disposition(
        for proposed: URL,
        currentDocument: URL?
    ) -> ReadingNavigationDisposition {
        switch proposed.scheme?.lowercased() {
        case "http", "https":
            return .openInBrowser
        default:
            break
        }
        guard let currentDocument, proposed == currentDocument else {
            return .cancel
        }
        return .allow
    }
}

@MainActor
@Observable
public final class ReadingWorkbenchStore {
    public private(set) var summaries: [SourceDocumentSummary] = []
    public private(set) var selectedDocumentID: SourceDocumentID?
    public private(set) var outline: [ReadingOutlineNode] = []
    public private(set) var importState: ReadingImportState = .idle

    private let library: any ReadingLibraryPort

    public init(library: any ReadingLibraryPort) {
        self.library = library
    }

    /// Loads (or reloads) the published document list, newest first.
    public func loadDocumentList() async {
        do {
            summaries = try await library.publishedDocumentSummaries()
        } catch {
            summaries = []
        }
    }

    public func select(_ documentID: SourceDocumentID?) async {
        selectedDocumentID = documentID
        outline = []
        guard let documentID else {
            return
        }
        guard let located = try? await library.sourceDocument(
            id: documentID
        ) else {
            return
        }
        outline = Self.outlineProjection(of: located.document.content)
    }

    /// Custom-scheme URL the reading web view loads for the selection.
    public var artifactLoadURL: URL? {
        guard let selectedDocumentID else {
            return nil
        }
        return URL(
            string: "\(ReadingArtifactRequest.scheme)://document/\(selectedDocumentID.rawValue.uuidString)/index.html"
        )
    }

    public func submitImport(rawURL: String) async {
        let trimmed = rawURL
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              Self.isValidWebURL(url)
        else {
            importState = .invalidURL
            return
        }
        do {
            try await library.submitImport(.webpage(url))
            importState = .submitted
        } catch {
            importState = .libraryUnavailable
        }
    }

    /// Heading blocks in reading order, each carrying its positional
    /// block index and heading level.
    static func outlineProjection(
        of content: SourceDocumentContent
    ) -> [ReadingOutlineNode] {
        let blocksByID = Dictionary(
            uniqueKeysWithValues: content.blocks.map { ($0.id, $0) }
        )
        var nodes: [ReadingOutlineNode] = []
        for (index, blockID) in content.structure.orderedBlockIDs
            .enumerated() {
            guard let block = blocksByID[blockID],
                  case .heading(let level) = block.role
            else {
                continue
            }
            nodes.append(ReadingOutlineNode(
                blockIndex: index,
                level: level,
                text: block.canonicalText
            ))
        }
        return nodes
    }

    private static func isValidWebURL(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty
        else {
            return false
        }
        return true
    }
}
