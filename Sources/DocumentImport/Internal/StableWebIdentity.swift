import CryptoKit
import Foundation
import KnowledgeCore

enum StableWebIdentity {
    static let ruleVersion = "static-web-v1"

    static func blockID(
        category: SourceBlockCategory,
        role: SourceBlockRole,
        ordinal: Int,
        text: String
    ) -> SourceBlockID {
        var identity = Data()
        append(ruleVersion, to: &identity)
        append(category.rawValue, to: &identity)
        append(stableRole(role), to: &identity)
        append(String(ordinal), to: &identity)
        append(normalized(text), to: &identity)

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
        blocks: [(category: SourceBlockCategory, role: SourceBlockRole, text: String)]
    ) -> ContentFingerprint {
        var identity = Data()
        append(ruleVersion, to: &identity)
        for block in blocks where block.role != .image {
            append(block.category.rawValue, to: &identity)
            append(stableRole(block.role), to: &identity)
            append(normalized(block.text), to: &identity)
        }
        return ContentFingerprint(sha256Hex(identity))
    }

    private static func stableRole(_ role: SourceBlockRole) -> String {
        switch role {
        case .heading(let level): "heading:\(level)"
        case .paragraph: "paragraph"
        case .listItem: "list-item"
        case .quotation: "quotation"
        case .codeBlock(let language):
            "code-block:\(language?.precomposedStringWithCanonicalMapping ?? "")"
        case .image: "image"
        case .caption: "caption"
        }
    }

    private static func normalized(_ value: String) -> String {
        value.precomposedStringWithCanonicalMapping
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
