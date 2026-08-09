import Foundation
import KnowledgeCore
import TestFixtures
import Testing

@testable import DocumentImport
import LocalLibrary

@Suite("Web milestone hardening", .serialized)
struct WebMilestoneHardeningTests {
    @Test func classifyMapsInsufficientDiskSpaceToTypedRequiresUserActionFailure() {
        let failure = DocumentImport.classify(LocalLibraryError.insufficientDiskSpace)

        #expect(failure.code == .insufficientDiskSpace)
        #expect(failure.recovery == .requiresUserAction)
    }

    @Test func builderRecordsEncodingFallbackIssueOnTheProduct() async throws {
        // Legacy GBK page: not valid UTF-8, so the meta-declared GBK
        // charset rescues it and the degradation must surface as an issue.
        let html = "<html><head><meta charset=\"gbk\"><title>编码救援</title></head><body><article><h1>编码救援</h1><p>正文段落足够长。</p></article></body></html>"
        let gbk = try #require(htmlStringEncoding(for: "gbk"))
        let bytes = try #require(html.data(using: gbk))
        let url = URL(string: "https://fixture.invalid/encoding")!
        let page = AcquiredWebPage(
            sourceURL: url,
            finalURL: url,
            mimeType: "text/html",
            textEncodingName: nil,
            bytes: bytes
        )

        let product = try await StaticWebDocumentBuilder().build(
            page,
            documentID: SourceDocumentID()
        )

        #expect(product.issues.contains(
            KnowledgeCore.ImportIssue(code: .webEncodingFallback)
        ))
    }

    @Test(.timeLimit(.minutes(1)))
    func successfulImportReportsOrderedStageTimingFacts() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let library = try await LocalLibrary.open(
            at: root.appending(path: "Library")
        )
        let fixture = try Data(contentsOf: FixtureCatalog.webArticleURL)
        let server = try await LocalHTTPFixtureServer.start { path in
            guard path.hasSuffix("index.html") else {
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
            return .init(
                headers: ["Content-Type": "text/html; charset=utf-8"],
                body: fixture
            )
        }
        defer { server.stop() }
        let importer = DocumentImport(library: library)

        let terminal = try await importer.submit(
            .webpage(server.url("articles/simple/index.html"))
        ).value()

        guard case .success(.published(_, _, let facts)) = terminal else {
            Issue.record("Expected published, got \(terminal)")
            return
        }
        let timings = try #require(facts).stageTimings
        #expect(timings.map(\.stage) == [
            .acquiringSource, .constructingDocument, .publishing,
        ])
        for timing in timings {
            #expect(timing.durationMilliseconds >= 0)
        }
    }
}
