import CryptoKit
import Foundation
import KnowledgeCore
import LocalLibrary
import SwiftSoup
import Testing
@testable import DocumentImport

@Test
func localizesDuplicateImagesOnceAndRecordsOptionalFailures() async throws {
    let probe = RequestProbe()
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg' width='8' height='6'></svg>".utf8)
    let server = try await LocalHTTPFixtureServer.start { path in
        probe.begin(path)
        if path == "/hero.svg" {
            return .init(headers: ["Content-Type": "Image/SVG+XML; charset=utf-8"], body: svg, delay: .milliseconds(40), onSendCompleted: { probe.end() })
        }
        return .init(status: 404, headers: ["Content-Type": "text/plain"], body: Data("missing".utf8), onSendCompleted: { probe.end() })
    }
    defer { server.stop() }
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let goodURL = server.url("hero.svg")
    let missingURL = server.url("missing.svg")
    let candidates = [
        candidate("first", goodURL, alt: "Hero"),
        candidate("duplicate", goodURL, alt: "Second alt"),
        candidate("missing", missingURL),
    ]

    let result = try await WebResourceLocalizer().localize(candidates, into: package)

    #expect(probe.count(for: "/hero.svg") == 1)
    #expect(result.mediaByCandidateKey["first"]?.artifactRelativePath == result.mediaByCandidateKey["duplicate"]?.artifactRelativePath)
    let digest = SHA256.hash(data: svg).map { String(format: "%02x", $0) }.joined()
    let relativePath = "assets/\(digest).svg"
    #expect(result.mediaByCandidateKey["first"]?.artifactRelativePath == relativePath)
    #expect(try Data(contentsOf: package.appending(path: relativePath)) == svg)
    #expect(result.issues == [
        .init(code: .optionalWebImageUnavailable, candidateKey: "missing"),
    ])
}

@Test
func boundsImageRequestsToFourRealConcurrentTransfers() async throws {
    let probe = RequestProbe()
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'></svg>".utf8)
    let server = try await LocalHTTPFixtureServer.start { path in
        probe.begin(path)
        return .init(headers: ["Content-Type": "image/svg+xml"], body: svg, delay: .milliseconds(80), onSendCompleted: { probe.end() })
    }
    defer { server.stop() }
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let candidates = (0..<10).map { candidate("image-\($0)", server.url("image-\($0).svg")) }

    let result = try await WebResourceLocalizer().localize(candidates, into: package)

    #expect(result.mediaByCandidateKey.count == 10)
    #expect(probe.maximumConcurrent == 4)
}

@Test
func rejectsInvalidUnsafeAndOversizedImagesWithoutFailingTheBatch() async throws {
    let oversized = Data(repeating: 0x41, count: WebResourceLocalizer.maximumImageBytes + 1)
    let server = try await LocalHTTPFixtureServer.start { path in
        switch path {
        case "/not-image": .init(headers: ["Content-Type": "text/html"], body: Data("<p>bad</p>".utf8))
        case "/oversized": .init(headers: ["Content-Type": "image/png"], body: oversized, framing: .chunked)
        default: .init(status: 403, headers: ["Content-Type": "image/png"])
        }
    }
    defer { server.stop() }
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let candidates = [
        candidate("mime", server.url("not-image")),
        candidate("large", server.url("oversized")),
        candidate("status", server.url("forbidden")),
        candidate("unsafe", URL(string: "file:///etc/passwd")!),
    ]

    let result = try await WebResourceLocalizer().localize(candidates, into: package)

    #expect(result.mediaByCandidateKey.isEmpty)
    #expect(result.issues.count == 4)
    #expect(result.issues.allSatisfy { $0.code == .optionalWebImageUnavailable })
}

@Test
func rendererCreatesClosedParseableOfflinePackage() async throws {
    let svg = Data("<svg xmlns='http://www.w3.org/2000/svg'><text>&amp;</text></svg>".utf8)
    let server = try await LocalHTTPFixtureServer.start { _ in
        .init(headers: ["Content-Type": "image/svg+xml"], body: svg)
    }
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let imageURL = server.url("hero.svg")
    let article = ExtractedWebArticle(
        metadata: .init(title: "A <safe> title", author: "Author & Co"),
        blocks: [
            .init(category: .text, role: .heading(level: 1), canonicalText: "Heading", inlineMarkup: [], evidenceLocator: "#h", imageKey: nil, relationTargetKey: nil),
            .init(category: .text, role: .paragraph, canonicalText: "Read linked code.", inlineMarkup: [
                .init(range: .init(utf16Offset: 5, utf16Length: 6), kind: .link(URL(string: "https://example.com/read?q=1&x=2")!)),
                .init(range: .init(utf16Offset: 12, utf16Length: 4), kind: .inlineCode),
            ], evidenceLocator: "#p", imageKey: nil, relationTargetKey: nil),
            .init(category: .media, role: .image, canonicalText: "Hero <alt>", inlineMarkup: [], evidenceLocator: "#img", imageKey: "hero", relationTargetKey: nil),
            .init(category: .text, role: .caption, canonicalText: "Caption", inlineMarkup: [], evidenceLocator: "#cap", imageKey: nil, relationTargetKey: "hero"),
            .init(category: .media, role: .image, canonicalText: "Missing", inlineMarkup: [], evidenceLocator: "#missing", imageKey: "missing", relationTargetKey: nil),
        ],
        rootSelector: "#article",
        imageCandidates: [candidate("hero", imageURL)]
    )
    let localized = try await WebResourceLocalizer().localize(article.imageCandidates, into: package)
    try WebArtifactRenderer().render(article, localizedMedia: localized.mediaByCandidateKey, into: package)
    let rendered = try LocalLibrary.describeWebPackage(at: package)
    server.stop()

    let htmlURL = package.appending(path: "index.html")
    let html = try String(contentsOf: htmlURL, encoding: .utf8)
    let parsed = try SwiftSoup.parse(html)
    #expect(try parsed.title() == "A <safe> title")
    #expect(try parsed.select("img").count == 1)
    #expect(try parsed.select("img[src^=assets/]").count == 1)
    #expect(try parsed.select("figure > img + figcaption").text() == "Caption")
    #expect(try parsed.select("img[srcset],source,script,style,link,iframe,form").isEmpty())
    #expect(try parsed.select("a[href^=https]").first()?.attr("rel") == "noopener noreferrer")
    #expect(try parsed.select("a").first()?.attr("referrerpolicy") == "no-referrer")
    #expect(!html.contains(imageURL.absoluteString))
    #expect(!html.lowercased().contains("javascript:"))
    for image in try parsed.select("img[src]").array() {
        #expect(FileManager.default.fileExists(atPath: package.appending(path: try image.attr("src")).path))
    }
    #expect(rendered.kind == .webPackage)
    #expect(rendered.byteCount > UInt64(svg.count))
}

@Test
func rendererKeepsCaptionWhenItsTargetImageIsAbsent() throws {
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let article = ExtractedWebArticle(
        metadata: .init(title: "Orphan caption", author: nil),
        blocks: [
            .init(
                category: .text,
                role: .caption,
                canonicalText: "Readable orphan caption.",
                inlineMarkup: [],
                evidenceLocator: "#caption",
                imageKey: nil,
                relationTargetKey: "missing-target"
            ),
        ],
        rootSelector: "#article",
        imageCandidates: []
    )

    try WebArtifactRenderer().render(article, localizedMedia: [:], into: package)

    let parsed = try SwiftSoup.parse(String(
        contentsOf: package.appending(path: "index.html"),
        encoding: .utf8
    ))
    #expect(try parsed.select("figcaption").text() == "Readable orphan caption.")
    #expect(try parsed.select("figcaption").count == 1)
}

@Test(arguments: ["", "Readable alt"])
func rendererKeepsUnavailableImageCaptionExactlyOnce(alt: String) throws {
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let article = ExtractedWebArticle(
        metadata: .init(title: "Unavailable image", author: nil),
        blocks: [
            .init(category: .media, role: .image, canonicalText: alt, inlineMarkup: [], evidenceLocator: "#image", imageKey: "image", relationTargetKey: nil),
            .init(category: .text, role: .caption, canonicalText: "Readable caption.", inlineMarkup: [], evidenceLocator: "#caption", imageKey: nil, relationTargetKey: "image"),
        ],
        rootSelector: "#article",
        imageCandidates: []
    )

    try WebArtifactRenderer().render(article, localizedMedia: [:], into: package)

    let html = try String(contentsOf: package.appending(path: "index.html"), encoding: .utf8)
    let parsed = try SwiftSoup.parse(html)
    #expect(try parsed.select("figure > figcaption").isEmpty())
    #expect(try parsed.select("article > figcaption").text() == "Readable caption.")
    #expect(try parsed.select("figcaption").count == 1)
    #expect(try parsed.select("img[src]").isEmpty())
    #expect(!html.contains("http://") && !html.contains("https://"))
}

@Test
func rendererPreservesNestedInlineSemantics() throws {
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let article = ExtractedWebArticle(
        metadata: .init(title: "Nested", author: nil),
        blocks: [
            .init(
                category: .text,
                role: .paragraph,
                canonicalText: "nested text",
                inlineMarkup: [
                    .init(range: .init(utf16Offset: 0, utf16Length: 11), kind: .strong),
                    .init(range: .init(utf16Offset: 0, utf16Length: 6), kind: .emphasis),
                ],
                evidenceLocator: "#nested",
                imageKey: nil,
                relationTargetKey: nil
            ),
        ],
        rootSelector: "#nested",
        imageCandidates: []
    )

    _ = try WebArtifactRenderer().render(article, localizedMedia: [:], into: package)

    let parsed = try SwiftSoup.parse(String(contentsOf: package.appending(path: "index.html"), encoding: .utf8))
    #expect(try parsed.select("strong > em").text() == "nested")
    #expect(try parsed.select("strong").text() == "nested text")
}

@Test(arguments: [false, true])
func rendererDeterministicallyNestsEqualRangeStrongAndEmphasis(
    reversed: Bool
) throws {
    let strong = InlineMarkup(
        range: .init(utf16Offset: 0, utf16Length: 4),
        kind: .strong
    )
    let emphasis = InlineMarkup(
        range: .init(utf16Offset: 0, utf16Length: 4),
        kind: .emphasis
    )
    let html = try renderedInlineHTML(
        text: "same",
        markup: reversed ? [emphasis, strong] : [strong, emphasis]
    )

    #expect(html.contains("<strong><em>same</em></strong>"))
    let parsed = try SwiftSoup.parse(html)
    #expect(try parsed.select("strong > em").text() == "same")
}

@Test(arguments: [false, true])
func rendererDeterministicallyNestsEqualRangeLinkAndEmphasis(
    reversed: Bool
) throws {
    let link = InlineMarkup(
        range: .init(utf16Offset: 0, utf16Length: 4),
        kind: .link(URL(string: "https://example.com/read")!)
    )
    let emphasis = InlineMarkup(
        range: .init(utf16Offset: 0, utf16Length: 4),
        kind: .emphasis
    )
    let html = try renderedInlineHTML(
        text: "same",
        markup: reversed ? [emphasis, link] : [link, emphasis]
    )

    #expect(html.contains(">same</em></a>"))
    let parsed = try SwiftSoup.parse(html)
    #expect(try parsed.select("a > em").text() == "same")
    #expect(try parsed.body()?.text() == "same")
}

@Test
func cancellationIsNotPersistedAsAnOptionalImageFailure() async throws {
    let probe = RequestProbe()
    let server = try await LocalHTTPFixtureServer.start { path in
        probe.begin(path)
        return .init(
            headers: ["Content-Type": "image/svg+xml"],
            body: Data("<svg/>".utf8),
            delay: .seconds(30),
            onSendCompleted: { probe.end() }
        )
    }
    defer { server.stop() }
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let task = Task {
        try await WebResourceLocalizer().localize(
            (0..<8).map { candidate("slow-\($0)", server.url("slow-\($0).svg")) },
            into: package
        )
    }
    await probe.wait(untilTotalCount: 4)
    task.cancel()

    await #expect(throws: CancellationError.self) {
        try await task.value
    }
    await server.waitUntilNoRetainedConnectionsForTesting()
    #expect(probe.totalCount == 4)
    #expect(server.retainedConnectionCountForTesting == 0)
}

@Test
func missingImageWithOnlyCaptionKeepsStandaloneReadableSemantics() throws {
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let article = ExtractedWebArticle(
        metadata: .init(title: "Caption fallback", author: nil),
        blocks: [
            .init(
                category: .media,
                role: .image,
                canonicalText: "",
                inlineMarkup: [],
                evidenceLocator: "#missing",
                imageKey: "missing",
                relationTargetKey: nil
            ),
            .init(
                category: .text,
                role: .caption,
                canonicalText: "Readable fallback caption",
                inlineMarkup: [],
                evidenceLocator: "#caption",
                imageKey: nil,
                relationTargetKey: "missing"
            ),
        ],
        rootSelector: "#article",
        imageCandidates: []
    )

    _ = try WebArtifactRenderer().render(article, localizedMedia: [:], into: package)

    let html = try String(contentsOf: package.appending(path: "index.html"), encoding: .utf8)
    let parsed = try SwiftSoup.parse(html)
    #expect(try parsed.select("figure").isEmpty())
    #expect(try parsed.select("article > [data-missing-image=true]").count == 1)
    #expect(try parsed.select("article > figcaption").text() == "Readable fallback caption")
    #expect(try parsed.select("figcaption").count == 1)
    #expect(try parsed.select("img,source").isEmpty())
    #expect(!html.contains("http://") && !html.contains("https://"))
}

private func candidate(_ key: String, _ url: URL, alt: String? = nil) -> WebImageCandidate {
    .init(stableKey: key, resolvedURL: url, altText: alt, evidenceLocator: "#\(key)")
}

private func temporaryPackage() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appending(path: "WebResourceLocalizerTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    return url
}

private func renderedInlineHTML(
    text: String,
    markup: [InlineMarkup]
) throws -> String {
    let package = try temporaryPackage()
    defer { try? FileManager.default.removeItem(at: package) }
    let article = ExtractedWebArticle(
        metadata: .init(title: "Inline", author: nil),
        blocks: [
            .init(
                category: .text,
                role: .paragraph,
                canonicalText: text,
                inlineMarkup: markup,
                evidenceLocator: "#inline",
                imageKey: nil,
                relationTargetKey: nil
            ),
        ],
        rootSelector: "#inline",
        imageCandidates: []
    )
    _ = try WebArtifactRenderer().render(article, localizedMedia: [:], into: package)
    return try String(contentsOf: package.appending(path: "index.html"), encoding: .utf8)
}

private final class RequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [String: Int] = [:]
    private var current = 0
    private var maximum = 0
    private var total = 0
    private var waiters: [(Int, CheckedContinuation<Void, Never>)] = []

    func begin(_ path: String) {
        let ready: [CheckedContinuation<Void, Never>] = lock.withLock {
            counts[path, default: 0] += 1
            current += 1
            total += 1
            maximum = max(maximum, current)
            let result = waiters.filter { total >= $0.0 }.map(\ .1)
            waiters.removeAll { total >= $0.0 }
            return result
        }
        ready.forEach { $0.resume() }
    }

    func end() { lock.withLock { current -= 1 } }
    func count(for path: String) -> Int { lock.withLock { counts[path, default: 0] } }
    var maximumConcurrent: Int { lock.withLock { maximum } }
    var totalCount: Int { lock.withLock { total } }

    func wait(untilTotalCount target: Int) async {
        await withCheckedContinuation { continuation in
            let resumeNow = lock.withLock {
                if total >= target { return true }
                waiters.append((target, continuation))
                return false
            }
            if resumeNow { continuation.resume() }
        }
    }
}
