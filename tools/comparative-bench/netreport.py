#!/usr/bin/env python3
"""Reads a netprofile capture and says what the app did as the link got worse.

Per loss phase: the rate it sent, how evenly it paced, and the longest gap in the downstream.
A stall in the stream shows up here as a gap, whatever the app is and whatever its protocol,
so this is the one comparison that needs nothing from the vendor.

    ./netreport.py /Volumes/yuh/business/.scratch/bench/<label>
"""
import subprocess, sys, os, statistics as st

def packets(pcap, phone):
    """(epoch_ms, bytes, downstream?) for every packet, via tcpdump."""
    out = subprocess.run(['tcpdump', '-r', pcap, '-nn', '-q', '-tt'],
                         capture_output=True, text=True).stdout
    rows = []
    for line in out.split('\n'):
        parts = line.split()
        if len(parts) < 5 or '>' not in line: continue
        try:
            t = float(parts[0]) * 1000
            src = parts[2]
            length = int(line.rsplit('length ', 1)[1].split()[0].rstrip(':')) if 'length ' in line else 0
        except (ValueError, IndexError):
            continue
        rows.append((t, length, src.startswith(phone)))
    return rows

def pct(v, p):
    s = sorted(v); return s[min(len(s)-1, int(round(p/100*(len(s)-1))))] if s else 0

d = sys.argv[1]
phone = sys.argv[2] if len(sys.argv) > 2 else None
phases = [(float(l.split(',')[0]), l.split(',')[1].strip()) for l in open(f'{d}/phases.csv')]
rows = packets(f'{d}/capture.pcap', phone or '')
if not rows:
    print('no packets read. Is tcpdump on PATH and the pcap non-empty?'); sys.exit(1)

print(f'{os.path.basename(d)}: {len(rows)} packets\n')
print(f'{"loss":>6} {"Mbps down":>10} {"pps":>7} {"pacing p99 ms":>14} {"longest gap ms":>15}')
for i, (start, plr) in enumerate(phases):
    end = phases[i+1][0] if i+1 < len(phases) else rows[-1][0]
    window = [r for r in rows if start <= r[0] < end]
    down = [r for r in window if not r[2]] if phone else window
    if len(down) < 10:
        print(f'{plr:>6} {"no data":>10}'); continue
    secs = (end - start) / 1000
    gaps = [b[0]-a[0] for a, b in zip(down, down[1:])]
    print(f'{plr:>6} {sum(r[1] for r in down)*8/secs/1e6:>10.2f} {len(down)/secs:>7.0f}'
          f' {pct(gaps,99):>14.1f} {max(gaps):>15.1f}')
print('\nPacing p99 is the interval between consecutive downstream packets at the 99th percentile:')
print('a protocol that bursts a keyframe and then waits shows a large one. The longest gap is')
print('the worst stall in the picture during that phase.')
