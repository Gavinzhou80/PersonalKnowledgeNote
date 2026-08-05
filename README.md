# Personal Knowledge Note

A macOS personal knowledge application. The current workspace provides the testable foundation for Document Import.

## Requirements

- Apple Silicon Mac
- Xcode 26 or newer
- macOS 15 deployment target
- XcodeGen only when regenerating the checked-in Xcode project

## Module boundaries

- `KnowledgeCore`: domain and Document Import logic; no SwiftUI or Observation dependency.
- `LocalLibrary`: persistence and managed-file infrastructure; no SwiftUI or Observation dependency.
- `AppSupport`: app-facing adapters and presentation state built on the lower modules.
- `PersonalKnowledgeNote`: the SwiftUI macOS application target.

`LocalLibrary` depends on the domain values in `KnowledgeCore`; `KnowledgeCore` does not depend on `LocalLibrary`. GRDB.swift is pinned to exactly `7.11.1`, and the production package declares it directly only as an implementation dependency of `LocalLibrary`. `LocalLibraryTests` also declares direct access for storage assertions; `KnowledgeCore` and `AppSupport` do not import GRDB.

## Local Library publication seam

The publication seam centers on the public capability types `LocalLibrary`, `ImportWorkspace`, `StagedArtifact`, `PublicationOutcome`, and `LocatedSourceDocument`. Callers accept or recover an import workspace, stage an artifact, and finish publication through those capabilities. SQLite schema and table names, managed-file paths and layout, publication intents, provenance records, and crash-recovery coordination remain hidden inside `LocalLibrary`.

## Test the Swift package

Run from the repository root:

```bash
swift test
swift test -c release
swift build -c release
```

Web and PDF fixtures are bundled in the test-only `TestFixtures` target, so automated tests do not require public network access.

## Build the macOS application

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/xcode-t02 \
  build
```

A first dependency resolution in a clean checkout requires network access to fetch GRDB.swift. After dependencies are available, opening and running the empty Import Center does not require network access.

## Regenerate the Xcode project

The generated project is committed so clean builds require only Xcode. After changing `project.yml`, regenerate it with:

```bash
xcodegen generate
```
