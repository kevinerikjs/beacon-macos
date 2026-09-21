#!/usr/bin/env python3
"""Compares "label p50 p95" lines on stdin with baseline.json; --update rewrites it."""
import json, sys, os
base_path, update = sys.argv[1], sys.argv[2] == "1"
measured = {}
for line in sys.stdin:
    parts = line.split()
    if len(parts) == 3: measured[parts[0]] = {"p50": float(parts[1]), "p95": float(parts[2])}
base = json.load(open(base_path)) if os.path.exists(base_path) else {}
print(f"\n{'scenario':16s} {'p50':>7s} {'base':>7s}   {'p95':>7s} {'base':>7s}   verdict")
fail = 0
for l in sorted(measured):
    m = measured[l]; b = base.get(l)
    if not b: print(f"{l:16s} {m['p50']:7.1f} {'-':>7s}   {m['p95']:7.1f} {'-':>7s}   no baseline"); continue
    tol50 = max(3.0, b["p50"] * 0.15); tol95 = max(5.0, b["p95"] * 0.25)
    bad = m["p50"] > b["p50"] + tol50 or m["p95"] > b["p95"] + tol95
    fail += bad
    print(f"{l:16s} {m['p50']:7.1f} {b['p50']:7.1f}   {m['p95']:7.1f} {b['p95']:7.1f}   {'REGRESSION' if bad else 'ok'}")
if update:
    json.dump(measured, open(base_path, "w"), indent=2); print(f"\nbaseline written to {base_path}")
elif fail:
    print(f"\n{fail} regression(s)"); sys.exit(1)
else:
    print("\nno regressions")