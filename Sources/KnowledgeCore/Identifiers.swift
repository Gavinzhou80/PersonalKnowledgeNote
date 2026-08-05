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
        precondition(!rawValue.isEmpty)
        self.rawValue = rawValue
    }
}
