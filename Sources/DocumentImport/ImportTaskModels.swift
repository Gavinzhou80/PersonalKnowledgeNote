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
    case failed(ImportFailure)
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
        issues: [KnowledgeCore.ImportIssue]
    )
    case alreadyImported(
        documentID: SourceDocumentID,
        location: ExistingDocumentLocation,
        provenanceAdded: Bool
    )
}

public struct ImportFailure: Error, Hashable, Sendable {
    public enum Code: String, Hashable, Sendable {
        case networkUnavailable
        case webpageHasNoReadableArticle
        case artifactConstructionFailed
        case localLibraryUnavailable
        case publicationFailed
    }

    public enum Recovery: String, Hashable, Sendable {
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

public enum ImportTerminalState: Hashable, Sendable {
    case success(ImportSuccess)
    case failure(ImportFailure)
}

public enum ImportSubmissionError: Error, Equatable, Sendable {
    case invalidWebURL
    case unsupportedOriginalSource
    case insufficientDiskSpace
    case localLibraryUnavailable
    case cannotPersistImportTask
}
