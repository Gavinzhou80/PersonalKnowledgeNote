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
        precondition(byteCount > 0)
        precondition(!contentHash.isEmpty)
        self.kind = kind
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}
