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

## Google's SDK tools (cmdline-tools 23.0, Android CLI 1.0.16625370)

**`sdkmanager`**

- It is a POSIX shell wrapper. It prints a deprecation warning, then runs
  `bin/android --sdk=<root> sdk install|remove|list …`.
- It converts `;` to `/` in package paths and maps `--channel=1` to `--beta`
  and 2 or 3 to `--canary`.

**`bin/android`** (3.6 MB)

- A launcher. On first use it downloads the real CLI to
  `~/.android/bin/android-cli` (87 MB, native arm64, no Java needed).
- State lives in `~/.android/cli/`: `analytics/`, `bundles/`,
  `last_update_check` and `tos_displayed`.

**Metrics**

- They are on by default.
- `--no-metrics` placed **before** the subcommand prevents any write under
  `~/.android/cli/analytics/`. This was verified by snapshotting the folder.

**Licenses**

- `sdk install` prints a terms-of-service banner once, then installs without a
  prompt.
- It writes `licenses/<id>` in the classic `sha1(text.trimmed)` format.

**Output and progress**

- No progress percentages are printed, even on a TTY. The output is just
  `\r<url>...` then `\rUnzipping <pkg>......`.
- Downloads go to `<sdk>/.sdk/arch/<archive-sha1>.part`.
- An SDK-wide lock lives at `<sdk>/.sdk/lock`.

**Results**

- Installed packages get Google's `package.xml`.
- Exit codes are non-zero on failure (since 1.0.16406183). Moorbox also confirms
  the package exists on disk.

**`android emulator create [profile]`** takes only a profile, so it can't choose
the image, RAM or cores. Not used.

**`avdmanager`**

- Still a Java program (`lib/avdmanager-classpath.jar`), needing Java 17 or newer.
- It only manages the SDK it is installed in; `--sdk_root` is rejected for
  `create avd`.
- `create avd -n <id> -k <package> -d <device>` asks "custom hardware profile?"
  on stdin; Moorbox answers `no`.
- It doesn't follow a symlinked system-image directory ("contains no system
  images"). An APFS clone (`cp -c`) works.
- It writes the full set of hardware defaults, including:
  - `disk.dataPartition.path=<temp>` — user data **still persists** across
    restarts (verified with an installed APK);
  - `hw.gpu.enabled=no` — Moorbox sets `yes`;
  - `hw.ramSize=2G`;
  - `disk.dataPartition.size=10G`;
  - `hw.cpu.ncore=4`.
- `list device` prints `id: N or "<id>"` blocks with `Name`, `OEM` and an
  optional `Tag`. Wear, TV, Automotive, XR, desktop and glasses profiles have a
  tag; phones and tablets don't.

## Downloads from dl.google.com

- When a client sends `Accept-Encoding: gzip`, the server answers range requests
  from a **gzip-encoded variant** of the zip (155,361,241 bytes vs 155,384,151).
- A resumed range of that variant can't be decoded (`NSURLErrorCannotDecodeRawData`).
  Moorbox requests `Accept-Encoding: identity`, so byte ranges match the file on
  disk.
