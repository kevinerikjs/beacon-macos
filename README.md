# Beacon

**Beacon turns your Mac's screen into a stream your iPhone can watch and lightly control.**

It is a macOS menu bar app that captures your display and system audio and sends them to the
[Beam](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962) iOS app over your local
network, or over your own Tailscale network when you are away from home. No cables, no Beam account,
and no Beam relay.

### [Download Beacon](https://github.com/kevinerikjs/beacon-macos/releases/latest/download/Beacon.dmg)

Free, signed, and notarized. Pair it with **[Beam on the App
Store](https://apps.apple.com/us/app/beam-stream-your-screen/id6760154962)** on your iPhone and you
are streaming in about a minute.

## Why this exists: macOS can't do it

Mac to iPhone is the one screen-mirroring direction Apple has never shipped, so the features
people find while searching all point the wrong way:

- **AirPlay** — an iPhone can *send* AirPlay but never *receive* it. A Mac can AirPlay to an Apple
  TV, an AirPlay-compatible TV, a HomePod for audio, or another Mac running AirPlay Receiver.
  Never to an iPhone. "Reverse AirPlay" isn't a thing.
- **Sidecar** — turns an *iPad* into a second Mac display. It has never supported iPhone.
- **iPhone Mirroring** (macOS Sequoia and later) — puts your *iPhone* on your *Mac*. Opposite
  direction.

Beacon plus Beam covers that gap: your Mac's screen and audio, on your phone, over your own WiFi.

Beam is viewer-first with light control. From the iPhone you can tap to click, type with the live
keyboard, and trigger up to eight custom controls configured here in Beacon. It is not a full remote
desktop: there is no pointer, dragging, file transfer, or clipboard sync.

More detail: [why AirPlay can't do this](https://beamscreen.app/guide/airplay-mac-to-iphone) ·
[every Mac mirroring path compared](https://beamscreen.app/guide/mac-screen-mirroring) ·
[setup guide](https://beamscreen.app/guide/mirror-mac-to-iphone)

> **Why the source is here.** Beacon records your screen and your audio, which is about as much
> trust as you can ask of a piece of software. Rather than ask you to take our word for what it
> does with that, the code is public so you can check. Most people should just grab the DMG above,
> it is the same app, signed and notarized, and it updates itself.

> **Controller passthrough needs an entitlement you cannot get from source.** Beacon replays an
> iPhone-paired game controller into a virtual gamepad on the Mac (`PhorosInput.VirtualGamepad`).
> Creating that device needs Apple's `com.apple.developer.hid.virtual.device` entitlement, which
> Apple grants per developer team on request. A build without it still runs and streams; it logs
> one line per session and drops controller input. The signed DMG above carries the entitlement.

---

## How it works

| | |
| --- | --- |
| **Capture** | [ScreenCaptureKit](https://developer.apple.com/documentation/screencapturekit) for both display frames and system audio |
| **Encode** | VideoToolbox, hardware accelerated H.264. Never falls back to software encoding |
| **Transport** | Network.framework over TCP on your LAN or Tailscale network |
| **Discovery** | Bonjour, advertising `_beam._tcp` |
| **Pairing** | Device keys held in the macOS Keychain |
| **Idle cost** | Near zero. No polling and no timers when you are not streaming, just a Bonjour listener |

Nothing is uploaded anywhere. There is no telemetry in Beacon, no account system, and no server
in the path between your Mac and your phone.

## Requirements

- macOS 14 Sonoma or later
- Screen Recording permission, which macOS prompts for on first launch
- An iPhone running Beam on the same network, or with Tailscale configured for remote access

## Building from source

You do not need to build Beacon to use it, the [DMG](#download-beacon) is the easy path. But if you
want to audit or modify it:

```bash
git clone https://github.com/kevinerikjs/beacon-macos.git
cd beacon-macos
open BeamHost.xcodeproj
```

Select the `BeamHost` scheme, choose **My Mac** as the destination, and Run. Beacon appears in the
menu bar. Xcode 15 or later is required.

> ScreenCaptureKit and real network streaming cannot be exercised in a simulator, and there is no
> Mac simulator anyway. Everything here has to be tested on real hardware, with a real iPhone at
> the other end.

## Project layout

```
BeamHost/
├── BeamHostApp.swift        # Entry point, menu bar only (LSUIElement)
├── AppState.swift           # Central observable state
├── Capture/
│   ├── ScreenCapture.swift  # ScreenCaptureKit wrapper
│   ├── VideoEncoder.swift   # VideoToolbox H.264 hardware encoder
│   ├── AudioEncoder.swift   # Float32 PCM audio capture
│   └── VideoQualityManager.swift
├── Network/
│   ├── StreamServer.swift   # TCP server, manages client sessions
│   ├── StreamSession.swift  # Per-client stream session
│   └── Protocol.swift       # Imports the shared wire contract
├── Pairing/
│   ├── PairingManager.swift
│   └── KeyStore.swift       # Keychain-stored paired device credentials
├── MenuBar/
│   └── StatusItemView.swift
└── Settings/
    └── SettingsView.swift
```

Beacon is built on [Phoros](https://github.com/kevinerikjs/phoros): the wire contract it shares
with Beam, plus the session logic (auth, send scheduling, video hold, quality adaptation), the
framed TCP connection, the VideoToolbox and AAC encoders, and the virtual gamepad. What lives in this repo is Beacon
itself: screen capture, the menu bar, pairing UI, the Keychain, and the policy on top of the
package (`BeamHost/Network/Protocol.swift`, `HostVideoEncoder`, `HostAudioEncoder`).

## Contributing

Issues and pull requests are welcome. A few things worth knowing before you start:

- Apple frameworks only. No third-party streaming or networking libraries.
- Swift concurrency (`async`/`await`, actors) for anything asynchronous.
- Test on real hardware. A PR that has only been compiled has not been tested.
- Larger changes are best discussed in an issue first, so you do not spend a weekend on something
  that does not fit the roadmap.

Contributions require agreeing to a short **[Contributor License Agreement](./CLA.md)**, which is
one line in your PR description. [That document](./CLA.md) explains why it is needed, and the short
version is that it is what keeps the dual licensing below possible.

## Project documents

| Document | What it covers |
| --- | --- |
| [SECURITY.md](./SECURITY.md) | How to report a vulnerability privately, and which parts of Beacon are worth looking at |
| [LICENSE](./LICENSE) | The AGPL-3.0 text |
| [COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md) | Using Beacon without the AGPL obligations, and how to arrange that |
| [CLA.md](./CLA.md) | The one line contributors add to a PR, and why it is needed |
| [CODE_OF_CONDUCT.md](./CODE_OF_CONDUCT.md) | How people are expected to behave here |
| [CLAUDE.md](./CLAUDE.md) | Architecture rules, coding conventions, and the release runbook |

**Found a security problem? Do not open an issue.** Read [SECURITY.md](./SECURITY.md) and mail
[support@beamscreen.app](mailto:support@beamscreen.app) instead.

## License

Beacon is **dual licensed**.

**By default it is [AGPL-3.0](./LICENSE).** You can use it, study it, modify it, and redistribute
it, including commercially. What the AGPL asks in return is that if you distribute Beacon or
something derived from it, you publish your source under the AGPL too.

**A commercial license is available** if you want to build on Beacon without those source
disclosure obligations, for instance inside a closed source product. Terms are negotiable.

If that is you, mail **[support@beamscreen.app](mailto:support@beamscreen.app)** with the subject
`Commercial license` and a paragraph on what you are building. See
**[COMMERCIAL-LICENSE.md](./COMMERCIAL-LICENSE.md)** for the full picture.

The **Beam** and **Beacon** names, logos, and icons are not covered by the AGPL grant. Fork the
code freely, but please ship it under your own name.

Copyright © Kevin Erik Iin.

---

## Maintainer notes

Releases are cut manually. The signing, notarization, DMG, and Sparkle appcast steps are documented
in [`CLAUDE.md`](./CLAUDE.md) under **Release Deployment**, and the runbook reads its Apple
credentials from the environment:

```bash
export ASC_KEY_ID=...          # App Store Connect API key id
export ASC_ISSUER_ID=...       # App Store Connect issuer id
export ASC_KEY_PATH=...        # path to the AuthKey_*.p8, never committed
```

DMGs are published to [beacon-macos](https://github.com/kevinerikjs/beacon-macos). The
download URL in this README always resolves to the newest release automatically, so it does not
need updating per release.
