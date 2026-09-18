#!/usr/bin/env python3
"""Pair harness events into per-press stage latencies and print percentiles.

Stages (all times mach ns on one clock):
  input   H0 (Beacon presses the harness pad) -> H1 (client samples it) -> H2 (Beacon receives .input) -> H3 (posted to Beam Controller) -> H4 (flash window flips)
  video   H4 -> capture PTS of the first frame at/after the flip -> H5 (SCK delivered) -> H5E (encoded) -> H6 (queued to send) -> H7 (client assembled) -> H8 (client decoded + detected)
  total   H0 -> H8
"""
import sys, os, statistics, json, subprocess

out = sys.argv[1]
def read(path):
    ev = []
    for line in open(path):
        parts = line.strip().split(",")
        if len(parts) < 3: continue
        ev.append((parts[0], int(parts[1]), int(parts[2]), parts[3:]))
    return ev
b = read(os.path.join(out, "beacon.log")); c = read(os.path.join(out, "client.log"))

def by(evs, stage): return [e for e in evs if e[0] == stage]
h0 = {e[1]: e for e in by(b, "H0")}; h1 = {e[1]: e for e in by(c, "H1")}; h2 = {e[1]: e for e in by(b, "H2")}
h3 = {e[1]: e for e in by(b, "H3")}; h4 = {e[1]: e for e in by(b, "H4")}
h5 = sorted(by(b, "H5"), key=lambda e: e[1])          # id = pts_us
h5e = {e[1]: e for e in by(b, "H5E")}                   # id = pts_us
h6 = {int(e[3][0]): e for e in by(b, "H6")}             # keyed by pts_us, extra has frame number? no: id=frame, extra[0]=pts
h6_by_frame = {e[1]: e for e in by(b, "H6")}
h7 = {e[1]: e for e in by(c, "H7")}; h8 = {e[1]: e for e in by(c, "H8")}
# pts -> frame number via H6 (extra[0] = pts_us)
pts_to_frame = {int(e[3][0]): e[1] for e in by(b, "H6")}
frame_to_pts = {v: k for k, v in pts_to_frame.items()}
h5_pts = [e[1] for e in h5]
h5_by_pts = {e[1]: e for e in h5}

ms = lambda ns: ns / 1e6
rows = []
for pid in sorted(h0):
    r = {"id": pid}
    t0 = h0[pid][2]
    def d(a, b): return ms(b - a) if a is not None and b is not None else None
    t1 = h1.get(pid, [None]*3)[2]; t2 = h2.get(pid, [None]*3)[2]; t3 = h3.get(pid, [None]*3)[2]; t4 = h4.get(pid, [None]*3)[2]
    r["h0_h1"] = d(t0, t1); r["h1_h2"] = d(t1, t2); r["h2_h3"] = d(t2, t3); r["h3_h4"] = d(t3, t4)
    if t4 is not None:
        # first captured frame whose PTS (host clock, us) is at/after the flip
        t4_us = t4 // 1000
        cand = [p for p in h5_pts if p >= t4_us]
        if cand:
            pts = cand[0]; fr = pts_to_frame.get(pts)
            r["flip_to_capture"] = (pts - t4_us) / 1000
            r["capture_to_delivered"] = d(pts * 1000, h5_by_pts[pts][2])
            r["delivered_to_encoded"] = d(h5_by_pts[pts][2], h5e.get(pts, [None]*3)[2])
            if fr is not None:
                r["encoded_to_queued"] = d(h5e.get(pts, [None]*3)[2], h6_by_frame[fr][2])
                r["queued_to_assembled"] = d(h6_by_frame[fr][2], h7.get(fr, [None]*3)[2])
                # detection: the first H8 with frame >= fr
                det = sorted([f for f in h8 if f >= fr])
                if det:
                    r["assembled_to_detected"] = d(h7.get(det[0], [None]*3)[2], h8[det[0]][2])
                    r["detect_frame_offset"] = det[0] - fr
                    r["total"] = d(t0, h8[det[0]][2]); r["video"] = d(t4, h8[det[0]][2])
    rows.append(r)

def pct(vals, p):
    v = sorted(x for x in vals if x is not None)
    if not v: return None
    k = (len(v) - 1) * p; f = int(k); c2 = min(f + 1, len(v) - 1)
    return v[f] + (v[c2] - v[f]) * (k - f)
cols = ["h0_h1","h1_h2","h2_h3","h3_h4","flip_to_capture","capture_to_delivered","delivered_to_encoded","encoded_to_queued","queued_to_assembled","assembled_to_detected","video","total"]
print(f"presses={len(rows)}  with total={sum(1 for r in rows if r.get('total') is not None)}  frames H7={len(h7)} H8 flips={len(h8)}  detect frame offset p50={pct([r.get('detect_frame_offset') for r in rows],0.5)}")
print(f"{'stage':24s} {'p50':>8s} {'p90':>8s} {'p95':>8s} {'max':>8s}")
summary = {}
for col in cols:
    vals = [r.get(col) for r in rows]
    p50, p90, p95 = pct(vals, .5), pct(vals, .9), pct(vals, .95)
    mx = max((v for v in vals if v is not None), default=None)
    fmt = lambda x: f"{x:8.1f}" if x is not None else f"{'-':>8s}"
    print(f"{col:24s} {fmt(p50)} {fmt(p90)} {fmt(p95)} {fmt(mx)}")
    summary[col] = {"p50": p50, "p90": p90, "p95": p95, "max": mx}
sha = subprocess.run(["git","-C","/Volumes/yuh/business/beam/beam-macos","rev-parse","--short","HEAD"],capture_output=True,text=True).stdout.strip()
json.dump({"dir": out, "beacon_sha": sha, "presses": len(rows), "summary": summary, "rows": rows}, open(os.path.join(out, "summary.json"), "w"), indent=1)
