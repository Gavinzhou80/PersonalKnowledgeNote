# T01 Workspace Bootstrap Design

> Status: approved; implementation tracked by the T01 workspace bootstrap plan
> Date: 2026-08-05
> Ticket: GitHub issue #2 — T01 Bootstrap the testable macOS workspace

## Goal

Create the smallest production-shaped foundation that provides both a real SwiftUI macOS application and independently testable Swift modules. The result must build and test from a clean checkout, open an empty Import Center without network access, and preserve the approved boundary that keeps SwiftUI lifetimes out of `KnowledgeCore`.

## Selected approach

Use a checked-in Xcode macOS application project backed by a local Swift package:

- the Xcode target produces the standard `.app` bundle and owns the SwiftUI application lifecycle;
- the local package owns `KnowledgeCore`, `LocalLibrary`, and `AppSupport` library targets;
- the app imports `AppSupport`, while `AppSupport` may depend on `KnowledgeCore` and `LocalLibrary`;
- neither `KnowledgeCore` nor `LocalLibrary` depends on SwiftUI or Observation.

The Xcode project will be generated deterministically from `project.yml` during development and committed so a clean checkout only requires Xcode to build. XcodeGen is a maintenance tool, not a runtime or clean-build dependency.

## Project structure

```text
Package.swift
project.yml
PersonalKnowledgeNote.xcodeproj/
App/
├── PersonalKnowledgeNoteApp.swift
└── ImportCenterView.swift
Sources/
├── KnowledgeCore/
│   └── KnowledgeCore.swift
├── LocalLibrary/
│   └── LocalLibrary.swift
└── AppSupport/
    └── ImportCenterPresentation.swift
Tests/
├── KnowledgeCoreTests/
│   └── KnowledgeCoreBoundaryTests.swift
├── LocalLibraryTests/
│   └── LocalLibraryBoundaryTests.swift
├── AppSupportTests/
│   ├── AppSupportBoundaryTests.swift
│   ├── FixtureCatalogTests.swift
│   └── ImportCenterPresentationTests.swift
└── Fixtures/
    ├── FixtureCatalog.swift
    ├── Web/
    │   └── article.html
    └── PDF/
        └── minimal.pdf
README.md
```

The lower module source files are deliberately empty of domain behavior. T01 proves module visibility, dependency direction, fixture loading, and application assembly through the Package manifest and compiler rather than introducing public marker APIs.

## Dependency direction

```text
PersonalKnowledgeNoteApp (SwiftUI)
              |
              v
          AppSupport
          /        \
         v          v
 KnowledgeCore   LocalLibrary
```

- `KnowledgeCore` uses Foundation only and remains independently testable.
- `LocalLibrary` establishes the infrastructure boundary but contains no persistence implementation in T01.
- `AppSupport` provides the initial empty Import Center presentation data without owning a SwiftUI view.
- SwiftUI exists only in the application target.
- GRDB is deferred until the Local Library publication seam ticket needs real persistence; T01 remains dependency-free and fully offline.

## Application shell

The application opens one standard macOS window titled “Import Center”. The content shows an empty state explaining that no imports have been added. It performs no networking, file acquisition, persistence, or background work.

The view receives its display state from `AppSupport`. This proves the app-facing boundary while avoiding premature task-store behavior that belongs to a later ticket.

## Platform policy

Set the deployment target to macOS 15. The development environment is Xcode 26.5 on Apple Silicon, and macOS 15 is the previous major release relative to macOS 26. This implements the approved current-and-previous-major-version support policy.

Use Swift tools version 6.0 and Swift language mode 6 so the package has explicit concurrency semantics without requiring the newest installed compiler version in its manifest.

## Test strategy

Use test-first development for behavior-bearing source files:

1. A `KnowledgeCore` smoke test fails until the core boundary is importable.
2. An `AppSupport` test fails until the empty Import Center presentation is implemented.
3. Fixture-loading tests fail until Web and PDF resources are configured in the test bundle.
4. `swift test` verifies all package targets without launching SwiftUI.
5. `xcodebuild` verifies the checked-in macOS application project and local-package integration.
6. A manual launch smoke check verifies that the built app opens the empty Import Center without network setup.

The Web fixture is a deterministic static HTML document. The PDF fixture is a tiny valid checked-in PDF intended only to prove bundle resource access; representative parsing fixtures belong to later tickets.

## Build and verification commands

```bash
swift test
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS' \
  build
```

`README.md` will document these commands, the macOS 15 deployment target, project regeneration with XcodeGen, and the module boundaries.

## Error and scope boundaries

T01 has no runtime import workflow, so it introduces no import errors, retry behavior, database schema, or network adapters. Build failures are surfaced by SwiftPM or Xcode. Missing fixtures fail focused tests with the expected resource name.

Explicitly deferred:

- Document Import public interfaces and domain models;
- GRDB and SQLite storage;
- PDFKit and WebKit adapters;
- durable task state and recovery;
- SwiftUI Observation task adapters;
- signing, sandbox entitlements, and distribution configuration beyond what is required for a local debug application.

## Acceptance mapping

- Clean checkout builds and tests: checked-in Xcode project plus `swift test` and `xcodebuild` commands.
- Separate boundaries: distinct `KnowledgeCore`, `LocalLibrary`, and `AppSupport` package targets.
- Core independence: `KnowledgeCore` imports no SwiftUI or Observation module.
- Fixture access: the test-only `TestFixtures` target loads Web and PDF resources through `Bundle.module` for package tests.
- Deployment policy: macOS 15 is declared in both SwiftPM and Xcode configuration and documented in `README.md`.
- Offline Import Center: the app shell contains only local presentation state and launches without configuration or network access.
