import Foundation
import KnowledgeCore

enum ManagedArtifactPath: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable {
        case staging = "Staging"
        case artifacts = "Artifacts"
    }

    case staging(taskID: ImportTaskID, artifactID: UUID)
    case artifacts(documentID: SourceDocumentID)

    var relativePath: String {
        switch self {
        case .staging(let taskID, let artifactID):
            "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        case .artifacts(let documentID):
            "Artifacts/\(documentID.rawValue.uuidString)"
        }
    }

    var scope: Scope {
        switch self {
        case .staging:
            .staging
        case .artifacts:
            .artifacts
        }
    }

    var identityComponents: [String] {
        switch self {
        case .staging(let taskID, let artifactID):
            [taskID.rawValue.uuidString, artifactID.uuidString]
        case .artifacts(let documentID):
            [documentID.rawValue.uuidString]
        }
    }

    static func parse(_ relativePath: String) throws -> ManagedArtifactPath {
        let components = relativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        ).map(String.init)
        let path: ManagedArtifactPath
        switch components.first {
        case Scope.staging.rawValue where components.count == 3:
            guard let taskID = UUID(uuidString: components[1]),
                  let artifactID = UUID(uuidString: components[2])
            else {
                throw managedArtifactPathCorruption()
            }
            path = .staging(
                taskID: ImportTaskID(taskID),
                artifactID: artifactID
            )
        case Scope.artifacts.rawValue where components.count == 2:
            guard let documentID = UUID(uuidString: components[1]) else {
                throw managedArtifactPathCorruption()
            }
            path = .artifacts(
                documentID: SourceDocumentID(documentID)
            )
        default:
            throw managedArtifactPathCorruption()
        }
        guard path.relativePath == relativePath else {
            throw managedArtifactPathCorruption()
        }
        return path
    }
}

private func managedArtifactPathCorruption() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}
