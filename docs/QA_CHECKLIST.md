# Manual QA checklist

Run this before each release on at least one Apple Silicon Mac. Record the Mac
model, the macOS version, the emulator version and the image used.

**Status column:**

- **✅ 0.1.0** — verified for 0.1.0, on an M4 Pro running macOS 27.0.1, with
  emulator 36.5.11 / 37.2.12 and API 34 / 36 images.
- **🔁** — automated by an integration test.
- **☐** — not yet run.

| # | Scenario | Steps | Expected | Status |
|---|---|---|---|---|
| 1 | First installation, existing SDK | Launch with Android Studio's SDK at `~/Library/Android/sdk`. | Setup shows the Mac checks, the SDK path, the emulator and adb versions, the installed images and existing devices. Nothing is downloaded. | ✅ 0.1.0 |
| 2 | Missing SDK | Point Settings → SDK at an empty folder. | Setup offers to install the Emulator and Platform tools, showing size, destination and license. Devices shows "Android Emulator not set up". | 🔁 (installer path) / ☐ (UI) |
| 3 | Fresh install from scratch | In an empty folder, install the emulator, platform-tools and an image, create a device and start it. | Each download shows its license first. The device boots. No Java needed. | 🔁 `freshSDKFromScratchBootsADevice` |
| 4 | Download interruption | Start an image install, then Cancel. Retry. Also turn off Wi‑Fi mid-download, then Retry. | Cancel removes the staging folder. The error is shown with a Retry button. Retry continues or restarts. Nothing half-installed appears in `system-images/`. | ☐ |
| 5 | Insufficient disk space | Use a nearly full volume as the SDK location. | The install sheet shows "Not enough free disk space" and disables Install. The installer refuses before downloading. | ☐ |
| 6 | Create device | New Device, then try each preset; try 1 GB RAM on API 37. | Limits match the image and Mac. API 37+ cannot go below 4 GB. The device appears in the list and in Android Studio. | ✅ 0.1.0 (AVD written + booted) |
| 7 | Start, stop, restart | Start (quick boot), Stop, Cold Boot, Restart. | The state moves through Starting → Booting → Running → Shutting down → Stopped. The UI stays responsive. Stop saves a quick-boot snapshot. | ✅ 0.1.0 (start/stop via AppModel) |
| 8 | Device boot failure | Remove the device's system image (Android Versions → Remove), then Start. | A clear "system image is not installed" error. The device and its data are untouched. | ☐ |
| 9 | Crash recovery | While a device runs, `kill -9` its qemu process. | The state shows Failed with a remedy. Start works again. User data is kept. | ✅ 0.1.0 (SIGKILL → "Failed to run", exit code 137, with a remedy; userdata and snapshot untouched; the next Start reached Running in 8 s) |
| 10 | ADB disconnection | `adb kill-server` while a device runs, then use Screenshot or App Installer. | Commands report the adb error. Diagnostics → "Check adb connection" restarts the server and reports the devices. | ☐ |
| 11 | Install APK | Drag `.build/test-apk/moorbox-hello.apk` onto App Installer. | "Installed moorbox-hello.apk." The package appears; Open launches it. | 🔁 (adb layer) / ☐ (drag-and-drop UI) |
| 12 | Invalid APK | Drop a renamed `.txt` file, and a non-`.apk` file. | "…is not an APK file." Nothing is sent to the device. | 🔁 unit test / ☐ UI |
| 13 | Incompatible APK | Install an x86-only APK on arm64. | The error explains the ABI mismatch (`INSTALL_FAILED_NO_MATCHING_ABIS`). | ☐ |
| 14 | Device deletion | Delete a device that has been booted. | The confirmation mentions its data and size. The device goes to the Trash and is recoverable. A running device can't be deleted. | ☐ |
| 15 | App relaunch with a running device | Start a device, quit Moorbox, reopen it. | The device keeps running and Moorbox shows it as Running. Stop still works. | ✅ 0.1.0 adoption (an emulator started outside Moorbox was shown as Running with its serial); ☐ Stop after relaunch |
| 16 | Quit Moorbox from Terminal with Ctrl-C | Run the app from Terminal, start a device, press Ctrl-C. | The emulator keeps running (it has its own session). | 🔁 unit test (`getsid`) |
| 17 | Sleep and wake | Sleep the Mac with a device running, then wake it. | The device resumes, the state is still Running, and adb commands work. | ☐ |
| 18 | Light and dark appearance | Switch the system appearance. | All screens stay readable. | ✅ 0.1.0 (Setup, Devices, Create, Versions, App Installer and Diagnostics captured in light and dark) |
| 19 | Keyboard | ⌘N, ⌘R, ⇧⌘R, ⌘→, ⇧⌘S, ⌘[, ⇧⌘H, ⌘, | Each runs its menu action, and is disabled when not applicable. | ☐ |
| 20 | Diagnostics export | Export Report… | The saved text contains no home path, user name, email or token. | 🔁 redaction unit test / ☐ UI |
| 21 | Uninstall Moorbox | Delete Moorbox.app. | The SDK, devices and logs remain (see README → Data locations). | ☐ |
| 22 | Play Store image | Install a `google_apis_playstore` image, then create and boot a device. | The license is shown before download. The device boots with Play Store. | ☐ |
