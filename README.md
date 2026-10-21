# Moorbox

**A lightweight, native macOS app for running Android virtual devices, without Android Studio.**

Moorbox is a SwiftUI app built on Google's official Android tooling:

- the Android Emulator runs the devices;
- the Android CLI installs SDK packages;
- `avdmanager` creates devices.

Moorbox handles the parts that are tedious from the command line:

- finding or setting up the SDK;
- choosing a current Android version;
- creating devices with sensible resources;
- starting and stopping them;
- installing APKs by drag and drop.

It's free and open source (Apache-2.0), and an independent project, not
affiliated with Google.

> **Status: 0.2.0, early.** Everything under *What works* has been verified on
> an Apple Silicon Mac. Read *Limitations* before relying on it.

## Why Moorbox

| | Typical setup | Moorbox |
|---|---|---|
| Prerequisites | Android Studio, or cmdline-tools plus a JDK set up by hand | Just the app. It finds what you have and offers to install anything missing, with your consent. |
| Getting an image | `sdkmanager` package paths | Pick an Android version. Size, destination and license are shown before anything downloads. |
| Devices | `avdmanager` flags or the IDE's Device Manager | One sheet: Google's hardware profiles plus Lightweight, Balanced and Performance presets, checked against your Mac and the Android version |
| App's own footprint | IDE: hundreds of MB to GBs | **44–53 MB** physical footprint, **0 s CPU** per idle minute ([measured](docs/PERFORMANCE.md)) |
| Telemetry | Android CLI collects usage metrics by default | Every Google tool is run with metrics off; Moorbox itself has none |
| Existing setup | — | Reused as-is: same SDK folder, same `~/.android/avd`, same license records as Android Studio |

The Android guest runs on Google's emulator either way, so **guest performance
and memory are the same as launching that device any other way**. We measured
this. The savings come from what you don't need: no IDE, no Gradle, and no
background services. Lighter default presets help too.

## What works (verified on Apple Silicon, macOS 27)

**First-run setup**

- Checks the Mac: architecture, memory, disk space and Hypervisor.framework.
- Finds the SDK and Java.
- Offers each missing piece separately. Each offer shows what it is, where it
  goes, and under which license.

**Google's official tools, with consent**

- Moorbox installs Google's command-line tools (verified download).
- Packages are then installed by Google's Android CLI with `--no-metrics`. We
  verified that the CLI writes no analytics with this flag.
- Devices are created by Google's `avdmanager`.

**Java, only when needed**

- `avdmanager` needs Java 17 or newer. Moorbox uses one already on your Mac
  (Android Studio's, `JAVA_HOME`, or any registered JDK).
- Otherwise it offers to install Eclipse Temurin for your user only, SHA-256
  verified, with no admin password.

**Android Versions**

- Read live from Google's SDK repository.
- Only images that run natively on your Mac are listed.
- The latest stable version is recommended. Previews and betas are in a separate
  section.
- Each entry shows its size, license and minimum emulator version.

**Devices**

- Create with Google's hardware profiles; edit RAM, cores and GPU mode; rename.
- Delete moves the device to the Trash, so it can be recovered.
- Start with quick boot or cold boot; stop gracefully, which saves the snapshot;
  restart; cancel a stuck start; force stop.
- Live state without polling.
- Devices created by Android Studio show up too, and vice versa.

**Device controls**

- Rotate, screenshot to Desktop, Home, Back and Recents, with keyboard shortcuts.
- Location, battery, sensors and network are in the emulator window's extended
  controls.

**App Installer**

- Drag an APK in, or choose a file. Moorbox checks it's a real APK and installs
  it with adb.
- Shows the real result, with explanations for common failures.
- Open or uninstall apps, and view logcat.

**Diagnostics**

- Toolchain status (SDK, cmdline-tools, Java, emulator, adb).
- Per-device emulator logs, rotated at 5 MB.
- An adb connection check, plus a warning if a second, different `adb` (for
  example Homebrew's) is installed.
- A redacted report export.

**Downloads**

- Moorbox's own downloads (command-line tools, JDK) are HTTPS-only from trusted
  hosts and checksum-verified.
- They resume after a cancel, even after you quit the app.

Details and test evidence: [docs/PROJECT_STATUS.md](docs/PROJECT_STATUS.md).

## Limitations — please read

- **Not every app will work.**
  - Google Play images can run Play Store apps, but **Play Integrity does not
    pass on emulators**.
  - Banking apps, DRM-protected video and many games with anti-cheat will
    refuse to run.
  - Apps with only x86 native code won't install on Apple Silicon.
- **Built for app development and testing.** Google licenses the emulator and
  system images "solely to develop applications" (Android SDK License §3.1).
- **The DMG isn't notarized.** The project has no Apple Developer ID, so allow
  the app once in System Settings ([details](docs/architecture/ADR-003-distribution.md)).
- **Intel Macs are untested.** No Intel hardware was available.
- **No embedded display.** Each device runs in the emulator's own window.
- Open manual QA items are listed in [docs/QA_CHECKLIST.md](docs/QA_CHECKLIST.md).

## Requirements

- **macOS 14 Sonoma or later.** Only macOS 27 has been verified so far.
- **An Apple Silicon Mac** (recommended and verified). Intel is untested.
- **Memory:** 8 GB minimum, 16 GB or more recommended. Android 17 (API 37)
  images need at least 4 GB of guest RAM.
- **Disk:**
  - about 155 MB for the command-line tools;
  - about 90 MB for Google's Android CLI;
  - about 400 MB for the emulator;
  - 0.8–2.4 GB per Android version;
  - 2–10 GB per device, allocated as it's used;
  - about 200 MB for a JDK, if you don't have one.
- **Hardware virtualization.** Not available inside most virtual machines.

## Install

**Option 1: DMG from GitHub Releases**

1. Download `Moorbox-<version>.dmg` from
   [Releases](https://github.com/web-dev-akash/moorbox/releases).
2. Open it and drag Moorbox to Applications.
3. The first time you open it, macOS blocks it because it isn't notarized. Open
   **System Settings → Privacy & Security** and click **Open Anyway** next to
   the Moorbox message. You only need to do this once per version.

**Option 2: Homebrew (builds from source, needs Xcode)**

```sh
brew install web-dev-akash/moorbox/moorbox
ln -sf "$(brew --prefix moorbox)/Moorbox.app" ~/Applications/Moorbox.app
```

Homebrew no longer distributes non-notarized apps as casks. The formula builds
Moorbox on your Mac instead, so no Gatekeeper exception is needed.

**Option 3: Build it yourself.** See [Build from source](#build-from-source).

## First run

1. **Check this Mac.** Green checks mean you're ready.
2. **Android SDK tools.**
   - With Android Studio installed, Moorbox uses its SDK at
     `~/Library/Android/sdk`.
   - It adds Google's command-line tools to that SDK, if you agree.
   - It can then install or update the emulator and platform-tools.
3. **Java (for creating devices).** Detected automatically. If none is found,
   click **Install Eclipse Temurin…** or install any JDK 17+ yourself and click
   **Check Again**.
4. **Android version.** Install the recommended version, or pick another in
   **Android Versions**.
5. **Create and start a device.** One click creates a Medium Phone with the
   Balanced preset.

Re-open the guide from **Moorbox → Setup Assistant…**.

## Everyday use

**Install another Android version**

1. Go to **Android Versions** and click **Install…**.
2. Review the size, destination and license, then confirm.

Progress shows in the row and can be cancelled.

**Create a device**

1. Click **+** (⌘N).
2. Choose a name, Android version, hardware profile, preset, and optionally
   memory, cores, storage and graphics.

If something is missing, the sheet says what and links to Setup.

**Start and stop devices**

| Action | How | Notes |
|---|---|---|
| Start | **Start** button or ⌘R | Uses quick boot if a snapshot exists |
| Cold boot | ⇧⌘R | |
| Stop | **Stop** | Saves state for a fast next start |
| Restart, Reset Quick Boot, Rename, Show in Finder, Delete | Right-click the device | |

**Install an APK**

1. Start a device.
2. Open **App Installer** and drop the `.apk` onto the drop zone.

**Shortcuts**

| Shortcut | Action |
|---|---|
| ⌘→ | Rotate |
| ⇧⌘S | Screenshot |
| ⌘[ | Back |
| ⇧⌘H | Home |

## Performance

These are measured numbers, not targets. Method, raw data and caveats are in
[docs/PERFORMANCE.md](docs/PERFORMANCE.md).

| What | Result | Notes |
|---|---|---|
| Moorbox app, idle | **44–53 MB** footprint, **0.00 s** CPU per idle minute | No polling; state comes from kqueue watches |
| Running device (API 34, 2 GB guest RAM) | 2.2–3.2 GB host footprint; about 6 CPU-s per idle minute | **Same as a plain `emulator -avd` launch** |
| Cold boot / quick boot (windowed) | about 17 s / about 7 s | Same as a plain launch |
| Graceful stop (saves the snapshot) | 2–5 s | |

These figures come from one machine: an Apple M4 Pro with 24 GB, running macOS
27.0.1. Small sample sizes; see the methodology.

## Build from source

Requirements:

- Xcode 16 or later (Swift 6) on macOS 14 or later;
- `brew install xcodegen`;
- for linting and DMGs: `brew install swiftlint swiftformat create-dmg`.

```sh
git clone https://github.com/web-dev-akash/moorbox.git && cd moorbox
make project      # generates Moorbox.xcodeproj from project.yml
make run          # debug build and launch
make app          # universal Release build → dist/Moorbox.app (+ zip)
make dmg          # dist/Moorbox-<version>.dmg
```

`Moorbox.xcodeproj` is generated and not committed. Edit `project.yml` instead.

## Tests

```sh
make test-core          # 69 unit tests: no network, SDK or emulator
make test-ui            # 8 XCUITest UI tests against a fake SDK
make lint               # SwiftFormat --lint + SwiftLint --strict
make test-integration   # real network, Google tools and emulator (opt-in)
```

**Integration tests** create their own SDK and device folders, and never touch
yours. They cover:

- installing cmdline-tools;
- the Android CLI with `--no-metrics`, checked against its analytics folder;
- download resume;
- `avdmanager` device creation;
- cold and quick boot;
- APK install, launch and persistence across a restart.

Extras: `MOORBOX_INTEGRATION_JDK=1` adds a Temurin install, and
`MOORBOX_INTEGRATION_FRESH=1` adds a complete from-scratch SDK.

**macOS UI tests** need permission for the test runner to control the Mac
(System Settings → Privacy & Security). They paste text instead of typing,
because synthetic typing fails with some keyboard layouts.

**CI** (`.github/workflows/ci.yml`) runs:

- lint;
- the unit tests;
- the UI tests;
- a universal Release build and DMG;
- doc and packaging checks.

The emulator can't boot on GitHub-hosted runners, so `integration.yml` is
manual and needs a self-hosted Apple Silicon Mac.

## Troubleshooting

**"Android Emulator not set up" / "Can't create devices yet"**
: Open Setup Assistant. It shows exactly which piece is missing:
  command-line tools, emulator, platform-tools, Java or an Android version.

**A version shows "Requires Android Emulator X or newer"**
: Update the emulator in Setup Assistant. Stop all devices first.

**The device is stuck on "Starting…"**
: Click **Cancel**, then check **Diagnostics → Emulator Log**. Moorbox launches
  the emulator with `-no-metrics -crash-report-mode never`, so it never waits
  on a hidden consent dialog.

**"Failed to run"**
: The device is selected and its panel shows the cause and a fix. Try
  **Cold Boot**, or **Reset Quick Boot**, which keeps your apps and data.

**Devices keep disconnecting from adb**
: Diagnostics warns if a second, different `adb` is installed, such as
  Homebrew's `android-platform-tools`. Two versions restart each other's
  server. Keep one.

**Hardware acceleration unavailable**
: You're probably inside a virtual machine. Run Moorbox directly on the Mac.

**Share details for a bug report**
: **Diagnostics → Export Report…** redacts paths, your user name, email
  addresses and tokens. Nothing is uploaded.

## Privacy and network use

- No account, no telemetry, no crash uploads, no background service.
- Moorbox contacts only:
  - `dl.google.com`: the SDK catalog and command-line tools;
  - `api.adoptium.net` and `github.com/adoptium`: only if you choose to
    install a JDK.
- Google's tools that Moorbox runs make their own requests to Google:
  - the Android CLI downloads packages, downloads itself on first use, and
    checks for its own updates;
  - the emulator.
- Moorbox always runs them with metrics and crash reporting turned off.

## Data locations

| What | Where | Removed when you delete Moorbox? |
|---|---|---|
| Android SDK (tools, emulator, images) | Settings → SDK location (default `~/Library/Android/sdk`, shared with Android Studio) | No |
| Google's Android CLI | `~/.android/bin/android-cli`, `~/.android/cli/` | No |
| Your devices (apps, data, snapshots) | `~/.android/avd` (or `$ANDROID_AVD_HOME`) | No |
| JDK installed by Moorbox | `~/Library/Application Support/Moorbox/JDK` | No (safe to delete; Setup will offer it again) |
| Emulator logs | `~/Library/Logs/Moorbox` | No (safe to delete) |
| Preferences | `~/Library/Preferences/io.github.web-dev-akash.Moorbox.plist` | No (safe to delete) |

**Only delete the SDK, `~/.android` and devices folders if no other tool, such
as Android Studio, uses them.**

## Architecture

- `Sources/MoorboxCore` is a Swift package with all the logic:
  - repository catalog;
  - verified installer;
  - Android CLI, `avdmanager` and Java wrappers;
  - AVD store;
  - `AndroidRuntime` protocol and the emulator runtime;
  - adb client;
  - diagnostics.
- `App/` is the SwiftUI app, built by the XcodeGen project.

Decisions are recorded in:

- [ADR-001 (runtime)](docs/architecture/ADR-001-runtime-strategy.md)
- [ADR-002 (official tools)](docs/architecture/ADR-002-official-sdk-tools.md)
- [ADR-003 (distribution)](docs/architecture/ADR-003-distribution.md)

Observed tool behavior is in
[docs/architecture/emulator-behavior.md](docs/architecture/emulator-behavior.md),
and the roadmap is in [docs/ROADMAP.md](docs/ROADMAP.md).

## Releasing (maintainers)

1. Bump `VERSION` and move the `CHANGELOG.md` entries under the new version.
2. Push the tag `v<version>`.
3. `release.yml` runs the tests, builds the universal DMG and zip, and creates
   a **draft** GitHub release. The release notes include the formula's `url`
   and `sha256`.
4. Copy those values into `Formula/moorbox.rb` in the
   `web-dev-akash/homebrew-moorbox` tap.

A template is in `packaging/homebrew/moorbox.rb`.

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md) and
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md). Report security issues privately
([SECURITY.md](SECURITY.md)).

## License

- Moorbox's code: [Apache-2.0](LICENSE).
- Android components are Google's, under Google's terms, and Google Play
  images contain proprietary software.
- Eclipse Temurin is GPLv2 with the Classpath Exception.
- See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
- Android is a trademark of Google LLC.
