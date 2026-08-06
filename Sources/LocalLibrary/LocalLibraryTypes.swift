import Foundation
import KnowledgeCore

public enum SourceArtifactInput: Sendable {
    case file(URL, descriptor: SourceArtifactDescriptor)
    case package(URL, descriptor: SourceArtifactDescriptor)
}

public struct StagedArtifact: Hashable, Sendable {
    package let rawValue: UUID
    public let descriptor: SourceArtifactDescriptor

    package init(
        rawValue: UUID,
        descriptor: SourceArtifactDescriptor
    ) {
        self.rawValue = rawValue
        self.descriptor = descriptor
    }
}

public struct PublicationCandidate: Sendable {
    public let fingerprint: ContentFingerprint
    public let artifact: StagedArtifact
    public let document: SourceDocumentContent
    public let originalSource: OriginalSource

    public init(
        fingerprint: ContentFingerprint,
        artifact: StagedArtifact,
        document: SourceDocumentContent,
        originalSource: OriginalSource
    ) {
        self.fingerprint = fingerprint
        self.artifact = artifact
        self.document = document
        self.originalSource = originalSource
    }
}

package struct CheckpointArtifactDescriptor: Hashable, Codable, Sendable {
    package let byteCount: Int64
    package let contentHash: String

    package init(byteCount: Int64, contentHash: String) {
        self.byteCount = byteCount
        self.contentHash = contentHash
    }

    package init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let byteCount = try container.decode(Int64.self, forKey: .byteCount)
        let contentHash = try container.decode(String.self, forKey: .contentHash)
        guard byteCount > 0, !contentHash.isEmpty else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Invalid checkpoint artifact descriptor"
            ))
        }
        self.byteCount = byteCount
        self.contentHash = contentHash
    }
}

package struct ManagedCheckpointArtifact: Hashable, Sendable {
    package let rawValue: UUID
    package let descriptor: CheckpointArtifactDescriptor

    package init(
        rawValue: UUID,
        descriptor: CheckpointArtifactDescriptor
    ) {
        self.rawValue = rawValue
        self.descriptor = descriptor
    }
}

package struct VerifiedCheckpointPackage: Sendable {
    package let descriptor: CheckpointArtifactDescriptor
    package let files: [String: Data]

    package init(
        descriptor: CheckpointArtifactDescriptor,
        files: [String: Data]
    ) {
        self.descriptor = descriptor
        self.files = files
    }
}

package struct CheckpointArtifactReplacement: Sendable {
    package let artifact: ManagedCheckpointArtifact
    package let snapshot: DurableImportSnapshot

    package init(
        artifact: ManagedCheckpointArtifact,
        snapshot: DurableImportSnapshot
    ) {
        self.artifact = artifact
        self.snapshot = snapshot
    }
}

public struct DurableImportSnapshot: Sendable {
    public let taskID: ImportTaskID
    package let journalSequence: UInt64
    public let queueSequence: UInt64?
    public let attempt: UInt
    public let revision: UInt64
    public let state: ImportTaskState
    public let failure: ImportTaskFailureEnvelope?
    public let checkpoint: CheckpointEnvelope?
    package let checkpointArtifact: ManagedCheckpointArtifact?
    public let stagedArtifact: StagedArtifact?

    package init(
        taskID: ImportTaskID,
        journalSequence: UInt64,
        queueSequence: UInt64?,
        attempt: UInt,
        revision: UInt64,
        state: ImportTaskState,
        failure: ImportTaskFailureEnvelope?,
        checkpoint: CheckpointEnvelope?,
        checkpointArtifact: ManagedCheckpointArtifact?,
        stagedArtifact: StagedArtifact?
    ) {
        self.taskID = taskID
        self.journalSequence = journalSequence
        self.queueSequence = queueSequence
        self.attempt = attempt
        self.revision = revision
        self.state = state
        self.failure = failure
        self.checkpoint = checkpoint
        self.checkpointArtifact = checkpointArtifact
        self.stagedArtifact = stagedArtifact
    }
}

package struct DurableQueueMutation: Sendable {
    package let primary: DurableImportSnapshot
    package let queueUpdates: [DurableImportSnapshot]

    package init(
        primary: DurableImportSnapshot,
        queueUpdates: [DurableImportSnapshot]
    ) {
        self.primary = primary
        self.queueUpdates = queueUpdates
    }
}

package struct DurableQueueClaim: Sendable {
    package let claimed: DurableImportSnapshot
    package let queueUpdates: [DurableImportSnapshot]

    package init(
        claimed: DurableImportSnapshot,
        queueUpdates: [DurableImportSnapshot]
    ) {
        self.claimed = claimed
        self.queueUpdates = queueUpdates
    }
}

public struct CheckpointUpdate: Sendable {
    public let expectedRevision: UInt64
    public let ordinal: UInt64
    public let envelope: CheckpointEnvelope

    public init(
        expectedRevision: UInt64,
        ordinal: UInt64,
        envelope: CheckpointEnvelope
    ) {
        self.expectedRevision = expectedRevision
        self.ordinal = ordinal
        self.envelope = envelope
    }
}

public enum PublicationOutcome: Hashable, Codable, Sendable {
    case published(documentID: SourceDocumentID)
    case alreadyImported(
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation,
        provenanceAdded: Bool
    )
}

public struct LocatedSourceDocument: Sendable {
    public let document: SourceDocument
    public let location: ExistingDocumentLocation

    package init(
        document: SourceDocument,
        location: ExistingDocumentLocation
    ) {
        self.document = document
        self.location = location
    }
}

public enum LocalLibraryError: Error, Equatable, Sendable {
    case unavailable
    case insufficientDiskSpace
    case staleRevision(current: UInt64)
    case invalidTaskState
    case checkpointRegression
    case artifactMissing
    case artifactOwnershipViolation
    case publicationFailed(retryable: Bool)
    case corruptLibrary(diagnosticID: UUID)
}
