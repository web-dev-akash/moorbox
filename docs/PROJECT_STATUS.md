# Project status

_Last updated: 2026-10-22. Moorbox 0.2.0 plus the Phase A player window (unreleased)._

## Summary

Moorbox 0.2.0 is a native SwiftUI app built on Google's official Android tooling:

- the **Android Emulator** runs devices;
- the **Android CLI** (the `sdkmanager` replacement) installs packages;
- **`avdmanager`** creates devices.

When something is missing — command-line tools, emulator, platform-tools, a JDK,
or an Android version — Moorbox explains what it is and installs it only after
consent. It never works around missing pieces and never bypasses macOS security.

## Since 0.2.0: the single-window player (Phase A of ADR-004)

**Verified on a real device (API 34):**

- **Start opens the player.** Starting a device opens Moorbox's player window,
  and Android boots inside it.
- **Display.** Frames arrive through shared memory: about 47 fps under
  continuous input, 20–35 fps during normal transitions.
- **Input.** Toolbar Home and Recents, and mouse drags, reach Android.
- **Closing stops the device.** Closing the window stops the device gracefully.
  Devices Moorbox didn't start are never stopped.
- **Cost.** Moorbox uses about 12.5% of one core while streaming, and is
  unchanged when idle (44 MB, 0 CPU).
- **Size.** The release build is now an archive: stripped, 34 MB app and 15 MB
  DMG, down from 135 MB unstripped.

**Not yet verified:**

- rotation (input mapping in landscape);
- keyboard typing into a text field;
- APK drag-and-drop onto the player;
- several player windows at once.

**Next phases are in ADR-004:**

- **B:** emulator from source, bundled.
- **C:** our own Android image. Build infrastructure is still to be decided.
- **D:** zero-install first launch.
- **E:** game keymapping and multi-instance.

## Verification environment

Only these configurations have been verified:

| Item | Value |
|---|---|
| Mac | Apple M4 Pro, 14 cores, 24 GB RAM |
| macOS | 27.0.1 (26A434); keyboard layout ABC-India |
| Toolchain | Xcode 26.6, Swift 6.3.3, XcodeGen 2.46.0, SwiftLint 0.65.1, SwiftFormat 0.64.0 |
| Google tools | cmdline-tools 23.0, Android CLI 1.0.16625370, emulator 36.5.11 / 37.2.12, platform-tools 37.0.0 / 37.0.1 |
| Java | Android Studio JBR 21.0.10; Homebrew OpenJDK 17.0.20; Temurin 21.0.12 (installed by the test) |
| CI | GitHub Actions `macos-26` (lint, core tests, UI tests, Release build + DMG) |

## Verification summary

| Check | Result |
|---|---|
| `make lint` (SwiftFormat --lint, SwiftLint --strict) | ✅ clean |
| `make test-core` | ✅ 69 tests |
| `make test-ui` (XCUITest, fake SDK) | ✅ 8 tests locally. On CI, 7 of 8 passed before a test-only fix to how dismissal is awaited. |
| `make test-integration` with Temurin (real network, Google tools, emulator) | ✅ 6 tests (see below) |
| `make dmg` | ✅ universal (x86_64 + arm64) app, ad-hoc signed with hardened runtime, DMG verified, launches with a 44 MB footprint |
| Homebrew formula | ⚠️ The recipe is verified by running its exact steps on a pristine GitHub tarball. `brew install` itself is blocked on this Mac: Homebrew requires Xcode 27 on macOS 27. |

**Integration tests, against the real tools:**

- **Live catalog.** cmdline-tools 23.0.0, emulator 37.2.12, and the
  recommended image `android-37.0;google_apis;arm64-v8a`.
- **Bootstrap.**
  - cmdline-tools installed into an empty SDK (16.9 s).
  - platform-tools installed by the Android CLI (3.5 s); `package.xml` written.
  - **`--no-metrics` verified**: the CLI's analytics folder was unchanged.
  - Package removed again through the CLI.
- **Download resume.** Cancel, then retry continued from 2.7–3.2 MB (HTTP
  Range). The partial file survives an app relaunch.
- **Temurin JDK.** Downloaded, SHA-256 verified and installed in 19.7 s, then
  found by `JavaLocator`.
- **Device lifecycle with official tools.**
  - `avdmanager` created a device with `medium_phone`.
  - Resource overrides were applied.
  - Cold boot 36 s (headless).
  - The APK installed and launched; its activity was verified.
  - Screenshot, rotate, Home and logcat worked.
  - Graceful stop in 2.4 s, with the snapshot saved.
  - Quick boot in 3.2 s; **the app survived the restart**.
  - Uninstall worked, and nothing was deleted.

## Definition of done — MVP

Every item from 0.1.0 still holds, now on the official toolchain. In particular:

- **Discovers or sets up a runtime.** Existing SDKs are reused. Missing pieces
  are installed after consent, through Moorbox's verified bootstrap for
  cmdline-tools and Google's Android CLI for everything else.
- **Creates devices with valid settings.** Uses Google's `avdmanager` and
  hardware profiles, with resources checked against the host and API level.
- **Handles failures without deleting user data.** Delete moves devices to the
  Trash. Start failures select the device and show the cause. The integration
  test asserts nothing is deleted.

## Problems found and fixed this session

| Problem | Cause | Fix |
|---|---|---|
| `sdkmanager` now hands off to the "Android CLI", which **collects usage metrics by default** | Google's cmdline-tools 23 change | Call the CLI directly, always with `--no-metrics`; verified by an analytics snapshot |
| Google's CLI accepts licenses without prompting | Same | Moorbox shows the license and asks before every install |
| Resume after cancel failed (`NSURLErrorCannotDecodeRawData`) | dl.google.com serves a gzip-encoded variant to clients that accept gzip, and its byte ranges can't be resumed | Own HTTP Range downloader with `Accept-Encoding: identity`; partial files kept |
| UI tests: typing timed out | Synthetic `typeText` fails with the ABC-India layout | Tests paste text instead |
| UI tests flaky on CI | `XCTAssertFalse(waitForExistence)` can't detect dismissal | Wait for `exists == false` |
| Accessibility: rows exposed child elements, not a container; device icon announced as "Iphone, Third Generation" | Missing container and hidden traits | Rows are containers; decorative icons hidden |
| ⌘N disabled with no explanation when no image was installed | UI gating | New Device always opens and explains what's missing |
| A start failure was only visible if that device was already selected | UX gap | The failed device is selected automatically |
| Homebrew rejects non-notarized casks (since 2026-09-01) | Homebrew policy | Build-from-source formula; DMG with Apple's "Open Anyway" flow (ADR-003) |
| A Homebrew test run cloned `homebrew/core` (1.5 GB) | `HOMEBREW_NO_INSTALL_FROM_API=1` used during testing | Untapped again; Homebrew is back to its previous state |

## Not yet verified, or blocked

- **`brew install` of the formula.** Blocked on this Mac because Homebrew
  requires Xcode 27 on macOS 27. The recipe steps are verified.
- **Manual QA.** Remaining ☐ items are in [QA_CHECKLIST.md](QA_CHECKLIST.md):
  - drag-and-drop APK onto the drop zone;
  - adb disconnection;
  - sleep and wake;
  - Play Store image;
  - insufficient disk space;
  - the Temurin install UI flow (the core path is integration-tested);
  - updating the emulator through the app;
  - installing the DMG from a download.
- **Intel Macs.** No hardware available.
- **The emulator can't boot on GitHub-hosted runners.** Integration tests need
  a self-hosted Apple Silicon runner (`integration.yml`).

## Side effects on this Mac from testing

- **Google's Android CLI** downloaded itself to `~/.android/bin/android-cli`,
  and keeps state in `~/.android/cli/`.
  - Early exploratory runs, before `--no-metrics` was known, queued usage
    metrics in `~/.android/cli/analytics/metrics/spool`.
  - Moorbox never runs the CLI without `--no-metrics`.
  - The queued entries can be deleted manually if you don't want them sent.
- **Homebrew:** installed xcodegen, swiftlint, swiftformat and create-dmg (as
  approved). The temporary taps were removed.

## Next concrete tasks

1. Work through the ☐ items in [QA_CHECKLIST.md](QA_CHECKLIST.md).
2. After installing Xcode 27, run `brew install --HEAD` with the formula in a
   local tap.
3. Create the `web-dev-akash/homebrew-moorbox` tap, and tag `v0.2.0`. The
   release workflow then builds the DMG and prints the formula checksum.
