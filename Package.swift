// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "PersonalKnowledgeNote",
    platforms: [
        .macOS(.v15),
    ],
    products: [
        .library(name: "KnowledgeCore", targets: ["KnowledgeCore"]),
        .library(name: "LocalLibrary", targets: ["LocalLibrary"]),
        .library(name: "DocumentImport", targets: ["DocumentImport"]),
        .library(name: "AppSupport", targets: ["AppSupport"]),
    ],
    dependencies: [
        .package(
            url: "https://github.com/groue/GRDB.swift.git",
            exact: "7.11.1"
        ),
    ],
    targets: [
        .target(name: "KnowledgeCore"),
        .target(
            name: "LocalLibrary",
            dependencies: [
                "KnowledgeCore",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .target(
            name: "DocumentImport",
            dependencies: ["KnowledgeCore", "LocalLibrary"]
        ),
        .target(
            name: "AppSupport",
            dependencies: ["KnowledgeCore", "LocalLibrary", "DocumentImport"]
        ),
        .target(
            name: "TestFixtures",
            path: "Tests/Fixtures",
            sources: ["FixtureCatalog.swift"],
            resources: [
                .copy("Web"),
                .copy("PDF"),
            ]
        ),
        .testTarget(
            name: "KnowledgeCoreTests",
            dependencies: ["KnowledgeCore"]
        ),
        .testTarget(
            name: "LocalLibraryTests",
            dependencies: [
                "LocalLibrary",
                "TestFixtures",
                .product(name: "GRDB", package: "GRDB.swift"),
            ]
        ),
        .testTarget(
            name: "DocumentImportTests",
            dependencies: [
                "DocumentImport",
                "KnowledgeCore",
                "LocalLibrary",
                "TestFixtures",
            ]
        ),
        .testTarget(
            name: "AppSupportTests",
            dependencies: ["AppSupport", "TestFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
