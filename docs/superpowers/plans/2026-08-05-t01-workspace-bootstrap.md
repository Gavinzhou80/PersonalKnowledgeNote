# T01 Workspace Bootstrap Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (- [ ]) syntax for tracking.

**Goal:** Build a standard SwiftUI macOS application backed by independently testable KnowledgeCore, LocalLibrary, and AppSupport Swift package modules, with bundled Web/PDF test fixtures and repeatable clean-checkout verification.

**Architecture:** A checked-in Xcode project owns only the SwiftUI app lifecycle and consumes the local AppSupport package product. The Swift package enforces one-way dependencies from AppSupport to KnowledgeCore and LocalLibrary; core and infrastructure targets remain free of SwiftUI and Observation. A test-only TestFixtures target owns deterministic resources through Bundle.module.

**Tech Stack:** Swift 6 language mode, Swift Package Manager, SwiftUI for macOS 15+, Swift Testing, Xcode 26.5, XcodeGen for deterministic project maintenance.

---

## File map

- Package.swift — package products, dependency direction, macOS 15 platform, Swift 6 mode, test targets, and fixture resources.
- Sources/KnowledgeCore/KnowledgeCoreBoundary.swift — minimal public core-module marker.
- Sources/LocalLibrary/LocalLibraryBoundary.swift — minimal public infrastructure-module marker.
- Sources/AppSupport/AppSupportBoundary.swift — compile-time proof that app support sees the two lower modules.
- Sources/AppSupport/ImportCenterPresentation.swift — UI-independent empty-state data.
- Tests/Fixtures/FixtureCatalog.swift — test-only resource lookup through Bundle.module.
- Tests/Fixtures/Web/article.html — deterministic static Web fixture.
- Tests/Fixtures/PDF/minimal.pdf — small PDF fixture for bundle-access verification.
- Tests/KnowledgeCoreTests/KnowledgeCoreBoundaryTests.swift — core import smoke test.
- Tests/LocalLibraryTests/LocalLibraryBoundaryTests.swift — infrastructure import smoke test.
- Tests/AppSupportTests/AppSupportBoundaryTests.swift — dependency-direction smoke test.
- Tests/AppSupportTests/FixtureCatalogTests.swift — Web/PDF resource loading tests.
- Tests/AppSupportTests/ImportCenterPresentationTests.swift — empty-state behavior test.
- App/PersonalKnowledgeNoteApp.swift — SwiftUI application entry point.
- App/ImportCenterView.swift — empty Import Center UI.
- project.yml — deterministic XcodeGen source configuration.
- PersonalKnowledgeNote.xcodeproj/ — checked-in generated Xcode project.
- .gitignore — generated, editor, CodeGraph database, user-state, and sample-material exclusions.
- README.md — prerequisites, module boundaries, build, test, regeneration, and launch instructions.

### Task 1: Establish the modular Swift package boundaries

**Files:**
- Create: Package.swift
- Create: Sources/KnowledgeCore/KnowledgeCoreBoundary.swift
- Create: Sources/LocalLibrary/LocalLibraryBoundary.swift
- Create: Sources/AppSupport/AppSupportBoundary.swift
- Create: Tests/KnowledgeCoreTests/KnowledgeCoreBoundaryTests.swift
- Create: Tests/LocalLibraryTests/LocalLibraryBoundaryTests.swift
- Create: Tests/AppSupportTests/AppSupportBoundaryTests.swift

- [ ] **Step 1: Add the package manifest, empty source modules, and failing boundary tests**

Create Package.swift:

~~~swift
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
            dependencies: ["AppSupport"]
        ),
    ],
    swiftLanguageModes: [.v6]
)
~~~

Create each source file with only:

~~~swift
import Foundation
~~~

Create Tests/KnowledgeCoreTests/KnowledgeCoreBoundaryTests.swift:

~~~swift
import KnowledgeCore
import Testing

@Test
func knowledgeCoreIsIndependentlyImportable() {
    #expect(KnowledgeCoreBoundary.moduleName == "KnowledgeCore")
}
~~~

Create Tests/LocalLibraryTests/LocalLibraryBoundaryTests.swift:

~~~swift
import LocalLibrary
import Testing

@Test
func localLibraryIsIndependentlyImportable() {
    #expect(LocalLibraryBoundary.moduleName == "LocalLibrary")
}
~~~

Create Tests/AppSupportTests/AppSupportBoundaryTests.swift:

~~~swift
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
~~~

- [ ] **Step 2: Run the tests and verify the boundary types are missing**

Run:

~~~bash
swift test
~~~

Expected: FAIL during compilation because KnowledgeCoreBoundary, LocalLibraryBoundary, and AppSupportBoundary do not exist.

- [ ] **Step 3: Implement the minimum boundary types**

Replace Sources/KnowledgeCore/KnowledgeCoreBoundary.swift with:

~~~swift
import Foundation

public enum KnowledgeCoreBoundary {
    public static let moduleName = "KnowledgeCore"
}
~~~

Replace Sources/LocalLibrary/LocalLibraryBoundary.swift with:

~~~swift
import Foundation

public enum LocalLibraryBoundary {
    public static let moduleName = "LocalLibrary"
}
~~~

Replace Sources/AppSupport/AppSupportBoundary.swift with:

~~~swift
import KnowledgeCore
import LocalLibrary

public enum AppSupportBoundary {
    public static let dependencies = [
        KnowledgeCoreBoundary.moduleName,
        LocalLibraryBoundary.moduleName,
    ]
}
~~~

- [ ] **Step 4: Run the focused boundary tests**

Run:

~~~bash
swift test
~~~

Expected: PASS, 3 tests and 0 failures.

- [ ] **Step 5: Verify forbidden UI imports are absent from lower modules**

Run:

~~~bash
if rg -n '^import (SwiftUI|Observation)$' Sources/KnowledgeCore Sources/LocalLibrary; then
  exit 1
fi
~~~

Expected: exit 0 with no matches.

- [ ] **Step 6: Commit the package boundaries**

~~~bash
git add Package.swift Sources Tests/KnowledgeCoreTests Tests/LocalLibraryTests Tests/AppSupportTests/AppSupportBoundaryTests.swift
git commit -m "chore: establish Swift module boundaries"
~~~

### Task 2: Bundle deterministic Web and PDF fixtures

**Files:**
- Modify: Package.swift
- Create: Tests/Fixtures/FixtureCatalog.swift
- Create: Tests/Fixtures/Web/article.html
- Create: Tests/Fixtures/PDF/minimal.pdf
- Create: Tests/AppSupportTests/FixtureCatalogTests.swift

- [ ] **Step 1: Write the failing fixture-loading test**

Create Tests/AppSupportTests/FixtureCatalogTests.swift:

~~~swift
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
~~~

- [ ] **Step 2: Run the focused test and verify the fixture module is missing**

Run:

~~~bash
swift test --filter loadsWebAndPDFFixturesFromTheTestBundle
~~~

Expected: FAIL during compilation with no such module TestFixtures.

- [ ] **Step 3: Add the test-only fixture target**

Add this target before the test targets in Package.swift:

~~~swift
.target(
    name: "TestFixtures",
    path: "Tests/Fixtures",
    sources: ["FixtureCatalog.swift"],
    resources: [
        .copy("Web"),
        .copy("PDF"),
    ]
),
~~~

Change the AppSupportTests dependency list to:

~~~swift
dependencies: ["AppSupport", "TestFixtures"]
~~~

Create Tests/Fixtures/FixtureCatalog.swift:

~~~swift
import Foundation

public enum FixtureCatalog {
    public static let webArticleURL = requiredResource(
        name: "article",
        extension: "html",
        subdirectory: "Web"
    )

    public static let minimalPDFURL = requiredResource(
        name: "minimal",
        extension: "pdf",
        subdirectory: "PDF"
    )

    private static func requiredResource(
        name: String,
        extension fileExtension: String,
        subdirectory: String
    ) -> URL {
        guard let url = Bundle.module.url(
            forResource: name,
            withExtension: fileExtension,
            subdirectory: subdirectory
        ) else {
            preconditionFailure(
                "Missing fixture: \(subdirectory)/\(name).\(fileExtension)"
            )
        }

        return url
    }
}
~~~

Create Tests/Fixtures/Web/article.html:

~~~html
<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8">
    <title>Fixture Article</title>
  </head>
  <body>
    <article>
      <h1>Fixture Article</h1>
      <p>Deterministic offline content.</p>
    </article>
  </body>
</html>
~~~

Create Tests/Fixtures/PDF/minimal.pdf with this complete ASCII PDF:

~~~text
%PDF-1.4
1 0 obj
<< /Type /Catalog /Pages 2 0 R >>
endobj
2 0 obj
<< /Type /Pages /Kids [3 0 R] /Count 1 >>
endobj
3 0 obj
<< /Type /Page /Parent 2 0 R /MediaBox [0 0 200 200] /Resources << /Font << /F1 5 0 R >> >> /Contents 4 0 R >>
endobj
4 0 obj
<< /Length 43 >>
stream
BT
/F1 18 Tf
50 100 Td
(Fixture PDF) Tj
ET
endstream
endobj
5 0 obj
<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>
endobj
xref
0 6
0000000000 65535 f
0000000009 00000 n
0000000058 00000 n
0000000115 00000 n
0000000241 00000 n
0000000333 00000 n
trailer
<< /Size 6 /Root 1 0 R >>
startxref
403
%%EOF
~~~

Verify the fixture with:

~~~bash
file Tests/Fixtures/PDF/minimal.pdf
~~~

Expected: the file command identifies PDF document data.

- [ ] **Step 4: Run the fixture test**

Run:

~~~bash
swift test --filter loadsWebAndPDFFixturesFromTheTestBundle
~~~

Expected: PASS, 1 test and 0 failures.

- [ ] **Step 5: Run the complete package suite**

Run:

~~~bash
swift test
~~~

Expected: PASS, 4 tests and 0 failures.

- [ ] **Step 6: Commit the fixture bundle**

~~~bash
git add Package.swift Tests/Fixtures Tests/AppSupportTests/FixtureCatalogTests.swift
git commit -m "test: add bundled document fixtures"
~~~

### Task 3: Define the empty Import Center presentation

**Files:**
- Create: Sources/AppSupport/ImportCenterPresentation.swift
- Create: Tests/AppSupportTests/ImportCenterPresentationTests.swift

- [ ] **Step 1: Write the failing empty-state test**

Create Tests/AppSupportTests/ImportCenterPresentationTests.swift:

~~~swift
import AppSupport
import Testing

@Test
func emptyImportCenterExplainsThatNoImportsExist() {
    let presentation = ImportCenterPresentation.empty

    #expect(presentation.title == "Import Center")
    #expect(presentation.message == "No imports yet")
    #expect(presentation.systemImage == "tray")
}
~~~

- [ ] **Step 2: Run the test and verify the presentation type is missing**

Run:

~~~bash
swift test --filter emptyImportCenterExplainsThatNoImportsExist
~~~

Expected: FAIL during compilation because ImportCenterPresentation does not exist.

- [ ] **Step 3: Implement the minimum UI-independent presentation value**

Create Sources/AppSupport/ImportCenterPresentation.swift:

~~~swift
public struct ImportCenterPresentation: Equatable, Sendable {
    public let title: String
    public let message: String
    public let systemImage: String

    public init(title: String, message: String, systemImage: String) {
        self.title = title
        self.message = message
        self.systemImage = systemImage
    }

    public static let empty = ImportCenterPresentation(
        title: "Import Center",
        message: "No imports yet",
        systemImage: "tray"
    )
}
~~~

- [ ] **Step 4: Run the focused and complete package tests**

Run:

~~~bash
swift test --filter emptyImportCenterExplainsThatNoImportsExist
swift test
~~~

Expected: both commands PASS; the complete suite reports 5 tests and 0 failures.

- [ ] **Step 5: Commit the presentation seam**

~~~bash
git add Sources/AppSupport/ImportCenterPresentation.swift Tests/AppSupportTests/ImportCenterPresentationTests.swift
git commit -m "feat: define empty import center presentation"
~~~

### Task 4: Add the standard SwiftUI macOS application

**Files:**
- Create: project.yml
- Create: App/PersonalKnowledgeNoteApp.swift
- Create: App/ImportCenterView.swift
- Generate and commit: PersonalKnowledgeNote.xcodeproj/

- [ ] **Step 1: Create the SwiftUI application entry point**

Create App/PersonalKnowledgeNoteApp.swift:

~~~swift
import AppSupport
import SwiftUI

@main
struct PersonalKnowledgeNoteApp: App {
    var body: some Scene {
        WindowGroup("Import Center") {
            ImportCenterView(presentation: .empty)
        }
        .defaultSize(width: 720, height: 520)
    }
}
~~~

- [ ] **Step 2: Create the empty Import Center view**

Create App/ImportCenterView.swift:

~~~swift
import AppSupport
import SwiftUI

struct ImportCenterView: View {
    let presentation: ImportCenterPresentation

    var body: some View {
        ContentUnavailableView(
            presentation.title,
            systemImage: presentation.systemImage,
            description: Text(presentation.message)
        )
        .frame(minWidth: 560, minHeight: 360)
    }
}
~~~

- [ ] **Step 3: Add deterministic XcodeGen configuration**

Create project.yml:

~~~yaml
name: PersonalKnowledgeNote
options:
  createIntermediateGroups: true
  deploymentTarget:
    macOS: "15.0"
packages:
  PersonalKnowledgeNotePackage:
    path: .
targets:
  PersonalKnowledgeNote:
    type: application
    platform: macOS
    deploymentTarget: "15.0"
    sources:
      - path: App
    dependencies:
      - package: PersonalKnowledgeNotePackage
        product: AppSupport
    settings:
      base:
        PRODUCT_BUNDLE_IDENTIFIER: com.gavinzhou.PersonalKnowledgeNote
        PRODUCT_NAME: PersonalKnowledgeNote
        GENERATE_INFOPLIST_FILE: YES
        SWIFT_VERSION: 6.0
        SWIFT_STRICT_CONCURRENCY: complete
        CODE_SIGNING_ALLOWED: NO
schemes:
  PersonalKnowledgeNote:
    build:
      targets:
        PersonalKnowledgeNote: all
    run:
      config: Debug
~~~

- [ ] **Step 4: Generate the checked-in Xcode project**

Run:

~~~bash
xcodegen generate
~~~

Expected: PersonalKnowledgeNote.xcodeproj is generated without errors.

- [ ] **Step 5: Build the macOS application**

Run:

~~~bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  build
~~~

Expected: BUILD SUCCEEDED and .build/xcode/Build/Products/Debug/PersonalKnowledgeNote.app exists.

- [ ] **Step 6: Launch the built application for a smoke check**

Run:

~~~bash
open .build/xcode/Build/Products/Debug/PersonalKnowledgeNote.app
sleep 2
pgrep -x PersonalKnowledgeNote
pkill -x PersonalKnowledgeNote
~~~

Expected: pgrep prints a process ID before the app is closed. The visible window contains the Import Center empty state and requires no network or credentials.

- [ ] **Step 7: Commit the application shell**

~~~bash
git add App project.yml PersonalKnowledgeNote.xcodeproj
git commit -m "feat: add macOS import center shell"
~~~

### Task 5: Document and protect the workspace

**Files:**
- Create: README.md
- Modify: .gitignore
- Modify: docs/superpowers/specs/2026-08-05-t01-workspace-bootstrap-design.md

- [ ] **Step 1: Expand the repository ignore rules**

Set .gitignore to:

~~~gitignore
.build/
.codegraph/
.cursor/
DerivedData/
xcuserdata/
*.xcuserstate
.DS_Store
mats/
~~~

- [ ] **Step 2: Document the workspace**

Create README.md:

~~~markdown
# Personal Knowledge Note

A macOS personal knowledge application. The current workspace provides the testable foundation for Document Import.

## Requirements

- Apple Silicon Mac
- Xcode 26 or newer
- macOS 15 deployment target
- XcodeGen only when regenerating the checked-in Xcode project

## Module boundaries

- KnowledgeCore: domain and Document Import logic; no SwiftUI or Observation dependency.
- LocalLibrary: persistence and managed-file infrastructure; no SwiftUI or Observation dependency.
- AppSupport: app-facing adapters and presentation state built on the lower modules.
- PersonalKnowledgeNote: the SwiftUI macOS application target.

## Test the Swift package

Run swift test from the repository root.

Web and PDF fixtures are bundled in the test-only TestFixtures target, so automated tests do not require public network access.

## Build the macOS application

Run:

    xcodebuild -project PersonalKnowledgeNote.xcodeproj -scheme PersonalKnowledgeNote -destination 'platform=macOS' build

## Regenerate the Xcode project

The generated project is committed so clean builds require only Xcode. After changing project.yml, run xcodegen generate.
~~~

- [ ] **Step 3: Mark the approved design as implementation-tracked**

Change the design header to:

~~~markdown
> Status: approved; implementation tracked by the T01 workspace bootstrap plan
~~~

- [ ] **Step 4: Verify documentation and ignore behavior**

Run:

~~~bash
git check-ignore -v mats mats/URL.md .build .codegraph .cursor
rg -n "macOS 15|swift test|xcodebuild|KnowledgeCore|LocalLibrary|AppSupport" README.md
git diff --check
~~~

Expected: generated/private paths are ignored, all required documentation terms are found, and git diff --check reports no whitespace errors.

- [ ] **Step 5: Commit workspace documentation**

~~~bash
git add .gitignore README.md docs/superpowers/specs/2026-08-05-t01-workspace-bootstrap-design.md
git commit -m "docs: document the macOS workspace"
~~~

### Task 6: Run release-level T01 verification

**Files:**
- Verify only; modify production files only if a command exposes a defect.

- [ ] **Step 1: Run the complete Swift package suite**

Run:

~~~bash
swift test
~~~

Expected: PASS, 5 tests and 0 failures.

- [ ] **Step 2: Build the checked-in Xcode project**

Run:

~~~bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS' \
  -derivedDataPath .build/xcode \
  build
~~~

Expected: BUILD SUCCEEDED.

- [ ] **Step 3: Prove the lower modules contain no UI-framework imports**

Run:

~~~bash
if rg -n '^import (SwiftUI|Observation)$' Sources/KnowledgeCore Sources/LocalLibrary; then
  exit 1
fi
~~~

Expected: exit 0 with no output.

- [ ] **Step 4: Verify a clean exported checkout**

Run:

~~~bash
clean_checkout="$(mktemp -d)"
git archive HEAD | tar -x -C "$clean_checkout"
swift test --package-path "$clean_checkout"
xcodebuild \
  -project "$clean_checkout/PersonalKnowledgeNote.xcodeproj" \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS' \
  -derivedDataPath "$clean_checkout/.build/xcode" \
  build
rm -rf "$clean_checkout"
~~~

Expected: the archived checkout completes both the package tests and Xcode build without untracked local files.

- [ ] **Step 5: Inspect the final change set**

Run:

~~~bash
git status --short
git log --oneline --decorate -8
~~~

Expected: T01 files are committed. Only pre-existing unrelated user changes, if any, remain uncommitted.

- [ ] **Step 6: Review against GitHub issue #2**

Confirm every criterion with the evidence above:

- clean checkout builds the application and passes swift test;
- KnowledgeCore, LocalLibrary, and AppSupport are separate targets;
- lower modules have no SwiftUI or Observation import;
- Web and PDF fixtures load from the test bundle;
- macOS 15 is documented and configured;
- the empty Import Center launches offline.

- [ ] **Step 7: Run the project code-review workflow**

Invoke .agents/skills/code-review/SKILL.md, address blocking findings, and rerun every affected verification command before declaring T01 complete.
