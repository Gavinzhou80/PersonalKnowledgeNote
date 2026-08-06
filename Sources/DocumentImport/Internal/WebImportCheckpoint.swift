import CryptoKit
import Darwin
import Foundation
import KnowledgeCore
import LocalLibrary

enum WebImportCheckpointError: Error, Equatable, Sendable {
    case invalidPackage
    case cannotWrite
}

struct EncodedWebCheckpointPackage: Sendable {
    let url: URL
    let descriptor: CheckpointArtifactDescriptor
}

struct PreparedWebPublication: Codable, Hashable, Sendable {
    let documentID: SourceDocumentID
    let fingerprint: ContentFingerprint
    let document: SourceDocumentContent
    let originalSource: OriginalSource
    let stagedArtifactID: UUID
    let stagedDescriptor: SourceArtifactDescriptor
    let issues: [KnowledgeCore.ImportIssue]
}

enum WebImportCheckpointMetadata: Codable, Sendable {
    struct AcquiredMetadata: Sendable {
        let payloadByteCount: Int
        let payloadSHA256: String
        let sourceURL: String
        let finalURL: String
        let mimeType: String
        let textEncodingName: String?
    }

    struct PreparedMetadata: Sendable {
        let payloadByteCount: Int
        let payloadSHA256: String
    }

    case acquired(AcquiredMetadata)
    case prepared(PreparedMetadata)

    private enum Constants {
        static let domain = "document-import.web"
        static let codecVersion = 1
        static let acquiredPayload = "response.bin"
        static let preparedPayload = "candidate.json"
    }

    private struct Key: CodingKey, Hashable {
        let stringValue: String
        let intValue: Int? = nil

        init?(stringValue: String) {
            self.stringValue = stringValue
        }

        init?(intValue: Int) {
            return nil
        }

        static func named(_ value: String) -> Key {
            Key(stringValue: value)!
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: Key.self)
        let domain = try container.decode(
            String.self,
            forKey: .named("domain")
        )
        let kind = try container.decode(
            String.self,
            forKey: .named("kind")
        )
        let codecVersion = try container.decode(
            Int.self,
            forKey: .named("codecVersion")
        )
        guard domain == Constants.domain,
            codecVersion == Constants.codecVersion
        else {
            throw WebImportCheckpointError.invalidPackage
        }

        let commonKeys: Set<String> = [
            "codecVersion", "domain", "kind", "payloadByteCount",
            "payloadFilename", "payloadSHA256",
        ]
        let payloadByteCount = try container.decode(
            Int.self,
            forKey: .named("payloadByteCount")
        )
        let payloadFilename = try container.decode(
            String.self,
            forKey: .named("payloadFilename")
        )
        let payloadSHA256 = try container.decode(
            String.self,
            forKey: .named("payloadSHA256")
        )

        switch kind {
        case "acquired":
            let expectedKeys = commonKeys.union([
                "sourceURL", "finalURL", "mimeType", "textEncodingName",
            ])
            guard Set(container.allKeys.map(\.stringValue)) == expectedKeys,
                payloadFilename == Constants.acquiredPayload
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            self = .acquired(
                AcquiredMetadata(
                    payloadByteCount: payloadByteCount,
                    payloadSHA256: payloadSHA256,
                    sourceURL: try container.decode(
                        String.self,
                        forKey: .named("sourceURL")
                    ),
                    finalURL: try container.decode(
                        String.self,
                        forKey: .named("finalURL")
                    ),
                    mimeType: try container.decode(
                        String.self,
                        forKey: .named("mimeType")
                    ),
                    textEncodingName: try container.decodeIfPresent(
                        String.self,
                        forKey: .named("textEncodingName")
                    )
                ))
        case "prepared":
            guard Set(container.allKeys.map(\.stringValue)) == commonKeys,
                payloadFilename == Constants.preparedPayload
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            self = .prepared(
                PreparedMetadata(
                    payloadByteCount: payloadByteCount,
                    payloadSHA256: payloadSHA256
                ))
        default:
            throw WebImportCheckpointError.invalidPackage
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        try container.encode(Constants.domain, forKey: .named("domain"))
        try container.encode(
            Constants.codecVersion,
            forKey: .named("codecVersion")
        )
        switch self {
        case .acquired(let metadata):
            try container.encode("acquired", forKey: .named("kind"))
            try container.encode(
                Constants.acquiredPayload,
                forKey: .named("payloadFilename")
            )
            try container.encode(
                metadata.payloadByteCount,
                forKey: .named("payloadByteCount")
            )
            try container.encode(
                metadata.payloadSHA256,
                forKey: .named("payloadSHA256")
            )
            try container.encode(
                metadata.sourceURL,
                forKey: .named("sourceURL")
            )
            try container.encode(
                metadata.finalURL,
                forKey: .named("finalURL")
            )
            try container.encode(
                metadata.mimeType,
                forKey: .named("mimeType")
            )
            if let charset = metadata.textEncodingName {
                try container.encode(
                    charset,
                    forKey: .named("textEncodingName")
                )
            } else {
                try container.encodeNil(forKey: .named("textEncodingName"))
            }
        case .prepared(let metadata):
            try container.encode("prepared", forKey: .named("kind"))
            try container.encode(
                Constants.preparedPayload,
                forKey: .named("payloadFilename")
            )
            try container.encode(
                metadata.payloadByteCount,
                forKey: .named("payloadByteCount")
            )
            try container.encode(
                metadata.payloadSHA256,
                forKey: .named("payloadSHA256")
            )
        }
    }
}

enum WebImportCheckpointCodec {
    private static let metadataFilename = "metadata.json"
    private static let acquiredPayloadFilename = "response.bin"
    private static let preparedPayloadFilename = "candidate.json"
    private static let maximumPayloadByteCount = 8 * 1_024 * 1_024
    private static let maximumMetadataByteCount = 64 * 1_024
    private static let maximumURLByteCount = 8 * 1_024
    private static let maximumMIMETypeByteCount = 128
    private static let maximumCharsetByteCount = 128

    static func writeAcquired(
        _ page: AcquiredWebPage
    ) throws -> EncodedWebCheckpointPackage {
        do {
            try validate(page)
            guard page.bytes.count <= maximumPayloadByteCount else {
                throw WebImportCheckpointError.invalidPackage
            }
            let metadata = WebImportCheckpointMetadata.acquired(
                .init(
                    payloadByteCount: page.bytes.count,
                    payloadSHA256: hash(page.bytes),
                    sourceURL: page.sourceURL.absoluteString,
                    finalURL: page.finalURL.absoluteString,
                    mimeType: page.mimeType,
                    textEncodingName: page.textEncodingName
                ))
            return try writePackage(
                payload: page.bytes,
                payloadFilename: acquiredPayloadFilename,
                metadata: metadata
            )
        } catch let error as WebImportCheckpointError {
            throw error
        } catch {
            throw WebImportCheckpointError.cannotWrite
        }
    }

    static func writePrepared(
        _ prepared: PreparedWebPublication
    ) throws -> EncodedWebCheckpointPackage {
        do {
            try validate(prepared)
            let payload = try jsonEncoder().encode(prepared)
            guard payload.count <= maximumPayloadByteCount else {
                throw WebImportCheckpointError.invalidPackage
            }
            let metadata = WebImportCheckpointMetadata.prepared(
                .init(
                    payloadByteCount: payload.count,
                    payloadSHA256: hash(payload)
                ))
            return try writePackage(
                payload: payload,
                payloadFilename: preparedPayloadFilename,
                metadata: metadata
            )
        } catch let error as WebImportCheckpointError {
            throw error
        } catch {
            throw WebImportCheckpointError.cannotWrite
        }
    }

    static func readAcquired(
        _ package: VerifiedCheckpointPackage
    ) throws -> AcquiredWebPage {
        do {
            guard package.directories.isEmpty,
                Set(package.files.keys) == [
                    metadataFilename, acquiredPayloadFilename,
                ], let metadataData = package.files[metadataFilename],
                let payload = package.files[acquiredPayloadFilename]
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            let metadata = try decodeMetadata(metadataData)
            guard case .acquired(let acquired) = metadata else {
                throw WebImportCheckpointError.invalidPackage
            }
            try validatePayload(
                payload,
                byteCount: acquired.payloadByteCount,
                sha256: acquired.payloadSHA256
            )
            guard let sourceURL = URL(string: acquired.sourceURL),
                let finalURL = URL(string: acquired.finalURL)
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            let page = AcquiredWebPage(
                sourceURL: sourceURL,
                finalURL: finalURL,
                mimeType: acquired.mimeType,
                textEncodingName: acquired.textEncodingName,
                bytes: payload
            )
            try validate(page)
            guard page.sourceURL.absoluteString == acquired.sourceURL,
                page.finalURL.absoluteString == acquired.finalURL,
                page.textEncodingName == acquired.textEncodingName
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            return page
        } catch let error as WebImportCheckpointError {
            throw error
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    static func readPrepared(
        _ package: VerifiedCheckpointPackage
    ) throws -> PreparedWebPublication {
        do {
            guard package.directories.isEmpty,
                Set(package.files.keys) == [
                    metadataFilename, preparedPayloadFilename,
                ], let metadataData = package.files[metadataFilename],
                let payload = package.files[preparedPayloadFilename]
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            let metadata = try decodeMetadata(metadataData)
            guard case .prepared(let preparedMetadata) = metadata else {
                throw WebImportCheckpointError.invalidPackage
            }
            try validatePayload(
                payload,
                byteCount: preparedMetadata.payloadByteCount,
                sha256: preparedMetadata.payloadSHA256
            )
            try validatePreparedTopLevelKeys(payload)
            let prepared = try jsonDecoder().decode(
                PreparedWebPublication.self,
                from: payload
            )
            try validate(prepared)
            return prepared
        } catch let error as WebImportCheckpointError {
            throw error
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    static func readAcquired(at url: URL) throws -> AcquiredWebPage {
        do {
            return try readAcquired(
                LocalLibrary.loadUnmanagedCheckpointPackage(at: url)
            )
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    static func readPrepared(at url: URL) throws -> PreparedWebPublication {
        do {
            return try readPrepared(
                LocalLibrary.loadUnmanagedCheckpointPackage(at: url)
            )
        } catch {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func writePackage(
        payload: Data,
        payloadFilename: String,
        metadata: WebImportCheckpointMetadata
    ) throws -> EncodedWebCheckpointPackage {
        let packageURL = FileManager.default.temporaryDirectory.appending(
            path: "WebImportCheckpoint-\(UUID().uuidString)"
        )
        do {
            try FileManager.default.createDirectory(
                at: packageURL,
                withIntermediateDirectories: false
            )
            let metadataData = try jsonEncoder().encode(metadata)
            guard metadataData.count <= maximumMetadataByteCount else {
                throw WebImportCheckpointError.invalidPackage
            }
            let payloadURL = packageURL.appending(path: payloadFilename)
            let metadataURL = packageURL.appending(path: metadataFilename)
            try payload.write(to: payloadURL, options: [.atomic])
            try metadataData.write(to: metadataURL, options: [.atomic])
            try synchronizeFile(payloadURL)
            try synchronizeFile(metadataURL)
            try synchronizeDirectory(packageURL)
            let verified = try LocalLibrary.loadUnmanagedCheckpointPackage(
                at: packageURL
            )
            return EncodedWebCheckpointPackage(
                url: packageURL,
                descriptor: verified.descriptor
            )
        } catch {
            try? FileManager.default.removeItem(at: packageURL)
            throw error
        }
    }

    private static func decodeMetadata(
        _ data: Data
    ) throws -> WebImportCheckpointMetadata {
        guard data.count <= maximumMetadataByteCount else {
            throw WebImportCheckpointError.invalidPackage
        }
        try StrictJSONValidator.validate(data)
        return try jsonDecoder().decode(
            WebImportCheckpointMetadata.self,
            from: data
        )
    }

    private static func validatePayload(
        _ payload: Data,
        byteCount: Int,
        sha256: String
    ) throws {
        guard payload.count <= maximumPayloadByteCount,
            byteCount >= 0,
            byteCount <= maximumPayloadByteCount,
            payload.count == byteCount,
            isLowercaseSHA256(sha256),
            hash(payload) == sha256
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func validate(_ page: AcquiredWebPage) throws {
        try validateHTTPURL(page.sourceURL)
        try validateHTTPURL(page.finalURL)
        guard page.mimeType == page.mimeType.lowercased(),
            ["text/html", "application/xhtml+xml"].contains(page.mimeType),
            page.mimeType.utf8.count <= maximumMIMETypeByteCount,
            page.mimeType.utf8.allSatisfy({ $0 < 0x80 })
        else {
            throw WebImportCheckpointError.invalidPackage
        }
        if let charset = page.textEncodingName {
            guard charset == normalizedWebCharsetName(charset),
                charset.utf8.count <= maximumCharsetByteCount
            else {
                throw WebImportCheckpointError.invalidPackage
            }
        }
    }

    private static func validate(_ prepared: PreparedWebPublication) throws {
        guard prepared.documentID == prepared.document.documentID,
            prepared.stagedDescriptor.kind == .webPackage,
            prepared.issues == prepared.document.issues
        else {
            throw WebImportCheckpointError.invalidPackage
        }
        guard case .webpage(let sourceURL) = prepared.originalSource else {
            throw WebImportCheckpointError.invalidPackage
        }
        try validateHTTPURL(sourceURL)
    }

    private static func validateHTTPURL(_ url: URL) throws {
        guard let scheme = url.scheme?.lowercased(),
            scheme == "http" || scheme == "https",
            let host = url.host,
            !host.isEmpty,
            url.absoluteString.utf8.count <= maximumURLByteCount
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func validatePreparedTopLevelKeys(_ data: Data) throws {
        try StrictJSONValidator.validate(data)
        guard
            let object = try JSONSerialization.jsonObject(with: data)
                as? [String: Any],
            Set(object.keys) == [
                "documentID", "fingerprint", "document", "originalSource",
                "stagedArtifactID", "stagedDescriptor", "issues",
            ]
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func jsonEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .millisecondsSince1970
        return encoder
    }

    private static func jsonDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .millisecondsSince1970
        return decoder
    }

    private static func hash(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }

    private static func isLowercaseSHA256(_ value: String) -> Bool {
        value.utf8.count == 64
            && value.utf8.allSatisfy { byte in
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
            }
    }

    private static func synchronizeFile(_ url: URL) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private static func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw WebImportCheckpointError.cannotWrite
        }
        defer { _ = close(descriptor) }
        guard fsync(descriptor) == 0 else {
            throw WebImportCheckpointError.cannotWrite
        }
    }
}

private enum StrictJSONValidator {
    static func validate(_ data: Data) throws {
        var parser = Parser(bytes: Array(data))
        try parser.parseValue()
        parser.skipWhitespace()
        guard parser.isAtEnd else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private struct Parser {
        let bytes: [UInt8]
        var index = 0

        var isAtEnd: Bool { index == bytes.count }

        mutating func parseValue() throws {
            skipWhitespace()
            guard let byte = current else {
                throw WebImportCheckpointError.invalidPackage
            }
            switch byte {
            case UInt8(ascii: "{"):
                try parseObject()
            case UInt8(ascii: "["):
                try parseArray()
            case UInt8(ascii: "\""):
                _ = try parseString()
            case UInt8(ascii: "t"):
                try consume("true")
            case UInt8(ascii: "f"):
                try consume("false")
            case UInt8(ascii: "n"):
                try consume("null")
            case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"):
                try parseNumber()
            default:
                throw WebImportCheckpointError.invalidPackage
            }
        }

        mutating func skipWhitespace() {
            while let byte = current,
                byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
            {
                index += 1
            }
        }

        private var current: UInt8? {
            index < bytes.count ? bytes[index] : nil
        }

        private mutating func parseObject() throws {
            try expect(UInt8(ascii: "{"))
            skipWhitespace()
            if current == UInt8(ascii: "}") {
                index += 1
                return
            }
            var keys: Set<String> = []
            while true {
                skipWhitespace()
                let keyData = try parseString()
                let key = try JSONDecoder().decode(String.self, from: keyData)
                guard keys.insert(key).inserted else {
                    throw WebImportCheckpointError.invalidPackage
                }
                skipWhitespace()
                try expect(UInt8(ascii: ":"))
                try parseValue()
                skipWhitespace()
                if current == UInt8(ascii: "}") {
                    index += 1
                    return
                }
                try expect(UInt8(ascii: ","))
            }
        }

        private mutating func parseArray() throws {
            try expect(UInt8(ascii: "["))
            skipWhitespace()
            if current == UInt8(ascii: "]") {
                index += 1
                return
            }
            while true {
                try parseValue()
                skipWhitespace()
                if current == UInt8(ascii: "]") {
                    index += 1
                    return
                }
                try expect(UInt8(ascii: ","))
            }
        }

        private mutating func parseString() throws -> Data {
            let start = index
            try expect(UInt8(ascii: "\""))
            while let byte = current {
                if byte == UInt8(ascii: "\"") {
                    index += 1
                    return Data(bytes[start..<index])
                }
                guard byte >= 0x20 else {
                    throw WebImportCheckpointError.invalidPackage
                }
                index += 1
                guard byte == UInt8(ascii: "\\") else {
                    continue
                }
                guard let escape = current,
                    [
                        UInt8(ascii: "\""), UInt8(ascii: "\\"),
                        UInt8(ascii: "/"), UInt8(ascii: "b"),
                        UInt8(ascii: "f"), UInt8(ascii: "n"),
                        UInt8(ascii: "r"), UInt8(ascii: "t"),
                        UInt8(ascii: "u"),
                    ].contains(escape)
                else {
                    throw WebImportCheckpointError.invalidPackage
                }
                index += 1
                if escape == UInt8(ascii: "u") {
                    guard index + 4 <= bytes.count,
                        bytes[index..<(index + 4)].allSatisfy(isHexDigit)
                    else {
                        throw WebImportCheckpointError.invalidPackage
                    }
                    index += 4
                }
            }
            throw WebImportCheckpointError.invalidPackage
        }

        private mutating func parseNumber() throws {
            let start = index
            while let byte = current,
                (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                    || [
                        UInt8(ascii: "-"), UInt8(ascii: "+"),
                        UInt8(ascii: "."), UInt8(ascii: "e"),
                        UInt8(ascii: "E"),
                    ].contains(byte)
            {
                index += 1
            }
            guard index > start else {
                throw WebImportCheckpointError.invalidPackage
            }
        }

        private mutating func consume(_ literal: StaticString) throws {
            let expected = Array(String(describing: literal).utf8)
            guard index + expected.count <= bytes.count,
                Array(bytes[index..<(index + expected.count)]) == expected
            else {
                throw WebImportCheckpointError.invalidPackage
            }
            index += expected.count
        }

        private mutating func expect(_ byte: UInt8) throws {
            guard current == byte else {
                throw WebImportCheckpointError.invalidPackage
            }
            index += 1
        }

        private func isHexDigit(_ byte: UInt8) -> Bool {
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }
}
