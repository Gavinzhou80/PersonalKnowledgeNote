import Foundation
import TestFixtures
import Testing

@Test
func loadsWebAndPDFFixturesFromTheTestBundle() throws {
    let html = try String(
        contentsOf: FixtureCatalog.webArticleURL,
        encoding: .utf8
    )
    let pdf = try Data(contentsOf: FixtureCatalog.minimalPDFURL)

    #expect(html.contains("<article>"))
    #expect(pdf.starts(with: Data("%PDF-".utf8)))
}
