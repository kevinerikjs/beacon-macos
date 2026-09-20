#!/bin/bash
# The phone half of the harness on a real iPhone over its own Wi-Fi: Beacon in harness mode on
# this Mac, Beam (Debug, with -harness) launched on the phone through devicectl, the phone's log
# copied back and analyzed. Usage: ./run-phone.sh [label] [presses] [interval_ms] [preset]
# Needs: the Debug Beam installed on the phone, HARNESS_DEVICE (udid) or a single paired phone,
# and the Mac reachable from the phone at HARNESS_HOST (default: this Mac's primary LAN address).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LABEL="${1:-phone}"; PRESSES="${2:-60}"; INTERVAL="${3:-600}"; PRESET="${4:-1080p60}"
OUT="/Volumes/yuh/business/.scratch/harness/$(date +%Y%m%d-%H%M%S)-$LABEL"
mkdir -p "$OUT"
APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
DEVICE="${HARNESS_DEVICE:-$(xcrun devicectl list devices 2>/dev/null | grep -i 'iphone' | awk '{print $3}' | head -1)}"
HOST="${HARNESS_HOST:-$(route -n get default 2>/dev/null | awk '/interface:/{print $2}' | xargs ipconfig getifaddr)}"
BUNDLE="com.beamapp.ios"
echo "device=$DEVICE host=$HOST out=$OUT"
pkill -x Beacon 2>/dev/null || true; sleep 1
BEACON_HARNESS=1 BEACON_HARNESS_LOG="$OUT/beacon.log" "$APP/Contents/MacOS/Beacon" >"$OUT/beacon.stdout" 2>&1 &
BEACON_PID=$!
restore() {
  kill $BEACON_PID 2>/dev/null || true; sleep 1
  if [ -d "$HOME/Applications/Beacon.app" ]; then (nohup "$HOME/Applications/Beacon.app/Contents/MacOS/Beacon" >/dev/null 2>&1 &); fi
}
trap restore EXIT
for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done
sleep 1.5
# a fresh launch every time: the runner reads its arguments at init
# the phone is often paired over the local network; the tunnel can time out, so retry
launched=0
for attempt in 1 2 3; do
  if xcrun devicectl device process launch --terminate-existing --device "$DEVICE" "$BUNDLE" -harness "$HOST" "$PRESSES" "$INTERVAL" "$PRESET" >"$OUT/launch.txt" 2>&1; then launched=1; break; fi
  sleep 3
done
[ "$launched" = 1 ] || { cat "$OUT/launch.txt"; exit 1; }
# devicectl will not overwrite a destination: copy to a fresh name, then move into place
fetch_log() {
  rm -f "$OUT/client.tmp"
  if xcrun devicectl device copy from --device "$DEVICE" --domain-type appDataContainer --domain-identifier "$BUNDLE" --source Documents/harness.log --destination "$OUT/client.tmp" >/dev/null 2>&1; then
    mv -f "$OUT/client.tmp" "$OUT/client.log"
  fi
}
# wait for DONE in the phone's log (copy it every few seconds)
DEADLINE=$(( $(date +%s) + 20 + PRESSES * (INTERVAL + 200) / 1000 ))
while [ "$(date +%s)" -lt "$DEADLINE" ]; do
  sleep 4
  fetch_log
  grep -q '^DONE' "$OUT/client.log" 2>/dev/null && break
done
sleep 1
fetch_log
python3 "$HERE/analyze-phone.py" "$OUT" | tee "$OUT/report.txt"
echo "$OUT"
