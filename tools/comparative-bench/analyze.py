#!/usr/bin/env python3
"""Turns a flashboard log and a watch capture into a latency distribution.

Two modes, both app agnostic.

  live   flashboard wrote the moment of each flip on this Mac's clock, and watch stamped every
         captured frame on the same clock. Latency is the difference. Use it when the capture
         device is the phone itself over USB.

             analyze.py live board.log phone.csv

  dual   one camera sees the Mac screen and the phone screen at once. The flip appears in
         region A, then in region B. The difference between them is the latency of everything
         between the two panels, and no clock is involved at all.

             analyze.py dual both.csv

A transition rarely lands exactly on a captured frame. Each crossing is interpolated between
the two frames that bracket it, so the error per trial is a fraction of the capture interval
rather than a whole one. With flip times uniformly distributed against the capture phase, which
is what flashboard's randomised interval is for, that error has no direction and averages out:
a 30 fps webcam over 100 trials estimates a mean to about a millisecond, though it cannot say
much about any single trial.
"""
import sys, statistics as st

def read_csv(path):
    rows = []
    for line in open(path):
        f = line.strip().split(',')
        if len(f) >= 3 and f[0] == 'L':
            rows.append((int(f[1]) / 1e6, [float(x) for x in f[2:]]))
    rows.sort()
    return rows

def read_board(path):
    out = []
    for line in open(path):
        f = line.strip().split(',')
        if len(f) >= 4 and f[0] == 'F':
            out.append((int(f[1]), int(f[2]) / 1e6, int(f[3])))
    return out

def crossings(samples, channel):
    """Times where the channel crosses the midpoint of its own range, with the direction."""
    values = [s[1][channel] for s in samples]
    lo, hi = min(values), max(values)
    if hi - lo < 25:
        return [], (lo, hi)      # nothing flashed: wrong region, or the stream never arrived
    mid = (lo + hi) / 2
    band = (hi - lo) * 0.15      # ignore noise that only brushes the midpoint
    out, armed = [], None
    for i in range(1, len(samples)):
        t0, v0 = samples[i - 1][0], values[i - 1]
        t1, v1 = samples[i][0], values[i]
        if v0 < mid - band and v1 > mid + band:
            up = True
        elif v0 > mid + band and v1 < mid - band:
            up = False
        else:
            continue
        # linear interpolation onto the midpoint: sub-frame, and unbiased
        t = t0 + (t1 - t0) * (mid - v0) / (v1 - v0) if v1 != v0 else t1
        out.append((t, up))
    return out, (lo, hi)

def pct(v, p):
    s = sorted(v)
    return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]

def report(label, deltas, interval):
    if not deltas:
        print(f"{label}: no paired transitions")
        return
    print(f"{label}: n={len(deltas)}  capture interval {interval:.1f} ms")
    print(f"  mean {st.mean(deltas):6.1f}   p50 {pct(deltas,50):6.1f}   p90 {pct(deltas,90):6.1f}"
          f"   p95 {pct(deltas,95):6.1f}   p99 {pct(deltas,99):6.1f}   max {max(deltas):6.1f}  ms")
    if len(deltas) > 2:
        print(f"  standard error of the mean {st.stdev(deltas)/len(deltas)**0.5:.2f} ms")
    if interval > 8:
        print(f"  NOTE: at {1000/interval:.0f} fps a single trial carries up to {interval/2:.0f} ms of "
              f"quantisation. Compare means, not percentiles. The percentiles above are the "
              f"capture rate as much as the stream.")

def main():
    mode = sys.argv[1] if len(sys.argv) > 1 else 'live'
    if mode == 'live':
        board, capture = read_board(sys.argv[2]), read_csv(sys.argv[3])
        if not capture:
            print('no captured frames'); return
        interval = st.median([b[0] - a[0] for a, b in zip(capture, capture[1:])] or [0])
        seen, (lo, hi) = crossings(capture, 0)
        if not seen:
            print(f'the watched region never changed brightness (range {lo:.0f}..{hi:.0f}). '
                  f'Wrong region, or the stream is not showing this Mac.'); return
        deltas = []
        for t, up in seen:
            # the last flip in the same direction before this crossing
            prior = [f for f in board if f[1] <= t and bool(f[2]) == up]
            if not prior: continue
            d = t - prior[-1][1]
            if 0 < d < 2000: deltas.append(d)
        report('glass to glass', deltas, interval)
    elif mode == 'dual':
        capture = read_csv(sys.argv[2])
        if not capture or len(capture[0][1]) < 2:
            print('dual mode needs a capture with two regions (watch --roi --roi2)'); return
        interval = st.median([b[0] - a[0] for a, b in zip(capture, capture[1:])] or [0])
        a, (alo, ahi) = crossings(capture, 0)
        b, (blo, bhi) = crossings(capture, 1)
        if not a or not b:
            print(f'one region never changed (A {alo:.0f}..{ahi:.0f}, B {blo:.0f}..{bhi:.0f}). '
                  f'Check that both screens are in shot and the regions are on them.'); return
        deltas = []
        for t, up in a:
            later = [x for x in b if x[0] > t and x[1] == up]
            if later and later[0][0] - t < 2000: deltas.append(later[0][0] - t)
        report('Mac panel to phone panel', deltas, interval)
    else:
        print(__doc__)

main()
