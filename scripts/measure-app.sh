#!/bin/bash
# Measures Moorbox's own idle cost: launches dist/Moorbox.app, waits, then samples
# memory (phys_footprint and RSS) and CPU time consumed over an idle window.
#   scripts/measure-app.sh [settle-seconds] [idle-seconds]
set -euo pipefail
cd "$(dirname "$0")/.."
SETTLE=${1:-15}; IDLE=${2:-60}
open -n dist/Moorbox.app
sleep "$SETTLE"
PID=$(pgrep -f 'Moorbox.app/Contents/MacOS/Moorbox' | head -1)
cpu() { ps -o time= -p "$PID" | awk -F'[:.]' '{ if (NF==3) print $1*60+$2+$3/100; else print $1*3600+$2*60+$3+$4/100 }'; }
C0=$(cpu); sleep "$IDLE"; C1=$(cpu)
FP=$(footprint "$PID" 2>/dev/null | awk '/Footprint:/ {print $(NF-5), $(NF-4)}')
RSS=$(ps -o rss= -p "$PID" | awk '{printf "%.0f MB", $1/1024}')
echo "footprint=$FP rss=$RSS cpu_seconds_over_${IDLE}s=$(echo "$C1 - $C0" | bc) threads=$(ps -M -p "$PID" | tail -n +2 | wc -l | tr -d ' ')"
kill "$PID"
