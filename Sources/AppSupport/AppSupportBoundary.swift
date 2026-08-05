import KnowledgeCore
import LocalLibrary

public enum AppSupportBoundary {
    public static let dependencies = [
        KnowledgeCoreBoundary.moduleName,
        LocalLibraryBoundary.moduleName,
    ]
}
