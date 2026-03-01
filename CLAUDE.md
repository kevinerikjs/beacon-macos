# Beam macOS Host App

## Overview
Beacon — menu bar app that captures the Mac's screen + system audio and streams it to a paired iPhone over the local network.

## Key References
- **PRD:** `../PRD.md` (source of truth for all requirements)
- **Work State:** `./WORKPAD.md` (current progress and next steps)
- **iOS Counterpart:** `../beam-ios/` (the receiving end)

## Tech Stack
- Swift / SwiftUI
- macOS 14.0+ (Sonoma) deployment target
- ScreenCaptureKit (screen + audio capture)
- VideoToolbox (H.264/H.265 hardware encoding)
- AudioToolbox (AAC encoding)
- Network.framework (UDP streaming + TCP control)
- Bonjour / NWBrowser / NWListener (device discovery)

## Architecture Rules
- **Menu bar app only.** No dock icon, no main window. `LSUIElement = YES` in Info.plist.
- **Start at login** support via `SMAppService` (modern API, no helper apps).
- **Minimal idle footprint.** When not streaming, the app should use near-zero CPU. No polling, no timers - only Bonjour listener waiting for connections.
- **ScreenCaptureKit for everything.** Use SCStream for both video frames and audio. Do not use deprecated CGDisplayStream or AVCaptureScreenInput.
- **Hardware encoding only.** Use VideoToolbox VTCompressionSession with `kVTVideoEncoderSpecification_EnableHardwareAcceleratedVideoEncoder`. Never fall back to software encoding.
- **Permissions handling.** Gracefully handle missing Screen Recording permission. Guide user to System Settings if not granted.

## Project Structure (Target)
```
beam-macos/
├── CLAUDE.md
├── WORKPAD.md
├── BeamHost/
│   ├── BeamHostApp.swift           # App entry point
│   ├── MenuBar/
│   │   ├── MenuBarController.swift  # Menu bar icon + dropdown
│   │   └── StatusItemView.swift     # Menu bar dropdown UI
│   ├── Capture/
│   │   ├── ScreenCapture.swift      # ScreenCaptureKit wrapper
│   │   ├── VideoEncoder.swift       # VideoToolbox H.264/H.265
│   │   └── AudioEncoder.swift       # AAC encoding
│   ├── Network/
│   │   ├── BonjourAdvertiser.swift   # Advertise _beam._tcp service
│   │   ├── StreamServer.swift       # Accept connections, send stream
│   │   ├── ControlChannel.swift     # TCP control messages (media keys, etc.)
│   │   └── Protocol.swift           # Shared message definitions
│   ├── Pairing/
│   │   ├── PairingManager.swift     # Handle pairing flow
│   │   ├── QRCodeGenerator.swift    # Generate pairing QR code
│   │   └── KeyStore.swift           # Persist paired device keys
│   ├── Settings/
│   │   ├── SettingsView.swift       # Preferences window
│   │   └── DisplayPicker.swift      # Display selection UI
│   └── Resources/
│       └── Assets.xcassets
├── BeamHost.xcodeproj
└── BeamHostTests/
```

## Coding Conventions
- Use Swift concurrency (async/await, actors) for all asynchronous work
- Use `@Observable` (Observation framework) instead of `ObservableObject`/`@Published`
- Use structured concurrency (TaskGroup, etc.) over raw Task {} where possible
- Error handling: use typed throws where practical, always handle errors gracefully in UI
- Naming: follow Swift API Design Guidelines exactly
- No force unwraps (`!`) except for IB outlets (which we don't have) and known-safe static resources

## Release Deployment (Public DMG Repo)

- **Source vs releases split:** keep source code in `flowtheci/beam-macos` (can be private), publish installer assets in public `flowtheci/beam-releases`.
- **Build host app (Release):**
  - `xcodebuild -project BeamHost.xcodeproj -scheme BeamHost -configuration Release -destination 'platform=macOS' build`
- **Locate built app path from Xcode settings:**
  - `xcodebuild -project BeamHost.xcodeproj -scheme BeamHost -configuration Release -showBuildSettings | rg "TARGET_BUILD_DIR =|FULL_PRODUCT_NAME ="`
  - Current product name is `Beacon.app` (not `BeamHost.app`).
- **Create DMG locally (manual path):**
  - `create-dmg --volname "Beacon vX.Y.Z" --window-size 540 380 --icon-size 128 --icon "Beacon.app" 140 190 --app-drop-link 400 190 --volicon /path/to/BeaconVolume.icns --no-internet-enable /path/Beacon-vX.Y.Z.dmg /path/to/Beacon.app`
  - Build `BeaconVolume.icns` from `beam.icon/Assets/full-icon.png` via `sips` + `iconutil` if needed.
- **Publish release asset to public repo:**
  - `gh release create vX.Y.Z --repo flowtheci/beam-releases --title "Beacon vX.Y.Z" --notes-file /path/release-notes.md "/path/Beacon-vX.Y.Z.dmg#Beacon.dmg"`
  - Keep stable asset name `Beacon.dmg` so `latest/download/Beacon.dmg` links remain valid.
- **Web download links (beam-web):**
  - Keep macOS download URL pointed to `https://github.com/flowtheci/beam-releases/releases/latest/download/Beacon.dmg`
  - Files that must stay aligned:
    - `beam-web/src/components/Hero.tsx`
    - `beam-web/src/components/Download.tsx`
  - If release repo owner/name changes, update those constants and `beam-web` latest-release API fetch repo path.
