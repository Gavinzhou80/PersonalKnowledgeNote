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
        var identity = Data()
        append(ruleVersion, to: &identity)
        append(role, to: &identity)
        append(String(ordinal), to: &identity)
        append(text, to: &identity)

        let bytes = Array(SHA256.hash(data: identity).prefix(16))
        let uuid = UUID(uuid: (
            bytes[0], bytes[1], bytes[2], bytes[3],
            bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11],
            bytes[12], bytes[13], bytes[14], bytes[15]
        ))
        return SourceBlockID(uuid)
    }

    static func fingerprint(
        blocks: [(role: String, text: String)]
    ) -> ContentFingerprint {
        var identity = Data()
        append(ruleVersion, to: &identity)
        for block in blocks {
            append(block.role, to: &identity)
            append(block.text, to: &identity)
        }
        return ContentFingerprint(sha256Hex(identity))
    }

    static func packageDescriptor(
        relativePath: String,
        contents: Data
    ) -> SourceArtifactDescriptor {
        let path = Data(relativePath.utf8)
        var manifest = Data([1])
        append(UInt64(path.count), to: &manifest)
        manifest.append(path)
        append(UInt64(contents.count), to: &manifest)
        manifest.append(contents)

        return SourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: UInt64(contents.count),
            contentHash: sha256Hex(manifest)
        )
    }

    private static func append(_ value: String, to data: inout Data) {
        let encoded = Data(value.utf8)
        append(UInt64(encoded.count), to: &data)
        data.append(encoded)
    }

    private static func append(_ value: UInt64, to data: inout Data) {
        var encoded = value.bigEndian
        withUnsafeBytes(of: &encoded) { data.append(contentsOf: $0) }
    }

    private static func sha256Hex(_ data: Data) -> String {
        SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
