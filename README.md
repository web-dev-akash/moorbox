# Moorbox

**A small, native macOS app for running Android virtual devices, with no Android Studio and no Java.**

Moorbox drives Google's official Android Emulator from a lightweight SwiftUI app.
It can:

- find the Android SDK you already have, or set one up from scratch;
- list current Android versions straight from Google's SDK repository;
- create devices with sensible resource presets;
- start and stop them;
- install APKs by drag and drop.

Moorbox is free and open source (Apache-2.0). It is an independent project, not
affiliated with Google.

> **Status: 0.1.0, early.** Everything listed under *What works* has been
> verified on an Apple Silicon Mac. Read *Limitations* before relying on it.

## Why Moorbox

| | Typical setup | Moorbox |
|---|---|---|
| Prerequisites | Android Studio (or cmdline-tools plus a JDK 17) | Just the app: emulator and images are fetched natively, no Java |
| Getting an image | `sdkmanager` package paths, license prompts | Pick an Android version; the license is shown once; download is verified |
| Devices | `avdmanager` flags or the IDE's Device Manager | One sheet with Lightweight, Balanced and Performance presets checked against your Mac and the Android version |
| App's own footprint | IDE: hundreds of MB to GBs | **43–53 MB** physical footprint, **0 s CPU** per idle minute ([measured](docs/PERFORMANCE.md)) |
| Existing SDK and devices | — | Reused as-is: same SDK folder, same `~/.android/avd`, same license records |

The Android guest runs on the same official emulator engine either way, so
**guest performance and memory are the same as launching that device any other
way**. We measured this and did not find a meaningful difference (see
[Performance](#performance)). The savings come from what Moorbox doesn't need:
no IDE, no JDK, no Gradle, and no background services. Lighter default device
presets help too.

## What works (verified on Apple Silicon, macOS 27)

- **First-run setup.** Checks the Mac (architecture, memory, disk space,
  Hypervisor.framework) and finds the SDK. Offers to install or update the
  emulator and platform-tools.
- **Install from an empty folder.** Moorbox can set everything up with no
  Android Studio. Tested with emulator 37.2.12, platform-tools 37.0.1 and the
  Android 16 image, all downloaded, SHA-1-verified, installed, then booted.
- **Android Versions.** Read live from `dl.google.com` metadata. Only shows
  images that run natively on your Mac. The latest stable image is
  recommended. Previews and betas are in a separate section. Each entry shows
  its size, license and minimum emulator version.
- **Devices.**
  - Create, edit (RAM, cores, GPU mode), rename, and delete (moved to the
    Trash, recoverable).
  - Start with quick boot or cold boot; stop gracefully, which saves the
    quick-boot snapshot; restart; cancel a stuck start; force stop.
  - Live state (Starting → Booting → Running → Shutting down) without polling.
    Moorbox watches the emulator's own instance registry.
  - Devices created by Android Studio show up too, and vice versa.
- **Device controls.** Rotate, screenshot to Desktop, Home, Back and Recents,
  with menu-bar shortcuts. Location, battery, sensors and network conditions are
  in the emulator window's extended controls.
- **App Installer.**
  - Drag an APK in or choose a file. Moorbox checks it's a real APK and installs
    it with adb.
  - Shows the real result. Common failures are explained, such as ABI mismatch,
    signature conflict, or a minimum SDK that's too high.
  - Lists user-installed apps, with Open and Uninstall. Shows logcat.
- **Diagnostics.** Host and SDK details, device state with a cause and remedy
  when something fails, per-device emulator logs (rotated at 5 MB), an adb
  connection check, and a redacted report export.

Verification details are in [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md).

## Limitations — please read

- **Not every app will work.**
  - Google Play images can run Play Store apps, but **Play Integrity does not
    pass on emulators**.
  - Banking apps, DRM-protected video, and many games with anti-cheat will
    refuse to run.
  - Apps with only x86 native code won't install on Apple Silicon.
- **Built for app development and testing.** Google licenses the emulator and
  system images "solely to develop applications" (Android SDK License §3.1).
  Moorbox is a developer and tester tool, not a general way to use Android apps
  on a Mac.
- **Intel Macs are untested.** The code chooses x86_64 images and the x64
  emulator, but no Intel hardware was available.
- **No embedded display.** Each device runs in the emulator's own window.
- **Not yet signed or notarized.** Builds are ad-hoc signed, so downloaded
  builds need right-click → Open the first time. See
  [Releasing](#releasing-maintainers).
- **Download resume only lasts for the current session.** Cancelled or failed
  downloads resume from where they stopped (tested), but resume state isn't
  kept after Moorbox quits.
- Open manual QA items are listed in [docs/QA_CHECKLIST.md](docs/QA_CHECKLIST.md).

## Requirements

- **macOS 14 Sonoma or later.** Only macOS 27 has been verified so far.
- **An Apple Silicon Mac** (recommended and verified). Intel is untested.
- **Memory:** 8 GB minimum, 16 GB or more recommended. Android 17 (API 37)
  images need at least 4 GB of guest RAM each.
- **Disk:**
  - about 400 MB for the emulator;
  - 0.8–2.4 GB per Android version;
  - 2–8 GB per device, allocated as it's used.
- **Hardware virtualization.** Not available inside most virtual machines, or
  on GitHub-hosted runners.

## Install

1. Download `Moorbox-<version>.zip` from Releases, or build it yourself
   (below).
2. Unzip it and move **Moorbox.app** to Applications.
3. Open it. Unsigned builds need right-click → **Open** the first time.

## First run

1. **Check this Mac.** Green checks mean you're ready. A warning explains what
   to change.
2. **Android Emulator.**
   - If you have Android Studio, Moorbox uses its SDK at
     `~/Library/Android/sdk`.
   - Otherwise click **Install** for the Emulator and Platform tools. Each one
     shows its size, destination and Google's license before downloading.
3. **Android version.** Install the recommended version, or pick another in
   **Android Versions**.
4. **Create and start a device.** One click creates a phone with the Balanced
   preset. The emulator window opens when it starts.

Re-open this guide at any time from **Moorbox → Setup Assistant…**.

## Everyday use

**Install another Android version**

1. Go to **Android Versions** and click **Install…**.
2. Read the size, destination and license, then confirm.

Progress shows in the row and can be cancelled. **Show Previews** lists beta
and canary images.

**Create a device**

1. Click **+** (⌘N).
2. Choose a name, Android version, device type, preset, and optionally memory,
   cores, storage and graphics.

Values outside what your Mac and the image support aren't offered.

**Start and stop devices**

| Action | How | Notes |
|---|---|---|
| Start | **Start** button or ⌘R | Uses quick boot if a snapshot exists |
| Cold boot | ⇧⌘R | |
| Stop | **Stop** | Saves state for a fast next start |
| Restart, Reset Quick Boot, Show in Finder, Delete | Right-click the device | |

**Install an APK**

1. Start a device.
2. Open **App Installer** and drop the `.apk` onto the drop zone.
3. Use **Open** to launch the app, **Uninstall** to remove it, and **Logcat**
   to see recent device logs.

**Shortcuts**

| Shortcut | Action |
|---|---|
| ⌘→ | Rotate |
| ⇧⌘S | Screenshot |
| ⌘[ | Back |
| ⇧⌘H | Home |

These are also in the **Device** menu.

## Performance

These are measured numbers, not targets. The full method, raw data and caveats
are in [docs/PERFORMANCE.md](docs/PERFORMANCE.md).

| What | Result | Notes |
|---|---|---|
| Moorbox app, idle | **43–53 MB** footprint, **0.00 s** CPU per idle minute | No polling; state comes from kqueue watches |
| Running device (API 34, 2 GB guest RAM) | 2.2–3.2 GB host footprint; about 6 CPU-s per idle minute | **Same as a plain `emulator -avd` launch.** Moorbox doesn't change the engine. |
| Cold boot / quick boot (windowed) | about 17 s / about 7 s | Same as a plain launch |
| Graceful stop (saves the snapshot) | 3–5 s | |
| Fresh setup from an empty folder | emulator 50 s, Android 16 image 96 s, first boot 35 s | Measured on a fast connection |

These figures come from one machine: an Apple M4 Pro with 24 GB, running macOS
27.0.1, with emulator 36.5.11. Small sample sizes; see the methodology.

## Build from source

You need Xcode 16 or later (Swift 6) on macOS 14 or later.

```sh
git clone <this repository> && cd moorbox
swift build                      # debug build
swift run Moorbox                 # run without bundling
scripts/package-app.sh           # dist/Moorbox.app and dist/Moorbox-<version>.zip
UNIVERSAL=1 scripts/package-app.sh   # arm64 + x86_64
```

## Tests

```sh
swift test                       # unit tests: no network, SDK or emulator needed
```

Integration tests use the real network, SDK and emulator. They create devices in
a temporary folder and never touch yours.

```sh
scripts/build-test-apk.sh                                        # builds a tiny test APK (needs JDK 17+ and SDK build-tools)
MOORBOX_INTEGRATION=1 swift test --filter IntegrationTests        # catalog, installer, full device lifecycle
MOORBOX_INTEGRATION=1 MOORBOX_INTEGRATION_FRESH=1 swift test --filter fresh   # SDK from scratch (~1.3 GB)
```

CI (`.github/workflows/ci.yml`):

- builds with warnings as errors;
- runs the unit tests;
- packages and verifies the app;
- checks the docs.

The emulator can't run on GitHub-hosted runners, so `integration.yml` is a
manual workflow for a self-hosted Apple Silicon Mac.

## Troubleshooting

**"Android Emulator not set up"**
: Open Setup Assistant. Moorbox looks in Settings → SDK location, then
  `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`, then `~/Library/Android/sdk`. Point it
  at your SDK, or install the emulator.

**A version shows "Requires Android Emulator X or newer"**
: Update the emulator in Setup Assistant. Stop all devices first.

**The device is stuck on "Starting…"**
: Use **Cancel**, then check **Diagnostics → Emulator Log**. Moorbox launches
  the emulator with `-no-metrics -crash-report-mode never`, so it never waits
  on a hidden consent dialog.

**"Failed to run"**
: The device row and Diagnostics show the cause and a fix, for example a
  missing system image, an architecture mismatch, or low disk space. Try
  **Cold Boot**, or **Reset Quick Boot**, which keeps your apps and data.

**adb commands fail**
: Use **Diagnostics → Check adb connection**. If another tool runs a different
  adb version, the two adb servers restart each other. Use one SDK for both.

**Hardware acceleration unavailable**
: You are probably inside a virtual machine. Run Moorbox directly on the Mac.

**Share details for a bug report**
: Use **Diagnostics → Export Report…**. Paths, your user name, email
  addresses and tokens are redacted. Nothing is uploaded.

## Privacy and network use

- No account, no telemetry, no crash uploads, no background service.
- Moorbox contacts only `dl.google.com`:
  - when you open Android Versions or Setup, to list packages;
  - when you install something.
- Emulators are launched with metrics and crash reporting disabled.

## Data locations

| What | Where | Removed when you delete Moorbox? |
|---|---|---|
| Android SDK (emulator, adb, images) | Settings → SDK location (default `~/Library/Android/sdk`, shared with Android Studio) | No |
| Your devices (apps, data, snapshots) | `~/.android/avd` (or `$ANDROID_AVD_HOME`) | No |
| Emulator logs | `~/Library/Logs/Moorbox` | No (safe to delete) |
| Preferences | `~/Library/Preferences/io.github.web-dev-akash.Moorbox.plist` | No (safe to delete) |

To remove everything, delete those folders yourself. **Only delete the SDK and
devices folders if no other tool, such as Android Studio, uses them.**

## Architecture

- `Sources/MoorboxCore` contains all logic:
  - SDK repository parser;
  - installer;
  - AVD store;
  - `AndroidRuntime` protocol with its `EmulatorRuntime` implementation;
  - adb client;
  - diagnostics.
- `Sources/Moorbox` is the SwiftUI app.

The reasoning is in
[ADR-001](docs/architecture/ADR-001-runtime-strategy.md). Emulator behavior
Moorbox relies on is described in
[docs/architecture/emulator-behavior.md](docs/architecture/emulator-behavior.md).
The roadmap is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Releasing (maintainers)

1. Bump `VERSION` and move the `CHANGELOG.md` entries under the new version.
2. Push the tag `v<version>`.
3. `.github/workflows/release.yml` tests the app, builds a universal app, and
   creates a **draft** GitHub release.

**Signing and notarization** happen only if these repository secrets are set:

- signing: `MACOS_CERT_P12_BASE64`, `MACOS_CERT_PASSWORD`,
  `MACOS_SIGN_IDENTITY`;
- notarization: `AC_API_KEY_ID`, `AC_API_ISSUER_ID`, `AC_API_KEY_P8_BASE64`.

To do it locally:

```sh
CODESIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<profile> scripts/package-app.sh
```

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
Report security issues privately ([SECURITY.md](SECURITY.md)).

## License

- Moorbox's code: [Apache-2.0](LICENSE).
- Android components that Moorbox downloads for you are Google's, under
  Google's terms. Google Play images contain proprietary software. See
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Android is a trademark of Google LLC.
