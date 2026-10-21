# ADR-001: Runtime strategy

- **Status:** Accepted. The runtime decision stands. The native package and AVD tooling was superseded by [ADR-002](ADR-002-official-sdk-tools.md) on 2026-10-21.
- **Date:** 2026-10-21
- **Deciders:** founding engineer (initial implementation session)

## Context

Moorbox is a free, open-source, native macOS app that should make running Android
virtual devices simple and light on resources. It has to decide which engine
actually runs Android. The options are an existing engine, a custom runtime, or a
hybrid of the two.

### Development host used for this research

The evidence below was gathered on, and is limited to, this machine:

| Item | Value |
|---|---|
| Machine | Apple M4 Pro, 14 cores, 24 GB RAM |
| macOS | 27.0.1 (build 26A434) |
| Xcode / Swift | Xcode 26.6, Swift 6.3.3 |
| Existing SDK | `~/Library/Android/sdk`, installed by Android Studio |
| Emulator | 36.5.11, arm64 |
| platform-tools | adb 37.0.0, universal binary |
| System image | android-34 `google_apis` arm64-v8a |
| `cmdline-tools` | **not installed**, so no `sdkmanager` or `avdmanager` |

Intel Macs were not available.

## Approaches investigated

### A. Native app that drives the official Android Emulator engine

The official emulator is QEMU-based. On macOS it uses Hypervisor.framework for
acceleration ([1]) and gfxstream for graphics, rendering through ANGLE, MoltenVK
or Metal.

Everything it can do is reachable from outside the binary:

- **Command-line flags** ([2]): `-avd`, `-no-snapshot-load`,
  `-no-snapshot-save`, `-no-window`, `-gpu`, `-memory`, `-cores`, `-read-only`.
- **Console** ([3]), also usable through `adb emu <cmd>`: `avd name`, `kill`,
  `rotate`, `avd snapshot …`.
- **gRPC.**
- **Its own Qt window**, which includes the extended controls for location,
  battery, sensors, cellular network, fingerprint and so on.

**Verified on this machine:**

- An AVD written by hand, with no `avdmanager`, booted the android-34 arm64
  image headlessly.
- adb attached as `emulator-5554`.
- `adb emu avd name` returned the AVD name.
- `screencap` produced a 1080×2400 PNG.
- `adb emu rotate` rotated the display.
- `adb emu kill` shut the device down cleanly in about 3 s and saved the
  quick-boot snapshot (log line: `Saving snapshot 'default_boot' using 2560 ms`).
- The next start loaded that snapshot in 1081 ms.

The emulator also writes a discovery file for each running instance at
`~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`. It contains
`avd.name`, `avd.dir`, `port.serial` and `port.adb`. The location is documented
in `emulator -help-all`, and the file was observed on this machine. **The file
is not removed reliably:** it stayed behind after a clean exit. Anything that
reads these files must check that the PID is still alive.

**The official tools are not light to install:**

- `sdkmanager` and `avdmanager` come in `cmdline-tools`. Their classes are Java
  class-file version 61, so they need **a JDK 17 or newer**, and no JRE is
  bundled ([4], checked by inspecting the zip).
- For a user who doesn't have Android Studio, that means installing a JDK
  (about 300 MB) just to download images.

The emulator and `sdkmanager` both get their packages from the same public
repository metadata:

- `https://dl.google.com/android/repository/repository2-3.xml`, which lists the
  emulator, platform-tools and `cmdline-tools`.
- `.../sys-img/<tag>/sys-img2-3.xml`, which lists system images.

Each package entry has:

- archive URLs, broken down by host OS and architecture;
- size and **SHA-1** checksum;
- channel: stable, beta, dev or canary;
- license reference;
- dependencies, such as a minimum emulator revision;
- for system images, API level, `codename` (present on previews), tag and ABI.

**How `sdkmanager` records license acceptance:**

- It appends `sha1(licenseText.trimmed)` as a line in `<sdk>/licenses/<license-id>`.
- **Verified:** the license text stored in this SDK's installed `package.xml`
  files hashes exactly to the values in `licenses/android-sdk-license`
  (`24333f8a…`) and `licenses/android-sdk-arm-dbt-license` (`859f3176…`).
- The text currently served by the repository has been re-wrapped since then,
  so it hashes to a new value. Accepting it means appending a new line, never
  replacing the file.

**Licensing**

- The Android SDK License Agreement covers the emulator and system images
  ([5], dated 2026-04-28).
  - §3.4: no redistribution.
  - §3.1: licensed "solely to develop applications for compatible
    implementations of Android".
- Google system images on ARM use `android-sdk-arm-dbt-license`. AOSP
  `default` images use `android-sdk-license`. Previews use
  `android-sdk-preview-license`.
- The emulator source ([6]) is mostly GPLv2 (QEMU), with other bundled
  licenses alongside.

**Host support**

- macOS 12 or later; Apple Silicon and Intel builds both ship ([1], [7]).
- Latest stable emulator: **37.2.12** (2026-10-01) ([8]).
- From API 37 onward, the minimum RAM for an AVD is **4 GB** ([8], 36.6.11 notes).

**Assessment:** high functionality, low engineering risk, no redistribution
needed. We do not control the engine itself or its resource use.

### B. Custom runtime built from open-source virtualization components

**Virtualization.framework**

- It boots Linux guests with virtio devices.
- Its only Linux graphics device is `VZVirtioGraphicsDeviceConfiguration`,
  which is 2D only: no virgl, Venus or gfxstream ([9]). The UTM maintainers
  confirm there is "no GPU acceleration under AVF" ([10]).
- macOS 27 adds `VZCustomVirtioDeviceConfiguration` ([11]). It might one day
  carry a 3D transport, but that work is experimental (UTM #7921, [12]).

**Cuttlefish**

- Cuttlefish is Google's virtual device for platform work.
- It needs a Linux host with KVM and has **no macOS host support** ([13]).

**What a custom runtime would need**

Getting an AOSP `virtio_arm64` guest to "emulator-equivalent" behaviour would
mean building or maintaining all of the following ourselves:

- a kernel and a ranchu-equivalent device tree;
- a 3D GPU path, which is effectively a gfxstream reimplementation;
- audio, sensors, camera, modem and GNSS;
- adb over vsock or TCP;
- snapshots;
- AOSP image builds, because Google's images target the emulator's own
  virtual hardware.

The only existing prior art does not change this. MacSubsystemForAndroid
([14]) combines LineageOS, QEMU and scrcpy, and it is a hobby project with
software rendering.

**Assessment:**

- Effort: years of engineering.
- GPU acceleration: not available through Apple's API today.
- Images: we would have to build and host our own.
- Not justified by the evidence.

### C. Hybrid: proven engine now, behind a runtime interface

- Ship A as the only runtime, behind a narrow `AndroidRuntime` protocol so the
  UI never builds emulator command lines itself.
- Re-implement natively, with no Java, the part of the official tooling that
  *is* simple and documented by its data: the repository-XML catalog,
  download, SHA-1 verification, unzip, license recording, and the AVD
  `config.ini` / `<name>.ini` format.

This removes the JDK requirement and still writes an SDK layout that is
byte-compatible with Android Studio and `sdkmanager`. Users with an existing SDK
(as on this machine) reuse their images and AVDs with no duplicate downloads.

## Decision

**Adopt C.**

- The first and only runtime adapter drives the official Android Emulator.
- Package management and AVD creation are done natively in Swift, so neither
  Java nor `cmdline-tools` is required.
- The emulator's own window and extended controls are reused instead of
  re-implementing display, input and sensors.
- Revisit B only when Apple exposes accelerated 3D for Linux guests and an
  AOSP target for it exists.

## Consequences

**Apple Silicon and Intel**

- arm64-v8a images run natively under Hypervisor.framework on Apple Silicon.
  This is the only verified configuration.
- Intel Macs would need x86_64 images and the `darwin_x64` emulator archive.
  The catalog logic selects archives by host architecture, so this should
  work, but it is **unverified**.
- ARM images on an Intel host cannot be accelerated ([1]). Moorbox hides those
  combinations.

**Google Play**

- Play images (`google_apis_playstore`) can be *downloaded by the user* from
  Google's official URLs after they accept `android-sdk-arm-dbt-license`. This
  is the same flow `sdkmanager` uses.
- Moorbox never mirrors or bundles them.
- Play Integrity will generally not pass on an emulator ([15]). Banking, DRM
  and some games will refuse to run. Moorbox states this plainly and makes no
  compatibility claims.

**Distribution**

- Moorbox ships only its own Apache-2.0 code.
- Emulator, platform-tools and images are always fetched from `dl.google.com`.
- License text is shown verbatim from the repository metadata before any
  download.

**Intended use**

- The SDK license limits use to app development (§3.1).
- The README positions Moorbox as a developer and tester tool, not a consumer
  "run Android games" product.

**Runtime resource use**

- With the same AVD settings, the engine uses the same resources whether
  Android Studio or Moorbox launches it.
- Moorbox's savings come from not needing the IDE, Java or Gradle, and from
  lighter default presets. The measurement procedure is in `docs/PERFORMANCE.md`.

**Maintenance**

- We depend on the stability of the repository XML schema, which has been on
  revision 2-3 for years, with 2-4 now appearing ([7]).
- We also depend on the AVD config keys and emulator flags.
- These are concentrated in `SDKRepository.swift`, `AVDStore.swift` and
  `EmulatorRuntime.swift`.

## Risks

| Risk | Mitigation |
|---|---|
| Repository schema change, e.g. `sys-img2-4` | Parser ignores unknown elements. Integration test runs against live XML. Fall back to the existing SDK. |
| API-level strings are no longer integers (`37.2`, `36x` for extension images) | Version handled as a string plus a parsed numeric major/minor. Covered by unit tests. |
| Emulator flag or config key churn | Small set of well-established keys, all documented. Integration test boots a real AVD. |
| Discovery files go stale | Check PID liveness and match on `avd.dir`. |
| SHA-1 is the only checksum Google publishes | Verify SHA-1 over HTTPS-only downloads from `dl.google.com`. Document the residual risk. |
| License misunderstanding | Show the full text, record consent the same way `sdkmanager` does, never auto-accept. |

## Sources (all accessed 2026-10-21)

1. Emulator acceleration: https://developer.android.com/studio/run/emulator-acceleration
2. Emulator command line: https://developer.android.com/studio/run/emulator-commandline
3. Emulator console: https://developer.android.com/studio/run/emulator-console
4. sdkmanager: https://developer.android.com/tools/sdkmanager ; avdmanager: https://developer.android.com/tools/avdmanager
5. SDK License Agreement: https://developer.android.com/studio/terms
6. Emulator source: https://android.googlesource.com/platform/external/qemu
7. Repository metadata: https://dl.google.com/android/repository/repository2-3.xml , https://dl.google.com/android/repository/addons_list-5.xml , https://dl.google.com/android/repository/sys-img/google_apis/sys-img2-3.xml
8. Emulator release notes: https://developer.android.com/studio/releases/emulator
9. VZVirtioGraphicsDeviceConfiguration: https://developer.apple.com/documentation/virtualization/vzvirtiographicsdeviceconfiguration
10. UTM discussion #5482: https://github.com/utmapp/UTM/discussions/5482
11. VZCustomVirtioDeviceConfiguration: https://developer.apple.com/documentation/virtualization/vzcustomvirtiodeviceconfiguration
12. UTM issue #7921: https://github.com/utmapp/UTM/issues/7921
13. Cuttlefish: https://source.android.com/docs/devices/cuttlefish , https://source.android.com/docs/devices/cuttlefish/get-started
14. MacSubsystemForAndroid: https://github.com/harkhowalia-1/MacSubsystemForAndroid
15. Play Integrity verdicts: https://developer.android.com/google/play/integrity/verdicts
16. Android Emulator overview: https://developer.android.com/studio/run/emulator
