import Foundation
import KnowledgeCore
@testable import LocalLibrary

func makeTemporaryLibraryRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appending(path: "PersonalKnowledgeNote-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root,
        withIntermediateDirectories: true
    )
    return root
}

func makeFixtureContent() -> SourceDocumentContent {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    return SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: "Fixture",
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [block.id: .web(locator: "article > p")]
    )
}
