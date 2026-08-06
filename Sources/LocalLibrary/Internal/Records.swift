import Foundation
import GRDB
import KnowledgeCore

struct ImportTaskRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "import_tasks"

    var taskID: String
    var sourceKind: String
    var sourceValue: String
    var attempt: Int64
    var revision: Int64
    var state: String
    var checkpointOrdinal: Int64?
    var checkpointCodecVersion: Int64?
    var checkpointPayload: Data?
    var stagedArtifactID: String?
    var outcomeJSON: Data?

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case sourceKind = "source_kind"
        case sourceValue = "source_value"
        case attempt
        case revision
        case state
        case checkpointOrdinal = "checkpoint_ordinal"
        case checkpointCodecVersion = "checkpoint_codec_version"
        case checkpointPayload = "checkpoint_payload"
        case stagedArtifactID = "staged_artifact_id"
        case outcomeJSON = "outcome_json"
    }
}

struct StagedArtifactRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "staged_artifacts"

    var artifactID: String
    var taskID: String
    var descriptorJSON: Data
    var relativePath: String

    private enum CodingKeys: String, CodingKey {
        case artifactID = "artifact_id"
        case taskID = "task_id"
        case descriptorJSON = "descriptor_json"
        case relativePath = "relative_path"
    }
}

struct SourceDocumentRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "source_documents"

    var documentID: String
    var fingerprint: String
    var location: String
    var visibility: String
    var contentJSON: Data
    var artifactDescriptorJSON: Data
    var managedRelativePath: String

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case fingerprint
        case location
        case visibility
        case contentJSON = "content_json"
        case artifactDescriptorJSON = "artifact_descriptor_json"
        case managedRelativePath = "managed_relative_path"
    }
}

struct PublicationIntentRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "publication_intents"

    var taskID: String
    var documentID: String
    var stagedArtifactID: String
    var finalRelativePath: String

    private enum CodingKeys: String, CodingKey {
        case taskID = "task_id"
        case documentID = "document_id"
        case stagedArtifactID = "staged_artifact_id"
        case finalRelativePath = "final_relative_path"
    }
}

struct SourceProvenanceRecord:
    Codable,
    FetchableRecord,
    PersistableRecord
{
    static let databaseTableName = "source_provenance"

    var documentID: String
    var sourceKind: String
    var sourceValue: String

    private enum CodingKeys: String, CodingKey {
        case documentID = "document_id"
        case sourceKind = "source_kind"
        case sourceValue = "source_value"
    }
}

struct StoredSourceProvenance: Sendable {
    let documentID: SourceDocumentID
    let source: OriginalSource
}

enum SourceColumns {
    static func encode(
        _ source: OriginalSource
    ) throws -> (kind: String, value: String) {
        let columns: (kind: String, value: String)
        switch source {
        case .webpage(let url):
            columns = ("webpage", url.absoluteString)
        case .pdfFile(let url):
            columns = ("pdf", url.absoluteString)
        }
        do {
            _ = try validatedSource(
                kind: columns.kind,
                value: columns.value
            )
            return columns
        } catch {
            throw LocalLibraryError.unavailable
        }
    }

    static func decode(kind: String, value: String) throws -> OriginalSource {
        do {
            return try validatedSource(kind: kind, value: value)
        } catch {
            throw corruptLibrary()
        }
    }

    private static func validatedSource(
        kind: String,
        value: String
    ) throws -> OriginalSource {
        guard let url = URL(string: value),
              url.absoluteString == value,
              let scheme = url.scheme?.lowercased()
        else {
            throw SourceValidationError.invalidURL
        }

        switch kind {
        case "webpage":
            guard (scheme == "http" || scheme == "https"),
                  let host = url.host,
                  !host.isEmpty
            else {
                throw SourceValidationError.invalidURL
            }
            return .webpage(url)
        case "pdf":
            let host = url.host?.lowercased()
            guard scheme == "file",
                  url.isFileURL,
                  url.path.hasPrefix("/"),
                  host == nil || host == "" || host == "localhost"
            else {
                throw SourceValidationError.invalidURL
            }
            return .pdfFile(url)
        default:
            throw SourceValidationError.invalidKind
        }
    }

    private enum SourceValidationError: Error {
        case invalidKind
        case invalidURL
    }
}

enum DomainJSON {
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        try JSONEncoder().encode(value)
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type,
        from data: Data
    ) throws -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw corruptLibrary()
        }
    }
}

extension ImportTaskState {
    var isValidForLegacyV1Columns: Bool {
        switch self {
        case .accepted, .working, .publicationPending, .completed, .abandoned:
            return true
        case .queued, .running, .cancelling, .failed, .cancelled:
            return false
        }
    }
}

extension ImportTaskRecord {
    func snapshot(
        stagedArtifact: StagedArtifactRecord?
    ) throws -> DurableImportSnapshot {
        guard let rawTaskID = UUID(uuidString: taskID),
              let decodedAttempt = UInt(exactly: attempt),
              decodedAttempt > 0,
              let decodedRevision = UInt64(exactly: revision),
              let decodedState = ImportTaskState(rawValue: state),
              decodedState.isValidForLegacyV1Columns
        else {
            throw corruptLibrary()
        }

        _ = try SourceColumns.decode(kind: sourceKind, value: sourceValue)
        let checkpoint = try decodeCheckpoint()
        let artifact = try decodeStagedArtifact(stagedArtifact)
        try validateOutcome(for: decodedState)

        return DurableImportSnapshot(
            taskID: ImportTaskID(rawTaskID),
            attempt: decodedAttempt,
            revision: decodedRevision,
            state: decodedState,
            checkpoint: checkpoint,
            stagedArtifact: artifact
        )
    }

    private func decodeCheckpoint() throws -> CheckpointEnvelope? {
        switch (
            checkpointOrdinal,
            checkpointCodecVersion,
            checkpointPayload
        ) {
        case (nil, nil, nil):
            return nil
        case (let ordinal?, let version?, let payload?):
            guard UInt64(exactly: ordinal) != nil,
                  let codecVersion = UInt16(exactly: version),
                  payload.count <= 1_048_576
            else {
                throw corruptLibrary()
            }
            return CheckpointEnvelope(
                codecVersion: codecVersion,
                payload: payload
            )
        default:
            throw corruptLibrary()
        }
    }

    private func decodeStagedArtifact(
        _ stagedArtifact: StagedArtifactRecord?
    ) throws -> StagedArtifact? {
        switch (stagedArtifactID, stagedArtifact) {
        case (nil, nil):
            return nil
        case (let expectedID?, let record?):
            guard expectedID == record.artifactID,
                  record.taskID == taskID,
                  let artifactID = UUID(uuidString: record.artifactID)
            else {
                throw corruptLibrary()
            }
            return StagedArtifact(
                rawValue: artifactID,
                descriptor: try DomainJSON.decode(
                    SourceArtifactDescriptor.self,
                    from: record.descriptorJSON
                )
            )
        default:
            throw corruptLibrary()
        }
    }

    private func validateOutcome(for state: ImportTaskState) throws {
        switch (state, outcomeJSON) {
        case (.completed, let data?):
            _ = try DomainJSON.decode(PublicationOutcome.self, from: data)
        case (.completed, nil), (_, .some):
            throw corruptLibrary()
        case (_, nil):
            return
        }
    }

    func storedOutcome() throws -> PublicationOutcome? {
        guard let state = ImportTaskState(rawValue: state),
              state.isValidForLegacyV1Columns
        else {
            throw corruptLibrary()
        }
        switch (state, outcomeJSON) {
        case (.completed, let data?):
            return try DomainJSON.decode(
                PublicationOutcome.self,
                from: data
            )
        case (.completed, nil), (_, .some):
            throw corruptLibrary()
        case (_, nil):
            return nil
        }
    }
}

extension SourceDocumentRecord {
    static func hidden(
        candidate: PublicationCandidate,
        descriptor: SourceArtifactDescriptor,
        managedRelativePath: String
    ) throws -> SourceDocumentRecord {
        SourceDocumentRecord(
            documentID: candidate.document.documentID.rawValue.uuidString,
            fingerprint: candidate.fingerprint.rawValue,
            location: ExistingDocumentLocation.library.rawValue,
            visibility: SourceDocumentVisibility.hidden.rawValue,
            contentJSON: try DomainJSON.encode(candidate.document),
            artifactDescriptorJSON: try DomainJSON.encode(descriptor),
            managedRelativePath: managedRelativePath
        )
    }

    func decoded() throws -> StoredSourceDocument {
        guard let rawDocumentID = UUID(uuidString: documentID),
              let location = ExistingDocumentLocation(rawValue: location),
              let visibility = SourceDocumentVisibility(rawValue: visibility)
        else {
            throw corruptLibrary()
        }
        let content = try DomainJSON.decode(
            SourceDocumentContent.self,
            from: contentJSON
        )
        let descriptor = try DomainJSON.decode(
            SourceArtifactDescriptor.self,
            from: artifactDescriptorJSON
        )
        let fingerprintData = try DomainJSON.encode(
            PersistedFingerprint(rawValue: fingerprint)
        )
        let decodedFingerprint = try DomainJSON.decode(
            ContentFingerprint.self,
            from: fingerprintData
        )
        let decodedDocumentID = SourceDocumentID(rawDocumentID)
        guard content.documentID == decodedDocumentID else {
            throw corruptLibrary()
        }
        return StoredSourceDocument(
            documentID: decodedDocumentID,
            fingerprint: decodedFingerprint,
            location: location,
            visibility: visibility,
            content: content,
            descriptor: descriptor,
            managedRelativePath: managedRelativePath
        )
    }
}

extension SourceProvenanceRecord {
    func decoded() throws -> StoredSourceProvenance {
        guard let rawDocumentID = UUID(uuidString: documentID) else {
            throw corruptLibrary()
        }
        return StoredSourceProvenance(
            documentID: SourceDocumentID(rawDocumentID),
            source: try SourceColumns.decode(
                kind: sourceKind,
                value: sourceValue
            )
        )
    }
}

enum SourceDocumentVisibility: String, Sendable {
    case hidden
    case visible
}

struct StoredSourceDocument: Sendable {
    let documentID: SourceDocumentID
    let fingerprint: ContentFingerprint
    let location: ExistingDocumentLocation
    let visibility: SourceDocumentVisibility
    let content: SourceDocumentContent
    let descriptor: SourceArtifactDescriptor
    let managedRelativePath: String
}

private struct PersistedFingerprint: Encodable {
    let rawValue: String
}

private func corruptLibrary() -> LocalLibraryError {
    LocalLibraryError.corruptLibrary(diagnosticID: UUID())
}
