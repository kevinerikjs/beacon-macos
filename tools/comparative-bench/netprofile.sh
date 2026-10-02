#!/bin/bash
# netprofile: what a streaming app's traffic does while the link degrades.
#
# Captures the packets between this Mac and the phone, runs a loss schedule underneath, and
# reports what the app did about it: how much it sent, how it paced, and how long it took to
# recover. This needs no cooperation from the app, so Beam, Parsec, Moonlight, Steam Link and
# AirPlay are all measured the same way.
#
# Usage: sudo ./netprofile.sh <label> <phone-ip> [seconds]
#
# Run it while the app under test is streaming and the person is doing something ordinary in
# the stream. It writes a pcap and a summary to .scratch/bench/<label>/.
set -euo pipefail
LABEL="${1:?usage: netprofile.sh <label> <phone-ip> [seconds]}"
PHONE="${2:?phone ip}"
SECONDS_TOTAL="${3:-120}"
OUT="/Volumes/yuh/business/.scratch/bench/$LABEL"
mkdir -p "$OUT"
IFACE="${BENCH_IFACE:-en1}"

echo "capturing $IFACE <-> $PHONE for ${SECONDS_TOTAL}s into $OUT"
tcpdump -i "$IFACE" -w "$OUT/capture.pcap" -s 96 "host $PHONE" >/dev/null 2>&1 &
TCPDUMP=$!
cleanup() {
  kill $TCPDUMP 2>/dev/null || true
  dnctl -q flush 2>/dev/null || true
  pfctl -a com.apple/beam.bench -F all 2>/dev/null || true
  pfctl -d 2>/dev/null || true
}
trap cleanup EXIT

# Four quarters: clean, then 1%, 2.5% and 5% loss on everything this Mac sends to the phone.
# The anchor lives under com.apple/ because that is the only anchor path the default pf.conf
# evaluates. Timestamps go in a log so the analyzer can slice the capture by phase.
phase() {
  local plr="$1" secs="$2"
  echo "$(python3 -c 'import time;print(int(time.time()*1000))'),$plr" >> "$OUT/phases.csv"
  if [ "$plr" = "0" ]; then
    dnctl -q flush 2>/dev/null || true
    pfctl -a com.apple/beam.bench -F all 2>/dev/null || true
  else
    dnctl pipe 1 config plr "$plr"
    printf 'dummynet out quick proto { tcp udp } from any to %s pipe 1\n' "$PHONE" | pfctl -a com.apple/beam.bench -f -
    pfctl -E >/dev/null 2>&1 || true
  fi
  echo "  loss ${plr} for ${secs}s"
  sleep "$secs"
}
: > "$OUT/phases.csv"
Q=$((SECONDS_TOTAL / 4))
phase 0 "$Q"
phase 0.01 "$Q"
phase 0.025 "$Q"
phase 0.05 "$Q"
cleanup
trap - EXIT
echo "pcap: $OUT/capture.pcap"
echo "now: ./netreport.py $OUT"
