import Foundation

enum WebAcquisitionError: Error {
    case networkUnavailable
}

protocol WebAcquiring: Sendable {
    func acquire(_ url: URL) async throws -> AcquiredWebPage
}

struct AcquiredWebPage: Sendable {
    let sourceURL: URL
    let html: Data

    init(sourceURL: URL, html: Data) {
        self.sourceURL = sourceURL
        self.html = html
    }
}
