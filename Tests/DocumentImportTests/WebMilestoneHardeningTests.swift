import Foundation
import KnowledgeCore
import Testing

@testable import DocumentImport
import LocalLibrary

@Suite("Web milestone hardening")
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
}
