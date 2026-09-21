#!/bin/bash
# One "go": installs the Debug Beam on the phone, then runs the transport matrix over Wi-Fi
# and prints one table. Usage: ./phone-matrix.sh [presses] [label]
# Each run launches Beam through devicectl (one tunnel, one ~3.5 s Wi-Fi scan, before the
# presses start); nothing else touches devicectl until the run is over.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PRESSES="${1:-60}"; TAG="${2:-m}"
export HARNESS_DEVICE="${HARNESS_DEVICE:-84724AF1-1AAB-55CB-A828-6B1E2EF109B0}"
export HARNESS_MAX_FPS="${HARNESS_MAX_FPS:-120}" HARNESS_CODEC="${HARNESS_CODEC:-hevc}"
BEAM="${BEAM_APP:-/Volumes/yuh/business/.scratch/dd-beam-dev/Build/Products/Debug-iphoneos/Beam.app}"
if [ "${SKIP_INSTALL:-0}" != 1 ]; then
  for i in 1 2 3; do
    xcrun devicectl device install app --device "$HARNESS_DEVICE" "$BEAM" 2>&1 | grep -qi installed && { echo "installed $BEAM"; break; }
    sleep 3
  done
  sleep 6   # the install tunnel's scan
  # the first runs after a new binary on the phone do not connect (iOS re-evaluates the
  # app's local-network access for a while); warm up until one does
  for w in 1 2 3 4 5 6; do
    "$HERE/run-phone.sh" "${TAG}_warmup$w" 5 600 1080p60 >/dev/null 2>&1 || true
    d=$(ls -dt /Volumes/yuh/business/.scratch/harness/*-"${TAG}_warmup$w" | head -1)
    [ "$(grep -c '^RTT' "$d/beacon.log" 2>/dev/null)" != 0 ] && { echo "warm after $w"; break; }
    sleep 10
  done
fi
pkill -x Beacon 2>/dev/null; sleep 1
# label | Beacon env | Beam extra args
MATRIX="${MATRIX:-
tcp        |BEACON_EXP=load|
rtc        |BEACON_EXP=load,rtc PHOROS_NOBWE=1|
rtc_dual   |BEACON_EXP=load,rtc PHOROS_NOBWE=1|-dualinput
rtc_vo     |BEACON_EXP=load,rtc PHOROS_NOBWE=1 PHOROS_UDP_CLASS=4|-udpclass 4
tcp        |BEACON_EXP=load|
rtc_dual   |BEACON_EXP=load,rtc PHOROS_NOBWE=1|-dualinput
}"
RUNS=()
while IFS='|' read -r label envs extra; do
  label="$(echo "$label" | xargs)"; [ -z "$label" ] && continue
  name="${TAG}_${label}_$(printf '%02d' ${#RUNS[@]})"
  echo "== $name  ($envs) [$extra]"
  env $envs HARNESS_EXTRA="$extra" "$HERE/run-phone.sh" "$name" "$PRESSES" 600 1080p60 2>&1 | grep -E 'input packet|presses='
  RUNS+=("$name")
  sleep 4
done <<< "$MATRIX"
echo
printf "%-22s %6s %6s %6s %6s %6s  %s\n" run p50 p90 p95 p99 max n
for name in "${RUNS[@]}"; do
  d=$(ls -dt /Volumes/yuh/business/.scratch/harness/*-"$name" | head -1)
  line=$(grep 'input packet' "$d/report.txt" 2>/dev/null)
  [ -n "$line" ] || { printf "%-22s (no result)\n" "$name"; continue; }
  printf "%-22s " "$name"; echo "$line" | awk '{printf "%6s %6s %6s %6s %6s  %s\n", $7, $9, $11, $13, $15, $16}'
  wire=$(grep '^WIRE' "$d/client.log" 2>/dev/null | awk -F, '{print $4}' | sort -n | awk '{v[NR]=$1} END{if (NR) printf "send->wire us p50=%d p90=%d max=%d", v[int(NR*.5)], v[int(NR*.9)], v[NR]}')
  [ -n "$wire" ] && printf "%-22s   %s\n" "" "$wire"
  won=$(grep '^H2W' "$d/beacon.log" 2>/dev/null | cut -d, -f4 | sort | uniq -c | xargs)
  [ -n "$won" ] && printf "%-22s   first copy: %s\n" "" "$won"
done
