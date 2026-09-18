#!/bin/bash
# One harness run: kill any Beacon, start the Debug Beacon in harness mode, run the client,
# stop Beacon, analyze. Usage: ./run.sh [label] [presses] [interval_ms] [preset]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-run}"; PRESSES="${2:-100}"; INTERVAL="${3:-700}"; PRESET="${4:-1080p60}"
OUT="/Volumes/yuh/business/.scratch/harness/$(date +%Y%m%d-%H%M%S)-$LABEL"
mkdir -p "$OUT"
APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
pkill -x Beacon 2>/dev/null || true; sleep 1
BEACON_HARNESS=1 BEACON_HARNESS_LOG="$OUT/beacon.log" "$APP/Contents/MacOS/Beacon" >"$OUT/beacon.stdout" 2>&1 &
BEACON_PID=$!
# wait for the listener
for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done
sleep 1.5
SHAPER_PID=""
if [ -n "${SHAPE:-}" ]; then
  # SHAPE="--down-mbps 8 --delay-ms 5"
  python3 "$HERE/shaper.py" --listen 7980 --target 7979 $SHAPE >"$OUT/shaper.log" 2>&1 &
  SHAPER_PID=$!; sleep 0.5
  export HARNESS_PORT=7980
fi
"$HERE/.build/release/harness-client" "$PRESSES" "$INTERVAL" "$OUT/client.log" "$PRESET" 2>"$OUT/client.stderr" || true
[ -n "$SHAPER_PID" ] && kill $SHAPER_PID 2>/dev/null
sleep 0.5
kill $BEACON_PID 2>/dev/null || true; sleep 1
open -g /Applications/Beacon.app 2>/dev/null || true
python3 "$HERE/analyze.py" "$OUT" | tee "$OUT/report.txt"
echo "$OUT"
