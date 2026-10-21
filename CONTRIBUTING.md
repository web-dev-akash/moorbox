# Contributing to Moorbox

Thanks for helping! Moorbox aims to be a small, honest, native macOS tool. Please
read this before opening a pull request.

## Ground rules

- **Real functionality only.** Every control in the UI must invoke a real
  operation and show its actual result. Don't add placeholder buttons or
  simulated states.
- **Measure before claiming.** Performance claims need numbers from the
  procedure in [`docs/PERFORMANCE.md`](docs/PERFORMANCE.md).
- **Keep it light.** Don't add dependencies without discussing them first in an
  issue. Moorbox currently has none beyond Apple frameworks.
- **Ask, don't work around.** If something required is missing, the app explains
  what and asks before installing it. Never bypass macOS security (Gatekeeper,
  quarantine, privileges). Don't add polling
  loops, background daemons, or work at launch that the home screen doesn't
  need.
- **Respect licenses.** Never commit or bundle Android SDK components, system
  images, APKs or device data. See
  [`THIRD_PARTY_NOTICES.md`](THIRD_PARTY_NOTICES.md).
- **Security.** Run tools with argument arrays, never through a shell. Validate
  anything that reaches `adb shell`. Never delete user data automatically.

## Layout

| Path | What lives there |
|---|---|
| `Sources/MoorboxCore/` | Swift package with all logic: repository catalog, verified installer, the Android CLI, `avdmanager` and Java wrappers, AVD store, emulator runtime, adb, diagnostics. No UI imports. |
| `App/` | The SwiftUI app (`Sources/`, `Resources/Assets.xcassets`). Views read `AppModel`, and `AppModel` calls MoorboxCore. |
| `Tests/MoorboxCoreTests/` | Unit tests, plus opt-in integration tests (`IntegrationTests.swift`) and recorded fixtures of real tool output |
| `UITests/` | XCUITest suite, run against a fake SDK and device folder |
| `project.yml` | XcodeGen spec. `Moorbox.xcodeproj` is generated, not committed. |
| `packaging/homebrew/` | Homebrew formula template (build from source) |
| `docs/` | ADRs, observed tool behavior, roadmap, status, performance, QA checklist |

The UI never builds tool command lines itself. Device lifecycle goes through the
`AndroidRuntime` protocol. SDK installs go through `AndroidCLI`, which always passes
`--no-metrics`, and device creation through `AVDManager`. See
`docs/architecture/ADR-002-official-sdk-tools.md`.

## Building and testing

Requirements:

- macOS 14 or later and Xcode 16 or later (Swift 6);
- `brew install xcodegen swiftlint swiftformat create-dmg`.

```sh
make project            # generate Moorbox.xcodeproj
make run                # debug build + launch
make lint               # must pass: SwiftFormat --lint + SwiftLint --strict
make format             # apply SwiftFormat
make test-core          # unit tests (no network, SDK or emulator)
make test-ui            # XCUITest (needs permission for the test runner to control the Mac)
make dmg                # universal Release app + DMG in dist/
```

Integration tests use the real network, Google's tools and the emulator. They
create their own SDK and device folders and never touch yours:

```sh
make test-integration                                   # needs a JDK 17+ and an Android SDK with an arm64 image
MOORBOX_INTEGRATION_JDK=1 make test-integration         # + Temurin install (~200 MB)
MOORBOX_INTEGRATION_FRESH=1 make test-integration       # + full SDK from scratch (~1.4 GB)
```

**When adding parsing for a Google tool**, record real output as a fixture in
`Tests/MoorboxCoreTests/Fixtures/` and test against it. Document any surprising
behavior in `docs/architecture/emulator-behavior.md`.

**UI tests** should find elements by accessibility identifier and should paste text
rather than call `typeText`, because synthetic typing fails with some keyboard
layouts.

## Pull requests

- Keep each pull request focused.
- Add or update tests for logic changes.
- Run `swift test` before pushing.
- Describe what you verified, and on which Mac, macOS and Android image.
- Add an entry under `[Unreleased]` in `CHANGELOG.md`.

## Releases

The maintainer flow:

1. Bump `VERSION`.
2. Move the changelog entries under the new version.
3. Tag the release as `v<version>`.

The release workflow then builds the app. Signing and notarization run only when
the maintainer has configured the repository secrets described in `README.md`.
