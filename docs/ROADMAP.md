# Roadmap

The order follows the project plan, with priorities adjusted for what has been
measured. Items are only marked done when they have been verified. See
[PROJECT_STATUS.md](PROJECT_STATUS.md).

## Done (0.1.0)

| Phase | Delivered |
|---|---|
| 0 — Feasibility | [ADR-001](architecture/ADR-001-runtime-strategy.md) |
| 1 — Native app foundation | Native SwiftUI app, runtime protocol, unit tests |
| 2 — SDK and runtime setup | SDK discovery; Java-free install of the emulator, platform-tools and system images from Google's repository metadata |
| 3 — Device lifecycle | Create, start, stop, restart, quick boot and cold boot, live state, adb |
| 4 — APK workflow and debugging | APK install, open and uninstall; logcat; screenshots; device controls; diagnostics |
| 5 — Performance (first pass) | Measurements in [PERFORMANCE.md](PERFORMANCE.md) |
| 6 — Release preparation | Docs, licenses, CI, packaging script, release workflow |

## Done (0.2.0)

- Official toolchain: Android CLI with `--no-metrics`, `avdmanager`, Java
  detection plus a Temurin install with consent ([ADR-002](architecture/ADR-002-official-sdk-tools.md)).
- XcodeGen project, XCUITest, SwiftLint and SwiftFormat, CI for lint, unit, UI
  and Release builds.
- Universal DMG; Homebrew build-from-source formula ([ADR-003](architecture/ADR-003-distribution.md)).
- Resumable downloads that survive relaunch.

## Next

1. **Finish manual QA.** Work through the ☐ rows in [QA_CHECKLIST.md](QA_CHECKLIST.md).
2. **First public release.** Create the Homebrew tap repository, tag `v0.2.0`,
   publish the draft release and update the formula checksum.
3. **Verify the formula end to end.** This needs Xcode 27 on macOS 27, which
   Homebrew requires.
4. **Updates for installed images.** Flag when an installed image has a newer
   revision in the catalog, and update it with `android sdk update`.
5. **Disk usage view.** Show the size of each image and device, and offer
   cleanup.
6. **Localization.** Add a String Catalog. The UI strings are already
   `LocalizedStringKey` literals.

## Phase 7 — Advanced features (in priority order)

1. **Several devices at once.** Already allowed by the emulator (different ports) and tracked by the app. Add per-device resource totals, and a warning before total guest RAM exceeds a safe fraction of host memory.
2. **More device profiles and custom screen sizes.** The model and validation exist. Expose width, height and density editing in the Create sheet.
3. **Location, battery, sensors and network.** The emulator's own window already provides these under extended controls. Native equivalents could use the emulator console (`geo fix`, `power capacity`, `network speed`) through `adb emu`.
4. **Import and export device configurations.** Export `config.ini` together with a reference to the image, never the user data.
5. **Snapshot management.** List, save and load named snapshots with `adb emu avd snapshot …`.
6. **Deeper runtime optimisation.** Benchmark lower RAM defaults per API level, `-gpu` modes and `hw.audioInput`. Measure before changing defaults.
7. **Alternative runtime.** Revisit when Virtualization.framework exposes accelerated 3D for Linux guests (see `VZCustomVirtioDeviceConfiguration`, macOS 27) and an AOSP target exists. The `AndroidRuntime` protocol is the seam.
8. **Intel Macs.** The code selects `darwin_x64` archives and `x86_64` images. Needs real hardware to verify.
