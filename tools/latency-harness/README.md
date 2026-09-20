# Latency harness

Measures the loop "controller press → Mac reacts → client shows it" on one Mac, so every stage shares one clock and no person is in the loop. It runs in the background: Beacon captures its own window, not the display.

- Beacon in harness mode (`BEACON_HARNESS=1`) authenticates a fixed client secret, owns a second virtual controller (DualShock 4 identity, the harness pad), presses its A button when the client asks over the control channel, and keeps a 1920x1080 borderless window at the back of the normal window level that flips black/white when the Beam Controller (the Xbox identity Beacon creates for the client) reports A. Beacon captures that window alone. A small square moves along its bottom edge on the display's link, so ScreenCaptureKit delivers a frame per refresh. It stamps events to `beacon.log`.
- `harness-client` is the phone side, on the Mac, built on the same Phoros products Beam uses. It streams, forwards the harness pad as `.input`, schedules presses, decodes frames with VideoToolbox, detects the luma flip in a centre patch, probes the host's clock and stamps each frame's age. It stamps events to `client.log`.
- `run.sh [label] [presses] [interval_ms] [preset]` runs one session and `analyze.py` pairs the events into per-press stage latencies with p50/p90/p95/max.
- `experiments.sh presses "label:BEACON_EXP" …` runs several configurations back to back and prints one table.
- `shaper.py` sits between the client and Beacon as a TCP proxy: a token bucket per direction, a fixed delay, an optional mid-run bandwidth step. `SHAPE="--down-mbps 12 --delay-ms 3"` on `run.sh` or `experiments.sh` turns it on.

```
cd tools/latency-harness && swift build -c release
./run.sh baseline 100 700 1080p60
HARNESS_MAX_FPS=120 ./experiments.sh 40 "sixty:" "load:load" "shaped:load"
SHAPE="--down-mbps 6 --delay-ms 3" ./experiments.sh 40 "slow_old:load,sched=old,noabr" "slow:load"
```

Stages: H0 harness pad pressed, H1 client sampled it, H2 Beacon received `.input`, H3 posted to the Beam Controller, H4 flash flipped, capture PTS, H5 frame delivered (H5I an idle frame with no pixels, H5S skipped by the capture gate, H5D dropped by VideoToolbox), H5E encoded, H6 queued (H6D handed to the transport, H6C accepted by it), H7 assembled on the client (H7R first fragment received), H8 decoded and detected. `total` is H0→H8, `video` is H4→H8. `RTT` lines carry the host's link probe (round trip, queueing delay, bitrate), `SNDBUF` the kernel's unacknowledged bytes and the scheduler's budget, `A` lines the client's frame age from the clock sync, `C` its clock samples.

`BEACON_EXP` switches, comma separated: `load` (scrolling texture in the flash window, game-like bitrates; `load=blocks`, `load=noise` for harder content), `fps=N` (capture and encode rate, overriding negotiation), `gop=N` (keyframe interval, default 5 s), `queue=N` (ScreenCaptureKit queue depth), `nollrc`, `delay0`, `speed`, `profile=baseline`, `burst=N`, `noabr` (no bitrate controller), `nogate` (no capture gate), `nokq` (ignore the kernel backlog), `sched=old` (pre-1.4 scheduler policy). `HARNESS_MAX_FPS=120` makes the client advertise `maximumFrameRate` like Beam does; unset, it is the pre-1.4 client and the host stays at the preset's rate.

What it cannot see: the real phone's decode, display scheduling and Wi-Fi. Those are read on the device with Beam's latency meter (Settings, Debug, Latency Meter). What it models badly: on loopback the receiver's kernel window absorbs a few hundred kilobytes before backpressure reaches Beacon, so the first seconds of a saturated shaped run are worse than a real access point queue; the steady state is representative.

Needs the Debug Beacon built through `Harness.xcworkspace` (Phoros from the checkout next to the repo, derived data at `.scratch/dd-beacon-local`, signed with the HID entitlement) and Python 3 for the analyzer and shaper.
