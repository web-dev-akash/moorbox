# Performance

Moorbox treats **the management app** and **the Android device** as two separate
resource budgets, and measures them separately. Nothing here is a target
restated as a result.

## Environment

| | |
|---|---|
| Mac | Apple M4 Pro (14 cores), 24 GB RAM |
| macOS | 27.0.1 (26A434) |
| Moorbox | 0.1.0, release build (ad-hoc signed). Re-checked on 0.2.0 (universal Xcode Release build): 44 MB footprint at launch. |
| Emulator | 36.5.11 (build 15261927), windowed, `hw.gpu.mode=auto` (gfxstream on the host GPU) |
| Device | API 34 `google_apis` arm64-v8a; 2 GB RAM, 2 cores, 1080×2400 @ 420 dpi, 6 GB data partition |
| Date | 2026-10-21 |

## 1. The Moorbox app itself

**Method:** `scripts/measure-app.sh <settle> <idle>`. It:

1. launches `dist/Moorbox.app`;
2. waits `<settle>` seconds;
3. samples CPU time with `ps -o time` at the start and end of a `<idle>`-second
   window, with no interaction;
4. reads memory with `footprint` (`phys_footprint`, the number Activity Monitor
   calls "Memory") and RSS.

No emulator was running.

| State | Settle | Footprint | RSS | CPU time used in 60 s idle | Threads |
|---|---|---|---|---|---|
| Devices screen (setup done) | 15 s | 43 MB | 116 MB | 0.24 s (launch tail) | 3 |
| Devices screen (setup done) | 60 s | 52 MB | 124 MB | **0.00 s** | 3 |
| First run: Setup sheet + full catalog fetched and parsed | 15 s | 53 MB | 123 MB | 0.33 s (launch tail) | 4 |

**Result:**

- **Under the 100 MB idle target:** 43–53 MB footprint.
- **No measurable idle CPU** once launch work has finished.

RSS is higher than footprint because it counts shared system framework pages.

Why idle is free:

- There are no polling timers.
- Device state comes from a kqueue watch on the emulator's instance registry
  directory and on each emulator process.
- adb is polled once per second, and only while a device is booting.
- The SDK catalog is fetched only when Android Versions or Setup is shown.

## 2. The emulator: Moorbox launch vs plain `emulator` launch

Moorbox doesn't replace the emulator engine (see
[ADR-001](architecture/ADR-001-runtime-strategy.md)). Its claim is **parity**,
not savings: launching a device through Moorbox should cost the same as
launching it any other way.

**Method:** `ANDROID_AVD_HOME=… scripts/benchmark-emulator.sh <avd> <runs>`.
Each run alternates the two launch modes on the same AVD:

| Mode | Launch flags |
|---|---|
| `moorbox` | Moorbox's flags: `-avd X -no-metrics -crash-report-mode never` |
| `plain` | `-avd X` |

Each mode is run as:

- **cold:** `-no-snapshot-load`, Android boots from scratch;
- **quick:** quick boot from the snapshot saved by the previous graceful stop.

What is measured:

| Metric | How |
|---|---|
| `boot_s` | Process launch until `getprop sys.boot_completed` = 1 (polled every 0.5 s) |
| Idle CPU | Host CPU-seconds the qemu process used in a 60 s window, starting 30 s after boot, with no interaction |
| Memory | `footprint` and RSS of the qemu process at the end of that window |
| `stop_s` | `adb emu kill` until the process exits; includes saving the snapshot |

### Results (2 runs per cell; device: API 34, 2 GB, 2 cores, windowed)

Raw data (`scripts/benchmark-emulator.sh Feas 2`):

```
mode,boot,run,boot_s,idle_cpu_s_per_60s,footprint_mb,rss_mb,stop_s
moorbox,cold,1,20.78,21.59,2603,2114,4.60
moorbox,quick,1,7.17,5.47,3230,1627,3.57
plain,cold,1,17.26,8.07,2221,1696,3.38
plain,quick,1,6.39,6.33,3077,980,4.19
moorbox,cold,2,17.04,8.11,2290,1668,3.77
moorbox,quick,2,7.05,5.85,3139,665,3.76
plain,cold,2,16.96,8.55,2281,3688,2.75
plain,quick,2,6.93,5.85,3130,1823,3.78
```

| | Moorbox launch | Plain `emulator -avd` |
|---|---|---|
| Cold boot to `boot_completed` | 17.0 s, 20.8 s¹ | 17.0 s, 17.3 s |
| Quick boot to `boot_completed` | 7.1 s, 7.2 s | 6.4 s, 6.9 s |
| Idle CPU after quick boot (CPU-s per minute) | 5.5, 5.9 | 5.9, 6.3 |
| Idle CPU after cold boot (CPU-s per minute) | 8.1, 21.6¹ | 8.1, 8.6 |
| Host footprint after quick boot | 3.1–3.2 GB | 3.1 GB |
| Host footprint after cold boot | 2.3–2.6 GB | 2.2–2.3 GB |
| Graceful stop with snapshot save | 3.6–4.6 s | 2.8–4.2 s |

¹ This was the very first emulator launch of the session, with cold file
caches and Android's first-boot work still running. The plain launch that
followed reused warm caches. The second Moorbox cold boot matches the plain
numbers.

**Conclusions:**

- **Parity.** There is no consistent difference between the two modes. Moorbox's
  extra flags (`-no-metrics -crash-report-mode never`) neither cost nor save
  measurable resources. Moorbox makes **no claim** that the guest uses less RAM
  or CPU than the official emulator.
- **A running 2 GB device costs about 2.2–3.2 GB of host memory.** After a quick
  boot the restored guest RAM is fully resident, which is why that number is
  higher.
- **An idle running device uses about 10% of one core** (about 6 CPU-seconds per
  minute). The Android guest is never fully idle. This is the biggest
  runtime-cost item, and the place to investigate next (see below). Stopping
  devices you aren't using is the most effective saving, and quick boot
  (about 7 s) makes that cheap.
- **RSS is not a usable metric here.** It swung between 0.7 and 3.7 GB for
  identical runs because macOS compresses and pages guest memory. Use
  `footprint`.

**Caveats for this run:**

- The Mac was not otherwise idle: builds and short UI captures ran during some
  of the runs.
- One Moorbox debug instance briefly adopted the running device and queried
  `sys.boot_completed` once.


## 3. Other measured timings (integration tests, headless)

These come from `MOORBOX_INTEGRATION=1 swift test` on the same Mac, using
`-no-window`. The emulator then picks software rendering (SwiftShader), so
these timings are not comparable with the windowed numbers above.

| Operation | Time |
|---|---|
| Cold boot, API 34 `google_apis`, 2 GB, 2 cores | 26.1 s, 27.4 s |
| Quick boot from snapshot | 6.0 s |
| Install and launch an 8.6 KB test APK (`adb install -r` + `am start`) | 4.2 s, 4.5 s |
| Graceful stop with snapshot save | 2.4 s |
| First boot of a freshly installed API 36 AOSP image | 35.2 s |
| Download, verify and install emulator 37.2.12 (396 MB) | 50 s |
| Download, verify and install API 36 AOSP image (773 MB) | 96 s |
| Download, verify and install platform-tools (15 MB) | 3–6 s |

## Disk usage and duplication

- Moorbox reuses an existing SDK and `~/.android/avd`, so nothing is downloaded
  twice when Android Studio is also installed.
- Downloads go through a single staging folder inside the SDK, which is removed
  after every install, whether it succeeded or failed.
- Device disk images are sparse, so Moorbox reports *allocated* size.

## Limitations of these measurements

- One Mac, one macOS version, one API level, small sample sizes (2 runs per
  cell). Treat the differences between modes as noise unless they are
  consistent across runs.
- Post-cold-boot idle CPU is dominated by Android's own first-boot work, such
  as dexopt and package scanning, and varies a lot between runs.
- Android Studio's own IDE footprint was not measured, so this document makes
  no claim of the form "X% lighter than Android Studio".
- GPU memory used by gfxstream on the host GPU is not fully captured by
  `footprint`.

## How to improve runtime cost (future work, measure first)

- Lower default guest RAM per API level where it stays stable. The Lightweight
  preset already uses 2 GB below API 37.
- Measure `hw.audioOutput=no`, `-no-audio` and 60 Hz vs lower refresh for idle
  CPU.
- Measure the effect of `hw.gpu.mode` choices on host memory.
- Expose a "pause when idle" option using the emulator's snapshot save.
