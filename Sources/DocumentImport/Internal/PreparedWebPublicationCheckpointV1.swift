import CoreFoundation
import Foundation
import KnowledgeCore

struct PreparedWebPublicationCheckpointV1: Codable, Sendable {
    let documentID: SourceDocumentID
    let fingerprint: ContentFingerprint
    let document: Document
    let originalSource: OriginalSource
    let stagedArtifactID: UUID
    let stagedDescriptor: SourceArtifactDescriptor
    let issues: [KnowledgeCore.ImportIssue]

    init(_ prepared: PreparedWebPublication) {
        self.documentID = prepared.documentID
        self.fingerprint = prepared.fingerprint
        self.document = Document(prepared.document)
        self.originalSource = prepared.originalSource
        self.stagedArtifactID = prepared.stagedArtifactID
        self.stagedDescriptor = prepared.stagedDescriptor
        self.issues = prepared.issues
    }

    func domainValue() throws -> PreparedWebPublication {
        PreparedWebPublication(
            documentID: documentID,
            fingerprint: fingerprint,
            document: try document.domainValue(),
            originalSource: originalSource,
            stagedArtifactID: stagedArtifactID,
            stagedDescriptor: stagedDescriptor,
            issues: issues
        )
    }

    struct Document: Codable, Sendable {
        let documentID: SourceDocumentID
        let importedMetadata: ImportedDocumentMetadata
        let blocks: [SourceBlock]
        let structure: SourceStructure
        let evidence: [EvidenceEntry]
        let issues: [KnowledgeCore.ImportIssue]

        init(_ document: SourceDocumentContent) {
            self.documentID = document.documentID
            self.importedMetadata = document.importedMetadata
            self.blocks = document.blocks
            self.structure = document.structure
            self.evidence = document.evidence
                .map { entry in
                    EvidenceEntry(
                        blockID: entry.key,
                        evidence: entry.value
                    )
                }
                .sorted { lhs, rhs in
                    lhs.blockID.rawValue.uuidString
                        < rhs.blockID.rawValue.uuidString
                }
            self.issues = document.issues
        }

        func domainValue() throws -> SourceDocumentContent {
            var evidenceByBlockID: [SourceBlockID: SourceEvidence] = [:]
            evidenceByBlockID.reserveCapacity(evidence.count)
            for entry in evidence {
                guard evidenceByBlockID.updateValue(
                    entry.evidence,
                    forKey: entry.blockID
                ) == nil else {
                    throw WebImportCheckpointError.invalidPackage
                }
            }

            let bridge = SourceDocumentContentBridge(
                documentID: documentID,
                importedMetadata: importedMetadata,
                blocks: blocks,
                structure: structure,
                evidence: evidenceByBlockID,
                issues: issues
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .millisecondsSince1970
            let data = try encoder.encode(bridge)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .millisecondsSince1970
            return try decoder.decode(SourceDocumentContent.self, from: data)
        }
    }

    struct EvidenceEntry: Codable, Sendable {
        let blockID: SourceBlockID
        let evidence: SourceEvidence

        init(blockID: SourceBlockID, evidence: SourceEvidence) {
            self.blockID = blockID
            self.evidence = evidence
        }
    }
}

private struct SourceDocumentContentBridge: Encodable {
    let documentID: SourceDocumentID
    let importedMetadata: ImportedDocumentMetadata
    let blocks: [SourceBlock]
    let structure: SourceStructure
    let evidence: [SourceBlockID: SourceEvidence]
    let issues: [KnowledgeCore.ImportIssue]
}

enum PreparedWebPublicationCheckpointV1WireValidator {
    static func validate(_ data: Data) throws {
        try StrictJSONValidator.validate(data)
        let root = try object(
            JSONSerialization.jsonObject(with: data),
            required: [
                "documentID", "fingerprint", "document", "originalSource",
                "stagedArtifactID", "stagedDescriptor", "issues",
            ]
        )
        try identifier(root["documentID"])
        try fingerprint(root["fingerprint"])
        try document(root["document"])
        try originalSource(root["originalSource"])
        try string(root["stagedArtifactID"])
        try descriptor(root["stagedDescriptor"])
        try issues(root["issues"])
    }

    private static func identifier(_ value: Any?) throws {
        let value = try object(value, required: ["rawValue"])
        try string(value["rawValue"])
    }

    private static func fingerprint(_ value: Any?) throws {
        let value = try object(value, required: ["rawValue"])
        try string(value["rawValue"])
    }

    private static func document(_ value: Any?) throws {
        let value = try object(
            value,
            required: [
                "documentID", "importedMetadata", "blocks", "structure",
                "evidence", "issues",
            ]
        )
        try identifier(value["documentID"])
        try importedMetadata(value["importedMetadata"])
        for block in try array(value["blocks"]) {
            try sourceBlock(block)
        }
        try structure(value["structure"])
        try evidence(value["evidence"])
        try issues(value["issues"])
    }

    private static func importedMetadata(_ value: Any?) throws {
        let value = try object(
            value,
            required: ["title"],
            optional: ["author", "publishedAt"]
        )
        try string(value["title"])
        if let author = value["author"] {
            try string(author)
        }
        if let publishedAt = value["publishedAt"] {
            try number(publishedAt)
        }
    }

    private static func sourceBlock(_ value: Any) throws {
        let value = try object(
            value,
            required: [
                "id", "canonicalText", "category", "role", "inlineMarkup",
            ],
            optional: ["media"]
        )
        try identifier(value["id"])
        try string(value["canonicalText"])
        try string(value["category"])
        try blockRole(value["role"])
        for markup in try array(value["inlineMarkup"]) {
            try inlineMarkup(markup)
        }
        if let media = value["media"] {
            try mediaReference(media)
        }
    }

    private static func blockRole(_ value: Any?) throws {
        let base = try object(
            value,
            required: ["type"],
            optional: ["level", "language"]
        )
        let type = try stringValue(base["type"])
        switch type {
        case "heading":
            try exactKeys(base, required: ["type", "level"])
            try integer(base["level"])
        case "codeBlock":
            try exactKeys(
                base,
                required: ["type"],
                optional: ["language"]
            )
            if let language = base["language"] {
                try string(language)
            }
        case "paragraph", "listItem", "quotation", "image", "caption":
            try exactKeys(base, required: ["type"])
        default:
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func inlineMarkup(_ value: Any) throws {
        let value = try object(value, required: ["range", "kind"])
        let range = try object(
            value["range"],
            required: ["utf16Offset", "utf16Length"]
        )
        try integer(range["utf16Offset"])
        try integer(range["utf16Length"])
        try inlineMarkupKind(value["kind"])
    }

    private static func inlineMarkupKind(_ value: Any?) throws {
        let base = try object(
            value,
            required: ["type"],
            optional: ["url"]
        )
        let type = try stringValue(base["type"])
        switch type {
        case "link":
            try exactKeys(base, required: ["type", "url"])
            try string(base["url"])
        case "citation":
            try exactKeys(base, required: ["type"], optional: ["url"])
            if let url = base["url"] {
                try string(url)
            }
        case "emphasis", "strong", "inlineCode":
            try exactKeys(base, required: ["type"])
        default:
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func mediaReference(_ value: Any) throws {
        let value = try object(
            value,
            required: ["kind", "artifactRelativePath", "mimeType"],
            optional: ["altText", "pixelWidth", "pixelHeight"]
        )
        try string(value["kind"])
        try string(value["artifactRelativePath"])
        try string(value["mimeType"])
        if let altText = value["altText"] {
            try string(altText)
        }
        if let width = value["pixelWidth"] {
            try integer(width)
        }
        if let height = value["pixelHeight"] {
            try integer(height)
        }
    }

    private static func structure(_ value: Any?) throws {
        let value = try object(
            value,
            required: ["orderedBlockIDs", "relations"]
        )
        for identifierValue in try array(value["orderedBlockIDs"]) {
            try identifier(identifierValue)
        }
        for relationValue in try array(value["relations"]) {
            let relation = try object(
                relationValue,
                required: ["sourceBlockID", "targetBlockID", "kind"]
            )
            try identifier(relation["sourceBlockID"])
            try identifier(relation["targetBlockID"])
            try string(relation["kind"])
        }
    }

    private static func evidence(_ value: Any?) throws {
        for entryValue in try array(value) {
            let entry = try object(
                entryValue,
                required: ["blockID", "evidence"]
            )
            try identifier(entry["blockID"])
            let wrapper = try object(entry["evidence"], required: ["web"])
            let web = try object(wrapper["web"], required: ["locator"])
            try string(web["locator"])
        }
    }

    private static func issues(_ value: Any?) throws {
        for issueValue in try array(value) {
            let issue = try object(
                issueValue,
                required: ["code"],
                optional: ["relatedBlockID"]
            )
            try string(issue["code"])
            if let relatedBlockID = issue["relatedBlockID"] {
                try identifier(relatedBlockID)
            }
        }
    }

    private static func originalSource(_ value: Any?) throws {
        let wrapper = try object(value, required: ["webpage"])
        let webpage = try object(wrapper["webpage"], required: ["_0"])
        try string(webpage["_0"])
    }

    private static func descriptor(_ value: Any?) throws {
        let value = try object(
            value,
            required: ["kind", "byteCount", "contentHash"]
        )
        try string(value["kind"])
        try integer(value["byteCount"])
        try string(value["contentHash"])
    }

    private static func object(
        _ value: Any?,
        required: Set<String>,
        optional: Set<String> = []
    ) throws -> [String: Any] {
        guard let value = value as? [String: Any] else {
            throw WebImportCheckpointError.invalidPackage
        }
        try exactKeys(value, required: required, optional: optional)
        return value
    }

    private static func exactKeys(
        _ object: [String: Any],
        required: Set<String>,
        optional: Set<String> = []
    ) throws {
        let keys = Set(object.keys)
        guard required.isSubset(of: keys),
            keys.isSubset(of: required.union(optional))
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func array(_ value: Any?) throws -> [Any] {
        guard let value = value as? [Any] else {
            throw WebImportCheckpointError.invalidPackage
        }
        return value
    }

    private static func string(_ value: Any?) throws {
        _ = try stringValue(value)
    }

    private static func stringValue(_ value: Any?) throws -> String {
        guard let value = value as? String else {
            throw WebImportCheckpointError.invalidPackage
        }
        return value
    }

    private static func integer(_ value: Any?) throws {
        guard let value = value as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.rounded(.towardZero) == value.doubleValue
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }

    private static func number(_ value: Any?) throws {
        guard let value = value as? NSNumber,
            CFGetTypeID(value) != CFBooleanGetTypeID()
        else {
            throw WebImportCheckpointError.invalidPackage
        }
    }
}
