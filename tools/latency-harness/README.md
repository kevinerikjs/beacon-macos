# Latency harness

Measures the loop "controller press → Mac reacts → client shows it" on one Mac, so every stage shares one clock and no person is in the loop.

- Beacon in harness mode (`BEACON_HARNESS=1`) authenticates a fixed client secret, owns a second virtual controller (DualShock 4 identity, the harness pad), presses its A button when the client asks over the control channel, and shows a full-screen window that flips black/white when the Beam Controller (the Xbox identity Beacon creates for the client) reports A. It stamps events to `beacon.log`.
- `harness-client` is the phone side, on the Mac, built on the same Phoros products Beam uses. It streams, forwards the harness pad as `.input`, schedules presses, decodes frames with VideoToolbox and detects the luma flip. It stamps events to `client.log`.
- `run.sh [label] [presses] [interval_ms] [preset]` runs one session and `analyze.py` pairs the events into per-press stage latencies with p50/p90/p95.

```
cd tools/latency-harness && swift build -c release && ./run.sh baseline 100 700 1080p60
```

Stages: H0 harness pad pressed, H1 client sampled it, H2 Beacon received `.input`, H3 posted to the Beam Controller, H4 flash flipped, capture PTS, H5 frame delivered, H5E encoded, H6 queued, H7 assembled on the client, H8 decoded and detected. `total` is H0→H8, `video` is H4→H8.

What it cannot see: the real phone's display scheduling and Wi-Fi. Both are checked with the in-app latency readout on a device.

Needs the Debug Beacon at `.scratch/dd-beacon` (signed with the HID entitlement) and the Phoros checkout next to the repo (path dependency).
