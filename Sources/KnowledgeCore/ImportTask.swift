import Foundation

public enum ImportTaskState: String, CaseIterable, Hashable, Codable, Sendable {
    case accepted
    case working
    case queued
    case running
    case cancelling
    case failed
    case cancelled
    case publicationPending
    case completed
    case abandoned
}

public struct ImportTaskFailureEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data

    public init(codecVersion: UInt16, payload: Data) {
        self.codecVersion = codecVersion
        self.payload = payload
    }
}

public struct CheckpointEnvelope: Hashable, Codable, Sendable {
    public let codecVersion: UInt16
    public let payload: Data

    public init(codecVersion: UInt16, payload: Data) {
        self.codecVersion = codecVersion
        self.payload = payload
    }
}
