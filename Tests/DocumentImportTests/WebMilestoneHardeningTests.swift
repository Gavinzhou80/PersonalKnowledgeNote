import Testing

@testable import DocumentImport
import LocalLibrary

@Suite("Web milestone hardening")
struct WebMilestoneHardeningTests {
    @Test func classifyMapsInsufficientDiskSpaceToTypedRequiresUserActionFailure() {
        let failure = DocumentImport.classify(LocalLibraryError.insufficientDiskSpace)

        #expect(failure.code == .insufficientDiskSpace)
        #expect(failure.recovery == .requiresUserAction)
    }
}
