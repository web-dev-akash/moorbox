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
  issue. Moorbox currently has none beyond Apple frameworks. Don't add polling
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
| `Sources/MoorboxCore/` | SDK, repository, installer, AVD, emulator runtime, adb and diagnostics logic. Has no UI imports and is unit-tested. |
| `Sources/Moorbox/` | The SwiftUI app. Views read `AppModel`, and `AppModel` calls into MoorboxCore. |
| `Tests/MoorboxCoreTests/` | Unit tests, plus opt-in integration tests (`IntegrationTests.swift`). |
| `docs/` | Architecture decisions, roadmap, status, performance and QA checklist. |

The UI never builds emulator command lines itself. Runtime work goes through the
`AndroidRuntime` protocol (see `docs/architecture/ADR-001-runtime-strategy.md`).

## Building and testing

Requirements: macOS 14 or later, and Xcode 16 or later (Swift 6).

```sh
swift build                 # debug build
swift test                  # unit tests (no network, no emulator needed)
scripts/package-app.sh      # dist/Moorbox.app + zip
```

The integration tests use the real network, SDK and emulator, so they are
opt-in:

```sh
scripts/build-test-apk.sh                                      # needs a JDK 17+ and SDK build-tools
MOORBOX_INTEGRATION=1 swift test --filter IntegrationTests      # ~1 min, boots a temporary device
MOORBOX_INTEGRATION=1 MOORBOX_INTEGRATION_FRESH=1 swift test --filter fresh   # downloads ~1.3 GB
```

Integration tests create devices in a temporary AVD folder. They never touch
your own devices.

For UI work, `MOORBOX_SNAPSHOT_DIR=/some/dir swift run Moorbox` (debug builds
only) renders each screen to PNG and quits.

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
