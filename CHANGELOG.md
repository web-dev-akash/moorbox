# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version in `VERSION` is the
source of truth; release tags are `v<version>`.

## [Unreleased]

### Added
- **Player window.** Running devices appear in Moorbox's own window: the Android
  screen streams over the emulator's local gRPC service using shared memory.
  - Mouse becomes touch, the trackpad scrolls, and the keyboard types.
  - A BlueStacks-style side toolbar: Back, Home, Recents, volume, rotate,
    screenshot, install APK and stop.
  - Drag an APK onto the screen to install it.
  - The emulator's own window remains available in Settings → Display.
- `EmulatorControl` library: a Swift client for the emulator's gRPC control API
  (SwiftProtobuf and gRPC Swift 2).
- Third-party license texts are bundled in the app (`ThirdPartyLicenses.txt`).

### Changed
- **Requires macOS 15 or later** (gRPC Swift 2 requires it).
- Release builds go through `xcodebuild archive`: stripped, with a separate dSYM.
  The app is 34 MB and the DMG 15 MB.

### Fixed
- Packaging could ship a stale app if `xcodebuild` failed. It now fails loudly.
- Moorbox only ever stops devices it started itself. Hidden-window emulators run
  by other tools, such as Android Studio, are never stopped when a player window
  closes or Moorbox quits.

## [0.2.0] - 2026-10-21

### Changed
- Renamed the project to **Moorbox**.
- Packages are now installed by Google's Android CLI (the `sdkmanager`
  replacement in cmdline-tools 23), always with `--no-metrics`.
- Devices are now created by Google's `avdmanager`, using Google's hardware
  profiles.
- The app is built from an XcodeGen project; MoorboxCore is a Swift package.
- Distribution is now a universal DMG plus a Homebrew build-from-source
  formula. Homebrew no longer accepts unsigned casks.

### Added
- Java detection (JAVA_HOME, Android Studio, `java_home`), plus an optional
  Eclipse Temurin install, with consent and SHA-256 verification.
- Resumable downloads (HTTP Range) that survive relaunching the app.
- Diagnostics shows command-line tools and Java, and warns about conflicting
  `adb` installations.
- An XCUITest suite, SwiftLint and SwiftFormat, and a Makefile.
- An app icon in an asset catalog.

### Fixed
- Resuming downloads from dl.google.com (gzip variant). The fix requests
  identity encoding.
- Accessibility: device rows are now containers, and decorative icons are
  hidden from VoiceOver.
- New Device is always available and explains what's missing.
- A device whose start fails is now selected, so its error is visible.

## [0.1.0] - 2026-10-21

### Added
- Native SwiftUI app for macOS 14 or later.
- Discovers an existing Android SDK, or installs the emulator and platform-tools
  without Java or Android Studio.
- Lists current Android versions from Google's SDK repository metadata, with
  license consent, SHA-1 verification and safe extraction.
- Creates, edits, renames and deletes devices (deleted devices go to the Trash),
  with Lightweight, Balanced and Performance presets.
- Starts devices (quick boot or cold boot), stops them gracefully, restarts and
  force-stops them, and tracks their state live.
- Installs APKs by drag-and-drop or file picker, and opens and uninstalls apps.
  Shows logcat.
- Device controls: rotate, screenshot, Home, Back and Recents.
- Diagnostics with a redacted report export.
