#!/bin/bash
# Latency regression gate. Runs the unit tests and a fixed set of harness scenarios on
# loopback, takes the better of two runs per scenario (the loopback has its own noise),
# and compares p50/p95 of the full loop against baseline.json. A scenario fails when it
# is worse than the baseline by more than the tolerance (3 ms or 15% at p50, 5 ms or 25%
# at p95, whichever is larger). Usage: ./regress.sh [--update] [--quick]
#   --update  write the measured numbers as the new baseline (after a deliberate change)
#   --quick   skip the shaped-link scenarios
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export BEACON_APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
export HARNESS_MAX_FPS="${HARNESS_MAX_FPS:-120}" HARNESS_CODEC="${HARNESS_CODEC:-hevc}"
UPDATE=0; QUICK=0
for a in "$@"; do [ "$a" = --update ] && UPDATE=1; [ "$a" = --quick ] && QUICK=1; done
PRESSES="${PRESSES:-40}"

echo "== phoros unit tests"
(cd "$HERE/../../../phoros" && swift test 2>&1 | grep -E 'Executed .* tests' | tail -1) || { echo "unit tests failed"; exit 1; }

# label | BEACON_EXP | SHAPE
SCENARIOS="
tcp_1080p120   |load|
rtc2_1080p120  |load,rtc|
tcp_1080p60    |load|
tcp_12mbps     |load|--down-mbps 12 --delay-ms 5
rtc2_drop2     |load,rtc|
"
RESULTS=""
while IFS='|' read -r label exp shape; do
  label="$(echo "$label" | xargs)"; [ -z "$label" ] && continue
  [ "$QUICK" = 1 ] && [[ "$label" == *mbps* ]] && continue
  best50=999; best95=999
  for run in 1 2; do
    fps=120; [[ "$label" == *1080p60 ]] && fps=60
    drop=0; [[ "$label" == *drop2 ]] && drop=2
    out=$(PHOROS_DROP=$drop HARNESS_MAX_FPS=$fps BEACON_EXP="$exp" SHAPE="$shape" "$HERE/run.sh" "rg_$label" "$PRESSES" 600 1080p60 2>/dev/null | tail -1)
    [ -f "$out/summary.json" ] || continue
    read -r p50 p95 < <(python3 -c "import json;s=json.load(open('$out/summary.json'))['summary']['total'];print(s['p50'] or 999, s['p95'] or 999)")
    if python3 -c "import sys; sys.exit(0 if $p50 < $best50 else 1)"; then best50=$p50; best95=$p95; fi
  done
  RESULTS+="$label $best50 $best95\n"
done <<< "$SCENARIOS"

printf "$RESULTS" | python3 "$HERE/regress_compare.py" "$HERE/baseline.json" "$UPDATE"
