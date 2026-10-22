# ADR-004: A self-contained Android runtime (BlueStacks-style)

- **Status:** Accepted in part (2026-10-22). Phase A is approved; Phases B and C follow, and the image-build infrastructure is decided later.
- **Date:** 2026-10-22
- **Context owner:** project owner. The goal is a production-grade emulator like
  BlueStacks or Nox that "has everything of its own and needs nothing from the
  user's end to be installed separately".

## Context

Moorbox 0.2 manages Google's emulator and SDK, which the user has to download (with
consent). The new goal is one app that brings its own Android runtime.

## Findings

These are summarised from two research passes. The sources are cited in the
research notes in the PR description.

**How the existing products work**

- BlueStacks Air (Android 13) and MuMu Pro (Android 12) run on Apple Silicon.
  Neither discloses its virtualization or GPU stack. Both include the Play Store.
- NoxPlayer and LDPlayer have no Apple Silicon build.
- Genymotion ships no Google apps "for IP reasons".

**Google Play can't be shipped by us**

- Bundling GMS (Play Store and Play services) requires a MADA licence from Google
  plus CTS/GTS certification. That isn't realistic for an open-source project.
- Google's emulator system images are not redistributable (SDK License §3.4).
- "Android" can't appear in the product name.

**What can be shipped**

| Component | License |
|---|---|
| Our own AOSP builds | Apache-2.0, plus a GPLv2 kernel whose source we publish |
| QEMU-based AEMU built from source | GPLv2 combined work; LGPL Qt kept as replaceable dylibs |
| F-Droid client and Privileged Extension | GPL-3.0 |
| microG | Apache-2.0 |

Aurora Store may be redistributed, but using it breaks Google Play's terms and
puts users' accounts at risk.

**Engine: AEMU is the only path with GPU acceleration on a Mac today**

- AEMU is the Android Emulator: QEMU + HVF + gfxstream, with Metal/KosmicKrisp
  for Vulkan and ANGLE for GLES. Source is at
  `android.googlesource.com/platform/external/qemu`, branch `emu-main-dev`. It
  builds on macOS arm64 with `android/rebuild.sh`.
- Virtualization.framework has no 3D. macOS 27's `VZCustomVirtioDevice` with
  Venus is Linux-guest-only and experimental.
- QEMU + virtio-gpu (as LineageOS virtio uses) has no fast GPU path on macOS
  hosts.

**System image: AOSP `sdk_phone64_arm64` (goldfish)**

- Built from `android-latest-release`, which is currently Android 17 / API 37.
  Since 2025 AOSP publishes source only twice a year (Q2 and Q4).
- **Building needs Linux x86_64, 64 GB+ RAM and about 400 GB of disk.** macOS
  hosts have been unsupported since Android 11. About 2–3 hours per build on
  16 cores.
- A prebuilt GKI kernel is used, and its matching source must be mirrored.

**32-bit ARM apps**

- Apple Silicon has no AArch32. armeabi-v7a-only apps cannot run, and no
  open-source translator exists. Google Play has required 64-bit code since
  2021, so this mainly affects old games and sideloaded APKs.

**Play Integrity**

- Basic integrity at best. Banking apps, DRM'd apps and some games will refuse
  to run, and that is true of any non-certified emulator.

**Display embedding works today**

- The emulator's gRPC `EmulatorController` provides `streamScreenshot` with
  `MMAP` shared-memory transport, plus `sendTouch`, `sendKey`, `sendMouse`,
  `injectWheel` and audio streams. The emulator runs with `-qt-hide-window`.
- This is how Android Studio embeds its emulator, and it applies equally to a
  source-built AEMU. Verified locally: the proto ships with emulator 36.5.11.

## Proposed architecture

```
Moorbox.app
├── Contents/MacOS/Moorbox                  SwiftUI app: single window, Android display embedded
├── Contents/Frameworks/…                   AEMU built from source (GPLv2), Qt (LGPL, dylibs), gfxstream, KosmicKrisp
└── (first launch) ~/Library/Application Support/Moorbox/images/
        android-17-arm64.img bundle          our AOSP build, downloaded once from our releases (checksummed)
```

- **One app, one window.** The Android screen is embedded via gRPC with MMAP.
  Moorbox draws the toolbar: Home, Back, Recents, rotate, volume, screenshot,
  install APK, shake and location.
- **The user installs nothing separately.** The runtime ships in the app. The
  system image is about 1.5 GB compressed. It's either downloaded on first launch
  (one consent screen, from our own GitHub Releases) or bundled in a larger DMG.
- **App stores.** F-Droid comes preinstalled. APK install by drag and drop already
  works. microG is optional, for apps that need basic Play Services APIs.
- **The current "Google SDK" mode stays** as a developer option for people who
  want Google APIs or Play Store images. Those come from Google under Google's
  terms.

## Phased plan

| Phase | Deliverable | Where | Notes |
|---|---|---|---|
| A | **Single-window player:** embedded display, input and toolbar, using the emulator Moorbox already manages | This Mac | Most of the BlueStacks-like UX. Unchanged when the engine is swapped. |
| B | **AEMU from source:** reproducible build script, hypervisor entitlement, bundled inside Moorbox.app, GPL source tarball | This Mac, then GitHub macOS CI | About 30–60 GB checkout. Removes the need to download Google's emulator. |
| C | **Our own Android 17 arm64 image:** AOSP `sdk_phone64_arm64` plus F-Droid, packaged and checksummed, hosted on our releases | Linux x86_64 build machine (64 GB RAM, 400 GB) | Removes the dependency on Google's images. Needs infrastructure. |
| D | **Zero-install flow:** first launch shows one consent screen, downloads the image, boots | Mac | Achieves "needs nothing from the user" |
| E | **Player features:** keyboard→touch mapping for games, multi-instance, per-instance resources, gamepad | Mac | The BlueStacks feature set |

## Open decisions (owner)

1. **Linux build machine** for Android images. Options:
   - rent a dedicated server (about €260/month);
   - use an on-demand cloud VM only for the twice-yearly builds (about $20–60
     per build);
   - provide our own machine.
2. **Google apps policy.** Options:
   - no Google apps; F-Droid plus APKs (recommended, legal);
   - optional microG;
   - optional Aurora Store with a warning.
3. **Start with Phase A now** on the current engine, while B and C are prepared.
4. **Disk use on this Mac** for the AEMU source checkout (about 30–60 GB of the
   109 GB free).

## Owner decisions (2026-10-22)

- **Start with Phase A,** the single-window player, on the emulator that works today.
- **App stores:** F-Droid preinstalled. Optional microG. Keep the Google-images
  developer mode, where the user downloads Google's images from Google.
- **Google Mobile Services licensing:** not pursued. The licence is free, but it
  is granted selectively to device-making companies after lab certification, so
  it isn't realistic for this project.
- **Image builds:** decided later. Options:
  - this Mac in an x86_64 Linux VM with Rosetta, plus an external SSD of 1 TB or
    more (109 GB is free now; a build needs about 250–400 GB);
  - an on-demand cloud VM;
  - freeing up internal disk.
- **Emulator source build on this Mac:** approved (about 30–60 GB).

## Progress

**Phase A, 2026-10-22: done and verified on a real device.**

- `EmulatorControl` is a gRPC Swift 2 client generated from the emulator's own
  proto.
- The emulator runs with `-qt-hide-window -grpc-use-token`. The endpoint and
  token come from the user-only discovery file, and the service binds to
  127.0.0.1.
- Frames arrive through a file-backed mmap. About 47 fps was measured.
- Mouse, wheel and keyboard input work, and there's a side toolbar.
- One window per device. Closing it stops devices that Moorbox started; other
  tools' devices are never stopped.
- Live UI tests cover: Start opens the player, Android boots in it, the toolbar
  and gestures work, and closing the window stops the device.
- The minimum macOS is now 15, as gRPC Swift 2 requires.
