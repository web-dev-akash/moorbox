#!/bin/bash
# Compares launching one AVD the way Moorbox does vs a plain `emulator -avd` launch.
# Same engine, same AVD, same window mode; only the launch flags differ.
#   ANDROID_AVD_HOME=/path scripts/benchmark-emulator.sh <avd-id> [runs]
# Prints CSV: mode,boot,run,boot_s,idle_cpu_s_per_60s,footprint_mb,rss_mb,stop_s
set -euo pipefail
AVD=$1; RUNS=${2:-2}
SDK="${ANDROID_HOME:-$HOME/Library/Android/sdk}"
ADB="$SDK/platform-tools/adb"
now() { perl -MTime::HiRes=time -e 'printf "%.2f\n", time'; }
cpu() { ps -o time= -p "$1" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
"$ADB" start-server >/dev/null 2>&1
if pgrep -f qemu-system >/dev/null; then echo "Stop other emulators first." >&2; exit 1; fi

echo "mode,boot,run,boot_s,idle_cpu_s_per_60s,footprint_mb,rss_mb,stop_s"
for run in $(seq 1 "$RUNS"); do
  for mode in moorbox plain; do
    for boot in cold quick; do
      args=(-avd "$AVD")
      [[ $mode == moorbox ]] && args+=(-no-metrics -crash-report-mode never)
      [[ $boot == cold ]] && args+=(-no-snapshot-load)
      t0=$(now)
      "$SDK/emulator/emulator" "${args[@]}" >/dev/null 2>&1 &
      until [[ "$("$ADB" -s emulator-5554 shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" == 1 ]]; do sleep 0.5; done
      t1=$(now)
      pid=$(pgrep -f "qemu-system.*-avd $AVD" | head -1)
      sleep 30                       # let post-boot work settle
      c0=$(cpu "$pid"); sleep 60; c1=$(cpu "$pid")
      fp=$(footprint "$pid" 2>/dev/null | awk '/Footprint:/ {v=$(NF-5); u=$(NF-4); if (u=="GB") v*=1024; if (u=="KB") v/=1024; printf "%.0f", v}')
      rss=$(ps -o rss= -p "$pid" | awk '{printf "%.0f", $1/1024}')
      t2=$(now)
      "$ADB" -s emulator-5554 emu kill >/dev/null 2>&1 || true
      while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
      t3=$(now)
      echo "$mode,$boot,$run,$(echo "$t1-$t0" | bc),$(echo "$c1-$c0" | bc),$fp,$rss,$(echo "$t3-$t2" | bc)"
      sleep 5
    done
  done
done
