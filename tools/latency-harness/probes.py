"""Dual-pipe probe train analysis: KA,<seq>,<phone_ns> on the phone, H2W/H2X,<seq>,<mac_ns>,<pipe> on the
host. One-way delay per pipe (via the clock offset from the C lines), and the phase of each probe's
send relative to the host's frame cadence (H6 encode times)."""
import sys, bisect
def pct(v,q):
    v=sorted(v); return v[min(len(v)-1,int(round(q*(len(v)-1))))] if v else float('nan')
for d in sys.argv[1:]:
    cl=[l.strip().split(',') for l in open(d+'/client.log') if l.strip()]
    bl=[l.strip().split(',') for l in open(d+'/beacon.log') if l.strip()]
    cs=[(int(e[1]),int(e[3])) for e in cl if e[0]=='C']
    if not cs: print(d,'no clock'); continue
    off=min(cs)[1]*1000
    sent={int(e[1]):int(e[2])+off for e in cl if e[0]=='KA'}
    arr={}
    for e in bl:
        if e[0] in ('H2W','H2X'): arr.setdefault(int(e[1]),{})[e[3]]=int(e[2])
    h6=sorted(int(e[2]) for e in bl if e[0]=='H6')
    per={'tcp':[], 'rtc':[]}; phase={'tcp':[], 'rtc':[]}
    for seq,t in sent.items():
        a=arr.get(seq)
        if not a: continue
        # phase: time since the host last encoded a frame, at the moment the probe was sent
        i=bisect.bisect_right(h6,t)-1
        ph=(t-h6[i])/1e6 if i>=0 else None
        for pipe,ta in a.items():
            per[pipe].append((ta-t)/1e6)
            if ph is not None and ph < 20: phase[pipe].append((ph,(ta-t)/1e6))
    print(d.split('-')[-1])
    for pipe in ('tcp','rtc'):
        v=per[pipe]
        print(f"  {pipe}: n={len(v)} one-way p50={pct(v,.5):.1f} p90={pct(v,.9):.1f} p99={pct(v,.99):.1f} ms")
    for pipe in ('tcp','rtc'):
        buckets={}
        for ph,dl in phase[pipe]: buckets.setdefault(int(ph//2)*2,[]).append(dl)
        print(f"  {pipe} by phase (ms since last encoded frame -> p50 delay): " + ' '.join(f"{k}:{pct(v,.5):.1f}" for k,v in sorted(buckets.items()) if len(v)>=10))
