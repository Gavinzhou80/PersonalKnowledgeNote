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

func removeTemporaryLibraryRoot(_ root: URL) {
    try? FileManager.default.removeItem(at: root)
}

func makeFixtureContent(titled title: String = "Fixture")
    -> SourceDocumentContent {
    let block = SourceBlock(
        id: SourceBlockID(),
        canonicalText: "Fixture document"
    )
    return SourceDocumentContent(
        documentID: SourceDocumentID(),
        importedMetadata: ImportedDocumentMetadata(
            title: title,
            author: nil
        ),
        blocks: [block],
        structure: SourceStructure(orderedBlockIDs: [block.id]),
        evidence: [block.id: .web(locator: "article > p")]
    )
}
