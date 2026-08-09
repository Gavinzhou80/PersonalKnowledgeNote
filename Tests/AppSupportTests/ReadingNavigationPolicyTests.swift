import AppSupport
import Foundation
import Testing

private func requireURL(_ string: String) throws -> URL {
    try #require(URL(string: string))
}

@Test
func externalWebLinksOpenInDefaultBrowser() async throws {
    let document = try requireURL(
        "pkn-reading://document/ABC/index.html"
    )
    for external in [
        "https://example.com/article",
        "http://example.com/page",
    ] {
        let disposition = ReadingNavigationPolicy.disposition(
            for: try requireURL(external),
            currentDocument: document
        )
        #expect(disposition == .openInBrowser, "For \(external)")
    }
}

@Test
func sameDocumentNavigationIsAllowed() async throws {
    let document = try requireURL(
        "pkn-reading://document/ABC/index.html"
    )
    let disposition = ReadingNavigationPolicy.disposition(
        for: document,
        currentDocument: document
    )
    #expect(disposition == .allow)
}

@Test
func otherNavigationsAreCancelled() async throws {
    let document = try requireURL(
        "pkn-reading://document/ABC/index.html"
    )
    let hostile: [URL] = [
        try requireURL("pkn-reading://document/OTHER/index.html"),
        try requireURL("file:///etc/passwd"),
        try requireURL("ftp://example.com/file"),
    ]
    for proposed in hostile {
        let disposition = ReadingNavigationPolicy.disposition(
            for: proposed,
            currentDocument: document
        )
        #expect(disposition == .cancel, "For \(proposed)")
    }

    let withoutCurrent = ReadingNavigationPolicy.disposition(
        for: document,
        currentDocument: nil
    )
    #expect(withoutCurrent == .cancel)
}
