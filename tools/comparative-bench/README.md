# Comparative benchmark

Measures the latency of a screen-streaming app without being inside it, so the same number can
be taken from Beam, Parsec, Moonlight, Steam Link or AirPlay and the comparison means something.

Our own latency harness (`../latency-harness`) instruments Beam and Beacon directly and is far
more precise. It is useless for a comparison, because nobody else will let us instrument their
client. Everything here works from outside: a Mac that flashes, and a camera that watches.

## What is measured

**Glass to glass.** A full-screen window on the Mac flips black to white at a randomised moment.
That flip travels through whatever app is streaming, and a camera sees it arrive on the phone.
The time between the two is the latency of that app's whole pipeline: capture, encode, network,
decode, display. It is the number a person actually experiences.

It is not the same number as our internal harness reports. That one measures press to decoded
frame and stops before the phone's display; this one includes the phone's display pipeline and
the capture device's own delay. Absolute values here are higher, and only comparisons between
apps measured the same way are meaningful.

**Behaviour under loss.** `netprofile.sh` runs a loss schedule underneath a live session and
records the traffic. `netreport.py` reports what the app did about it: the rate it kept, how it
paced, and the longest stall. This needs no camera and no cooperation from the app.

## Setup

Two ways to watch the phone. Use whichever hardware is at hand.

**A: the phone itself, over USB.** An iPhone connected by cable, unlocked and trusted, appears
to macOS as a capture device, which is what QuickTime's movie recording uses. Its frames arrive
stamped on this Mac's clock, the same clock the flashboard writes, so no synchronisation is
needed anywhere. Highest precision, and the phone must be free for the duration.

**B: a camera pointing at both screens.** Prop the phone next to the Mac display so one camera
sees both, and watch two regions. The flip appears in the Mac region, then in the phone region,
and the difference is the latency. No clocks are involved at all, so this works with any camera,
including a cheap 30 fps webcam.

A low frame rate is less of a problem than it looks. Each crossing is interpolated between the
two frames that bracket it, and the flashboard's interval is randomised so the remaining error
falls in every phase of the capture equally. Over a hundred trials the mean converges: in a
simulation of a 30 fps camera against a true 60.0 ms latency, this code returned 60.9 ms with a
standard error of 0.9 ms. Single-trial percentiles at that frame rate are meaningless and the
report says so.

## Running one app

```bash
./build.sh

# 1. Start the app under test, streaming this Mac to the phone, full screen.
# 2. Watch the phone.
./watch --list                                     # what capture devices exist
./watch --device iPhone --roi 0.35,0.35,0.3,0.3 \
        --out /Volumes/yuh/business/.scratch/bench/parsec.csv --seconds 200 &

# 3. Flash. This takes over the Mac's screen for the duration.
./flashboard 120 /Volumes/yuh/business/.scratch/bench/parsec.board.log

# 4. Read it.
./analyze.py live /Volumes/yuh/business/.scratch/bench/parsec.board.log \
                  /Volumes/yuh/business/.scratch/bench/parsec.csv
```

With one camera on both screens, step 2 takes a second region and step 4 uses `dual`:

```bash
./watch --device Logitech --roi 0.05,0.3,0.3,0.4 --roi2 0.6,0.3,0.3,0.4 --out both.csv --seconds 200 &
./flashboard 120
./analyze.py dual both.csv
```

The regions are fractions of the frame: `x,y,width,height`, origin top left. Get them right by
running `watch` for a few seconds first and checking that both channels swing between roughly 16
and 235. The analyzer says which region never changed, which is the usual mistake.

## Behaviour under loss

```bash
sudo ./netprofile.sh parsec 192.168.18.45 240
./netreport.py /Volumes/yuh/business/.scratch/bench/parsec 192.168.18.45
```

Four minutes in four phases: clean, 1%, 2.5%, 5% loss on everything this Mac sends to the phone.
Keep the session doing something ordinary throughout, the same thing for every app.

`pfctl -E` stays on while a loss phase runs. If anything on this Mac stops reaching the phone
afterwards, `sudo pfctl -d` is the fix.

## Rules for a fair comparison

Each of these was a way to get a wrong answer.

- **Same content.** Identical on-screen activity for every app. A still desktop flatters a codec.
- **Same resolution and frame rate**, or if an app will not be pinned, record what it chose and
  say so in the result.
- **Same network, same session.** Measure all apps in one sitting. Wi-Fi conditions move.
- **Nothing else on the radio.** No AirDrop, no Bluetooth audio on either device, no
  `devicectl` while measuring. Each of those cost us a day of wrong numbers.
- **Every app at its lowest-latency setting.** Compare each app at its best, not at its default.
  Write the settings down.
- **Publish the method and the logs**, not only the table. The board logs and capture CSVs are
  small, so they go in the result directory alongside it.

## Files

| | |
|---|---|
| `flashboard.swift` | Full-screen flip source. Logs the moment each flip reached the display, on the host clock. |
| `watch.swift` | Samples one or two regions of every frame from any capture device. |
| `analyze.py` | Pairs flips with arrivals, interpolates the crossings, reports the distribution. |
| `netprofile.sh` | Packet capture with a loss schedule underneath. |
| `netreport.py` | Rate, pacing and stalls per loss phase. |
| `build.sh` | Builds the two Swift tools. |
