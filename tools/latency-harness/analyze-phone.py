#!/usr/bin/env python3
"""Pairs the phone harness log: P (input packet with A down sent) → H8 (decoded frame whose luma
flipped), both on the phone's clock, so no clock offset is involved. Prints p50/p90/p95/p99/max
of the full loop and of the frame-age samples (host capture → assembled on the phone, from the
clock sync). Also the host-side stages from beacon.log where they pair by order."""
import sys, os
d = sys.argv[1]
ev = [l.strip().split(",") for l in open(os.path.join(d, "client.log")) if l.strip()]
downs = [(int(e[1]), int(e[2])) for e in ev if e[0] == "P" and len(e) > 3 and e[3] == "down"]
flips = sorted(int(e[2]) for e in ev if e[0] == "H8")
ages = sorted(int(e[3]) / 1000 for e in ev if e[0] == "A")
done = [e for e in ev if e[0] == "DONE"]
loop = []
fi = 0
for pid, t in downs:
    # first flip after this press, and before the next press
    nxt = next((tt for _, tt in downs if tt > t), None)
    while fi < len(flips) and flips[fi] < t: fi += 1
    if fi < len(flips) and (nxt is None or flips[fi] < nxt):
        loop.append((flips[fi] - t) / 1e6); fi += 1
def pct(v, q):
    if not v: return float("nan")
    v = sorted(v); return v[min(len(v) - 1, int(round(q * (len(v) - 1))))]
def row(name, v):
    print(f"{name:28s} p50 {pct(v,.5):7.1f}  p90 {pct(v,.9):7.1f}  p95 {pct(v,.95):7.1f}  p99 {pct(v,.99):7.1f}  max {max(v) if v else float('nan'):7.1f}  n={len(v)}")
print(f"presses={len(downs)} flips={len(flips)} paired={len(loop)} {'DONE: ' + ','.join(done[0][3:]) if done else 'NOT DONE'}")
row("input packet -> decoded (ms)", loop)
row("frame age at assembly (ms)", ages)
