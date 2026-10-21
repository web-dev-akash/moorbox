# ADR-002: Use Google's official SDK tools for installs and device creation

- **Status:** Accepted. It supersedes ADR-001's decision to re-implement `sdkmanager` and `avdmanager` natively.
- **Date:** 2026-10-21
- **Decided by:** the project owner, choosing among options the maintainer researched

## Context

Moorbox 0.1 installed packages and wrote AVD configs with its own Swift code. That
code worked and was tested, but it was an unofficial re-implementation:

- it wrote no `package.xml`;
- it used none of `avdmanager`'s hardware profiles;
- it had to track Google's formats by hand.

The owner wants production-grade robustness. Where something is missing, Moorbox
should ask permission and install the real tool, not work around it.

## What we found (2026-10-21, cmdline-tools 23.0)

Everything below was verified on this machine. Sources and raw output are in
`docs/architecture/emulator-behavior.md`.

**`sdkmanager` is deprecated**

- It is now a shell script that runs Google's new **Android CLI**:
  `android --sdk=<root> sdk …` ([docs](https://developer.android.com/tools/agents/android-cli)).
- The `bin/android` file in cmdline-tools is a launcher. On first use it downloads
  the full CLI (an 87 MB native binary, no Java needed) to
  `~/.android/bin/android-cli`.

**The Android CLI collects usage metrics by default**

- Passing `--no-metrics` **before the subcommand** disables collection. We verified
  this: the CLI's analytics folder was unchanged after a full install.
- Moorbox passes `--no-metrics` on every invocation.

**The Android CLI accepts licenses without asking**

- It records acceptance in `<sdk>/licenses/` the same way `sdkmanager` did.
- Consent therefore has to happen *before* Moorbox calls it. Moorbox always shows
  the license text from Google's metadata first.

**`avdmanager` still needs Java 17 or newer**

- It is still a Java program.
- `android emulator create` takes only a profile name. It cannot choose the system
  image, RAM or cores, so it can't replace `avdmanager` for our needs.
- `avdmanager` only manages the SDK it lives in, so cmdline-tools must be
  installed inside the user's SDK.
- `avdmanager` writes the emulator's full hardware defaults, including
  `disk.dataPartition.path=<temp>` and `hw.gpu.enabled=no`. A real boot showed that
  user data **still persists** across restarts. Moorbox then applies the user's
  chosen settings, as Android Studio's device wizard does.

**The CLI doesn't print progress when it's not on a terminal**

- It downloads to `<sdk>/.sdk/arch/<archive-sha1>.part`.
- Moorbox shows progress from that file's size against the size in the catalog.
  If the file isn't found, the progress bar becomes indeterminate.

## Decision

| Need | Implementation |
|---|---|
| Catalog of versions | Google's repository XML, the same metadata the CLI reads. Used for sizes, licenses, previews and minimum emulator versions. |
| cmdline-tools | Installed by Moorbox from the official `cmdline-tools;latest` package: verified SHA-1, resumable download. This is the only SDK package Moorbox installs itself, as Android Studio also does. |
| Emulator, platform-tools, system images (install, update, remove) | `android --no-metrics --sdk=<root> sdk install/remove …` |
| Device creation | `avdmanager create avd --name --package --device`, then the chosen RAM, cores, storage and GPU written to `config.ini` |
| Java for `avdmanager` | Found automatically (JAVA_HOME, Moorbox-installed, Android Studio's bundled JDK, `/usr/libexec/java_home -v 17+`). Otherwise Eclipse Temurin LTS is installed **only after consent**, SHA-256 verified, into the user's Application Support folder. No admin rights needed. |
| Running devices | The `emulator` binary directly, as before |

Before every install, Moorbox shows:

- the size;
- the destination;
- which tool performs the install;
- for cmdline-tools, that Google's launcher downloads the CLI to `~/.android/bin`;
- the license text.

## Consequences

- **Fully compatible with Android Studio and `sdkmanager`.** Packages get Google's
  own `package.xml`, and devices are created by Google's tool.
- **Java is needed only to create devices.** Running existing devices, installing
  packages and installing APKs don't need it.
- **We depend on the Android CLI (version 1.0, released April 2026).** If its
  command-line interface changes, the failure surfaces as a clear tool error, and
  installs are confirmed on disk rather than trusting the exit status. The
  integration test `bootstrapsOfficialToolsIntoFreshSDK` exercises the CLI.
- **Moorbox's own downloader is still used** for cmdline-tools and the JDK. It
  makes HTTP `Range` requests with `Accept-Encoding: identity`, because
  dl.google.com serves a gzip-encoded variant whose byte ranges can't be resumed.
  Partial files are kept, so resume also works after relaunching the app.
