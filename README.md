# Beacon

**The Mac half of Beam. Beacon sends your Mac's screen and sound to your iPhone or iPad.**

Beacon lives in your menu bar. It captures your display, or a single window, along with system audio,
and streams it to the [Beam](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962) app on
your phone. At home that happens over your own Wi-Fi. Away from home it can go over your own Tailscale
network. There is no Beam account and no Beam server in between.

### [Download Beacon](https://github.com/kevinerikjs/beacon-macos/releases/latest/download/Beacon.dmg)

Free, signed and notarized, and it keeps itself up to date. Pair it with
**[Beam on the App Store](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962)** and you'll
be watching your Mac on your phone in a couple of minutes.

## What it's for

macOS has no way to show your Mac on an iPhone. AirPlay can't send to a phone, Sidecar only works with an
iPad, and iPhone Mirroring goes the other way (your phone on your Mac). Beacon and Beam fill that gap.

People use it to watch a render or a download from the couch, finish a film in bed, follow a livestream
from the kitchen, answer a dialog on a Mac in another room, or play Mac games with a controller.

## What Beacon does

- **Streams the whole display or one window.** Choose from the phone, or use **Beam a Specific Window…**
  in the menu bar. A global shortcut can switch window mode on and off from anywhere, and Beacon can
  start every stream on a window you pick (Preferences, Display, On Connect). Picture in Picture windows
  from Chrome, Safari or QuickTime show up in the list too.
- **Picks the display.** If you have more than one screen, choose which one to stream.
- **Sends sound.** System audio goes with the picture, or not at all if you turn audio off in Beam.
- **Matches the quality you ask for.** From 360p up to 1080p, and since 1.8.0 also 1440p, 4K and your
  display's native resolution, at 30 or 60 fps. Beacon tells Beam the largest size your display can
  produce, so Beam only offers sizes that make sense. On a 120 Hz iPhone or iPad, the 60 fps presets run
  at up to 120 fps when your Mac's display refreshes that fast too. Video is hardware-encoded in HEVC, or
  H.264 when the phone asks for it.
- **Takes input from the phone.** Clicks, double-clicks, right-clicks, drags and scrolling from Beam's
  click mode. Keys and text from Beam's live keyboard, including esc, tab, the arrows, function keys and
  ⌃ ⌥ ⇧ ⌘.
- **Lets you design the phone's button bar.** In Preferences, Controls, build a bar of up to eight buttons:
  keys, shortcuts, media keys, recorded macros, a text box, the keyboard and click. Two layouts come
  built in.
- **Turns the phone's controller into a Mac gamepad.** A controller paired with the iPhone or iPad shows
  up on the Mac as an Xbox Wireless Controller, or as a PlayStation DualShock 4 or a generic gamepad if
  you change it in Preferences, Controls.
- **Works away from home.** If Tailscale runs on the Mac, Beacon tells the phone its Tailscale address,
  so Beam (with Beam Unlimited) can reach it from anywhere.

What it doesn't do: Beacon doesn't make the phone an extra display, and it doesn't move files or sync the
clipboard between the phone and the Mac.

Guides: [why AirPlay can't do this](https://beamscreen.app/guide/airplay-mac-to-iphone) ·
[every Mac mirroring path](https://beamscreen.app/guide/mac-screen-mirroring) ·
[setup guide](https://beamscreen.app/guide/mirror-mac-to-iphone) ·
[Mac games with a controller](https://beamscreen.app/guide/controller-passthrough)

> **Why the source is public.** Beacon records your screen and your audio. That's a lot of trust to ask
> of any app, so the code is here for you to check. To use it, grab the DMG above. It's the same app,
> signed and notarized, and it updates itself.

> **Controller passthrough needs an entitlement you can't get from source.** Beacon turns the phone's
> controller into a virtual gamepad on the Mac (`PhorosInput.VirtualGamepad`). Creating that device
> needs Apple's `com.apple.developer.hid.virtual.device` entitlement, which Apple grants per developer
> team on request. A build without it runs and streams fine; it logs one line per session and ignores
> controller input. The signed DMG has the entitlement.

---

## How it works

| | |
| --- | --- |
| **Capture** | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit), for both the picture and system audio |
| **Encode** | VideoToolbox hardware encoding, HEVC or H.264. Audio as AAC-LC, or Float32 PCM for older Beam versions |
| **Discovery** | Bonjour, advertising `_beam._tcp` |
| **Control connection** | Network.framework TCP, encrypted with keys from the pairing secret (Phoros: X25519 and AES-256-GCM): pairing, sign-in, settings, phone input |
| **Media** | A UDP peer transport (ICE, DTLS, SRTP) from [Phoros](https://github.com/kevinerikjs/phoros), with loss repair and forward error correction. If it fails mid-stream, Beacon moves the stream to the TCP connection by itself |
| **Pairing** | Beam asks to pair, Beacon shows a 6-digit code, you type it on the phone. The secret is kept in the macOS Keychain |
| **Input** | Clicks, keys and text are replayed with `PhorosInput`, which needs Accessibility permission |
| **Controller** | An `IOHIDUserDevice` virtual gamepad (`PhorosInput.VirtualGamepad`), fed by the phone's controller reports |
| **Idle cost** | Close to nothing. No polling and no timers when you're not streaming, just a Bonjour listener |

Your screen never goes to a server. Beacon has no analytics, no account system, and no relay. It does
make two kinds of outside requests: Sparkle checks `beamscreen.app/appcast.xml` for updates, and the
feedback form in Preferences sends what you write to `beamscreen.app/api/feedback`.

**Encryption.** Everything Beacon and Beam send each other is encrypted end to end, using the secret your
two devices agree on when you pair: the picture, the sound, and every click and key press. Since Beacon 1.9
and Beam 3.6. Older Beam versions still connect without encryption until you turn that off in Preferences,
Paired Devices. See [SECURITY.md](./SECURITY.md).

## Dependencies

Beacon has two dependencies, both MIT licensed and compatible with the AGPL:

| Package | Why |
| --- | --- |
| [Phoros](https://github.com/kevinerikjs/phoros) | The protocol and plumbing Beacon shares with Beam: framing, handshake, sessions, the TCP connection, the UDP media transport, the VideoToolbox and AAC encoders, input replay and the virtual game controller. Pinned to an exact version, because two apps that ship on different days must not drift apart on a shared protocol. |
| [Sparkle](https://github.com/sparkle-project/Sparkle) | Updates, from the appcast at beamscreen.app |

Beyond Phoros, the capture and streaming path is Apple frameworks: ScreenCaptureKit, VideoToolbox,
AudioToolbox, Network.framework and IOKit.

## Requirements

- macOS 14 Sonoma or later
- Screen Recording permission, which Beacon asks for on first launch
- Accessibility permission, for clicks, typing and the custom buttons (Preferences, General shows both)
- An iPhone or iPad running Beam, on the same Wi-Fi or on your Tailscale network

## Building from source

You don't need to build Beacon to use it; the [DMG](#download-beacon) is the easy way. If you want to read
or change the code:

```bash
git clone https://github.com/kevinerikjs/beacon-macos.git
cd beacon-macos
open BeamHost.xcodeproj
```

Pick the `BeamHost` scheme and **My Mac**, then Run. Beacon appears in the menu bar. You'll need Xcode 15
or later.

> Screen capture and real network streaming need real hardware, so test on your Mac with a real iPhone or
> iPad running Beam at the other end.

## Project layout

```
BeamHost/
├── BeamHostApp.swift            # Entry point, menu bar only (LSUIElement)
├── AppState.swift               # Shared app state and preferences
├── PhoneControls.swift          # The phone's button bar: layouts, actions, macros
├── HotkeyManager.swift          # Global shortcut for window mode
├── LoginItemManager.swift       # Launch at login
├── Capture/
│   ├── ScreenCapture.swift      # ScreenCaptureKit, display and window capture
│   ├── VideoEncoder.swift       # VideoToolbox HEVC / H.264
│   ├── AudioEncoder.swift       # PCM and AAC-LC
│   └── VideoQualityManager.swift
├── Network/
│   ├── StreamServer.swift       # Listener, sessions, window switching
│   ├── StreamSession.swift      # One phone's stream, transport choice and fallback
│   ├── ControlChannel.swift     # Phone input to keys, clicks and media keys
│   ├── BonjourAdvertiser.swift
│   ├── TailscaleAddress.swift   # Finds the Mac's Tailscale address for remote access
│   └── Protocol.swift           # Imports the shared wire contract
├── Pairing/
│   ├── PairingManager.swift
│   ├── PairingWindowController.swift  # The window with the 6-digit code
│   └── KeyStore.swift           # Keychain-stored pairing secrets
├── Onboarding/                  # First-launch setup and permissions
├── MenuBar/
│   └── StatusItemView.swift
└── Settings/
    ├── SettingsView.swift       # General, Controls, Display, Devices
    ├── DisplayPicker.swift
    └── MacFeedbackView.swift
```

Beacon is built on [Phoros](https://github.com/kevinerikjs/phoros): the wire contract it shares with Beam,
plus the session logic (sign-in, send scheduling, video hold, quality adaptation), the TCP connection, the
UDP media transport, the encoders, input replay and the virtual gamepad. This repo holds Beacon itself:
screen capture, the menu bar, pairing, the Keychain, settings, and the policy on top of the package
(`BeamHost/Network/Protocol.swift`, `HostVideoEncoder`, `HostAudioEncoder`).

## Contributing

Issues and pull requests are welcome. A few ground rules:

- Apple frameworks only in the streaming path, through Phoros. No third-party streaming or networking
  libraries. A wire change starts in Phoros, with a pinned fixture test, and lands here as a version bump.
- Use Swift concurrency (`async`/`await`, actors) for anything asynchronous.
- Test on real hardware. A PR that has only been compiled hasn't been tested.
- Open an issue before a large change, so you don't spend a weekend on something that won't fit.

Contributions need a short **[Contributor License Agreement](./CLA.md)**: one line in your PR description.
[The CLA](./CLA.md) explains why. In short, it's what makes the dual licensing below possible.

## Project documents

| Document | What it covers |
| --- | --- |
| [SECURITY.md](./SECURITY.md) | How to report a vulnerability privately, and what's in scope |
| [LICENSE](./LICENSE) | The AGPL-3.0 text |
| [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) | Using Beacon without the AGPL obligations |
| [CLA.md](./CLA.md) | The one line contributors add to a PR, and why |
| [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) | How people are expected to treat each other here |
| [RELEASE_TEMPLATE.md](./RELEASE_TEMPLATE.md) | Steps for cutting a release |
| [CLAUDE.md](./CLAUDE.md) | Architecture rules, coding conventions and the full release runbook |

**Found a security problem? Please don't open an issue.** Read [SECURITY.md](./SECURITY.md) and email
[support@beamscreen.app](mailto:support@beamscreen.app).

## License

Beacon is **dual licensed**.

**By default it's [AGPL-3.0](./LICENSE).** You can use, study, change and share it, commercially too. In
return, if you distribute Beacon or something built from it, you publish your source under the AGPL as
well.

**A commercial license is available** if you want to build on Beacon without that obligation, for example
inside a closed-source product. Terms are open to discussion. Email
**[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject `Commercial license` and a
paragraph about what you're building. [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) has the details.

The **Beam** and **Beacon** names, logos and icons aren't part of the AGPL grant. Fork the code freely,
but please ship it under your own name.

Copyright © Kevin Erik Iin.

---

## Maintainer notes

Releases are cut by hand. Signing, notarization, the DMG and the Sparkle appcast are covered in
[RELEASE_TEMPLATE.md](./RELEASE_TEMPLATE.md) and, in full, in [`CLAUDE.md`](./CLAUDE.md) under
**Release Deployment**. The runbook reads Apple credentials from the environment:

```bash
export ASC_KEY_ID=...          # App Store Connect API key id
export ASC_ISSUER_ID=...       # App Store Connect issuer id
export ASC_KEY_PATH=...        # path to the AuthKey_*.p8, never committed
```

DMGs are published here, on [beacon-macos](https://github.com/kevinerikjs/beacon-macos) releases. The
download link at the top always points at the newest release, so it never needs updating.
