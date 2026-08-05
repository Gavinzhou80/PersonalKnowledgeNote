import Foundation

public enum OriginalSource: Hashable, Codable, Sendable {
    case webpage(URL)
    case pdfFile(URL)
}

public enum ExistingDocumentLocation: String, Hashable, Codable, Sendable {
    case library
    case trash
}
