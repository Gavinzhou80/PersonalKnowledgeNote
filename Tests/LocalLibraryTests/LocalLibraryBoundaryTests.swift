import LocalLibrary
import Testing

@Test
func localLibraryIsIndependentlyImportable() {
    #expect(LocalLibraryBoundary.moduleName == "LocalLibrary")
}
