import AppSupport
import Testing

@Test
func emptyImportCenterExplainsThatNoImportsExist() {
    let presentation = ImportCenterPresentation.empty

    #expect(presentation.title == "Import Center")
    #expect(presentation.message == "No imports yet")
    #expect(presentation.systemImage == "tray")
}
