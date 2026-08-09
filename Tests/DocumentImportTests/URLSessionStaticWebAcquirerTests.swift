import Foundation
import Network
import Testing
@testable import DocumentImport

@Suite(.serialized)
struct URLSessionStaticWebAcquirerTests {
    @Test
    func acquiresHTMLWithURLProvenanceMIMETypeCharsetAndBytes() async throws {
        let html = Data("<html><article>Hello</article></html>".utf8)
        let server = try await LocalHTTPFixtureServer.start { path in
            #expect(path == "/article")
            return .init(
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: html
            )
        }
        defer { server.stop() }

        let sourceURL = server.url("article")
        let page = try await URLSessionStaticWebAcquirer().acquire(sourceURL)

        #expect(page.sourceURL == sourceURL)
        #expect(page.finalURL == server.url("article"))
        #expect(page.mimeType == "text/html")
        #expect(page.textEncodingName == "utf-8")
        #expect(page.bytes == html)
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

        let sourceURL = server.url("redirect")
        let page = try await URLSessionStaticWebAcquirer().acquire(sourceURL)

        #expect(page.sourceURL == sourceURL)
        #expect(page.finalURL == server.url("final"))
        #expect(page.mimeType == "application/xhtml+xml")
        #expect(page.textEncodingName == nil)
    }

    @Test(arguments: [
        ("text/html; charset=WiNdOwS-1252", "windows-1252"),
        ("text/html; charset=X-UnKnOwN", "x-unknown"),
        ("text/html", nil),
    ])
    func normalizesPersistedHTTPCharset(
        contentType: String,
        expectedCharset: String?
    ) async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": contentType],
                body: Data("<html></html>".utf8)
            )
        }
        defer { server.stop() }

        let page = try await URLSessionStaticWebAcquirer().acquire(
            server.url("charset")
        )

        #expect(page.textEncodingName == expectedCharset)
    }

    @Test(arguments: [
        ("UTF-8", "utf-8"),
        ("Shift_JIS", "shift_jis"),
        ("X.Custom+Future", "x.custom+future"),
        ("X!#$%&'*+-.^_`|~", "x!#$%&'*+-.^_`|~"),
    ])
    func charsetTokenNormalizationAcceptsOnlyNormalizedHTTPTokenCharacters(
        input: String,
        expected: String
    ) {
        #expect(normalizedWebCharsetName(input) == expected)
    }

    @Test(arguments: [
        "", " utf-8", "utf-8 ", "utf 8", "utf\t8", "utf\n8",
        "utf\u{0}8", "utf\u{1f}8", "utf\u{7f}8", "\"utf-8\"",
        "utf/8", "utf;8", "utf=8", "utf(8)", "utf,8", "é",
    ])
    func charsetTokenNormalizationRejectsWhitespaceControlsAndSeparators(
        input: String
    ) {
        #expect(normalizedWebCharsetName(input) == nil)
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
    func cancelsAnOversizedUnknownLengthResponseWhileStreaming() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "text/html"],
                body: Data(repeating: 0x61, count: 8_192),
                framing: .omitContentLength
            )
        }
        defer { server.stop() }
        let acquirer = URLSessionStaticWebAcquirer(maximumResponseBytes: 1_024)

        await #expect(throws: WebAcquisitionError.responseTooLarge) {
            try await acquirer.acquire(server.url("large"))
        }
    }

    @Test
    func responseLimitCheckIsOverflowSafeForOneHugeCallback() {
        #expect(
            responseWouldExceedLimit(
                receivedCount: 0,
                incomingCount: Int.max,
                maximumResponseBytes: 1_024
            )
        )
    }

    @Test
    func rejectsDecodedResponseDespiteDeceptiveShortWireContentLength() async throws {
        let compressedBody = Data(base64Encoded:
            "H4sIAPwEdGoAA+3BAQ0AAADCoK7vH8IcbkABAAAAAAAAAO8GKkjRagAgAAA="
        )!
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: [
                    "Content-Encoding": "gzip",
                    "Content-Type": "text/html",
                ],
                body: compressedBody
            )
        }
        defer { server.stop() }

        await #expect(throws: WebAcquisitionError.responseTooLarge) {
            try await URLSessionStaticWebAcquirer(maximumResponseBytes: 1_024)
                .acquire(server.url("deceptive"))
        }
    }

    @Test
    func acceptsAStreamingResponseAtTheExactMaximum() async throws {
        let body = Data(repeating: 0x63, count: 1_024)
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "text/html"],
                body: body,
                framing: .chunked
            )
        }
        defer { server.stop() }

        let page = try await URLSessionStaticWebAcquirer(
            maximumResponseBytes: body.count
        ).acquire(server.url("exact"))

        #expect(page.responseBytes == body)
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

    @Test
    func taskCancellationThrowsCancellationError() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(
                headers: ["Content-Type": "text/html"],
                body: Data("<html></html>".utf8),
                delay: .seconds(2)
            )
        }
        defer { server.stop() }

        let task = Task {
            try await URLSessionStaticWebAcquirer().acquire(server.url("delayed"))
        }
        try await Task.sleep(for: .milliseconds(50))
        task.cancel()

        await #expect(throws: CancellationError.self) {
            try await task.value
        }
    }

    @Test
    func redirectLoopIsAnInvalidHTTPResponse() async throws {
        let server = try await LocalHTTPFixtureServer.start { _ in
            .init(status: 302, headers: ["Location": "/loop"])
        }
        defer { server.stop() }

        await #expect(throws: WebAcquisitionError.invalidHTTPResponse) {
            try await URLSessionStaticWebAcquirer().acquire(server.url("loop"))
        }
    }

    @Test
    func stoppedServerReleasesListenerHandlersAndDeallocates() async throws {
        var server: LocalHTTPFixtureServer? = try await .start { _ in
            .init(headers: ["Content-Type": "text/html"])
        }
        weak let weakServer = server

        server?.stop()
        server = nil
        for _ in 0..<20 where weakServer != nil {
            await Task.yield()
        }

        #expect(weakServer == nil)
    }

    @Test
    func queuedConnectionDeliveredAfterStopIsCancelledAndNotRetained() async throws {
        var server: LocalHTTPFixtureServer? = try await .start { _ in
            .init(headers: ["Content-Type": "text/html"])
        }
        weak let weakServer = server
        let queuedConnection = NWConnection(
            host: "127.0.0.1",
            port: .http,
            using: .tcp
        )

        server?.stop()
        let wasStarted = server?.acceptQueuedConnectionForTesting(
            queuedConnection
        )

        #expect(wasStarted == false)
        #expect(server?.retainedConnectionCountForTesting == 0)
        server = nil
        for _ in 0..<20 where weakServer != nil {
            await Task.yield()
        }
        #expect(weakServer == nil)
    }
}
