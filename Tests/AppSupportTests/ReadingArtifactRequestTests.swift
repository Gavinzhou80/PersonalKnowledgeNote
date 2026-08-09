import AppSupport
import Foundation
import KnowledgeCore
import Testing

@Test
func artifactRequestParsesDocumentIndexURL() throws {
    let documentID = SourceDocumentID()
    let url = try #require(URL(
        string: "pkn-reading://document/\(documentID.rawValue.uuidString)/index.html"
    ))

    let request = ReadingArtifactRequest.parse(url)

    #expect(request?.documentID == documentID)
    #expect(request?.relativePath == "index.html")
}

@Test
func artifactRequestParsesNestedAssetPaths() throws {
    let documentID = SourceDocumentID()
    let url = try #require(URL(
        string: "pkn-reading://document/\(documentID.rawValue.uuidString)/assets/deep/figure.png"
    ))

    let request = ReadingArtifactRequest.parse(url)

    #expect(request?.documentID == documentID)
    #expect(request?.relativePath == "assets/deep/figure.png")
}

@Test
func artifactRequestRejectsMalformedURLs() {
    let documentID = SourceDocumentID()
    let validPrefix = "pkn-reading://document/\(documentID.rawValue.uuidString)"
    let rejected: [URL?] = [
        URL(string: "https://document/\(documentID.rawValue.uuidString)/index.html"),
        URL(string: "pkn-reading://other/\(documentID.rawValue.uuidString)/index.html"),
        URL(string: "pkn-reading://document/not-a-uuid/index.html"),
        URL(string: "pkn-reading://document/\(documentID.rawValue.uuidString)"),
        URL(string: "\(validPrefix)/"),
        URL(string: "pkn-reading://document/"),
    ]
    for url in rejected {
        #expect(
            url.flatMap(ReadingArtifactRequest.parse) == nil,
            "Accepted malformed URL \(url?.absoluteString ?? "nil")"
        )
    }
}
