# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version in `VERSION` is the
source of truth; release tags are `v<version>`.

## [Unreleased]

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
