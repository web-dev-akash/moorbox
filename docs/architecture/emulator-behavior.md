# Emulator behavior Moorbox depends on

These notes were observed with emulator 36.5.11 and 37.2.12 on macOS 27
(Apple Silicon), 2026-10-21. Re-check them when bumping the minimum emulator
version.

## Running-instance registry

The emulator writes `~/Library/Caches/TemporaryItems/avd/running/pid_<pid>.ini`.
The location is documented in `emulator -help-all`.

| Key | Meaning |
|---|---|
| `avd.id` | The AVD's file name (`My_Phone`) |
| `avd.name` | The **display name** (`My Phone`), not the ID |
| `avd.dir` | Absolute path of the `.avd` folder |
| `port.serial` | Console port. The adb serial is `emulator-<port.serial>`. |
| `port.adb` | adb port |
| `grpc.*` | gRPC port and tokens. Redacted from diagnostics. |

The file is written once the emulator is up, not at process start.

**Gotcha: stale files.** The file is **not reliably deleted**. It stays behind
after `adb emu kill`, after SIGKILL, and after a crash. Moorbox therefore:

- treats an entry as live only if the PID is alive, is not a zombie, and its
  executable is `qemu-system-*` or `emulator` (guards against PID reuse);
- matches devices on `avd.dir` first, then `avd.id`.

Moorbox watches the directory with a kqueue `DISPATCH_SOURCE_TYPE_VNODE` source,
so state updates without polling.

## Process model

- With `-no-window`, `emulator` exec's `qemu-system-aarch64-headless`. With a
  window, it runs `qemu-system-aarch64`.
- In both cases the PID Moorbox spawns is the PID in the registry, since the
  launcher exec's rather than forking.
- Moorbox spawns with `POSIX_SPAWN_SETSID`, so the emulator survives Moorbox
  quitting and Ctrl-C in a terminal.
- **Zombies:** an exited child that hasn't been reaped still answers
  `kill(pid, 0)`. Liveness checks use `sysctl(KERN_PROC_PID)` and test for
  `SZOMB`.

## Blocking consent dialogs

- If a previous run crashed, which also happens occasionally during exit, the
  next launch shows a **modal crash-report consent dialog**.
- Android doesn't boot until someone answers it, and the process ignores
  SIGTERM while it's shown.
- Moorbox always passes `-no-metrics -crash-report-mode never`. This also
  enforces "no telemetry".

## Shutdown and snapshots

- `adb -s emulator-N emu kill` saves the `default_boot` snapshot (about 2.5 s
  for a 2 GB guest) and exits cleanly. Snapshot saving is skipped with
  `-no-snapshot-save`.
- `-no-snapshot-load` forces a cold boot but still saves on exit.
- A missing or invalid snapshot falls back to a cold boot automatically. The
  log shows `Failed to load snapshot` at WARNING level, which is not an error.
- Device data (`userdata-qemu.img*`) is independent of the snapshot, so "Reset
  Quick Boot" deletes only `snapshots/default_boot`.

## Graphics

- With `hw.gpu.mode=auto`:
  - a windowed launch uses gfxstream on the host GPU;
  - a headless launch (`-no-window`) selects software rendering (lavapipe and
    SwiftShader).
- Headless timings are therefore not comparable with windowed ones.

## Error output

These were captured and are used in `EmulatorDiagnosis` tests:

| Situation | Output |
|---|---|
| Unknown AVD | `ERROR | Unknown AVD name [X], use -list-avds to see valid list.` |
| Missing system image | `FATAL | Cannot find AVD system path. Please define ANDROID_SDK_ROOT` (exit 1) |
| Wrong architecture | `Avd's CPU Architecture '%s' is not supported by the QEMU2 emulator on aarch64 host.` (from the binary's strings) |

## SDK repository

- Previews are marked by `<codename>`. Their `<channelRef>` can still be
  `channel-0` ("stable").
- `api-level` is a string: `"36.1"`, or `"36x"` for extension-level images.
- Images can carry extra capability tags, such as `ai_glasses_compatible` on
  the 37.0 `google_apis` image, so match tags by membership.
- Checksums are SHA-1 only.
- Resumed downloads from `dl.google.com` return HTTP 206.
- **License acceptance** is stored by `sdkmanager` as `sha1(text.trimmed)`, one
  line per accepted text, in `licenses/<id>`. Google re-wraps license text over
  time, so the same license can need a new line.
