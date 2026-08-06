import Foundation

enum WebAcquisitionError: Error, Equatable, Sendable {
    case networkUnavailable
    case requestTimedOut
    case accessDenied
    case invalidHTTPResponse
    case unsupportedContentType
    case responseTooLarge
}

protocol WebAcquiring: Sendable {
    func acquire(_ url: URL) async throws -> AcquiredWebPage
}

struct AcquiredWebPage: Sendable {
    let finalURL: URL
    let mimeType: String
    let responseBytes: Data

    var sourceURL: URL { finalURL }
    var html: Data { responseBytes }

    init(finalURL: URL, mimeType: String, responseBytes: Data) {
        self.finalURL = finalURL
        self.mimeType = mimeType
        self.responseBytes = responseBytes
    }

    init(sourceURL: URL, html: Data) {
        self.init(
            finalURL: sourceURL,
            mimeType: "text/html",
            responseBytes: html
        )
    }
}
