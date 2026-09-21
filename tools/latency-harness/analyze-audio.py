#!/usr/bin/env python3
"""Audio harness report: what the host sent (HA) against what the client received (CA), and
what Beam's AudioPlayer would have done with it.

  HA,pts_us,ns,bytes,hash            one chunk handed to the transport (host)
  CA,seq,ns,pts_us,bytes,hash,age    one chunk received (client)
  H7,frame,ns,pts_us,bytes           one video frame assembled (client)

Loopback runs share one clock, so CA.ns - HA.ns is the one-way delay. The player model is
AudioPlayer.schedule(): audio is placed on the video timeline (anchor = the first frame's
arrival) 100 ms ahead of the matching video, chained back to back, and a chunk that arrives
after the previous one has finished playing is a gap in the sound.
Usage: analyze-audio.py <run dir>
"""
import sys, os, statistics as st

def pct(v, p):
    if not v: return 0
    s = sorted(v); return s[min(len(s) - 1, int(round(p / 100 * (len(s) - 1))))]

def rows(path, stage):
    out = []
    if not os.path.exists(path): return out
    for line in open(path):
        f = line.rstrip('\n').split(',')
        if f and f[0] == stage: out.append(f)
    return out

d = sys.argv[1]
ha = rows(f'{d}/beacon.log', 'HA')
ca = rows(f'{d}/client.log', 'CA')
h7 = rows(f'{d}/client.log', 'H7')
LEAD_US = 100_000
CHUNK_US = 10_000

# keyed by pts: a steady tone encodes to repeating AAC units, so hashes are not unique
sent = {int(r[1]): (int(r[2]), int(r[3]), r[4]) for r in ha}   # pts -> ns, bytes, hash
recv = [(int(r[1]), int(r[2]), int(r[3]), int(r[4]), int(r[3])) for r in ca]  # seq, ns, pts, bytes, key
hashes = {int(r[3]): r[5] for r in ca}
recv.sort(key=lambda r: r[1])
print(f'audio chunks: sent {len(sent)}, received {len(recv)}')
if not recv:
    print('no audio received (HARNESS_AUDIO=1 on the client, and the client must ask for audio)'); sys.exit(0)

# chunks the host sent after the client had left do not count as lost
last_ns = recv[-1][1]
sent = {k: v for k, v in sent.items() if v[0] <= last_ns} if os.environ.get('LOOPBACK') else {k: v for k, v in sent.items() if k <= recv[-1][2]}
missing = len(sent) - len({r[4] for r in recv if r[4] in sent})
unknown = sum(1 for r in recv if r[4] not in sent or sent[r[4]][2] != hashes[r[4]])
seqs = [r[0] for r in recv]
seqgaps = sum(1 for a, b in zip(seqs, seqs[1:]) if b != a + 1)
print(f'lost/dropped (sent, never received): {missing}   corrupted (received, not matching anything sent): {unknown}   sequence gaps: {seqgaps}')

owd = [(r[1] - sent[r[4]][0]) / 1e6 for r in recv if r[4] in sent]
if owd and os.environ.get('LOOPBACK'):
    print(f'one-way delay ms: p50 {pct(owd,50):.1f}  p95 {pct(owd,95):.1f}  p99 {pct(owd,99):.1f}  max {max(owd):.1f}')
ia = [(b[1] - a[1]) / 1e6 for a, b in zip(recv, recv[1:])]
print(f'inter-arrival ms: p50 {pct(ia,50):.1f}  p99 {pct(ia,99):.1f}  max {max(ia):.1f}   over 30 ms: {sum(1 for x in ia if x > 30)}   over 100 ms: {sum(1 for x in ia if x > 100)}')

# pts continuity on the wire: the tone is 10 ms per chunk
pts = sorted(r[2] for r in recv)
deltas = [b - a for a, b in zip(pts, pts[1:]) if b > a]
CHUNK_US = int(st.median(deltas)) if deltas else CHUNK_US   # 10 ms PCM, 21.3 ms AAC
holes = [(b - a) / 1000 for a, b in zip(pts, pts[1:]) if b - a > CHUNK_US * 1.5]
print(f'chunk {CHUNK_US/1000:.1f} ms   pts holes (>1.5 chunks between consecutive chunks): {len(holes)}' + (f'  largest {max(holes):.0f} ms' if holes else ''))

# audio against the video timeline the player anchors on
frames = sorted((int(r[3]), int(r[2])) for r in h7)   # pts, ns
if frames:
    import bisect
    fpts = [f[0] for f in frames]
    skew = []
    for seq, ns, p, _, _ in recv:
        i = bisect.bisect_right(fpts, p) - 1
        if i < 0: continue
        vpts, vns = frames[i]
        skew.append((ns - vns - (p - vpts) * 1000) / 1e6)
    if skew:
        print(f'audio behind the video timeline ms (arrival of audio at pts t minus arrival of video at pts t): p50 {pct(skew,50):.1f}  p95 {pct(skew,95):.1f}  max {max(skew):.1f}  min {min(skew):.1f}')

    # AudioPlayer model
    anchor_pts, anchor_ns = frames[0]
    next_end = None
    gaps, gap_ms, slack, immediate = 0, 0.0, [], 0
    first = recv[0][1]; last = recv[-1][1]
    for seq, ns, p, nbytes, _ in recv:
        if p < anchor_pts: continue
        target = anchor_ns + (p - anchor_pts) * 1000 + LEAD_US * 1000
        slack.append((target - ns) / 1e6)
        if next_end is not None: target = max(target, next_end)
        if target <= ns + 3_000_000:
            immediate += 1
            if next_end is not None and ns > next_end + 1_000_000:
                gaps += 1; gap_ms += (ns - next_end) / 1e6
            target = max(target, ns)
        dur = CHUNK_US * 1000
        next_end = target + dur
    minutes = max(1e-9, (last - first) / 60e9)
    print(f'player model (100 ms lead on the video clock): slack ms p5 {pct(slack,5):.1f}  p50 {pct(slack,50):.1f}  min {min(slack):.1f}   scheduled immediately: {immediate}/{len(slack)}')
    print(f'audible gaps: {gaps} ({gap_ms:.0f} ms total, {gaps/minutes:.1f}/min over {minutes*60:.0f} s)')
else:
    print('no video frames in the client log: cannot model the player')

# the phone's own player, when the run had -audio
pa = rows(f'{d}/client.log', 'PA'); pz = rows(f'{d}/client.log', 'PZ'); pd = rows(f'{d}/client.log', 'PD')
if pa:
    paths = {}
    for r in pa: paths[r[3]] = paths.get(r[3], 0) + 1
    gaps = [int(r[4]) for r in pa if len(r) > 4 and int(r[4]) > 0]
    slack = [int(r[1]) for r in pa if r[3] in ('synced', 'catchup')]
    print(f'player on the phone: {len(pa)} chunks scheduled, paths {paths}')
    if slack: print(f'  slack ms: p5 {pct(slack,5)}  p50 {pct(slack,50)}  min {min(slack)}   chunks due already (slack<0): {sum(1 for x in slack if x < 0)}')
    print(f'  gaps the scheduler opened: {len(gaps)} ({sum(gaps)} ms total)')
if pz or pa:
    silent = [int(r[1]) for r in pz]
    print(f'  silent render buffers while audio arrived: {len(silent)} ({sum(silent)} ms total)')
if pd:
    print('  player diagnostics:')
    for r in pd[:30]: print('   ', r[3] if len(r) > 3 else r)
