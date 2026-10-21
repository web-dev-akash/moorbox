# Project status

_Last updated: 2026-10-21, end of the initial implementation session._

## Summary

Moorbox 0.1.0 is a native SwiftUI app that drives the official Android Emulator.
It replaces the parts of `sdkmanager` and `avdmanager` it needs with native
Swift code, so it requires neither Java nor Android Studio. The first
end-to-end milestone is done and verified on real hardware:

> set up the runtime → create a device → start Android → install an APK → shut down

## Verification environment

The following are the only verified configurations:

| Item | Value |
|---|---|
| Mac | Apple M4 Pro, 14 cores, 24 GB RAM |
| macOS | 27.0.1 (26A434) |
| Toolchain | Xcode 26.6, Swift 6.3.3 |
| Emulator | 36.5.11 (existing Android Studio SDK) and 37.2.12 (installed by Moorbox from scratch) |
| Images | android-34 `google_apis` arm64-v8a; android-36 `default` arm64-v8a |

## Definition of done — MVP

| Requirement | Status | Evidence |
|---|---|---|
| Builds from documented prerequisites | ✅ | `swift build -Xswiftc -warnings-as-errors`, `scripts/package-app.sh` |
| Launches as a native app | ✅ | `dist/Moorbox.app` launched with `open`; menus, sidebar and sheets render (screens captured via the DEBUG snapshot hook) |
| Identifies host architecture and constraints | ✅ | Setup and Diagnostics show arch, RAM, disk and `kern.hv_support`. Mach-O arch check on the emulator binary. |
| Discovers or sets up a runtime | ✅ | Reuses the existing SDK. `freshSDKFromScratchBootsADevice` installs emulator, platform-tools and image into an empty folder, then boots. |
| Discovers current system images via supported mechanisms | ✅ | Google's `repository2-3.xml` and `sys-img2-3.xml`, live (552 packages). `liveCatalogHasRuntimeAndImagesForThisMac`. |
| Creates a device with valid settings | ✅ | `AVDStore.create`. Validated against `ResourceLimits`. Booted by the emulator in the integration tests. |
| Starts and stops the device from the app | ✅ | DEBUG lifecycle drive through `AppModel`: Starting → Booting → Running → Stopped. Window mode; running after 7–17 s, stopped in 3–4 s. |
| Accurately displays runtime and device state | ✅ | Discovery-registry watcher, plus process exit source, plus `sys.boot_completed`. Unit tests for state resolution. |
| Connects through ADB | ✅ | Integration test: serial mapping, boot wait, shell, `emu`, logcat |
| Installs a test APK and reports the real result | ✅ | Integration: `moorbox-hello.apk` installed, launched (activity verified in `dumpsys`), persisted across restart, then uninstalled. Failure mapping unit-tested. |
| Functional logs and diagnostics | ✅ | Per-device emulator logs (rotated), activity log, adb check, redacted export |
| Handles failures without deleting user data | ✅ | Delete moves to the Trash and needs confirmation. Reset Quick Boot removes only the snapshot. Failed starts never touch device files. Integration test asserts the device still exists. |
| Core logic has meaningful tests | ✅ | 57 unit tests. 5 opt-in integration tests against the real network and emulator. |
| README covers setup, usage, testing, troubleshooting | ✅ | `README.md` |
| Licensing and third-party notices | ✅ | `LICENSE` (Apache-2.0), `NOTICE`, `THIRD_PARTY_NOTICES.md` |
| Performance measurements and limitations documented | ✅ | `docs/PERFORMANCE.md` |
| No claimed feature depends on a placeholder | ✅ | Every control calls a real operation. Location, sensors and battery are left to the emulator's own window, and the UI says so rather than faking them. |

## Feature status

### Verified

- SDK discovery: settings, then `ANDROID_HOME`/`ANDROID_SDK_ROOT`, then
  `~/Library/Android/sdk`.
- Health check: emulator presence and architecture, adb presence.
- Repository catalog:
  - host and ABI filtering;
  - previews detected by `<codename>`;
  - 16 KB page-size and extension images ranked below standard images;
  - recommended image = newest stable base Google APIs image (currently
    `android-37.0;google_apis;arm64-v8a`);
  - minimum emulator version warning.
- Installer:
  - HTTPS from `dl.google.com` only, with a disk space check;
  - SHA-1 verification;
  - `unzip` into staging, then a symlink audit, then an atomic move;
  - staging always cleaned up;
  - cancel, and resume via HTTP 206 (tested).
- License consent recorded in `sdkmanager`'s format. Append-only. The hash
  format was verified against Android Studio's own records.
- AVD create, list, update, rename, delete-to-Trash, and quick-boot reset.
  Android Studio–created devices are read correctly.
- Emulator launch:
  - in its own session (survives app quit and Ctrl-C);
  - with `-no-metrics -crash-report-mode never`;
  - zombie-aware, PID-reuse-safe process checks.
- Cold boot, quick boot, graceful stop with snapshot save, force stop, and
  cancel start.
- APK install, launch, uninstall, user package list; screenshot, rotate, keys;
  logcat.
- Adopting an emulator started outside Moorbox: shown as Running with the
  correct serial.
- Light and dark appearance, captured for every screen.
- Crash recovery: a SIGKILLed emulator is shown as Failed (exit 137) with a
  remedy, device data is untouched, and the next start boots normally.

### Implemented, not yet verified

These are in the code, but no test or manual run has exercised them yet:

- Drag-and-drop and the file picker in App Installer. The underlying adb
  install is verified.
- Keyboard shortcuts.
- Settings window.
- Export Report save panel. Redaction is unit-tested.
- Emulator update with replacement (`replacing: true`). The code path keeps the
  old copy until the new one is in place; untested with the real emulator
  package.

### Not implemented (see ROADMAP)

- Embedded device display inside the Moorbox window.
- Native controls for location, battery and sensors. The emulator's extended
  controls cover these.
- Named snapshot management; device import and export.
- Image update notifications; persisting download resume across app launches.

## Problems found and fixed this session

| Problem | Cause | Fix |
|---|---|---|
| Devices stuck on "Starting…" after an earlier emulator crash | The emulator shows a blocking crash-report consent dialog on the next launch | Always launch with `-no-metrics -crash-report-mode never` |
| Stop never completed for child processes | `kill(pid, 0)` succeeds on unreaped zombies | `Shell.isAlive` checks `p_stat != SZOMB` via `sysctl` |
| Wrong device matched by discovery | The discovery file's `avd.name` is the *display name* | Prefer `avd.id` |
| Recommended image skipped Android 17 | Google's 37.0 image carries an extra `ai_glasses_compatible` tag | Match tags by membership |
| Resume after cancel failed | HTTP 206 rejected as an error | Accept 200 and 206 |
| Device names said "Android 34" | API level used as the marketing version | `AndroidVersion.shortName` |

## Blockers and external constraints

- **Signing and notarization.** These need an Apple Developer ID and an App
  Store Connect API key. The script and workflow are ready but untested, and
  builds are currently ad-hoc signed.
- **Intel Macs.** No hardware available. The x86_64 code paths are unverified.
- **CI can't boot Android.** GitHub-hosted Apple Silicon runners lack nested
  virtualization, so `integration.yml` targets self-hosted runners.
- **Licensing.**
  - Emulator and images can't be redistributed (SDK License §3.4) and are
    licensed for app development (§3.1).
  - Play Integrity doesn't pass on emulators.

## Next concrete task

Work through the ☐ items in [QA_CHECKLIST.md](QA_CHECKLIST.md), starting with:

1. #15: Stop after relaunching Moorbox while a device is running;
2. #11: drag-and-drop install;
3. #10: adb disconnection;
4. #17: sleep and wake.

Then do a first Developer ID–signed build once credentials are available.
