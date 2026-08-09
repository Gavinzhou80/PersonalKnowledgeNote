import AppSupport
import Foundation
import KnowledgeCore
import LocalLibrary
import WebKit

/// Serves `pkn-reading://document/<id>/<path>` through the library read
/// seam; refuses every other request.
@MainActor
final class ArtifactSchemeHandler: NSObject, WKURLSchemeHandler {
    static let scheme = ReadingArtifactRequest.scheme

    private let library: any ReadingLibraryPort
    // Deliveries to a stopped scheme task raise an uncatchable
    // NSException; track live tasks so async responses never land
    // after WebKit has stopped them.
    private var activeTaskIDs: Set<ObjectIdentifier> = []

    init(library: any ReadingLibraryPort) {
        self.library = library
    }

    func webView(
        _ webView: WKWebView,
        start urlSchemeTask: any WKURLSchemeTask
    ) {
        let taskID = ObjectIdentifier(urlSchemeTask)
        activeTaskIDs.insert(taskID)
        let requestURL = urlSchemeTask.request.url
        Task { [weak self] in
            let response: URLResponse
            let body: Data
            if let requestURL,
               let resolved = await self?.resource(for: requestURL) {
                response = HTTPURLResponse(
                    url: requestURL,
                    statusCode: 200,
                    httpVersion: "HTTP/1.1",
                    headerFields: [
                        "Content-Type": resolved.contentType,
                        "Cache-Control": "no-store",
                    ]
                )!
                body = resolved.data
            } else {
                response = HTTPURLResponse(
                    url: requestURL
                        ?? URL(string: "\(Self.scheme)://invalid")!,
                    statusCode: 404,
                    httpVersion: "HTTP/1.1",
                    headerFields: [:]
                )!
                body = Data()
            }
            guard let self,
                  self.activeTaskIDs.contains(taskID)
            else {
                return
            }
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(body)
            urlSchemeTask.didFinish()
            self.activeTaskIDs.remove(taskID)
        }
    }

    func webView(
        _ webView: WKWebView,
        stop urlSchemeTask: any WKURLSchemeTask
    ) {
        activeTaskIDs.remove(ObjectIdentifier(urlSchemeTask))
    }

    private func resource(
        for url: URL
    ) async -> ArtifactResource? {
        guard let request = ReadingArtifactRequest.parse(url) else {
            return nil
        }
        return try? await library.artifactResource(
            documentID: request.documentID,
            relativePath: request.relativePath
        )
    }
}
