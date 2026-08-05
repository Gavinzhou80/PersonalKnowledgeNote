enum PublicationFaultPoint: Equatable, Sendable {
    case beforeDuplicateProvenanceInsert
    case afterIntentCommit
    case afterArtifactMove
    case beforeVisibilityCommit
    case afterVisibilityCommit
}

struct PublicationFaultInjector: Sendable {
    let hit: @Sendable (PublicationFaultPoint) throws -> Void

    static let none = PublicationFaultInjector { _ in }
}
