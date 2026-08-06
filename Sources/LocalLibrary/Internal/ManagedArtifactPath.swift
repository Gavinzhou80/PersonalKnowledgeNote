import Foundation
import KnowledgeCore

enum ManagedArtifactPath: Hashable, Sendable {
    enum Scope: String, Hashable, Sendable {
        case staging = "Staging"
        case artifacts = "Artifacts"
        case checkpoints = "Checkpoints"
    }

    case staging(taskID: ImportTaskID, artifactID: UUID)
    case artifacts(documentID: SourceDocumentID)
    case checkpoint(taskID: ImportTaskID, artifactID: UUID)

    var relativePath: String {
        switch self {
        case .staging(let taskID, let artifactID):
            "Staging/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        case .artifacts(let documentID):
            "Artifacts/\(documentID.rawValue.uuidString)"
        case .checkpoint(let taskID, let artifactID):
            "Checkpoints/\(taskID.rawValue.uuidString)/\(artifactID.uuidString)"
        }
    }

    var scope: Scope {
        switch self {
        case .staging:
            .staging
        case .artifacts:
            .artifacts
        case .checkpoint:
            .checkpoints
        }
    }

    var identityComponents: [String] {
        switch self {
        case .staging(let taskID, let artifactID):
            [taskID.rawValue.uuidString, artifactID.uuidString]
        case .artifacts(let documentID):
            [documentID.rawValue.uuidString]
        case .checkpoint(let taskID, let artifactID):
            [taskID.rawValue.uuidString, artifactID.uuidString]
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
        case Scope.checkpoints.rawValue where components.count == 3:
            guard let taskID = UUID(uuidString: components[1]),
                  let artifactID = UUID(uuidString: components[2])
            else {
                throw managedArtifactPathCorruption()
            }
            path = .checkpoint(
                taskID: ImportTaskID(taskID),
                artifactID: artifactID
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
