import Foundation
import KnowledgeCore

@available(*, deprecated, renamed: "KnowledgeCore.ImportIssue")
public typealias ImportIssue = KnowledgeCore.ImportIssue

public enum ImportTaskQuery: Hashable, Sendable {
    case unfinished
    case active
    case all
}

public enum OriginalSourceSummary: Hashable, Sendable {
    case webpage(URL)
    case pdfFile(name: String)
}

public struct ImportTaskSnapshot: Hashable, Sendable {
    public let id: ImportTaskID
    public let revision: UInt64
    public let attempt: UInt
    public let source: OriginalSourceSummary
    public let state: ImportTaskState

    public init(
        id: ImportTaskID,
        revision: UInt64,
        attempt: UInt,
        source: OriginalSourceSummary,
        state: ImportTaskState
    ) {
        self.id = id
        self.revision = revision
        self.attempt = attempt
        self.source = source
        self.state = state
    }
}

public enum ImportTaskState: Hashable, Sendable {
    case queued(position: Int)
    case running(ImportProgress)
    case cancelling
    case failed(ImportFailure)
    case cancelled
    case completed(ImportSuccess)
}

public struct ImportProgress: Hashable, Sendable {
    public let activity: ImportActivity
    public let completedUnitCount: Int64
    public let totalUnitCount: Int64?

    public init(
        activity: ImportActivity,
        completedUnitCount: Int64,
        totalUnitCount: Int64?
    ) {
        self.activity = activity
        self.completedUnitCount = completedUnitCount
        self.totalUnitCount = totalUnitCount
    }
}

public enum ImportActivity: String, Hashable, Sendable {
    case acquiringOriginalSource
    case constructingSourceDocument
    case publishing
}

public enum ImportSuccess: Hashable, Sendable {
    case published(
        documentID: SourceDocumentID,
        issues: [KnowledgeCore.ImportIssue],
        facts: ImportPublicationFacts?
    )
    case alreadyImported(
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation,
        provenanceAdded: Bool
    )
}

public struct ImportFailure: Error, Hashable, Sendable {
    public enum Code: String, Hashable, Codable, Sendable {
        case networkUnavailable
        case requestTimedOut
        case accessDenied
        case invalidHTTPResponse
        case unsupportedContentType
        case responseTooLarge
        case webpageHasNoReadableArticle
        case artifactConstructionFailed
        case checkpointInvalid
        case localLibraryUnavailable
        case publicationFailed
        case insufficientDiskSpace
    }

    public enum Recovery: String, Hashable, Codable, Sendable {
        case retryable
        case requiresNewOriginalSource
        case requiresUserAction
        case unsupported
    }

    public let code: Code
    public let recovery: Recovery
    public let diagnosticID: UUID

    public init(
        code: Code,
        recovery: Recovery,
        diagnosticID: UUID = UUID()
    ) {
        self.code = code
        self.recovery = recovery
        self.diagnosticID = diagnosticID
    }
}

public enum ImportStage: String, Codable, Hashable, Sendable {
    case acquiringSource
    case constructingDocument
    case publishing
}

public struct ImportStageTiming: Hashable, Codable, Sendable {
    public let stage: ImportStage
    public let durationMilliseconds: Int64

    public init(stage: ImportStage, durationMilliseconds: Int64) {
        self.stage = stage
        self.durationMilliseconds = durationMilliseconds
    }
}

/// Transient runtime facts for one publication.
///
/// Stage timings only cover the stages the producing run actually
/// executed: a resume from a checkpoint reports the remaining stages,
/// and each timing includes checkpoint persistence overhead. Durable
/// re-projections carry `nil` instead.
public struct ImportPublicationFacts: Hashable, Codable, Sendable {
    public let diagnosticID: UUID
    public let stageTimings: [ImportStageTiming]

    public init(
        diagnosticID: UUID = UUID(),
        stageTimings: [ImportStageTiming]
    ) {
        self.diagnosticID = diagnosticID
        self.stageTimings = stageTimings
    }
}

public enum ImportTerminalState: Hashable, Sendable {
    case success(ImportSuccess)
    case failure(ImportFailure)
    case cancelled
}

public enum ImportTaskControlError: Error, Hashable, Sendable {
    case taskNotFound
    case invalidState
    case retryNotAllowed
    case tooLate
}

public enum DocumentImportAvailabilityError: Error, Hashable, Sendable {
    case localLibraryUnavailable
}

public enum ImportSubmissionError: Error, Equatable, Sendable {
    case invalidWebURL
    case unsupportedOriginalSource
    case insufficientDiskSpace
    case localLibraryUnavailable
    case cannotPersistImportTask
}
