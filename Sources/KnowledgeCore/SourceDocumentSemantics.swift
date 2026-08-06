import Foundation

public enum SourceBlockCategory: String, Codable, Hashable, Sendable {
    case text
    case code
    case media
}

public enum SourceBlockRole: Codable, Hashable, Sendable {
    case heading(level: Int)
    case paragraph
    case listItem
    case quotation
    case codeBlock(language: String?)
    case image
    case caption
}

public struct SourceTextRange: Codable, Hashable, Sendable {
    public let utf16Offset: Int
    public let utf16Length: Int

    public init(utf16Offset: Int, utf16Length: Int) {
        precondition(
            (try? Self.validate(
                utf16Offset: utf16Offset,
                utf16Length: utf16Length
            )) != nil,
            "SourceTextRange requires a nonnegative offset and positive length"
        )
        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let utf16Offset = try container.decode(Int.self, forKey: .utf16Offset)
        let utf16Length = try container.decode(Int.self, forKey: .utf16Length)

        do {
            try Self.validate(
                utf16Offset: utf16Offset,
                utf16Length: utf16Length
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceTextRange requires a nonnegative offset and positive length",
                    underlyingError: error
                )
            )
        }

        self.utf16Offset = utf16Offset
        self.utf16Length = utf16Length
    }

    private enum CodingKeys: String, CodingKey {
        case utf16Offset
        case utf16Length
    }

    private enum ValidationError: Error {
        case negativeOffset
        case nonpositiveLength
    }

    private static func validate(
        utf16Offset: Int,
        utf16Length: Int
    ) throws {
        guard utf16Offset >= 0 else {
            throw ValidationError.negativeOffset
        }
        guard utf16Length > 0 else {
            throw ValidationError.nonpositiveLength
        }
    }
}

public enum InlineMarkupKind: Codable, Hashable, Sendable {
    case emphasis
    case strong
    case link(URL)
    case citation(URL?)
    case inlineCode
}

public struct InlineMarkup: Codable, Hashable, Sendable {
    public let range: SourceTextRange
    public let kind: InlineMarkupKind

    public init(range: SourceTextRange, kind: InlineMarkupKind) {
        self.range = range
        self.kind = kind
    }
}

public struct SourceMediaReference: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Hashable, Sendable {
        case image
    }

    public let kind: Kind
    public let artifactRelativePath: String
    public let mimeType: String
    public let altText: String?
    public let pixelWidth: Int?
    public let pixelHeight: Int?

    public init(
        kind: Kind,
        artifactRelativePath: String,
        mimeType: String,
        altText: String?,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) {
        precondition(
            (try? Self.validate(
                artifactRelativePath: artifactRelativePath,
                mimeType: mimeType,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )) != nil,
            "SourceMediaReference requires a safe assets path, MIME type, and positive dimensions"
        )
        self.kind = kind
        self.artifactRelativePath = artifactRelativePath
        self.mimeType = mimeType
        self.altText = altText
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        let artifactRelativePath = try container.decode(
            String.self,
            forKey: .artifactRelativePath
        )
        let mimeType = try container.decode(String.self, forKey: .mimeType)
        let altText = try container.decodeIfPresent(String.self, forKey: .altText)
        let pixelWidth = try container.decodeIfPresent(Int.self, forKey: .pixelWidth)
        let pixelHeight = try container.decodeIfPresent(Int.self, forKey: .pixelHeight)

        do {
            try Self.validate(
                artifactRelativePath: artifactRelativePath,
                mimeType: mimeType,
                pixelWidth: pixelWidth,
                pixelHeight: pixelHeight
            )
        } catch {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(
                    codingPath: decoder.codingPath,
                    debugDescription: "SourceMediaReference requires a safe assets path, MIME type, and positive dimensions",
                    underlyingError: error
                )
            )
        }

        self.kind = kind
        self.artifactRelativePath = artifactRelativePath
        self.mimeType = mimeType
        self.altText = altText
        self.pixelWidth = pixelWidth
        self.pixelHeight = pixelHeight
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case artifactRelativePath
        case mimeType
        case altText
        case pixelWidth
        case pixelHeight
    }

    private enum ValidationError: Error {
        case unsafeArtifactRelativePath
        case emptyMIMEType
        case nonpositiveDimension
    }

    private static func validate(
        artifactRelativePath: String,
        mimeType: String,
        pixelWidth: Int?,
        pixelHeight: Int?
    ) throws {
        let components = artifactRelativePath.split(
            separator: "/",
            omittingEmptySubsequences: false
        )
        let safeCharacters = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "-._")
        )
        guard components.count >= 2,
              components.first == "assets",
              components.dropFirst().allSatisfy({ component in
                  !component.isEmpty
                      && component != "."
                      && component != ".."
                      && component.unicodeScalars.allSatisfy(
                          safeCharacters.contains
                      )
              }) else {
            throw ValidationError.unsafeArtifactRelativePath
        }
        guard !mimeType.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw ValidationError.emptyMIMEType
        }
        guard pixelWidth.map({ $0 > 0 }) ?? true,
              pixelHeight.map({ $0 > 0 }) ?? true else {
            throw ValidationError.nonpositiveDimension
        }
    }
}

public enum SourceRelationKind: String, Codable, Hashable, Sendable {
    case captionForMedia
}

public struct SourceRelation: Codable, Hashable, Sendable {
    public let sourceBlockID: SourceBlockID
    public let targetBlockID: SourceBlockID
    public let kind: SourceRelationKind

    public init(
        sourceBlockID: SourceBlockID,
        targetBlockID: SourceBlockID,
        kind: SourceRelationKind
    ) {
        self.sourceBlockID = sourceBlockID
        self.targetBlockID = targetBlockID
        self.kind = kind
    }
}

public struct ImportIssue: Codable, Hashable, Sendable {
    public enum Code: String, Codable, Hashable, Sendable {
        case optionalWebImageUnavailable
    }

    public let code: Code
    public let relatedBlockID: SourceBlockID?

    public init(code: Code, relatedBlockID: SourceBlockID? = nil) {
        self.code = code
        self.relatedBlockID = relatedBlockID
    }
}
