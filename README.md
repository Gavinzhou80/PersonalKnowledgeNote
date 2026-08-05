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

## Test the Swift package

Run from the repository root:

```bash
swift test
```

Web and PDF fixtures are bundled in the test-only `TestFixtures` target, so automated tests do not require public network access.

## Build the macOS application

```bash
xcodebuild \
  -project PersonalKnowledgeNote.xcodeproj \
  -scheme PersonalKnowledgeNote \
  -destination 'platform=macOS' \
  build
```

## Regenerate the Xcode project

The generated project is committed so clean builds require only Xcode. After changing `project.yml`, regenerate it with:

```bash
xcodegen generate
```
