# T03 Static Web Import Tracer Bullet Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Submit one deterministic HTTPS webpage through the public Document Import interface, expose authoritative progress and terminal success, build and atomically publish a managed static Web Source Document, and map its snapshots into Import Center presentation data.

**Architecture:** Add a standalone `DocumentImport` Swift target between `KnowledgeCore`, `LocalLibrary`, and `AppSupport`. The actor durably accepts work through Local Library before returning a handle, uses an internal injected acquisition port to obtain fixture HTML, builds deterministic Web content and a script-free package, and publishes through the existing revision-checked workspace seam. Automated tests inject fixture bytes but exercise submission, observation, terminal waiting, and final document access through public interfaces.

**Tech Stack:** Swift 6, Swift Package Manager, Swift Testing, Foundation, FoundationXML, CryptoKit, GRDB-backed `LocalLibrary`, `AsyncStream`, Swift actors.

---

## File Structure

Create or modify the following focused files:

- `Package.swift` — add the DocumentImport product, target, test target, and AppSupport dependency.
- `Sources/DocumentImport/ImportTaskModels.swift` — public task queries, snapshots, progress, success, failure, and terminal values.
- `Sources/DocumentImport/ImportTaskHandle.swift` — public capability tied to one task.
- `Sources/DocumentImport/DocumentImport.swift` — durable submission, task registry, observation, orchestration, publication, and failure translation.
- `Sources/DocumentImport/Internal/WebAcquisition.swift` — internal static Web acquisition port and acquired-page value.
- `Sources/DocumentImport/Internal/StableWebIdentity.swift` — SHA-256 helpers, deterministic block IDs, fingerprinting, and single-file package descriptor calculation.
- `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift` — HTML extraction, ordered blocks/evidence, Source Document construction, and script-free `index.html` package generation.
- `Tests/DocumentImportTests/ImportTaskModelTests.swift` — public value semantics.
- `Tests/DocumentImportTests/StaticWebDocumentBuilderTests.swift` — deterministic fixture extraction and artifact tests.
- `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift` — public-interface durable acceptance, progress, publication, and failure-boundary tests.
- `Tests/DocumentImportTests/DocumentImportTestSupport.swift` — temporary library helpers and gated/throwing acquisition adapters.
- `Sources/AppSupport/ImportCenterPresentation.swift` — pure task-snapshot presentation mapping.
- `Tests/AppSupportTests/ImportCenterPresentationTests.swift` — queued, running, failed, and success presentation coverage.

Do not modify or commit the existing dirty files listed by `git status` unless a later user instruction explicitly places them in scope.

---

### Task 1: Add the DocumentImport target and public task values

**Files:**

- Modify: `Package.swift`
- Create: `Sources/DocumentImport/ImportTaskModels.swift`
- Test: `Tests/DocumentImportTests/ImportTaskModelTests.swift`

- [ ] **Step 1: Write the failing public-value tests**

Create `Tests/DocumentImportTests/ImportTaskModelTests.swift`:

```swift
import Foundation
import KnowledgeCore
import Testing
import DocumentImport

@Test
func importTaskSnapshotCarriesApprovedPublicState() throws {
    let taskID = ImportTaskID()
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    let snapshot = ImportTaskSnapshot(
        id: taskID,
        revision: 3,
        attempt: 1,
        source: .webpage(sourceURL),
        state: .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )

    #expect(snapshot.id == taskID)
    #expect(snapshot.revision == 3)
    #expect(snapshot.attempt == 1)
    #expect(snapshot.source == .webpage(sourceURL))
    #expect(
        snapshot.state == .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
}

@Test
func terminalSuccessPreservesPublicationOutcome() {
    let documentID = SourceDocumentID()
    let success = ImportSuccess.published(
        documentID: documentID,
        issues: []
    )

    #expect(ImportTerminalState.success(success) == .success(success))
}
```

- [ ] **Step 2: Add the package graph and verify the target is missing**

Modify `Package.swift` to add:

```swift
.library(name: "DocumentImport", targets: ["DocumentImport"]),
```

Add the target before `AppSupport`:

```swift
.target(
    name: "DocumentImport",
    dependencies: ["KnowledgeCore", "LocalLibrary"]
),
```

Change AppSupport dependencies to:

```swift
dependencies: ["KnowledgeCore", "LocalLibrary", "DocumentImport"]
```

Add the test target:

```swift
.testTarget(
    name: "DocumentImportTests",
    dependencies: [
        "DocumentImport",
        "LocalLibrary",
        "TestFixtures",
    ]
),
```

Run:

```bash
swift test --filter importTaskSnapshotCarriesApprovedPublicState
```

Expected: FAIL because `ImportTaskSnapshot`, `ImportProgress`, and the DocumentImport public values do not exist.

- [ ] **Step 3: Implement the minimal public value model**

Create `Sources/DocumentImport/ImportTaskModels.swift`:

```swift
import Foundation
import KnowledgeCore

public enum ImportTaskQuery: Hashable, Sendable {
    case unfinished
    case active
    case all
}

public enum OriginalSourceSummary: Hashable, Sendable {
    case webpage(URL)
    case pdfFile(name: String)
}

public struct ImportTaskSnapshot: Hashable, Sendable {
    public let id: ImportTaskID
    public let revision: UInt64
    public let attempt: UInt
    public let source: OriginalSourceSummary
    public let state: ImportTaskState

    public init(
        id: ImportTaskID,
        revision: UInt64,
        attempt: UInt,
        source: OriginalSourceSummary,
        state: ImportTaskState
    ) {
        self.id = id
        self.revision = revision
        self.attempt = attempt
        self.source = source
        self.state = state
    }
}

public enum ImportTaskState: Hashable, Sendable {
    case queued(position: Int)
    case running(ImportProgress)
    case failed(ImportFailure)
    case completed(ImportSuccess)
}

public struct ImportProgress: Hashable, Sendable {
    public let activity: ImportActivity
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64?

    public init(
        activity: ImportActivity,
        completedUnitCount: Int64,
        totalUnitCount: Int64?
    ) {
        self.activity = activity
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public enum ImportActivity: String, Hashable, Sendable {
    case acquiringOriginalSource
    case constructingSourceDocument
    case publishing
}

public struct ImportIssue: Hashable, Sendable {
    public enum Code: String, Hashable, Sendable {
        case optionalResourceUnavailable
    }

    public let code: Code

    public init(code: Code) {
        self.code = code
    }
}

public enum ImportSuccess: Hashable, Sendable {
    case published(
        documentID: SourceDocumentID,
        issues: [ImportIssue]
    )
    case alreadyImported(
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation,
        provenanceAdded: Bool
    )
}

public struct ImportFailure: Error, Hashable, Sendable {
    public enum Code: String, Hashable, Sendable {
        case networkUnavailable
        case webpageHasNoReadableArticle
        case artifactConstructionFailed
        case localLibraryUnavailable
        case publicationFailed
    }

    public enum Recovery: String, Hashable, Sendable {
        case retryable
        case requiresNewOriginalSource
        case requiresUserAction
        case unsupported
    }

    public let code: Code
    public let recovery: Recovery
    public let diagnosticID: UUID

    public init(
        code: Code,
        recovery: Recovery,
        diagnosticID: UUID = UUID()
    ) {
        self.code = code
        self.recovery = recovery
        self.diagnosticID = diagnosticID
    }
}

public enum ImportTerminalState: Hashable, Sendable {
    case success(ImportSuccess)
    case failure(ImportFailure)
}

public enum ImportSubmissionError: Error, Equatable, Sendable {
    case invalidWebURL
    case unsupportedOriginalSource
    case insufficientDiskSpace
    case localLibraryUnavailable
    case cannotPersistImportTask
}
```

- [ ] **Step 4: Run the narrow tests**

Run:

```bash
swift test --filter ImportTaskModelTests
```

Expected: PASS.

- [ ] **Step 5: Commit the public model**

```bash
git add Package.swift Sources/DocumentImport/ImportTaskModels.swift Tests/DocumentImportTests/ImportTaskModelTests.swift
git commit -m "feat: define public document import task values"
```

---

### Task 2: Build deterministic static Web content and package output

**Files:**

- Create: `Sources/DocumentImport/Internal/WebAcquisition.swift`
- Create: `Sources/DocumentImport/Internal/StableWebIdentity.swift`
- Create: `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift`
- Test: `Tests/DocumentImportTests/StaticWebDocumentBuilderTests.swift`

- [ ] **Step 1: Write the failing fixture-builder test**

Create `Tests/DocumentImportTests/StaticWebDocumentBuilderTests.swift`:

```swift
import Foundation
import KnowledgeCore
import TestFixtures
import Testing
@testable import DocumentImport

@Test
func staticFixtureBuildsDeterministicManagedWebContent() throws {
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    let page = AcquiredWebPage(
        sourceURL: sourceURL,
        html: try Data(contentsOf: FixtureCatalog.webArticleURL)
    )
    let documentID = SourceDocumentID(
        try #require(UUID(uuidString: "10000000-0000-0000-0000-000000000001"))
    )
    let first = try StaticWebDocumentBuilder().build(
        page: page,
        documentID: documentID
    )
    defer { try? FileManager.default.removeItem(at: first.packageURL) }
    let second = try StaticWebDocumentBuilder().build(
        page: page,
        documentID: documentID
    )
    defer { try? FileManager.default.removeItem(at: second.packageURL) }

    #expect(first.document.importedMetadata.title == "Fixture Article")
    #expect(first.document.importedMetadata.author == nil)
    #expect(
        first.document.blocks.map(\.canonicalText) == [
            "Fixture Article",
            "Deterministic offline content.",
        ]
    )
    #expect(
        first.document.structure.orderedBlockIDs
            == first.document.blocks.map(\.id)
    )
    #expect(Set(first.document.evidence.keys) == Set(first.document.blocks.map(\.id)))
    #expect(
        first.document.evidence[first.document.blocks[0].id]
            == .web(locator: "article > h1:nth-of-type(1)")
    )
    #expect(
        first.document.evidence[first.document.blocks[1].id]
            == .web(locator: "article > p:nth-of-type(1)")
    )
    #expect(first.document.blocks.map(\.id) == second.document.blocks.map(\.id))
    #expect(first.fingerprint == second.fingerprint)
    #expect(first.descriptor == second.descriptor)

    let artifact = try String(
        contentsOf: first.packageURL.appending(path: "index.html"),
        encoding: .utf8
    )
    #expect(!artifact.localizedCaseInsensitiveContains("<script"))
    #expect(!artifact.localizedCaseInsensitiveContains("<form"))
    #expect(!artifact.localizedCaseInsensitiveContains("http://"))
    #expect(!artifact.localizedCaseInsensitiveContains("https://"))
    #expect(artifact.contains("Fixture Article"))
    #expect(artifact.contains("Deterministic offline content."))
    #expect(first.descriptor.kind == .webPackage)
    #expect(first.descriptor.byteCount > 0)
    #expect(!first.descriptor.contentHash.isEmpty)
}
```

- [ ] **Step 2: Run the builder test to verify RED**

Run:

```bash
swift test --filter staticFixtureBuildsDeterministicManagedWebContent
```

Expected: FAIL because the acquisition value and static builder do not exist.

- [ ] **Step 3: Define the internal acquisition port**

Create `Sources/DocumentImport/Internal/WebAcquisition.swift`:

```swift
import Foundation

protocol WebAcquiring: Sendable {
    func acquire(_ url: URL) async throws -> AcquiredWebPage
}

struct AcquiredWebPage: Sendable {
    let sourceURL: URL
    let html: Data
}
```

- [ ] **Step 4: Implement stable identities and the package descriptor**

Create `Sources/DocumentImport/Internal/StableWebIdentity.swift` with these operations:

```swift
import CryptoKit
import Foundation
import KnowledgeCore

enum StableWebIdentity {
    static let ruleVersion = "static-web-v1"

    static func blockID(
        role: String,
        ordinal: Int,
        text: String
    ) -> SourceBlockID {
        let digest = sha256Hex(
            Data("\(ruleVersion)\u{1f}\(role)\u{1f}\(ordinal)\u{1f}\(text)".utf8)
        )
        let uuidString = [
            String(digest.prefix(8)),
            String(digest.dropFirst(8).prefix(4)),
            String(digest.dropFirst(12).prefix(4)),
            String(digest.dropFirst(16).prefix(4)),
            String(digest.dropFirst(20).prefix(12)),
        ].joined(separator: "-")
        return SourceBlockID(UUID(uuidString: uuidString)!)
    }

    static func fingerprint(
        blocks: [(role: String, text: String)]
    ) -> ContentFingerprint {
        let body = blocks.enumerated().map { index, block in
            "\(index)\u{1f}\(block.role)\u{1f}\(block.text)"
        }.joined(separator: "\u{1e}")
        return ContentFingerprint(
            sha256Hex(Data("\(ruleVersion)\u{1d}\(body)".utf8))
        )
    }

    static func packageDescriptor(
        relativePath: String,
        contents: Data
    ) -> SourceArtifactDescriptor {
        let path = Data(relativePath.utf8)
        var manifest = Data([1])
        manifest.append(fixedWidthBytes(UInt64(path.count)))
        manifest.append(path)
        manifest.append(fixedWidthBytes(UInt64(contents.count)))
        manifest.append(contents)
        return SourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: UInt64(contents.count),
            contentHash: sha256Hex(manifest)
        )
    }

    private static func fixedWidthBytes(_ value: UInt64) -> Data {
        var encoded = value.bigEndian
        return withUnsafeBytes(of: &encoded) { Data($0) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
```

- [ ] **Step 5: Implement the static article builder**

Create `Sources/DocumentImport/Internal/StaticWebDocumentBuilder.swift`. The implementation must:

```swift
import Foundation
import FoundationXML
import KnowledgeCore

enum StaticWebBuildError: Error {
    case unreadableHTML
    case missingArticle
    case noReadableBlocks
    case cannotWritePackage
}

struct StaticWebImportProduct {
    let packageURL: URL
    let descriptor: SourceArtifactDescriptor
    let fingerprint: ContentFingerprint
    let document: SourceDocumentContent
}

struct StaticWebDocumentBuilder {
    private enum Role {
        case heading(level: Int)
        case paragraph

        var fingerprintValue: String {
            switch self {
            case .heading(let level): "heading-\(level)"
            case .paragraph: "paragraph"
            }
        }
    }

    private struct ExtractedBlock {
        let role: Role
        let tag: String
        let text: String
        let locator: String
    }

    func build(
        page: AcquiredWebPage,
        documentID: SourceDocumentID
    ) throws -> StaticWebImportProduct {
        let xml: XMLDocument
        do {
            xml = try XMLDocument(
                data: page.html,
                options: .documentTidyHTML
            )
        } catch {
            throw StaticWebBuildError.unreadableHTML
        }

        guard let article = try xml.nodes(forXPath: "//article").first
            as? XMLElement
        else {
            throw StaticWebBuildError.missingArticle
        }

        var counts: [String: Int] = [:]
        var extracted: [ExtractedBlock] = []
        for case let element as XMLElement in article.children ?? [] {
            guard let rawName = element.name?.lowercased() else { continue }
            let role: Role
            if rawName.count == 2,
               rawName.first == "h",
               let level = Int(String(rawName.last!)),
               (1...6).contains(level)
            {
                role = .heading(level: level)
            } else if rawName == "p" {
                role = .paragraph
            } else {
                continue
            }
            let text = normalize(element.stringValue ?? "")
            guard !text.isEmpty else { continue }
            counts[rawName, default: 0] += 1
            extracted.append(ExtractedBlock(
                role: role,
                tag: rawName,
                text: text,
                locator: "article > \(rawName):nth-of-type(\(counts[rawName]!))"
            ))
        }
        guard !extracted.isEmpty else {
            throw StaticWebBuildError.noReadableBlocks
        }

        let title = normalize(
            (try xml.nodes(forXPath: "//title").first?.stringValue) ?? ""
        )
        let resolvedTitle = title.isEmpty ? extracted[0].text : title
        let blocks = extracted.enumerated().map { index, item in
            SourceBlock(
                id: StableWebIdentity.blockID(
                    role: item.role.fingerprintValue,
                    ordinal: index,
                    text: item.text
                ),
                canonicalText: item.text
            )
        }
        let evidence = Dictionary(uniqueKeysWithValues: zip(blocks, extracted).map {
            ($0.0.id, SourceEvidence.web(locator: $0.1.locator))
        })
        let content = SourceDocumentContent(
            documentID: documentID,
            importedMetadata: ImportedDocumentMetadata(
                title: resolvedTitle,
                author: nil
            ),
            blocks: blocks,
            structure: SourceStructure(orderedBlockIDs: blocks.map(\.id)),
            evidence: evidence
        )
        let html = renderHTML(title: resolvedTitle, blocks: extracted)
        let htmlData = Data(html.utf8)
        let packageURL = FileManager.default.temporaryDirectory.appending(
            path: "DocumentImport-\(UUID().uuidString)",
            directoryHint: .isDirectory
        )
        do {
            try FileManager.default.createDirectory(
                at: packageURL,
                withIntermediateDirectories: true
            )
            try htmlData.write(
                to: packageURL.appending(path: "index.html"),
                options: .atomic
            )
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw StaticWebBuildError.cannotWritePackage
        }
        return StaticWebImportProduct(
            packageURL: packageURL,
            descriptor: StableWebIdentity.packageDescriptor(
                relativePath: "index.html",
                contents: htmlData
            ),
            fingerprint: StableWebIdentity.fingerprint(
                blocks: extracted.map {
                    ($0.role.fingerprintValue, $0.text)
                }
            ),
            document: content
        )
    }

    private func normalize(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private func renderHTML(
        title: String,
        blocks: [ExtractedBlock]
    ) -> String {
        let body = blocks.map { block in
            "<\(block.tag)>\(escape(block.text))</\(block.tag)>"
        }.joined(separator: "\n")
        return """
        <!doctype html>
        <html lang="en">
          <head>
            <meta charset="utf-8">
            <title>\(escape(title))</title>
          </head>
          <body>
            <article>
        \(body)
            </article>
          </body>
        </html>
        """
    }

    private func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
}
```

- [ ] **Step 6: Run the builder test and full target tests**

Run:

```bash
swift test --filter staticFixtureBuildsDeterministicManagedWebContent
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 7: Commit the static builder**

```bash
git add Sources/DocumentImport/Internal Tests/DocumentImportTests/StaticWebDocumentBuilderTests.swift
git commit -m "feat: build deterministic static web documents"
```

---

### Task 3: Implement durable submission, authoritative streams, and atomic publication

**Files:**

- Create: `Sources/DocumentImport/ImportTaskHandle.swift`
- Create: `Sources/DocumentImport/DocumentImport.swift`
- Create: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Create: `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift`

- [ ] **Step 1: Add the gated public-interface integration test**

Create test support with:

```swift
import Foundation
import TestFixtures
@testable import DocumentImport

func makeDocumentImportTestRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory.appending(
        path: "DocumentImportTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
    )
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

actor GatedFixtureWebAcquirer: WebAcquiring {
    private let html: Data
    private var started = false
    private var released = false
    private var startedWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?

    init() throws {
        html = try Data(contentsOf: FixtureCatalog.webArticleURL)
    }

    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        started = true
        startedWaiters.forEach { $0.resume() }
        startedWaiters.removeAll()
        if !released {
            await withCheckedContinuation { releaseWaiter = $0 }
        }
        return AcquiredWebPage(sourceURL: url, html: html)
    }

    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiters.append($0) }
    }

    func release() {
        released = true
        releaseWaiter?.resume()
        releaseWaiter = nil
    }
}
```

Create `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift` with a test that:

```swift
import Foundation
import KnowledgeCore
import LocalLibrary
import Testing
@testable import DocumentImport

@Test
func publicInterfaceImportsStaticFixtureAfterDurableAcceptance() async throws {
    let root = try makeDocumentImportTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try await LocalLibrary.open(
        at: root.appending(path: "Library")
    )
    let acquirer = try GatedFixtureWebAcquirer()
    let documentID = SourceDocumentID(
        try #require(UUID(uuidString: "20000000-0000-0000-0000-000000000001"))
    )
    let importer = DocumentImport(
        library: library,
        webAcquirer: acquirer,
        documentIDGenerator: { documentID }
    )
    let sourceURL = try #require(
        URL(string: "https://fixture.invalid/article")
    )
    var allTasks = importer.observeTasks(.all).makeAsyncIterator()
    #expect(try #require(await allTasks.next()).isEmpty)

    let handle = try await importer.submit(.webpage(sourceURL))
    let queued = try #require(await allTasks.next()).first
    #expect(queued?.state == .queued(position: 0))
    let durableWorkspace = try #require(
        try await library.importWorkspace(id: handle.id)
    )
    #expect((try await durableWorkspace.snapshot()).state == .accepted)

    await acquirer.waitUntilStarted()
    #expect(try await library.sourceDocument(id: documentID) == nil)
    let acquiring = try #require(await allTasks.next()).first
    #expect(
        acquiring?.state == .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    var handleUpdates = handle.updates().makeAsyncIterator()
    #expect(try #require(await handleUpdates.next()).revision == acquiring?.revision)

    async let terminal = handle.value()
    await acquirer.release()
    let constructing = try #require(await allTasks.next()).first
    let publishing = try #require(await allTasks.next()).first
    let completed = try #require(await allTasks.next()).first
    #expect((constructing?.revision ?? 0) < (publishing?.revision ?? 0))
    #expect((publishing?.revision ?? 0) < (completed?.revision ?? 0))
    #expect(
        constructing?.state == .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    #expect(
        publishing?.state == .running(ImportProgress(
            activity: .publishing,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    )
    let expectedSuccess = ImportSuccess.published(
        documentID: documentID,
        issues: []
    )
    #expect(completed?.state == .completed(expectedSuccess))
    #expect(await terminal == .success(expectedSuccess))

    let located = try #require(
        try await library.sourceDocument(id: documentID)
    )
    #expect(located.location == .library)
    #expect(located.document.artifact.kind == .webPackage)
    #expect(
        located.document.content.blocks.map(\.canonicalText) == [
            "Fixture Article",
            "Deterministic offline content.",
        ]
    )
    #expect(
        located.document.content.structure.orderedBlockIDs
            == located.document.content.blocks.map(\.id)
    )
    #expect(
        Set(located.document.content.evidence.keys)
            == Set(located.document.content.blocks.map(\.id))
    )
}
```

- [ ] **Step 2: Run the integration test to verify RED**

Run:

```bash
swift test --filter publicInterfaceImportsStaticFixtureAfterDurableAcceptance
```

Expected: FAIL because `DocumentImport`, `ImportTaskHandle`, observation, and orchestration do not exist.

- [ ] **Step 3: Implement the task handle**

Create `Sources/DocumentImport/ImportTaskHandle.swift`:

```swift
import KnowledgeCore

public struct ImportTaskHandle: Sendable {
    public let id: ImportTaskID
    private let owner: DocumentImport

    init(id: ImportTaskID, owner: DocumentImport) {
        self.id = id
        self.owner = owner
    }

    public func updates() -> AsyncStream<ImportTaskSnapshot> {
        owner.updates(for: id)
    }

    public func value() async -> ImportTerminalState {
        await owner.value(for: id)
    }
}
```

- [ ] **Step 4: Implement the actor registry and observation streams**

Create `Sources/DocumentImport/DocumentImport.swift` with:

```swift
import Foundation
import KnowledgeCore
import LocalLibrary

public actor DocumentImport {
    private struct TaskRecord {
        var snapshot: ImportTaskSnapshot
        let sequence: UInt64
        var terminal: ImportTerminalState? = nil
        var observers: [UUID: AsyncStream<ImportTaskSnapshot>.Continuation] = [:]
        var waiters: [CheckedContinuation<ImportTerminalState, Never>] = []
    }

    private struct ListObserver {
        let query: ImportTaskQuery
        let continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
    }

    private let library: LocalLibrary
    private let webAcquirer: any WebAcquiring
    private let documentIDGenerator: @Sendable () -> SourceDocumentID
    private var records: [ImportTaskID: TaskRecord] = [:]
    private var listObservers: [UUID: ListObserver] = [:]
    private var nextSequence: UInt64 = 0

    init(
        library: LocalLibrary,
        webAcquirer: any WebAcquiring,
        documentIDGenerator: @escaping @Sendable () -> SourceDocumentID = {
            SourceDocumentID()
        }
    ) {
        self.library = library
        self.webAcquirer = webAcquirer
        self.documentIDGenerator = documentIDGenerator
    }

    public nonisolated func observeTasks(
        _ query: ImportTaskQuery = .unfinished
    ) -> AsyncStream<[ImportTaskSnapshot]> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let token = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeListObserver(token) }
            }
            Task { await self.addListObserver(token, query, continuation) }
        }
    }

    nonisolated func updates(
        for id: ImportTaskID
    ) -> AsyncStream<ImportTaskSnapshot> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let token = UUID()
            continuation.onTermination = { @Sendable _ in
                Task { await self.removeTaskObserver(id: id, token: token) }
            }
            Task { await self.addTaskObserver(id: id, token: token, continuation: continuation) }
        }
    }

    func value(for id: ImportTaskID) async -> ImportTerminalState {
        if let terminal = records[id]?.terminal { return terminal }
        guard records[id] != nil else {
            return .failure(ImportFailure(
                code: .localLibraryUnavailable,
                recovery: .requiresUserAction
            ))
        }
        return await withCheckedContinuation { continuation in
            records[id]?.waiters.append(continuation)
        }
    }
```

Add these private observation methods so every stream immediately yields current state, filters with the approved semantics, and never cancels work when a continuation terminates:

```swift
private func addListObserver(
    _ token: UUID,
    _ query: ImportTaskQuery,
    _ continuation: AsyncStream<[ImportTaskSnapshot]>.Continuation
) {
    listObservers[token] = ListObserver(
        query: query,
        continuation: continuation
    )
    continuation.yield(snapshots(matching: query))
}

private func removeListObserver(_ token: UUID) {
    listObservers.removeValue(forKey: token)
}

private func addTaskObserver(
    id: ImportTaskID,
    token: UUID,
    continuation: AsyncStream<ImportTaskSnapshot>.Continuation
) {
    guard var record = records[id] else {
        continuation.finish()
        return
    }
    continuation.yield(record.snapshot)
    guard record.terminal == nil else {
        continuation.finish()
        return
    }
    record.observers[token] = continuation
    records[id] = record
}

private func removeTaskObserver(id: ImportTaskID, token: UUID) {
    guard var record = records[id] else { return }
    record.observers.removeValue(forKey: token)
    records[id] = record
}

private func snapshots(
    matching query: ImportTaskQuery
) -> [ImportTaskSnapshot] {
    records.values
        .filter { record in
            switch query {
            case .all:
                true
            case .active:
                switch record.snapshot.state {
                case .queued, .running: true
                case .failed, .completed: false
                }
            case .unfinished:
                switch record.snapshot.state {
                case .queued, .running, .failed: true
                case .completed: false
                }
            }
        }
        .sorted { $0.sequence < $1.sequence }
        .map(\.snapshot)
}

private func notifyListObservers() {
    for observer in listObservers.values {
        observer.continuation.yield(
            snapshots(matching: observer.query)
        )
    }
}

private func updateSnapshot(_ snapshot: ImportTaskSnapshot) {
    guard var record = records[snapshot.id] else { return }
    record.snapshot = snapshot
    let observers = Array(record.observers.values)
    records[snapshot.id] = record
    observers.forEach { $0.yield(snapshot) }
    notifyListObservers()
}
```

- [ ] **Step 5: Implement durable submission and the success workflow**

Add `submit`, checkpoint progression, construction, staging, and publication to the same actor:

```swift
public func submit(
    _ source: OriginalSource
) async throws -> ImportTaskHandle {
    guard case .webpage(let url) = source else {
        throw ImportSubmissionError.unsupportedOriginalSource
    }
    guard let scheme = url.scheme?.lowercased(),
          ["http", "https"].contains(scheme),
          url.host != nil
    else {
        throw ImportSubmissionError.invalidWebURL
    }

    let workspace: ImportWorkspace
    do {
        workspace = try await library.accept(source)
    } catch let error as LocalLibraryError {
        switch error {
        case .insufficientDiskSpace:
            throw ImportSubmissionError.insufficientDiskSpace
        case .unavailable, .corruptLibrary:
            throw ImportSubmissionError.localLibraryUnavailable
        default:
            throw ImportSubmissionError.cannotPersistImportTask
        }
    }
    let durable = try await workspace.snapshot()
    let snapshot = ImportTaskSnapshot(
        id: durable.taskID,
        revision: durable.revision,
        attempt: durable.attempt,
        source: .webpage(url),
        state: .queued(position: 0)
    )
    records[durable.taskID] = TaskRecord(
        snapshot: snapshot,
        sequence: nextSequence
    )
    nextSequence += 1
    notifyListObservers()

    let handle = ImportTaskHandle(id: durable.taskID, owner: self)
    Task { await self.runWebImport(source: source, url: url, workspace: workspace) }
    return handle
}

private func runWebImport(
    source: OriginalSource,
    url: URL,
    workspace: ImportWorkspace
) async {
    var packageURL: URL?
    do {
        var durable = try await checkpoint(
            workspace: workspace,
            ordinal: 1,
            activity: .acquiringOriginalSource
        )
        let page = try await webAcquirer.acquire(url)
        durable = try await checkpoint(
            workspace: workspace,
            expectedRevision: durable.revision,
            ordinal: 2,
            activity: .constructingSourceDocument
        )
        let product = try StaticWebDocumentBuilder().build(
            page: page,
            documentID: documentIDGenerator()
        )
        packageURL = product.packageURL
        let staged = try await workspace.stageArtifact(
            .package(product.packageURL, descriptor: product.descriptor),
            expectedRevision: durable.revision
        )
        durable = try await workspace.snapshot()
        durable = try await checkpoint(
            workspace: workspace,
            expectedRevision: durable.revision,
            ordinal: 3,
            activity: .publishing
        )
        let outcome = try await workspace.finish(
            PublicationCandidate(
                fingerprint: product.fingerprint,
                artifact: staged,
                document: product.document,
                originalSource: source
            ),
            expectedRevision: durable.revision
        )
        let completed = try await workspace.snapshot()
        finishTask(
            id: workspace.taskID,
            revision: completed.revision,
            success: map(outcome)
        )
    } catch {
        await failTask(id: workspace.taskID, workspace: workspace, error: error)
    }
    if let packageURL {
        try? FileManager.default.removeItem(at: packageURL)
    }
}
```

Add the exact checkpoint, outcome, completion, and initial generic-failure helpers below. Task 4 replaces the generic failure classification with typed classification.

```swift
private func checkpoint(
    workspace: ImportWorkspace,
    expectedRevision: UInt64? = nil,
    ordinal: UInt64,
    activity: ImportActivity
) async throws -> DurableImportSnapshot {
    let current = try await workspace.snapshot()
    let expected = expectedRevision ?? current.revision
    let durable = try await workspace.checkpoint(
        CheckpointUpdate(
            expectedRevision: expected,
            ordinal: ordinal,
            envelope: CheckpointEnvelope(
                codecVersion: 1,
                payload: Data(
                    "document-import-t03:\(activity.rawValue)".utf8
                )
            )
        )
    )
    guard let prior = records[workspace.taskID]?.snapshot else {
        throw LocalLibraryError.unavailable
    }
    updateSnapshot(ImportTaskSnapshot(
        id: prior.id,
        revision: durable.revision,
        attempt: durable.attempt,
        source: prior.source,
        state: .running(ImportProgress(
            activity: activity,
            completedUnitCount: 0,
            totalUnitCount: nil
        ))
    ))
    return durable
}

private func map(_ outcome: PublicationOutcome) -> ImportSuccess {
    switch outcome {
    case .published(let documentID):
        .published(documentID: documentID, issues: [])
    case .alreadyImported(
        let documentID,
        let location,
        let provenanceAdded
    ):
        .alreadyImported(
            documentID: documentID,
            location: location,
            provenanceAdded: provenanceAdded
        )
    }
}

private func finishTask(
    id: ImportTaskID,
    revision: UInt64,
    success: ImportSuccess
) {
    guard var record = records[id] else { return }
    let snapshot = ImportTaskSnapshot(
        id: id,
        revision: revision,
        attempt: record.snapshot.attempt,
        source: record.snapshot.source,
        state: .completed(success)
    )
    let terminal = ImportTerminalState.success(success)
    let observers = Array(record.observers.values)
    let waiters = record.waiters
    record.snapshot = snapshot
    record.terminal = terminal
    record.observers.removeAll()
    record.waiters.removeAll()
    records[id] = record
    observers.forEach {
        $0.yield(snapshot)
        $0.finish()
    }
    waiters.forEach { $0.resume(returning: terminal) }
    notifyListObservers()
}

private func failTask(
    id: ImportTaskID,
    workspace: ImportWorkspace,
    error: Error
) async {
    let durable = try? await workspace.snapshot()
    if let durable {
        try? await workspace.abandon(expectedRevision: durable.revision)
    }
    let failure = ImportFailure(
        code: .localLibraryUnavailable,
        recovery: .requiresUserAction
    )
    completeFailure(
        id: id,
        durableRevision: durable?.revision,
        failure: failure
    )
}

private func completeFailure(
    id: ImportTaskID,
    durableRevision: UInt64?,
    failure: ImportFailure
) {
    guard var record = records[id] else { return }
    let revision = max(
        record.snapshot.revision + 1,
        durableRevision ?? 0
    )
    let snapshot = ImportTaskSnapshot(
        id: id,
        revision: revision,
        attempt: record.snapshot.attempt,
        source: record.snapshot.source,
        state: .failed(failure)
    )
    let terminal = ImportTerminalState.failure(failure)
    let observers = Array(record.observers.values)
    let waiters = record.waiters
    record.snapshot = snapshot
    record.terminal = terminal
    record.observers.removeAll()
    record.waiters.removeAll()
    records[id] = record
    observers.forEach {
        $0.yield(snapshot)
        $0.finish()
    }
    waiters.forEach { $0.resume(returning: terminal) }
    notifyListObservers()
}
```

- [ ] **Step 6: Run the integration and Local Library regression tests**

Run:

```bash
swift test --filter publicInterfaceImportsStaticFixtureAfterDurableAcceptance
swift test --filter DocumentImportTests
swift test --filter LocalLibraryTests
```

Expected: PASS.

- [ ] **Step 7: Commit the public vertical slice**

```bash
git add Sources/DocumentImport/DocumentImport.swift Sources/DocumentImport/ImportTaskHandle.swift Tests/DocumentImportTests/DocumentImportTestSupport.swift Tests/DocumentImportTests/DocumentImportIntegrationTests.swift
git commit -m "feat: import static web fixture through public interface"
```

---

### Task 4: Enforce the submission and post-acceptance failure boundary

**Files:**

- Modify: `Sources/DocumentImport/DocumentImport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportTestSupport.swift`
- Modify: `Tests/DocumentImportTests/DocumentImportIntegrationTests.swift`

- [ ] **Step 1: Add failing submission and task-failure tests**

Add a throwing adapter:

```swift
struct ThrowingFixtureWebAcquirer: WebAcquiring {
    func acquire(_ url: URL) async throws -> AcquiredWebPage {
        throw WebAcquisitionError.networkUnavailable
    }
}
```

Add tests that assert:

```swift
@Test
func invalidWebURLFailsBeforeDurableAcceptance() async throws {
    let root = try makeDocumentImportTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingFixtureWebAcquirer()
    )

    await #expect(throws: ImportSubmissionError.invalidWebURL) {
        _ = try await importer.submit(.webpage(URL(string: "relative/path")!))
    }
    #expect(try await library.recoverableImports().isEmpty)
}

@Test
func acquisitionFailureIsTerminalTaskDataAfterAcceptance() async throws {
    let root = try makeDocumentImportTestRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    let library = try await LocalLibrary.open(at: root.appending(path: "Library"))
    let importer = DocumentImport(
        library: library,
        webAcquirer: ThrowingFixtureWebAcquirer()
    )
    let sourceURL = try #require(URL(string: "https://fixture.invalid/offline"))

    let handle = try await importer.submit(.webpage(sourceURL))
    let terminal = await handle.value()

    guard case .failure(let failure) = terminal else {
        Issue.record("Expected terminal task failure")
        return
    }
    #expect(failure.code == .networkUnavailable)
    #expect(failure.recovery == .retryable)
    #expect(try await library.importWorkspace(id: handle.id) == nil)
}
```

- [ ] **Step 2: Run the failure tests to verify RED**

Run:

```bash
swift test --filter invalidWebURLFailsBeforeDurableAcceptance
swift test --filter acquisitionFailureIsTerminalTaskDataAfterAcceptance
```

Expected: invalid URL may pass once validation exists; acquisition test FAIL until failure classification, best-effort abandon, waiter resumption, and failed snapshot completion are implemented.

- [ ] **Step 3: Implement typed failure classification and abandonment**

Add the production-owned acquisition error to `WebAcquisition.swift`:

```swift
enum WebAcquisitionError: Error {
    case networkUnavailable
}
```

Add a classifier with explicit cases:

```swift
private func classify(_ error: Error) -> ImportFailure {
    if error is WebAcquisitionError {
        return ImportFailure(code: .networkUnavailable, recovery: .retryable)
    }
    if let error = error as? StaticWebBuildError {
        switch error {
        case .missingArticle, .noReadableBlocks:
            return ImportFailure(
                code: .webpageHasNoReadableArticle,
                recovery: .unsupported
            )
        case .unreadableHTML, .cannotWritePackage:
            return ImportFailure(
                code: .artifactConstructionFailed,
                recovery: .retryable
            )
        }
    }
    if let error = error as? LocalLibraryError {
        switch error {
        case .publicationFailed:
            return ImportFailure(code: .publicationFailed, recovery: .retryable)
        default:
            return ImportFailure(
                code: .localLibraryUnavailable,
                recovery: .requiresUserAction
            )
        }
    }
    return ImportFailure(code: .networkUnavailable, recovery: .retryable)
}
```

Implement `failTask` so it:

1. reads the latest durable snapshot when possible;
2. attempts `workspace.abandon(expectedRevision:)`;
3. selects a public revision greater than the prior public revision;
4. stores `.failed(failure)` and `.failure(failure)`;
5. resumes every waiter;
6. finishes per-task streams;
7. notifies list observers.

- [ ] **Step 4: Run the failure and full DocumentImport tests**

Run:

```bash
swift test --filter invalidWebURLFailsBeforeDurableAcceptance
swift test --filter acquisitionFailureIsTerminalTaskDataAfterAcceptance
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 5: Commit the failure boundary**

```bash
git add Sources/DocumentImport Tests/DocumentImportTests
git commit -m "feat: classify document import task failures"
```

---

### Task 5: Map public task snapshots into Import Center presentation

**Files:**

- Modify: `Sources/AppSupport/ImportCenterPresentation.swift`
- Modify: `Tests/AppSupportTests/ImportCenterPresentationTests.swift`

- [ ] **Step 1: Write failing presentation-mapping tests**

Extend the test file to construct public snapshots and assert these mappings:

```swift
import AppSupport
import DocumentImport
import Foundation
import KnowledgeCore
import Testing

@Test(arguments: [
    TaskPresentationCase(
        state: .queued(position: 0),
        message: "Waiting to import",
        systemImage: "clock"
    ),
    TaskPresentationCase(
        state: .running(ImportProgress(
            activity: .acquiringOriginalSource,
            completedUnitCount: 0,
            totalUnitCount: nil
        )),
        message: "Acquiring webpage",
        systemImage: "arrow.down.doc"
    ),
    TaskPresentationCase(
        state: .running(ImportProgress(
            activity: .constructingSourceDocument,
            completedUnitCount: 0,
            totalUnitCount: nil
        )),
        message: "Building source document",
        systemImage: "doc.text"
    ),
    TaskPresentationCase(
        state: .running(ImportProgress(
            activity: .publishing,
            completedUnitCount: 0,
            totalUnitCount: nil
        )),
        message: "Publishing source document",
        systemImage: "tray.and.arrow.down"
    ),
    TaskPresentationCase(
        state: .failed(ImportFailure(
            code: .networkUnavailable,
            recovery: .retryable
        )),
        message: "Import failed",
        systemImage: "exclamationmark.triangle"
    ),
    TaskPresentationCase(
        state: .completed(.published(
            documentID: SourceDocumentID(),
            issues: []
        )),
        message: "Import completed",
        systemImage: "checkmark.circle"
    ),
])
func taskSnapshotMapsWithoutWorkflowKnowledge(
    testCase: TaskPresentationCase
) throws {
    let snapshot = ImportTaskSnapshot(
        id: ImportTaskID(),
        revision: 1,
        attempt: 1,
        source: .webpage(try #require(URL(string: "https://fixture.invalid/article"))),
        state: testCase.state
    )

    let presentation = ImportCenterPresentation.task(snapshot)

    #expect(presentation.title == "Import Center")
    #expect(presentation.message == testCase.message)
    #expect(presentation.systemImage == testCase.systemImage)
}

struct TaskPresentationCase: Sendable {
    let state: DocumentImport.ImportTaskState
    let message: String
    let systemImage: String
}
```

- [ ] **Step 2: Run the presentation test to verify RED**

Run:

```bash
swift test --filter taskSnapshotMapsWithoutWorkflowKnowledge
```

Expected: FAIL because the task presentation factory does not exist.

- [ ] **Step 3: Implement the pure presentation mapping**

Import DocumentImport in `Sources/AppSupport/ImportCenterPresentation.swift` and add:

```swift
public static func task(
    _ snapshot: ImportTaskSnapshot
) -> ImportCenterPresentation {
    switch snapshot.state {
    case .queued:
        ImportCenterPresentation(
            title: "Import Center",
            message: "Waiting to import",
            systemImage: "clock"
        )
    case .running(let progress):
        switch progress.activity {
        case .acquiringOriginalSource:
            ImportCenterPresentation(
                title: "Import Center",
                message: "Acquiring webpage",
                systemImage: "arrow.down.doc"
            )
        case .constructingSourceDocument:
            ImportCenterPresentation(
                title: "Import Center",
                message: "Building source document",
                systemImage: "doc.text"
            )
        case .publishing:
            ImportCenterPresentation(
                title: "Import Center",
                message: "Publishing source document",
                systemImage: "tray.and.arrow.down"
            )
        }
    case .failed:
        ImportCenterPresentation(
            title: "Import Center",
            message: "Import failed",
            systemImage: "exclamationmark.triangle"
        )
    case .completed(.published):
        ImportCenterPresentation(
            title: "Import Center",
            message: "Import completed",
            systemImage: "checkmark.circle"
        )
    case .completed(.alreadyImported):
        ImportCenterPresentation(
            title: "Import Center",
            message: "Already imported",
            systemImage: "checkmark.circle"
        )
    }
}
```

- [ ] **Step 4: Run AppSupport and package tests**

Run:

```bash
swift test --filter ImportCenterPresentationTests
swift test --filter AppSupportTests
swift test --filter DocumentImportTests
```

Expected: PASS.

- [ ] **Step 5: Commit the Import Center adapter**

```bash
git add Sources/AppSupport/ImportCenterPresentation.swift Tests/AppSupportTests/ImportCenterPresentationTests.swift
git commit -m "feat: present document import task progress"
```

---

### Task 6: Verify, review, and push the completed branch

**Files:**

- Review all T03-owned files created or modified by Tasks 1–5.
- Preserve the pre-existing dirty and untracked files.

- [ ] **Step 1: Run formatting and whitespace checks**

Run:

```bash
git diff --check origin/main...HEAD
```

Expected: no output and exit status 0.

- [ ] **Step 2: Run focused tests**

Run:

```bash
swift test --filter DocumentImportTests
swift test --filter AppSupportTests
swift test --filter LocalLibraryTests
```

Expected: all selected tests PASS.

- [ ] **Step 3: Run full debug and release verification**

Run:

```bash
swift test
swift test -c release
swift build -c release
```

Expected: all tests pass and the release package builds successfully.

- [ ] **Step 4: Build the macOS application shell**

Run:

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t03 \
  build
```

Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 5: Run the required code-review workflow**

Invoke `superpowers:requesting-code-review` through the project `/code-review` flow. Review the diff against:

- `docs/superpowers/specs/2026-08-06-t03-static-web-import-tracer-bullet-design.md`;
- Issue #4 acceptance criteria;
- module-boundary and no-public-network constraints.

Address every confirmed finding, rerun the narrow test covering each fix, then rerun `swift test`. Commit review fixes with a focused message such as:

```bash
git add <reviewed-t03-files>
git commit -m "fix: address static web import review"
```

If the review has no findings, do not create an empty commit.

- [ ] **Step 6: Confirm protected workspace state**

Run:

```bash
git status --short --branch
git diff --name-only origin/main...HEAD
```

Expected: the branch diff contains only committed T03 work and its committed design/plan documents. The user's pre-existing modified and untracked paths remain uncommitted.

- [ ] **Step 7: Push the feature branch**

Run:

```bash
git push -u origin feature/t03-static-web-tracer-bullet
```

Expected: the remote branch is created or updated successfully.

---

## Completion Criteria

- `submit(.webpage)` returns only after Local Library durable acceptance.
- Public task streams begin with current state and expose monotonic authoritative revisions.
- The deterministic fixture progresses through acquisition, construction, publication, and terminal success.
- The published Source Document contains the expected ordered blocks, exact structure coverage, and exact Web evidence coverage.
- Local Library owns and verifies a managed `.webPackage` artifact.
- No Source Document is visible before publication and the complete document is visible after success.
- Import Center presentation depends only on public task snapshots.
- Automated tests use an injected fixture adapter and perform no public network access.
- Debug, release, package, and macOS app verification pass.
- Required code review is complete and the branch is pushed.
