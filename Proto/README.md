# Vendored protocol definitions

`emulator_controller.proto` is the Android Emulator's gRPC control API
(`android.emulation.control.EmulatorController`), copied unmodified from Android
Emulator 36.5.11 (`<sdk>/emulator/lib/emulator_controller.proto`). The upstream
source is https://android.googlesource.com/platform/external/qemu (`android/android-grpc`).

License: Apache License 2.0, Copyright (C) 2018 The Android Open Source Project.
See the header of the file.

The Swift code in `Sources/EmulatorControl/Generated/` is generated from it by
`scripts/generate-grpc.sh`. Regenerate after updating the proto. Don't edit the
generated files by hand.
