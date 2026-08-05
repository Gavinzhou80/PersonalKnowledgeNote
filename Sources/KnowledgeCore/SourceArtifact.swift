import Foundation

public enum SourceArtifactKind: String, Hashable, Codable, Sendable {
    case webPackage
    case pdf
}

public struct SourceArtifactDescriptor: Hashable, Codable, Sendable {
    public let kind: SourceArtifactKind
    public let byteCount: UInt64
    public let contentHash: String

    public init(
        kind: SourceArtifactKind,
        byteCount: UInt64,
        contentHash: String
    ) {
        precondition(
            (try? Self.validate(
                byteCount: byteCount,
                contentHash: contentHash
            )) != nil,
            "SourceArtifactDescriptor requires a positive byte count and non-empty content hash"
        )
        self.kind = kind
        self.byteCount = byteCount
        self.contentHash = contentHash
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(SourceArtifactKind.self, forKey: .kind)
        let byteCount = try container.decode(UInt64.self, forKey: .byteCount)
        let contentHash = try container.decode(String.self, forKey: .contentHash)

        do {
            try Self.validate(
                byteCount: byteCount,
                contentHash: contentHash
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceArtifactDescriptor requires a positive byte count and non-empty content hash",
                    underlyingError: error
                )
            )
        }

        self.kind = kind
        self.byteCount = byteCount
        self.contentHash = contentHash
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case byteCount
        case contentHash
    }

    private enum ValidationError: Error {
        case zeroByteCount
        case emptyContentHash
    }

    private static func validate(
        byteCount: UInt64,
        contentHash: String
    ) throws {
        guard byteCount > 0 else {
            throw ValidationError.zeroByteCount
        }
        guard !contentHash.isEmpty else {
            throw ValidationError.emptyContentHash
        }
    }
}
