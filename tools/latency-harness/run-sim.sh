#!/bin/bash
# The phone half of the harness in the iOS Simulator on this Mac: Beacon in harness mode,
# Beam (Debug, -harness) launched in a booted simulator, its log copied out and analyzed with
# analyze-phone.py. No radio, but the real Beam client code, PhorosCore's simulator slice and
# the iOS decode path. Usage: ./run-sim.sh [label] [presses] [interval_ms] [preset]
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-sim}"; PRESSES="${2:-40}"; INTERVAL="${3:-600}"; PRESET="${4:-1080p60}"
OUT="/Volumes/yuh/business/.scratch/harness/$(date +%Y%m%d-%H%M%S)-$LABEL"
mkdir -p "$OUT"
APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
SIM="${HARNESS_SIM:-iPhone 17}"
BEAM="${BEAM_APP:-/Volumes/yuh/business/.scratch/dd-beam-sim/Build/Products/Debug-iphonesimulator/Beam.app}"
BUNDLE="com.beamapp.ios"
xcrun simctl boot "$SIM" 2>/dev/null || true
xcrun simctl bootstatus "$SIM" -b >/dev/null 2>&1 || true
xcrun simctl install "$SIM" "$BEAM"
pkill -x Beacon 2>/dev/null || true
for i in $(seq 1 50); do pgrep -x Beacon >/dev/null 2>&1 || break; sleep 0.2; done   # the old Beacon must be gone, not just its listener
pkill -9 -x Beacon 2>/dev/null || true
sleep 0.5
BEACON_HARNESS=1 BEACON_HARNESS_LOG="$OUT/beacon.log" "$APP/Contents/MacOS/Beacon" >"$OUT/beacon.stdout" 2>&1 &
BEACON_PID=$!
restore() {
  kill $BEACON_PID 2>/dev/null || true; sleep 1
  (nohup "$APP/Contents/MacOS/Beacon" >/dev/null 2>&1 &)  # the build under test, never an older Beacon
}
trap restore EXIT
for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done
sleep 1.5
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
xcrun simctl launch "$SIM" "$BUNDLE" -harness 127.0.0.1 "$PRESSES" "$INTERVAL" "$PRESET" ${HARNESS_EXTRA:-} >"$OUT/launch.txt" 2>&1
CONTAINER=$(xcrun simctl get_app_container "$SIM" "$BUNDLE" data)
DEADLINE=$(( $(date +%s) + 25 + PRESSES * (INTERVAL + 200) / 1000 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 3
  cp -f "$CONTAINER/Documents/harness.log" "$OUT/client.log" 2>/dev/null || true
  grep -q '^DONE' "$OUT/client.log" 2>/dev/null && break
done
sleep 1; cp -f "$CONTAINER/Documents/harness.log" "$OUT/client.log" 2>/dev/null || true
xcrun simctl terminate "$SIM" "$BUNDLE" 2>/dev/null || true
python3 "$HERE/analyze-phone.py" "$OUT" | tee "$OUT/report.txt"
echo "$OUT"
