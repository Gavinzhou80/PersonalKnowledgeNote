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
        .library(name: "AppSupport", targets: ["AppSupport"]),
    ],
    targets: [
        .target(name: "KnowledgeCore"),
        .target(name: "LocalLibrary"),
        .target(
            name: "AppSupport",
            dependencies: ["KnowledgeCore", "LocalLibrary"]
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
            dependencies: ["LocalLibrary"]
        ),
        .testTarget(
            name: "AppSupportTests",
            dependencies: ["AppSupport", "TestFixtures"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
