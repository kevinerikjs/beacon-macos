#!/bin/bash
# One harness run: kill any Beacon, start the Debug Beacon in harness mode, run the client,
# stop Beacon, analyze. Usage: ./run.sh [label] [presses] [interval_ms] [preset]
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-run}"; PRESSES="${2:-100}"; INTERVAL="${3:-700}"; PRESET="${4:-1080p60}"
OUT="/Volumes/yuh/business/.scratch/harness/$(date +%Y%m%d-%H%M%S)-$LABEL"
mkdir -p "$OUT"
APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
pkill -x Beacon 2>/dev/null || true
for i in $(seq 1 50); do pgrep -x Beacon >/dev/null 2>&1 || break; sleep 0.2; done   # the old Beacon must be gone, not just its listener
pkill -9 -x Beacon 2>/dev/null || true
sleep 0.5
BEACON_HARNESS=1 BEACON_HARNESS_LOG="$OUT/beacon.log" "$APP/Contents/MacOS/Beacon" >"$OUT/beacon.stdout" 2>&1 &
BEACON_PID=$!
# wait for the listener
for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done
sleep 1.5
SHAPER_PID=""
if [ -n "${SHAPE:-}" ]; then
  # SHAPE="--down-mbps 8 --delay-ms 5"
  python3 "$HERE/shaper.py" --listen 7980 --target 7979 $SHAPE >"$OUT/shaper.log" 2>&1 &
  SHAPER_PID=$!
  for i in $(seq 1 20); do nc -z 127.0.0.1 7980 2>/dev/null && break; sleep 0.25; done
  export HARNESS_PORT=7980
fi
"$HERE/.build/release/harness-client" "$PRESSES" "$INTERVAL" "$OUT/client.log" "$PRESET" 2>"$OUT/client.stderr" || true
[ -n "$SHAPER_PID" ] && kill $SHAPER_PID 2>/dev/null
sleep 0.5
kill $BEACON_PID 2>/dev/null || true; sleep 1
# Bring the person's Beacon back. A Debug build launched from a shell inherits the shell's
# Screen Recording grant; launched through LaunchServices it needs its own. Prefer the dev
# copy in ~/Applications when there is one.
# The build under test, never an older Beacon, from ~/Applications when the same build is
  # installed there: macOS keeps privacy grants per path, and the person's copy holds them.
  RESTORE="$APP"; for c in "$HOME/Applications/Beacon.app" /Applications/Beacon.app; do [ -d "$c" ] && { RESTORE="$c"; break; }; done
  (nohup "$RESTORE/Contents/MacOS/Beacon" >/dev/null 2>&1 &)
python3 "$HERE/analyze.py" "$OUT" | tee "$OUT/report.txt"
echo "$OUT"
