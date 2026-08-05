enum PublicationFaultPoint: Equatable, Sendable {
    case beforeDuplicateProvenanceInsert
    case afterDuplicateProvenanceInsert
    case afterIntentCommit
    case afterArtifactMove
    case beforeVisibilityCommit
    case afterVisibilityCommit
    case beforeCommittedStagingCleanup
}

struct InjectedPublicationFault: Error {
    let underlying: Error
}

struct PublicationFaultInjector: Sendable {
    private let injection: @Sendable (PublicationFaultPoint) throws -> Void

    init(
        _ injection: @escaping @Sendable (PublicationFaultPoint) throws -> Void
    ) {
        self.injection = injection
    }

    func hit(_ point: PublicationFaultPoint) throws {
        do {
            try injection(point)
        } catch {
            throw InjectedPublicationFault(underlying: error)
        }
    }

    static let none = PublicationFaultInjector { _ in }
}
