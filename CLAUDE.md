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

Source code lives in `flowtheci/beam-macos` (private). Installer DMGs are published to `flowtheci/beacon-releases` (public).

### Full release process (run from `beam-macos/` repo root)

**1. Build Release app**
```
xcodebuild -project BeamHost.xcodeproj -scheme BeamHost -configuration Release -destination 'platform=macOS' build
```
Locate built app:
```
xcodebuild -project BeamHost.xcodeproj -scheme BeamHost -configuration Release -showBuildSettings 2>/dev/null | grep -E "TARGET_BUILD_DIR |FULL_PRODUCT_NAME "
```
Current product name is `Beacon.app`.

**2. Build volume icon (if beam.icon/Assets/full-icon.png changed)**
```bash
ICONSET=/tmp/Beacon.iconset; mkdir -p $ICONSET; ICON=beam.icon/Assets/full-icon.png
for s in 16 32 128 256 512; do sips -z $s $s $ICON --out $ICONSET/icon_${s}x${s}.png; done
sips -z 32 32   $ICON --out $ICONSET/icon_16x16@2x.png
sips -z 64 64   $ICON --out $ICONSET/icon_32x32@2x.png
sips -z 256 256 $ICON --out $ICONSET/icon_128x128@2x.png
sips -z 512 512 $ICON --out $ICONSET/icon_256x256@2x.png
cp $ICON $ICONSET/icon_512x512@2x.png
iconutil -c icns $ICONSET -o /tmp/BeaconVolume.icns
```

**3. Create DMG** (asset name is always `Beacon.dmg` — version goes in release title only)
```bash
APP=<TARGET_BUILD_DIR>/Beacon.app
create-dmg --volname "Beacon" --window-size 540 380 --icon-size 128 \
  --icon "Beacon.app" 140 190 --app-drop-link 400 190 \
  --volicon /tmp/BeaconVolume.icns --no-internet-enable \
  /tmp/Beacon.dmg "$APP"
```

**4. Publish to releases repo**
```
gh release create vX.Y.Z --repo flowtheci/beacon-releases --title "Beacon vX.Y.Z" --notes "..." "/tmp/Beacon.dmg#Beacon.dmg"
```
Asset name is always `Beacon.dmg` so the stable `/releases/latest/download/Beacon.dmg` URL never changes.

**5. Tag the source commit** — tag the last commit in `beam-macos` that was part of the deployed build:
```
git tag vX.Y.Z && git push origin vX.Y.Z
```
This marks exactly which source code corresponds to each public release.

### Web download links (beam-web)
Stable URL: `https://github.com/flowtheci/beacon-releases/releases/latest/download/Beacon.dmg`
Files that reference this constant (keep aligned):
- `beam-web/src/components/Hero.tsx` — `MACOS_DOWNLOAD_URL`
- `beam-web/src/components/Download.tsx` — `MACOS_DOWNLOAD_URL`
