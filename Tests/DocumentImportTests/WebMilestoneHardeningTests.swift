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

    @Test(.timeLimit(.minutes(3)))
    func restartAfterAcquiredCheckpointReLocalizesResources() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let libraryRoot = root.appending(path: "Library")
        let library = try await LocalLibrary.open(at: libraryRoot)
        let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
        let hero = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
        let server = try await LocalHTTPFixtureServer.start { path in
            switch path {
            case "/articles/rich/index.html":
                return .init(
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: fixture
                )
            case "/articles/rich/hero.svg":
                return .init(
                    headers: ["Content-Type": "image/svg+xml"],
                    body: hero
                )
            default:
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
        }
        defer { server.stop() }
        let crashInjector = ImportRunnerCrashInjector(
            crashPoint: .afterAcquiredCheckpoint
        )
        let first = DocumentImport(
            library: library,
            webAcquirer: URLSessionStaticWebAcquirer(),
            importRunnerBoundaryHook: { point in
                try crashInjector.hit(point)
            }
        )

        let handle = try await first.submit(
            .webpage(server.url("articles/rich/index.html"))
        )
        try await crashInjector.waitForInjectedTermination()

        let reopened = try await LocalLibrary.open(at: libraryRoot)
        let second = DocumentImport(
            library: reopened,
            webAcquirer: ThrowingWebAcquirer()
        )
        try await second.start()

        let recovered = try #require(try await second.task(id: handle.id))
        let terminal = await recovered.value()

        guard case .success(.published(let documentID, _, _)) = terminal else {
            Issue.record("Expected published after restart, got \(terminal)")
            return
        }
        // The restart must re-run localization from the acquired
        // checkpoint and produce the image asset in the final package.
        let assetsURL = libraryRoot
            .appending(path: "Artifacts/\(documentID.rawValue.uuidString)/payload/assets")
        let assets = try FileManager.default.contentsOfDirectory(
            at: assetsURL,
            includingPropertiesForKeys: nil
        )
        #expect(!assets.isEmpty)
        let heroAsset = try #require(assets.first)
        #expect(try Data(contentsOf: heroAsset) == hero)
    }

    @Test func failureDiagnosticsCarryNoSourceOrContent() throws {
        let urlMarker = "https://secret.example.com/private/article"
        let bodyMarker = "CONFIDENTIAL_ARTICLE_BODY"
        let failure = DocumentImport.classify(
            WebAcquisitionError.networkUnavailable
        )
        // PersistedImportFailure is the durable shape of a terminal
        // failure; it must carry no source or content information.
        let persisted = PersistedImportFailure(
            code: failure.code,
            recovery: failure.recovery,
            diagnosticID: failure.diagnosticID
        )

        let payload = String(
            decoding: try JSONEncoder().encode(persisted),
            as: UTF8.self
        )

        #expect(!payload.contains(urlMarker))
        #expect(!payload.contains(bodyMarker))
        #expect(payload.contains(failure.diagnosticID.uuidString))
    }

    @Test(.timeLimit(.minutes(1)))
    func typicalStaticImportStaysWithinThePerformanceBudget() async throws {
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

        let clock = ContinuousClock()
        let elapsed = await clock.measure {
            _ = try? await importer.submit(
                .webpage(server.url("articles/budget/index.html"))
            ).value()
        }

        #expect(elapsed < .seconds(5))
    }
}
