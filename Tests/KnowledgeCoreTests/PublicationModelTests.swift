import Foundation
import KnowledgeCore
import Testing

@Test
func identifiersRoundTripThroughCodable() throws {
    let original = ImportTaskID()
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ImportTaskID.self, from: data)

    #expect(decoded == original)
}

@Test
func identicalTextAtDifferentPositionsKeepsDistinctBlockIdentity() {
    let first = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )
    let second = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Repeated text"
    )

    #expect(first.id != second.id)
    #expect(first.canonicalText == second.canonicalText)
}

@Test
func sourceDocumentContentIsReadableAndLocatable() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let content = SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [
            block.id: .web(locator: "article > p:nth-of-type(1)")
        ]
    )

    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: data
    )

    #expect(decoded == content)
}

@Test
func legacySourceDocumentJSONDecodesWithSemanticDefaults() throws {
    let blockID = SourceBlockID()
    let legacy = LegacySourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: LegacyImportedDocumentMetadata(
            title: "Legacy",
            author: nil
        ),
        blocks: [LegacySourceBlock(
            id: blockID,
            canonicalText: "Legacy paragraph"
        )],
        structure: LegacySourceStructure(orderedBlockIDs: [blockID]),
        evidence: [blockID: .web(locator: "article > p")]
    )

    let decoded = try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: JSONEncoder().encode(legacy)
    )

    #expect(decoded.importedMetadata.publishedAt == nil)
    #expect(decoded.blocks[0].category == .text)
    #expect(decoded.blocks[0].role == .paragraph)
    #expect(decoded.blocks[0].inlineMarkup.isEmpty)
    #expect(decoded.blocks[0].media == nil)
    #expect(decoded.structure.relations.isEmpty)
    #expect(decoded.issues.isEmpty)
}

@Test
func webSourceDocumentSemanticsRoundTrip() throws {
    let sourceURL = URL(string: "https://example.com")!
    let citationURL = URL(string: "https://example.com/citation")!
    let heading = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "A rich article",
        category: .text,
        role: .heading(level: 2),
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 0, utf16Length: 14),
                kind: .strong
            ),
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 2, utf16Length: 4),
                kind: .emphasis
            ),
        ]
    )
    let code = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "let value = 1",
        category: .code,
        role: .codeBlock(language: "swift"),
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 0, utf16Length: 3),
                kind: .inlineCode
            )
        ]
    )
    let image = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Knowledge graph",
        category: .media,
        role: .image,
        media: SourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/knowledge/graph.png",
            mimeType: "image/png",
            altText: "Knowledge graph",
            pixelWidth: 640,
            pixelHeight: 480
        )
    )
    let caption = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Read the source",
        category: .text,
        role: .caption,
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 0, utf16Length: 4),
                kind: .link(sourceURL)
            ),
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 5, utf16Length: 10),
                kind: .citation(citationURL)
            ),
        ]
    )
    let blocks = [heading, code, image, caption]
    let content = SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Rich",
            author: "Fixture Author",
            publishedAt: Date(timeIntervalSince1970: 1_700_000_000)
        ),
        blocks: blocks,
        structure: SourceStructure(
            orderedBlockIDs: blocks.map(\.id),
            relations: [
                SourceRelation(
                    sourceBlockID: caption.id,
                    targetBlockID: image.id,
                    kind: .captionForMedia
                )
            ]
        ),
        evidence: Dictionary(uniqueKeysWithValues: blocks.map {
            ($0.id, .web(locator: "#\($0.id.rawValue.uuidString)"))
        }),
        issues: [
            ImportIssue(
                code: .optionalWebImageUnavailable,
                relatedBlockID: image.id
            )
        ]
    )

    let data = try JSONEncoder().encode(content)
    let decoded = try JSONDecoder().decode(SourceDocumentContent.self, from: data)

    #expect(decoded == content)
}

@Test
func sourceBlockRoleUsesStableTaggedJSON() throws {
    let fixtures: [(SourceBlockRole, [String: Any])] = [
        (.heading(level: 2), ["type": "heading", "level": 2]),
        (.paragraph, ["type": "paragraph"]),
        (.listItem, ["type": "listItem"]),
        (.quotation, ["type": "quotation"]),
        (.codeBlock(language: "swift"), [
            "type": "codeBlock",
            "language": "swift",
        ]),
        (.codeBlock(language: nil), ["type": "codeBlock"]),
        (.image, ["type": "image"]),
        (.caption, ["type": "caption"]),
    ]

    for (role, expectedJSON) in fixtures {
        let data = try JSONEncoder().encode(role)
        let actualJSON = try #require(
            JSONSerialization.jsonObject(with: data) as? NSDictionary
        )
        #expect(actualJSON == expectedJSON as NSDictionary)
        #expect(try JSONDecoder().decode(SourceBlockRole.self, from: data) == role)
    }

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            SourceBlockRole.self,
            from: Data(#"{"type":"futureRole"}"#.utf8)
        )
    }
}

@Test
func inlineMarkupKindUsesStableTaggedJSON() throws {
    let linkURL = URL(string: "https://example.com/article")!
    let citationURL = URL(string: "https://example.com/source")!
    let fixtures: [(InlineMarkupKind, [String: Any])] = [
        (.emphasis, ["type": "emphasis"]),
        (.strong, ["type": "strong"]),
        (.link(linkURL), [
            "type": "link",
            "url": "https://example.com/article",
        ]),
        (.citation(citationURL), [
            "type": "citation",
            "url": "https://example.com/source",
        ]),
        (.citation(nil), ["type": "citation"]),
        (.inlineCode, ["type": "inlineCode"]),
    ]

    for (kind, expectedJSON) in fixtures {
        let data = try JSONEncoder().encode(kind)
        let actualJSON = try #require(
            JSONSerialization.jsonObject(with: data) as? NSDictionary
        )
        #expect(actualJSON == expectedJSON as NSDictionary)
        #expect(try JSONDecoder().decode(InlineMarkupKind.self, from: data) == kind)
    }

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            InlineMarkupKind.self,
            from: Data(#"{"type":"futureMarkup"}"#.utf8)
        )
    }
}

@Test
func persistedSemanticEnumsDecodeLegacySynthesizedJSON() throws {
    let roleFixtures: [(String, SourceBlockRole)] = [
        (#"{"heading":{"level":2}}"#, .heading(level: 2)),
        (#"{"paragraph":{}}"#, .paragraph),
        (#"{"codeBlock":{"language":"swift"}}"#, .codeBlock(language: "swift")),
    ]
    for (json, expected) in roleFixtures {
        #expect(try JSONDecoder().decode(
            SourceBlockRole.self,
            from: Data(json.utf8)
        ) == expected)
    }

    let markupFixtures: [(String, InlineMarkupKind)] = [
        (#"{"emphasis":{}}"#, .emphasis),
        (
            #"{"link":{"_0":"https://example.com/article"}}"#,
            .link(URL(string: "https://example.com/article")!)
        ),
        (
            #"{"citation":{"_0":"https://example.com/source"}}"#,
            .citation(URL(string: "https://example.com/source")!)
        ),
        (#"{"citation":{}}"#, .citation(nil)),
    ]
    for (json, expected) in markupFixtures {
        #expect(try JSONDecoder().decode(
            InlineMarkupKind.self,
            from: Data(json.utf8)
        ) == expected)
    }
}

@Test
func utf16MarkupRangeEndingAtTextBoundaryIsValid() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "A😀",
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 1, utf16Length: 2),
                kind: .emphasis
            )
        ]
    )

    let decoded = try JSONDecoder().decode(
        SourceBlock.self,
        from: JSONEncoder().encode(block)
    )

    #expect(decoded == block)
}

@Test
func utf16MarkupRangesMustAlignWithStringIndices() throws {
    let invalidRanges = [
        SourceTextRange(utf16Offset: 2, utf16Length: 1),
        SourceTextRange(utf16Offset: 1, utf16Length: 1),
    ]

    for range in invalidRanges {
        let data = try JSONEncoder().encode(
            UncheckedSemanticSourceBlock(
                id: SourceBlockID(),
                canonicalText: "A😀B",
                category: .text,
                role: .paragraph,
                inlineMarkup: [InlineMarkup(range: range, kind: .emphasis)],
                media: nil
            )
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceBlock.self, from: data)
        }
    }

    let valid = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "A😀B",
        inlineMarkup: [InlineMarkup(
            range: SourceTextRange(utf16Offset: 1, utf16Length: 2),
            kind: .emphasis
        )]
    )

    #expect(try JSONDecoder().decode(
        SourceBlock.self,
        from: JSONEncoder().encode(valid)
    ) == valid)
}

@Test
func decodingRejectsNegativeOrZeroSourceTextRanges() throws {
    for range in [
        UncheckedSourceTextRange(utf16Offset: -1, utf16Length: 1),
        UncheckedSourceTextRange(utf16Offset: 0, utf16Length: 0),
    ] {
        let data = try JSONEncoder().encode(range)
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceTextRange.self, from: data)
        }
    }
}

@Test
func decodingRejectsMarkupBeyondCanonicalText() throws {
    let data = try JSONEncoder().encode(
        UncheckedSemanticSourceBlock(
            id: SourceBlockID(),
            canonicalText: "short",
            category: .text,
            role: .paragraph,
            inlineMarkup: [
                InlineMarkup(
                    range: SourceTextRange(utf16Offset: 4, utf16Length: 2),
                    kind: .strong
                )
            ],
            media: nil
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceBlock.self, from: data)
    }
}

@Test
func decodingRejectsUnsafeInlineDestinations() throws {
    for kind in [
        InlineMarkupKind.link(URL(fileURLWithPath: "/tmp/source")),
        InlineMarkupKind.citation(URL(string: "javascript:alert(1)")),
    ] {
        let data = try JSONEncoder().encode(
            UncheckedSemanticSourceBlock(
                id: SourceBlockID(),
                canonicalText: "unsafe",
                category: .text,
                role: .paragraph,
                inlineMarkup: [
                    InlineMarkup(
                        range: SourceTextRange(utf16Offset: 0, utf16Length: 6),
                        kind: kind
                    )
                ],
                media: nil
            )
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceBlock.self, from: data)
        }
    }
}

@Test
func decodingRejectsHostlessInlineWebDestinations() throws {
    let unsafeURLs = [
        URL(string: "https:///article")!,
        URL(string: "http:relative")!,
    ]

    for url in unsafeURLs {
        for kind in [
            InlineMarkupKind.link(url),
            InlineMarkupKind.citation(url),
        ] {
            let data = try JSONEncoder().encode(
                UncheckedSemanticSourceBlock(
                    id: SourceBlockID(),
                    canonicalText: "unsafe",
                    category: .text,
                    role: .paragraph,
                    inlineMarkup: [
                        InlineMarkup(
                            range: SourceTextRange(utf16Offset: 0, utf16Length: 6),
                            kind: kind
                        )
                    ],
                    media: nil
                )
            )

            #expect(throws: DecodingError.self) {
                try JSONDecoder().decode(SourceBlock.self, from: data)
            }
        }
    }
}

@Test
func decodingAllowsNestedMarkupButRejectsCrossingOverlap() throws {
    let nested = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "0123456789",
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 0, utf16Length: 10),
                kind: .emphasis
            ),
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 3, utf16Length: 2),
                kind: .strong
            ),
        ]
    )
    let crossing = UncheckedSemanticSourceBlock(
        id: SourceBlockID(),
        canonicalText: "0123456789",
        category: .text,
        role: .paragraph,
        inlineMarkup: [
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 0, utf16Length: 5),
                kind: .emphasis
            ),
            InlineMarkup(
                range: SourceTextRange(utf16Offset: 3, utf16Length: 5),
                kind: .strong
            ),
        ],
        media: nil
    )

    #expect(try JSONDecoder().decode(
        SourceBlock.self,
        from: JSONEncoder().encode(nested)
    ) == nested)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(
            SourceBlock.self,
            from: JSONEncoder().encode(crossing)
        )
    }
}

@Test
func decodingRejectsInvalidMediaReferences() throws {
    let invalidReferences = [
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "/assets/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/../image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets//image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "images/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: 0,
            pixelHeight: -1
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "text/plain",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: 640,
            pixelHeight: nil
        ),
        UncheckedSourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: 480
        ),
    ]

    for reference in invalidReferences {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SourceMediaReference.self,
                from: JSONEncoder().encode(reference)
            )
        }
    }

    let normalizedMIME = SourceMediaReference(
        kind: .image,
        artifactRelativePath: "assets/image.png",
        mimeType: " IMAGE/PNG \n",
        altText: nil,
        pixelWidth: 640,
        pixelHeight: 480
    )
    #expect(try JSONDecoder().decode(
        SourceMediaReference.self,
        from: JSONEncoder().encode(normalizedMIME)
    ) == normalizedMIME)
}

@Test
func decodingRejectsInvalidBlockCategoryRoleOrEmptyMediaText() throws {
    let invalidBlocks = [
        UncheckedSemanticSourceBlock(
            id: SourceBlockID(),
            canonicalText: "code",
            category: .text,
            role: .codeBlock(language: nil),
            inlineMarkup: [],
            media: nil
        ),
    ]

    for block in invalidBlocks {
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SourceBlock.self,
                from: JSONEncoder().encode(block)
            )
        }
    }
}

@Test
func mediaBlockWithCanonicalAltTextSurvivesOptionalImageFailure() throws {
    let block = UncheckedSemanticSourceBlock(
        id: SourceBlockID(),
        canonicalText: "Unavailable image description",
        category: .media,
        role: .image,
        inlineMarkup: [],
        media: nil
    )

    let decoded = try JSONDecoder().decode(
        SourceBlock.self,
        from: JSONEncoder().encode(block)
    )

    #expect(decoded.category == .media)
    #expect(decoded.role == .image)
    #expect(decoded.media == nil)
}

@Test
func emptyImageCanonicalTextRequiresLocalizedMedia() throws {
    let unavailable = try JSONEncoder().encode(
        UncheckedSemanticSourceBlock(
            id: SourceBlockID(),
            canonicalText: "",
            category: .media,
            role: .image,
            inlineMarkup: [],
            media: nil
        )
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceBlock.self, from: unavailable)
    }

    let localizedMedia = SourceMediaReference(
        kind: .image,
        artifactRelativePath: "assets/image.png",
        mimeType: "image/png",
        altText: nil,
        pixelWidth: nil,
        pixelHeight: nil
    )
    let localized = try JSONEncoder().encode(
        UncheckedSemanticSourceBlock(
            id: SourceBlockID(),
            canonicalText: "",
            category: .media,
            role: .image,
            inlineMarkup: [],
            media: localizedMedia
        )
    )
    let decoded = try JSONDecoder().decode(SourceBlock.self, from: localized)
    #expect(decoded.media == localizedMedia)
}

@Test
func decodingRejectsInvalidHeadingLevel() throws {
    for level in [0, 7] {
        let block = UncheckedSourceBlockWithRole(
            id: SourceBlockID(),
            canonicalText: "Heading",
            category: .text,
            role: .heading(level: level),
            inlineMarkup: [],
            media: nil
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(
                SourceBlock.self,
                from: JSONEncoder().encode(block)
            )
        }
    }
}

@Test
func decodingRejectsInvalidRelationsAndIssueReferences() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Caption",
        role: .caption
    )
    let unknownID = SourceBlockID()
    let evidence: [SourceBlockID: SourceEvidence] = [
        block.id: .web(locator: "article > figcaption")
    ]
    let invalidStructures = [
        SourceStructure(
            orderedBlockIDs: [block.id],
            relations: [
                SourceRelation(
                    sourceBlockID: block.id,
                    targetBlockID: unknownID,
                    kind: .captionForMedia
                )
            ]
        ),
        SourceStructure(
            orderedBlockIDs: [block.id],
            relations: [
                SourceRelation(
                    sourceBlockID: block.id,
                    targetBlockID: block.id,
                    kind: .captionForMedia
                ),
                SourceRelation(
                    sourceBlockID: block.id,
                    targetBlockID: block.id,
                    kind: .captionForMedia
                ),
            ]
        ),
    ]

    for structure in invalidStructures {
        let data = try JSONEncoder().encode(
            UncheckedSourceDocumentContent(
                documentID: SourceDocumentID(),
                importedMetadata: ImportedDocumentMetadata(
                    title: "Fixture",
                    author: nil
                ),
                blocks: [block],
                structure: structure,
                evidence: evidence,
                issues: []
            )
        )
        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceDocumentContent.self, from: data)
        }
    }

    let issueData = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [block],
            structure: SourceStructure(orderedBlockIDs: [block.id]),
            evidence: evidence,
            issues: [
                ImportIssue(
                    code: .optionalWebImageUnavailable,
                    relatedBlockID: unknownID
                )
            ]
        )
    )
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: issueData)
    }
}

@Test
func captionForMediaRequiresDistinctCaptionAndImageBlocks() throws {
    let caption = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Caption",
        role: .caption
    )
    let secondCaption = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Another caption",
        role: .caption
    )
    let paragraph = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Paragraph"
    )
    let image = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Image",
        category: .media,
        role: .image,
        media: SourceMediaReference(
            kind: .image,
            artifactRelativePath: "assets/image.png",
            mimeType: "image/png",
            altText: nil,
            pixelWidth: nil,
            pixelHeight: nil
        )
    )
    let blocks = [caption, secondCaption, paragraph, image]
    let evidence = Dictionary(uniqueKeysWithValues: blocks.map {
        ($0.id, SourceEvidence.web(locator: "#\($0.id.rawValue.uuidString)"))
    })
    let invalidEndpoints = [
        (caption.id, caption.id),
        (caption.id, secondCaption.id),
        (paragraph.id, image.id),
        (caption.id, paragraph.id),
    ]

    for (sourceID, targetID) in invalidEndpoints {
        let data = try JSONEncoder().encode(
            UncheckedSourceDocumentContent(
                documentID: SourceDocumentID(),
                importedMetadata: ImportedDocumentMetadata(
                    title: "Fixture",
                    author: nil
                ),
                blocks: blocks,
                structure: SourceStructure(
                    orderedBlockIDs: blocks.map(\.id),
                    relations: [SourceRelation(
                        sourceBlockID: sourceID,
                        targetBlockID: targetID,
                        kind: .captionForMedia
                    )]
                ),
                evidence: evidence
            )
        )

        #expect(throws: DecodingError.self) {
            try JSONDecoder().decode(SourceDocumentContent.self, from: data)
        }
    }

    let valid = SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: blocks,
        structure: SourceStructure(
            orderedBlockIDs: blocks.map(\.id),
            relations: [SourceRelation(
                sourceBlockID: caption.id,
                targetBlockID: image.id,
                kind: .captionForMedia
            )]
        ),
        evidence: evidence
    )

    #expect(try JSONDecoder().decode(
        SourceDocumentContent.self,
        from: JSONEncoder().encode(valid)
    ) == valid)
}

@Test
func decodingRejectsEmptyContentFingerprint() throws {
    let data = try JSONEncoder().encode(
        UncheckedContentFingerprint(rawValue: "")
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(ContentFingerprint.self, from: data)
    }
}

@Test
func decodingRejectsZeroByteArtifact() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceArtifactDescriptor(
            kind: .webPackage,
            byteCount: 0,
            contentHash: "hash"
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceArtifactDescriptor.self, from: data)
    }
}

@Test
func decodingRejectsArtifactWithEmptyContentHash() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceArtifactDescriptor(
            kind: .pdf,
            byteCount: 1,
            contentHash: ""
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceArtifactDescriptor.self, from: data)
    }
}

@Test
func decodingRejectsBlockWithEmptyCanonicalText() throws {
    let data = try JSONEncoder().encode(
        UncheckedSourceBlock(
            id: SourceBlockID(),
            canonicalText: ""
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceBlock.self, from: data)
    }
}

@Test
func decodingRejectsDocumentGraphWithoutEvidenceCoverage() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [block],
            structure: SourceStructure(orderedBlockIDs: [block.id]),
            evidence: [:]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

@Test
func decodingRejectsDuplicateBlockIDs() throws {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [block, block],
            structure: SourceStructure(orderedBlockIDs: [block.id]),
            evidence: [block.id: .web(locator: "article > p")]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

@Test
func decodingRejectsDuplicateOrderedBlockIDs() throws {
    let first = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "First block"
    )
    let second = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Second block"
    )
    let data = try JSONEncoder().encode(
        UncheckedSourceDocumentContent(
            documentID: SourceDocumentID(),
            importedMetadata: ImportedDocumentMetadata(
                title: "Fixture",
                author: nil
            ),
            blocks: [first, second],
            structure: SourceStructure(
                orderedBlockIDs: [first.id, first.id]
            ),
            evidence: [
                first.id: .web(locator: "article > p:first-of-type"),
                second.id: .web(locator: "article > p:last-of-type")
            ]
        )
    )

    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(SourceDocumentContent.self, from: data)
    }
}

private struct UncheckedContentFingerprint: Encodable {
    let rawValue: String
}

private struct UncheckedSourceArtifactDescriptor: Encodable {
    let kind: SourceArtifactKind
    let byteCount: UInt64
    let contentHash: String
}

private struct UncheckedSourceBlock: Encodable {
    let id: SourceBlockID
    let canonicalText: String
}

private struct LegacyImportedDocumentMetadata: Encodable {
    let title: String
    let author: String?
}

private struct LegacySourceBlock: Encodable {
    let id: SourceBlockID
    let canonicalText: String
}

private struct LegacySourceStructure: Encodable {
    let orderedBlockIDs: [SourceBlockID]
}

private struct LegacySourceDocumentContent: Encodable {
    let documentID: SourceDocumentID
    let importedMetadata: LegacyImportedDocumentMetadata
    let blocks: [LegacySourceBlock]
    let structure: LegacySourceStructure
    let evidence: [SourceBlockID: SourceEvidence]
}

private struct UncheckedSourceTextRange: Encodable {
    let utf16Offset: Int
    let utf16Length: Int
}

private struct UncheckedSourceMediaReference: Encodable {
    let kind: SourceMediaReference.Kind
    let artifactRelativePath: String
    let mimeType: String
    let altText: String?
    let pixelWidth: Int?
    let pixelHeight: Int?
}

private struct UncheckedSemanticSourceBlock: Encodable {
    let id: SourceBlockID
    let canonicalText: String
    let category: SourceBlockCategory
    let role: SourceBlockRole
    let inlineMarkup: [InlineMarkup]
    let media: SourceMediaReference?
}

private enum UncheckedSourceBlockRole: Encodable {
    case heading(level: Int)
}

private struct UncheckedSourceBlockWithRole: Encodable {
    let id: SourceBlockID
    let canonicalText: String
    let category: SourceBlockCategory
    let role: UncheckedSourceBlockRole
    let inlineMarkup: [InlineMarkup]
    let media: SourceMediaReference?
}

private struct UncheckedSourceDocumentContent: Encodable {
    let documentID: SourceDocumentID
    let importedMetadata: ImportedDocumentMetadata
    let blocks: [SourceBlock]
    let structure: SourceStructure
    let evidence: [SourceBlockID: SourceEvidence]
    var issues: [ImportIssue] = []
}
