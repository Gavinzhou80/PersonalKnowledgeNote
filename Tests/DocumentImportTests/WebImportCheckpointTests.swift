import CryptoKit
import Foundation
import KnowledgeCore
import LocalLibrary
import Testing

@testable import DocumentImport

@Suite(.serialized)
struct WebImportCheckpointTests {

    @Test
    func acquiredWebCheckpointRoundTripsResponseBytesAndCharset() throws {
        let page = AcquiredWebPage(
            sourceURL: URL(string: "https://example.test/start")!,
            finalURL: URL(string: "https://example.test/final")!,
            mimeType: "text/html",
            textEncodingName: "windows-1252",
            bytes: Data([0x93, 0x48, 0x69, 0x94])
        )
        let package = try WebImportCheckpointCodec.writeAcquired(page)
        defer { try? FileManager.default.removeItem(at: package.url) }

        #expect(try WebImportCheckpointCodec.readAcquired(at: package.url) == page)
        #expect(package.descriptor.byteCount > 0)
        #expect(package.descriptor.contentHash.count == 64)
    }

    @Test
    func preparedWebCheckpointRoundTripsDeterministicPublicationGraph() throws {
        let prepared = makePreparedWebPublication()
        let package = try WebImportCheckpointCodec.writePrepared(prepared)
        defer { try? FileManager.default.removeItem(at: package.url) }

        #expect(try WebImportCheckpointCodec.readPrepared(at: package.url) == prepared)
    }

    @Test
    func checkpointPackagesUseExactRootLayoutsAndDeterministicMetadata() throws {
        let page = AcquiredWebPage(
            sourceURL: URL(string: "https://example.test/start")!,
            finalURL: URL(string: "https://example.test/final")!,
            mimeType: "text/html",
            textEncodingName: nil,
            bytes: Data("<html></html>".utf8)
        )
        let first = try WebImportCheckpointCodec.writeAcquired(page)
        let second = try WebImportCheckpointCodec.writeAcquired(page)
        let prepared = try WebImportCheckpointCodec.writePrepared(
            makePreparedWebPublication()
        )
        let secondPrepared = try WebImportCheckpointCodec.writePrepared(
            makePreparedWebPublication()
        )
        defer {
            for url in [first.url, second.url, prepared.url, secondPrepared.url] {
                try? FileManager.default.removeItem(at: url)
            }
        }

        #expect(try packageEntryNames(first.url) == ["metadata.json", "response.bin"])
        #expect(try packageEntryNames(prepared.url) == ["candidate.json", "metadata.json"])
        let firstMetadata = try Data(contentsOf: first.url.appending(path: "metadata.json"))
        let secondMetadata = try Data(contentsOf: second.url.appending(path: "metadata.json"))
        #expect(firstMetadata == secondMetadata)
        let object = try #require(
            JSONSerialization.jsonObject(with: firstMetadata) as? [String: Any]
        )
        #expect(
            Set(object.keys) == [
                "codecVersion", "domain", "finalURL", "kind", "mimeType",
                "payloadByteCount", "payloadFilename", "payloadSHA256",
                "sourceURL", "textEncodingName",
            ])
        #expect(object["codecVersion"] as? Int == 1)
        #expect(object["domain"] as? String == "document-import.web")
        #expect(object["kind"] as? String == "acquired")
        #expect(object["payloadFilename"] as? String == "response.bin")
        #expect(
            try Data(contentsOf: prepared.url.appending(path: "candidate.json"))
                == Data(contentsOf: secondPrepared.url.appending(path: "candidate.json"))
        )
        #expect(
            try Data(contentsOf: prepared.url.appending(path: "metadata.json"))
                == Data(contentsOf: secondPrepared.url.appending(path: "metadata.json"))
        )
    }

    @Test
    func runtimeReadersConsumeVerifiedCheckpointPackages() throws {
        let acquired = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
        let prepared = try WebImportCheckpointCodec.writePrepared(
            makePreparedWebPublication()
        )
        defer {
            try? FileManager.default.removeItem(at: acquired.url)
            try? FileManager.default.removeItem(at: prepared.url)
        }

        #expect(
            try WebImportCheckpointCodec.readAcquired(
                LocalLibrary.loadUnmanagedCheckpointPackage(at: acquired.url)
            ) == makeAcquiredPage())
        #expect(
            try WebImportCheckpointCodec.readPrepared(
                LocalLibrary.loadUnmanagedCheckpointPackage(at: prepared.url)
            ) == makePreparedWebPublication())
    }

    @Test(arguments: [
        "metadata.json",
        "response.bin",
    ])
    func acquiredReaderRejectsMissingRequiredFiles(filename: String) throws {
        let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
        defer { try? FileManager.default.removeItem(at: package.url) }
        try FileManager.default.removeItem(at: package.url.appending(path: filename))

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.readAcquired(at: package.url)
        }
    }

    @Test
    func acquiredReaderRejectsExtraFilesDirectoriesAndSymlinks() throws {
        for entry in ["extra-file", "extra-directory", "symlink"] {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            let url = package.url.appending(path: entry)
            switch entry {
            case "extra-file":
                try Data().write(to: url)
            case "extra-directory":
                try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
            default:
                try FileManager.default.createSymbolicLink(
                    at: url,
                    withDestinationURL: package.url.appending(path: "response.bin")
                )
            }

            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
    }

    @Test
    func acquiredReaderRejectsNoncanonicalEntryNames() throws {
        let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
        defer { try? FileManager.default.removeItem(at: package.url) }
        let decomposed = "e\u{301}.txt"
        try Data().write(to: package.url.appending(path: decomposed))

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.readAcquired(at: package.url)
        }
    }

    enum UnsupportedMetadataMutation: Sendable {
        case string(key: String, value: String)
        case integer(key: String, value: Int)
    }

    @Test(arguments: [
        UnsupportedMetadataMutation.string(key: "domain", value: "other.domain"),
        .string(key: "kind", value: "future"),
        .integer(key: "codecVersion", value: 2),
        .string(key: "payloadFilename", value: "../response.bin"),
    ])
    func acquiredReaderRejectsUnsupportedMetadataValues(
        mutation: UnsupportedMetadataMutation
    ) throws {
        let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
        defer { try? FileManager.default.removeItem(at: package.url) }
        try mutateMetadata(at: package.url) { metadata in
            switch mutation {
            case .string(let key, let value):
                metadata[key] = value
            case .integer(let key, let value):
                metadata[key] = value
            }
        }

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.readAcquired(at: package.url)
        }
    }

    @Test
    func acquiredReaderRejectsUnknownMetadataFieldsCorruptJSONAndOversizedMetadata() throws {
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            try mutateMetadata(at: package.url) { $0["unknown"] = true }
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            try Data("{".utf8).write(to: package.url.appending(path: "metadata.json"))
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            try Data(repeating: 0x20, count: 65_537).write(
                to: package.url.appending(path: "metadata.json")
            )
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
    }

    @Test
    func readersRejectDuplicateJSONFields() throws {
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            let metadataURL = package.url.appending(path: "metadata.json")
            let metadata = try String(
                contentsOf: metadataURL,
                encoding: .utf8
            ).replacingOccurrences(
                of: "\"domain\":\"document-import.web\"",
                with: "\"domain\":\"document-import.web\",\"domain\":\"document-import.web\""
            )
            try Data(metadata.utf8).write(to: metadataURL)

            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
        do {
            let package = try WebImportCheckpointCodec.writePrepared(
                makePreparedWebPublication()
            )
            defer { try? FileManager.default.removeItem(at: package.url) }
            let candidateURL = package.url.appending(path: "candidate.json")
            let candidate = try String(
                contentsOf: candidateURL,
                encoding: .utf8
            ).replacingOccurrences(
                of: "\"stagedArtifactID\":\"33333333-3333-3333-3333-333333333333\"",
                with:
                    "\"stagedArtifactID\":\"33333333-3333-3333-3333-333333333333\",\"stagedArtifactID\":\"33333333-3333-3333-3333-333333333333\""
            )
            let payload = Data(candidate.utf8)
            try payload.write(to: candidateURL)
            try mutateMetadata(at: package.url) { metadata in
                metadata["payloadByteCount"] = payload.count
                metadata["payloadSHA256"] = SHA256.hash(data: payload)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }

            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readPrepared(at: package.url)
            }
        }
    }

    @Test
    func acquiredReaderVerifiesPayloadHashAndByteCountBeforeReturningBytes() throws {
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            try Data("tampered".utf8).write(to: package.url.appending(path: "response.bin"))
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
        do {
            let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
            defer { try? FileManager.default.removeItem(at: package.url) }
            try mutateMetadata(at: package.url) { metadata in
                metadata["payloadByteCount"] = 999
            }
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readAcquired(at: package.url)
            }
        }
    }

    @Test(arguments: ["sourceURL", "finalURL", "mimeType", "textEncodingName"])
    func acquiredReaderRejectsInvalidPersistedDomainValues(key: String) throws {
        let package = try WebImportCheckpointCodec.writeAcquired(makeAcquiredPage())
        defer { try? FileManager.default.removeItem(at: package.url) }
        try mutateMetadata(at: package.url) { metadata in
            switch key {
            case "sourceURL":
                metadata[key] = "file:///tmp/source"
            case "finalURL":
                metadata[key] = "javascript:alert(1)"
            case "mimeType":
                metadata[key] = "text/plain"
            default:
                metadata[key] = "UTF-8"
            }
        }

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.readAcquired(at: package.url)
        }
    }

    @Test(arguments: [
        AcquiredWebPage(
            sourceURL: URL(fileURLWithPath: "/tmp/source"),
            finalURL: URL(string: "https://example.test/final")!,
            mimeType: "text/html",
            textEncodingName: nil,
            bytes: Data("x".utf8)
        ),
        AcquiredWebPage(
            sourceURL: URL(string: "https://example.test/source")!,
            finalURL: URL(string: "https://example.test/final")!,
            mimeType: "text/plain",
            textEncodingName: nil,
            bytes: Data("x".utf8)
        ),
    ])
    func acquiredWriterRejectsInvalidDomainValues(page: AcquiredWebPage) {
        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.writeAcquired(page)
        }
    }

    @Test
    func acquiredWriterRejectsOversizedPayloadAndCleansTemporaryPackage() throws {
        let before = try checkpointTemporaryPackageNames()
        let oversized = AcquiredWebPage(
            sourceURL: URL(string: "https://example.test/source")!,
            finalURL: URL(string: "https://example.test/final")!,
            mimeType: "text/html",
            textEncodingName: nil,
            bytes: Data(repeating: 0x61, count: 8 * 1_024 * 1_024 + 1)
        )

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.writeAcquired(oversized)
        }
        #expect(try checkpointTemporaryPackageNames() == before)
    }

    @Test
    func preparedReaderRejectsNonWebSourceAndNonWebArtifactDescriptor() throws {
        for mutation in ["source", "descriptor"] {
            let package = try WebImportCheckpointCodec.writePrepared(
                makePreparedWebPublication()
            )
            defer { try? FileManager.default.removeItem(at: package.url) }
            try replaceCandidate(in: package.url) { candidate in
                if mutation == "source" {
                    candidate["originalSource"] = [
                        "pdfFile": ["_0": "file:///tmp/source.pdf"]
                    ]
                } else {
                    var descriptor = try #require(
                        candidate["stagedDescriptor"] as? [String: Any]
                    )
                    descriptor["kind"] = "pdf"
                    candidate["stagedDescriptor"] = descriptor
                }
            }

            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readPrepared(at: package.url)
            }
        }
    }

    @Test(arguments: [
        "unknown", "mismatched-document", "invalid-artifact-id",
        "invalid-artifact-byte-count",
    ])
    func preparedReaderRejectsInvalidCandidateValues(mutation: String) throws {
        let package = try WebImportCheckpointCodec.writePrepared(
            makePreparedWebPublication()
        )
        defer { try? FileManager.default.removeItem(at: package.url) }
        try replaceCandidate(in: package.url) { candidate in
            switch mutation {
            case "unknown":
                candidate["unknown"] = true
            case "mismatched-document":
                candidate["documentID"] = [
                    "rawValue": "44444444-4444-4444-4444-444444444444"
                ]
            case "invalid-artifact-id":
                candidate["stagedArtifactID"] = "not-a-uuid"
            default:
                var descriptor = try #require(
                    candidate["stagedDescriptor"] as? [String: Any]
                )
                descriptor["byteCount"] = 0
                candidate["stagedDescriptor"] = descriptor
            }
        }

        #expect(throws: WebImportCheckpointError.self) {
            try WebImportCheckpointCodec.readPrepared(at: package.url)
        }
    }

    @Test
    func preparedReaderRejectsCorruptAndOversizedCandidatePayloads() throws {
        do {
            let package = try WebImportCheckpointCodec.writePrepared(
                makePreparedWebPublication()
            )
            defer { try? FileManager.default.removeItem(at: package.url) }
            let payload = Data("{".utf8)
            try payload.write(to: package.url.appending(path: "candidate.json"))
            try mutateMetadata(at: package.url) { metadata in
                metadata["payloadByteCount"] = payload.count
                metadata["payloadSHA256"] = SHA256.hash(data: payload)
                    .map { String(format: "%02x", $0) }
                    .joined()
            }
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readPrepared(at: package.url)
            }
        }
        do {
            let package = FileManager.default.temporaryDirectory.appending(
                path: "OversizedWebCheckpoint-\(UUID().uuidString)"
            )
            try FileManager.default.createDirectory(
                at: package,
                withIntermediateDirectories: false
            )
            defer { try? FileManager.default.removeItem(at: package) }
            try Data(repeating: 0x20, count: 8 * 1_024 * 1_024 + 1).write(
                to: package.appending(path: "candidate.json")
            )
            try Data(#"{"codecVersion":1}"#.utf8).write(
                to: package.appending(path: "metadata.json")
            )
            #expect(throws: WebImportCheckpointError.self) {
                try WebImportCheckpointCodec.readPrepared(at: package)
            }
        }
    }

}

private func makeAcquiredPage() -> AcquiredWebPage {
    AcquiredWebPage(
        sourceURL: URL(string: "https://example.test/start")!,
        finalURL: URL(string: "https://example.test/final")!,
        mimeType: "text/html",
        textEncodingName: "utf-8",
        bytes: Data("<html><article>Body</article></html>".utf8)
    )
}

private func makePreparedWebPublication() -> PreparedWebPublication {
    let documentID = SourceDocumentID(
        UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    )
    let blockID = SourceBlockID(
        UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    )
    let issue = KnowledgeCore.ImportIssue(
        code: .optionalWebImageUnavailable,
        relatedBlockID: blockID
    )
    return PreparedWebPublication(
        documentID: documentID,
        fingerprint: ContentFingerprint("sha256:fixture"),
        document: SourceDocumentContent(
            documentID: documentID,
            importedMetadata: ImportedDocumentMetadata(
                title: "Deterministic fixture",
                author: "Ada",
                publishedAt: Date(
                    timeIntervalSince1970: 1_700_000_000.123_456
                )
            ),
            blocks: [
                SourceBlock(
                    id: blockID,
                    canonicalText: "Fixture body",
                    role: .paragraph
                )
            ],
            structure: SourceStructure(orderedBlockIDs: [blockID]),
            evidence: [blockID: .web(locator: "#fixture")],
            issues: [issue]
        ),
        originalSource: .webpage(
            URL(string: "https://example.test/source")!
        ),
        stagedArtifactID: UUID(
            uuidString: "33333333-3333-3333-3333-333333333333"
        )!,
        stagedDescriptor: SourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: 42,
            contentHash: String(repeating: "a", count: 64)
        ),
        issues: [issue]
    )
}

private func packageEntryNames(_ url: URL) throws -> [String] {
    try FileManager.default.contentsOfDirectory(atPath: url.path).sorted()
}

private func mutateMetadata(
    at packageURL: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    let url = packageURL.appending(path: "metadata.json")
    var object = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: url))
            as? [String: Any]
    )
    try mutation(&object)
    try JSONSerialization.data(
        withJSONObject: object,
        options: [.sortedKeys]
    ).write(to: url)
}

private func replaceCandidate(
    in packageURL: URL,
    _ mutation: (inout [String: Any]) throws -> Void
) throws {
    let candidateURL = packageURL.appending(path: "candidate.json")
    var candidate = try #require(
        JSONSerialization.jsonObject(with: Data(contentsOf: candidateURL))
            as? [String: Any]
    )
    try mutation(&candidate)
    let payload = try JSONSerialization.data(
        withJSONObject: candidate,
        options: [.sortedKeys]
    )
    try payload.write(to: candidateURL)
    try mutateMetadata(at: packageURL) { metadata in
        metadata["payloadByteCount"] = payload.count
        metadata["payloadSHA256"] = SHA256.hash(data: payload)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}

private func checkpointTemporaryPackageNames() throws -> Set<String> {
    Set(
        try FileManager.default.contentsOfDirectory(
            atPath: FileManager.default.temporaryDirectory.path
        ).filter { $0.hasPrefix("WebImportCheckpoint-") })
}
