import Foundation
import Testing
@testable import DocumentImport

@Suite(.serialized)
struct URLSessionStaticWebAcquirerTests {
    @Test
    func acquiresHTMLWithFinalURLMIMETypeAndBytes() async throws {
        let html = Data("<html><article>Hello</article></html>".utf8)
        let server = try await LocalHTTPFixtureServer.start { path in
            #expect(path == "/article")
            return .init(
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        }
        defer { server.stop() }

        let page = try await URLSessionStaticWebAcquirer().acquire(server.url("article"))

        #expect(page.finalURL == server.url("article"))
        #expect(page.mimeType == "text/html")
        #expect(page.responseBytes == html)
    }

    @Test
    func followsRedirectAndReportsFinalURL() async throws {
        let server = try await LocalHTTPFixtureServer.start { path in
            if path == "/redirect" {
                return .init(status: 302, headers: ["Location": "/final"])
            }
            return .init(
                headers: ["Content-Type": "application/xhtml+xml"],
                body: Data("<html><body>Final</body></html>".utf8)
            )
        }
        defer { server.stop() }

        let page = try await URLSessionStaticWebAcquirer().acquire(server.url("redirect"))

        #expect(page.finalURL == server.url("final"))
        #expect(page.mimeType == "application/xhtml+xml")
    }

    @Test
    func mapsForbiddenResponseToAccessDenied() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(status: 403)
        }
        defer { server.stop() }

        await #expect(throws: WebAcquisitionError.accessDenied) {
            try await URLSessionStaticWebAcquirer().acquire(server.url("forbidden"))
        }
    }

    @Test
    func rejectsNonHTMLContentType() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "application/json"],
                body: Data("{}".utf8)
            )
        }
        defer { server.stop() }

        await #expect(throws: WebAcquisitionError.unsupportedContentType) {
            try await URLSessionStaticWebAcquirer().acquire(server.url("json"))
        }
    }

    @Test
    func cancelsAnOversizedResponse() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "text/html"],
                body: Data(repeating: 0x61, count: 8_192)
            )
        }
        defer { server.stop() }
        let acquirer = URLSessionStaticWebAcquirer(maximumResponseBytes: 1_024)

        await #expect(throws: WebAcquisitionError.responseTooLarge) {
            try await acquirer.acquire(server.url("large"))
        }
    }

    @Test
    func mapsConfiguredTimeout() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "text/html"],
                body: Data("<html></html>".utf8),
                delay: .milliseconds(500)
            )
        }
        defer { server.stop() }
        let acquirer = URLSessionStaticWebAcquirer(
            requestTimeout: 0.1,
            resourceTimeout: 0.1
        )

        await #expect(throws: WebAcquisitionError.requestTimedOut) {
            try await acquirer.acquire(server.url("slow"))
        }
    }

    @Test
    func rejectsNonHTTPURLBeforeStartingANetworkRequest() async {
        await #expect(throws: WebAcquisitionError.invalidHTTPResponse) {
            try await URLSessionStaticWebAcquirer().acquire(
                URL(fileURLWithPath: "/tmp/article.html")
            )
        }
    }
}
