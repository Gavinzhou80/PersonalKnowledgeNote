import Foundation

public struct ImportTaskID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SourceDocumentID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct SourceBlockID: Hashable, Codable, Sendable {
    public let rawValue: UUID

    public init(_ rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public struct ContentFingerprint: Hashable, Codable, Sendable {
    public let rawValue: String

    public init(_ rawValue: String) {
        precondition(
            (try? Self.validate(rawValue)) != nil,
            "ContentFingerprint rawValue must not be empty"
        )
        self.rawValue = rawValue
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let rawValue = try container.decode(String.self, forKey: .rawValue)

        do {
            try Self.validate(rawValue)
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "ContentFingerprint rawValue must not be empty",
                    underlyingError: error
                )
            )
        }

        self.rawValue = rawValue
    }

    private enum CodingKeys: String, CodingKey {
        case rawValue
    }

    private enum ValidationError: Error {
        case emptyRawValue
    }

    private static func validate(_ rawValue: String) throws {
        guard !rawValue.isEmpty else {
            throw ValidationError.emptyRawValue
        }
    }
}
