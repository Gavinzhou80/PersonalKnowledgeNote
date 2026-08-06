import Foundation
import KnowledgeCore
import LocalLibrary
import TestFixtures
import Testing
@testable import DocumentImport

@Suite(.serialized)
struct RealStaticWebImportIntegrationTests {
    @Test(.timeLimit(.minutes(1)))
    func publicImportPublishesAnAuthoritativeOfflineWebPackage() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let libraryRoot = root.appending(path: "Library")
        let library = try await LocalLibrary.open(at: libraryRoot)
        let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
        let hero = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
        let server = try await LocalHTTPFixtureServer.start { path in
            switch path {
            case "/articles/rich/index.html?utm_source=integration":
                return .init(
                    headers: ["Content-Type": "text/html; charset=utf-8"],
                    body: fixture,
                    delay: .milliseconds(100)
                )
            case "/articles/rich/hero.svg":
                return .init(
                    headers: ["Content-Type": "image/svg+xml"],
                    body: hero,
                    delay: .milliseconds(250)
                )
            default:
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
        }
        defer { server.stop() }
        let sourceURL = server.url("articles/rich/index.html?utm_source=integration")
        let documentImport = DocumentImport(library: library)

        let handle = try await documentImport.submit(.webpage(sourceURL))
        let workspace = try #require(try await library.importWorkspace(id: handle.id))
        #expect((try await workspace.snapshot()).state != .completed)

        var updates = handle.updates().makeAsyncIterator()
        var snapshots: [ImportTaskSnapshot] = []
        var checkedAtomicVisibility = false
        while let snapshot = await updates.next() {
            snapshots.append(snapshot)
            if case .running(let progress) = snapshot.state,
               progress.activity == .constructingSourceDocument {
                checkedAtomicVisibility = true
                let artifacts = try FileManager.default.contentsOfDirectory(
                    at: libraryRoot.appending(path: "Artifacts"),
                    includingPropertiesForKeys: nil
                )
                #expect(artifacts.isEmpty)
            }
        }
        #expect(checkedAtomicVisibility)

        let terminal = await handle.value()
        let documentID = try #require(publishedDocumentID(terminal))
        #expect(terminal == .success(.published(documentID: documentID, issues: [])))
        #expect(snapshots.compactMap(\.activity) == [
            .acquiringOriginalSource,
            .constructingSourceDocument,
            .publishing,
        ])
        #expect(snapshots.last?.state == .completed(
            .published(documentID: documentID, issues: [])
        ))

        let located = try #require(try await library.sourceDocument(id: documentID))
        let content = located.document.content
        #expect(located.location == .library)
        #expect(located.document.artifact.kind == .webPackage)
        #expect(content.importedMetadata == ImportedDocumentMetadata(
            title: "Rich Fixture Article",
            author: "Ada Example",
            publishedAt: ISO8601DateFormatter().date(from: "2025-04-03T10:15:30Z")
        ))
        #expect(content.blocks.map(\.role) == [
            .heading(level: 1), .paragraph, .heading(level: 2), .paragraph,
            .listItem, .listItem, .listItem, .quotation,
            .codeBlock(language: "swift"), .image, .caption,
        ])
        #expect(content.blocks.map(\.canonicalText) == [
            "Rich Fixture Article",
            "A careful article with strong evidence, a useful link, Example Journal, and inline().",
            "Details", "Second paragraph.", "First unordered item", "Second unordered item",
            "First ordered item", "Quoted insight.",
            "let greeting = \"hello\"\nprint(greeting)", "Abstract fixture hero", "The fixture hero image.",
        ])
        #expect(content.blocks[1].inlineMarkup.map(\.kind) == [
            .emphasis, .strong,
            .link(URL(string: "https://example.com/reference?keep=yes")!),
            .citation(nil), .inlineCode,
        ])
        let intro = content.blocks[1]
        let introText = intro.canonicalText as NSString
        #expect(intro.inlineMarkup.map {
            introText.substring(with: NSRange(
                location: $0.range.utf16Offset,
                length: $0.range.utf16Length
            ))
        } == [
            "careful", "strong evidence", "useful link", "Example Journal", "inline()",
        ])
        #expect(content.structure.orderedBlockIDs == content.blocks.map(\.id))
        let image = content.blocks[9]
        let caption = content.blocks[10]
        #expect(image.media?.kind == .image)
        #expect(image.media?.mimeType == "image/svg+xml")
        #expect(image.media?.altText == "Abstract fixture hero")
        #expect(image.media?.artifactRelativePath.hasPrefix("assets/") == true)
        #expect(content.structure.relations == [
            SourceRelation(
                sourceBlockID: caption.id,
                targetBlockID: image.id,
                kind: .captionForMedia
            ),
        ])
        #expect(content.evidence[content.blocks[0].id] == .web(locator: "#headline"))
        #expect(content.evidence[content.blocks[1].id] == .web(locator: "#intro"))
        #expect(content.evidence[content.blocks[2].id] == .web(locator: "#story > h2:nth-of-type(1)"))
        #expect(content.evidence[content.blocks[3].id] == .web(locator: "#story > p:nth-of-type(2)"))
        #expect(content.evidence[image.id] == .web(locator: "#hero-image"))
        #expect(content.evidence[caption.id] == .web(locator: "#hero-caption"))
        #expect(Set(content.evidence.keys) == Set(content.blocks.map(\.id)))
        #expect(content.issues.isEmpty)

        let packageURL = libraryRoot.appending(path: "Artifacts/\(documentID.rawValue.uuidString)/payload")
        let indexURL = packageURL.appending(path: "index.html")
        let assetURL = try #require(image.media).artifactRelativePath
        #expect(FileManager.default.fileExists(atPath: indexURL.path))
        #expect(FileManager.default.fileExists(atPath: packageURL.appending(path: assetURL).path))
        server.stop()
        let offlineHTML = try Data(contentsOf: indexURL)
        let rendered = String(decoding: offlineHTML, as: UTF8.self).lowercased()
        #expect(rendered.contains("default-src 'none'"))
        #expect(!rendered.contains("src=\"http://"))
        #expect(!rendered.contains("src=\"https://"))
        let parsed = try StaticArticleExtractor().extract(
            html: offlineHTML,
            sourceURL: sourceURL
        )
        #expect(parsed.blocks.map(\.canonicalText) == content.blocks.map(\.canonicalText))
    }

    @Test(.timeLimit(.minutes(1)))
    func missingOptionalImagePublishesWithTheExactPersistentIssue() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
        let fixture = try Data(contentsOf: FixtureCatalog.richArticleURL)
        let server = try await LocalHTTPFixtureServer.start { path in
            if path == "/missing/index.html" {
                return .init(headers: ["Content-Type": "text/html"], body: fixture)
            }
            return .init(status: 404, headers: ["Content-Type": "text/plain"])
        }
        defer { server.stop() }

        let handle = try await DocumentImport(library: library).submit(
            .webpage(server.url("missing/index.html"))
        )
        let terminal = await handle.value()
        let documentID = try #require(publishedDocumentID(terminal))
        let located = try #require(try await library.sourceDocument(id: documentID))
        let image = try #require(located.document.content.blocks.first { $0.role == .image })
        let expected = [KnowledgeCore.ImportIssue(
            code: .optionalWebImageUnavailable,
            relatedBlockID: image.id
        )]

        #expect(located.document.content.issues == expected)
        #expect(terminal == .success(.published(documentID: documentID, issues: expected)))
    }

    @Test(.timeLimit(.minutes(1)))
    func canonicalDuplicateAddsProvenanceWithoutReplacingTheFirstPublication() async throws {
        let root = try makeTemporaryDocumentImportRoot()
        defer { removeTemporaryDocumentImportRoot(root) }
        let libraryRoot = root.appending(path: "Library")
        let library = try await LocalLibrary.open(at: libraryRoot)
        let fixture = String(decoding: try Data(contentsOf: FixtureCatalog.richArticleURL), as: UTF8.self)
        let hero = try Data(contentsOf: FixtureCatalog.richArticleHeroURL)
        let alternate = fixture
            .replacingOccurrences(of: "Navigation noise", with: "Changed navigation chrome")
            .replacingOccurrences(of: "Advertisement noise", with: "Changed advertisement chrome")
            .replacingOccurrences(
                of: "https://example.com/reference?utm_source=fixture&amp;utm_medium=test&amp;keep=yes",
                with: "https://elsewhere.example/reference?utm_campaign=duplicate&amp;keep=yes"
            )
        let server = try await LocalHTTPFixtureServer.start { path in
            switch path {
            case "/first/index.html":
                return .init(headers: ["Content-Type": "text/html"], body: Data(fixture.utf8))
            case "/first/hero.svg":
                return .init(headers: ["Content-Type": "image/svg+xml"], body: hero)
            case "/second/article.html?utm_source=duplicate&utm_campaign=changed":
                return .init(headers: ["Content-Type": "text/html"], body: Data(alternate.utf8))
            default:
                return .init(status: 404, headers: ["Content-Type": "text/plain"])
            }
        }
        defer { server.stop() }
        let importer = DocumentImport(library: library)

        let firstTerminal = try await importer.submit(
            .webpage(server.url("first/index.html"))
        ).value()
        let firstID = try #require(publishedDocumentID(firstTerminal))
        let first = try #require(try await library.sourceDocument(id: firstID)).document
        let firstPackage = libraryRoot.appending(path: "Artifacts/\(firstID.rawValue.uuidString)/payload")
        let firstIndex = try Data(contentsOf: firstPackage.appending(path: "index.html"))

        let secondURL = server.url("second/article.html?utm_source=duplicate&utm_campaign=changed")
        let secondTerminal = try await importer.submit(.webpage(secondURL)).value()

        #expect(secondTerminal == .success(.alreadyImported(
            documentID: firstID,
            location: .library,
            provenanceAdded: true
        )))
        let preserved = try #require(try await library.sourceDocument(id: firstID)).document
        #expect(preserved == first)
        #expect(try Data(contentsOf: firstPackage.appending(path: "index.html")) == firstIndex)
        #expect(try FileManager.default.contentsOfDirectory(
            at: libraryRoot.appending(path: "Artifacts"),
            includingPropertiesForKeys: nil
        ).count == 1)
    }
}

private extension ImportTaskSnapshot {
    var activity: ImportActivity? {
        guard case .running(let progress) = state else { return nil }
        return progress.activity
    }
}

private func publishedDocumentID(_ terminal: ImportTerminalState) -> SourceDocumentID? {
    guard case .success(.published(let documentID, _)) = terminal else { return nil }
    return documentID
}
