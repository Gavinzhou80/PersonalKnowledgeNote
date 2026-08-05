import AppSupport
import Testing

@Test
func appSupportSeesOnlyTheApprovedLowerModules() {
    #expect(
        AppSupportBoundary.dependencies == [
            "KnowledgeCore",
            "LocalLibrary",
        ]
    )
}
