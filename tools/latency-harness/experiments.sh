#!/bin/bash
# Run a list of experiments back to back and print one comparison table.
# Usage: ./experiments.sh presses "label:BEACON_EXP" ...   e.g. ./experiments.sh 60 "base:" "delay0:delay0" "llrc:llrc"
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
export BEACON_APP="${BEACON_APP:-/Volumes/yuh/business/.scratch/dd-beacon-local/Build/Products/Debug/Beacon.app}"
PRESSES="$1"; shift
DIRS=()
for spec in "$@"; do
  label="${spec%%:*}"; exp="${spec#*:}"
  out=$(BEACON_EXP="$exp" SHAPE="${SHAPE:-}" HARNESS_MAX_FPS="${HARNESS_MAX_FPS:-}" HARNESS_CODEC="${HARNESS_CODEC:-}" "$HERE/run.sh" "$label" "$PRESSES" 600 "${PRESET:-1080p60}" 2>/dev/null | tail -1)
  DIRS+=("$out")
done
python3 - "${DIRS[@]}" <<'PY'
import json, sys, os
cols = ["h0_h1","flip_to_capture","delivered_to_encoded","assembled_to_detected","detect_frame_offset","video","total"]
print(f"{'run':18s} " + " ".join(f"{c[:14]:>14s}" for c in cols) + "   (p50 / p95, ms)")
for d in sys.argv[1:]:
    s = json.load(open(os.path.join(d, "summary.json")))["summary"]
    label = os.path.basename(d).split("-", 2)[-1]
    cells = []
    for c in cols:
        v = s[c]; cells.append(f"{(v['p50'] or 0):5.1f}/{(v['p95'] or 0):5.1f}".rjust(14))
    print(f"{label:18s} " + " ".join(cells))
PY
