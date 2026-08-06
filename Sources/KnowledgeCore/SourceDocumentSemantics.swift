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

    private enum CodingKeys: String, CodingKey {
        case type
        case level
        case language
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case heading
        case paragraph
        case listItem
        case quotation
        case codeBlock
        case image
        case caption
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.type) else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if legacy.contains(.heading) {
                let values = try legacy.nestedContainer(
                    keyedBy: CodingKeys.self,
                    forKey: .heading
                )
                self = .heading(level: try values.decode(Int.self, forKey: .level))
            } else if legacy.contains(.paragraph) {
                self = .paragraph
            } else if legacy.contains(.listItem) {
                self = .listItem
            } else if legacy.contains(.quotation) {
                self = .quotation
            } else if legacy.contains(.codeBlock) {
                let values = try legacy.nestedContainer(
                    keyedBy: CodingKeys.self,
                    forKey: .codeBlock
                )
                self = .codeBlock(
                    language: try values.decodeIfPresent(String.self, forKey: .language)
                )
            } else if legacy.contains(.image) {
                self = .image
            } else if legacy.contains(.caption) {
                self = .caption
            } else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown legacy SourceBlockRole"
                    )
                )
            }
            return
        }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "heading":
            self = .heading(level: try container.decode(Int.self, forKey: .level))
        case "paragraph": self = .paragraph
        case "listItem": self = .listItem
        case "quotation": self = .quotation
        case "codeBlock":
            self = .codeBlock(
                language: try container.decodeIfPresent(String.self, forKey: .language)
            )
        case "image": self = .image
        case "caption": self = .caption
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown SourceBlockRole type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .heading(let level):
            try container.encode("heading", forKey: .type)
            try container.encode(level, forKey: .level)
        case .paragraph:
            try container.encode("paragraph", forKey: .type)
        case .listItem:
            try container.encode("listItem", forKey: .type)
        case .quotation:
            try container.encode("quotation", forKey: .type)
        case .codeBlock(let language):
            try container.encode("codeBlock", forKey: .type)
            try container.encodeIfPresent(language, forKey: .language)
        case .image:
            try container.encode("image", forKey: .type)
        case .caption:
            try container.encode("caption", forKey: .type)
        }
    }
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

    private enum CodingKeys: String, CodingKey {
        case type
        case url
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case emphasis
        case strong
        case link
        case citation
        case inlineCode
    }

    private enum LegacyValueKeys: String, CodingKey {
        case value = "_0"
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard container.contains(.type) else {
            let legacy = try decoder.container(keyedBy: LegacyCodingKeys.self)
            if legacy.contains(.emphasis) {
                self = .emphasis
            } else if legacy.contains(.strong) {
                self = .strong
            } else if legacy.contains(.link) {
                let values = try legacy.nestedContainer(
                    keyedBy: LegacyValueKeys.self,
                    forKey: .link
                )
                self = .link(try values.decode(URL.self, forKey: .value))
            } else if legacy.contains(.citation) {
                let values = try legacy.nestedContainer(
                    keyedBy: LegacyValueKeys.self,
                    forKey: .citation
                )
                self = .citation(
                    try values.decodeIfPresent(URL.self, forKey: .value)
                )
            } else if legacy.contains(.inlineCode) {
                self = .inlineCode
            } else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "Unknown legacy InlineMarkupKind"
                    )
                )
            }
            return
        }
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "emphasis": self = .emphasis
        case "strong": self = .strong
        case "link":
            self = .link(try container.decode(URL.self, forKey: .url))
        case "citation":
            self = .citation(
                try container.decodeIfPresent(URL.self, forKey: .url)
            )
        case "inlineCode": self = .inlineCode
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unknown InlineMarkupKind type: \(type)"
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .emphasis:
            try container.encode("emphasis", forKey: .type)
        case .strong:
            try container.encode("strong", forKey: .type)
        case .link(let url):
            try container.encode("link", forKey: .type)
            try container.encode(url, forKey: .url)
        case .citation(let url):
            try container.encode("citation", forKey: .type)
            try container.encodeIfPresent(url, forKey: .url)
        case .inlineCode:
            try container.encode("inlineCode", forKey: .type)
        }
    }
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
                kind: kind,
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
                kind: kind,
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
        case invalidMIMEType
        case incompleteDimensions
        case nonpositiveDimension
    }

    private static func validate(
        kind: Kind,
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
        let normalizedMIMEType = mimeType
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        guard !normalizedMIMEType.isEmpty else {
            throw ValidationError.emptyMIMEType
        }
        switch kind {
        case .image:
            guard normalizedMIMEType.hasPrefix("image/") else {
                throw ValidationError.invalidMIMEType
            }
        }
        guard (pixelWidth == nil) == (pixelHeight == nil) else {
            throw ValidationError.incompleteDimensions
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

public extension ImportIssue.Code {
    @available(*, deprecated, renamed: "optionalWebImageUnavailable")
    static let optionalResourceUnavailable = Self.optionalWebImageUnavailable
}
