# Third-party notices

Moorbox's own source code is licensed under Apache-2.0 (see `LICENSE`). Moorbox
links only against Apple system frameworks:

- Foundation
- SwiftUI
- AppKit
- CryptoKit
- Observation

It has **no third-party Swift package dependencies**, and the app bundle
contains no third-party code.

## Components Moorbox downloads for you (not bundled, not redistributed)

At your request, Moorbox downloads these components directly from Google
(`https://dl.google.com/android/repository/`), using the same repository
metadata that `sdkmanager` and Android Studio use.

Before each download, Moorbox shows you the full license text from that
metadata. If you accept, Moorbox records your acceptance the same way
`sdkmanager` does. These components are **not** covered by Moorbox's license.

| Component | Repository license ID | Notes |
|---|---|---|
| Android Emulator (`emulator`) | `android-sdk-license` (stable channel) | Google binary distribution. Its source is mostly GPLv2 (QEMU) plus other open-source licenses ([source](https://android.googlesource.com/platform/external/qemu)). Bundled notices are in the emulator's `NOTICE` files inside your SDK folder. |
| Android SDK Platform-Tools (`adb`) | `android-sdk-license` | Google binary distribution. |
| Android system images, AOSP (`default`) | `android-sdk-license` | Built from the Android Open Source Project. |
| Android system images, Google APIs / Google Play (ARM) | `android-sdk-arm-dbt-license` | Contain **proprietary Google software**. Google Play images include Google Play services and the Play Store. These are not open source. |
| Preview, beta and canary system images | `android-sdk-preview-license` | Pre-release terms apply. |

The [Android Software Development Kit License Agreement](https://developer.android.com/studio/terms)
restricts redistribution (§3.4) and licenses the SDK for developing
applications (§3.1). For these reasons Moorbox does not mirror, cache for others,
or bundle any of these components.

## Test-only tools (never shipped)

`scripts/build-test-apk.sh` builds a tiny test APK from `Tests/TestApp` for the
opt-in integration tests. It uses the following tools from your local SDK and
JDK:

- From the SDK: `aapt2`, `d8`, `zipalign`, `apksigner`, `android.jar`.
- From the JDK: `javac`, `keytool`.

The built APK and its throwaway signing key are written to `.build/` and are
git-ignored.

## Trademarks

Android, Google Play and Google are trademarks of Google LLC. Apple, macOS and
Apple Silicon are trademarks of Apple Inc. Moorbox is not affiliated with either
company.
