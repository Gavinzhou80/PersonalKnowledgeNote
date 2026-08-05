import Foundation

public enum ImportTaskState: String, Hashable, Codable, Sendable {
    case accepted
    case working
    case publicationPending
    case completed
    case abandoned
}

public struct CheckpointEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data

    public init(codecVersion: UInt16, payload: Data) {
        self.codecVersion = codecVersion
        self.payload = payload
    }
}
