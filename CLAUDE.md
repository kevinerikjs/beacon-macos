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

Source and installer DMGs both live in `kevinerikjs/beacon-macos`.

### Prerequisites
- **Developer ID Application** cert in keychain: `Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)`
  - If missing: Xcode → Settings → Accounts → Manage Certificates → + → Developer ID Application
- **App Store Connect API key** at `"$ASC_KEY_PATH"`
  - Key ID: `$ASC_KEY_ID`, Issuer ID: `$ASC_ISSUER_ID`

### Full release process (run from `beam-macos/` repo root)

**1. Archive Release app** (hardened runtime + secure timestamp required for notarization)
```bash
xcodebuild archive \
  -project BeamHost.xcodeproj \
  -scheme BeamHost \
  -configuration Release \
  -archivePath /tmp/Beacon.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=R4KDRC8S4D \
  ENABLE_HARDENED_RUNTIME=YES \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "OTHER_CODE_SIGN_FLAGS=--timestamp"
```
App is at: `/tmp/Beacon.xcarchive/Products/Applications/Beacon.app`

> **Note:** The Sparkle framework's nested binaries (Updater.app, Autoupdate, XPC services) are NOT re-signed by the archive step and will fail notarization. Always run step 1.5 before creating the DMG.

**1.5 Re-sign Sparkle nested binaries** (required — notarization will fail without this)
```bash
APP="/tmp/Beacon.xcarchive/Products/Applications/Beacon.app"
CERT="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)"
SPK="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"

codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/XPCServices/Downloader.xpc/Contents/MacOS/Downloader"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/XPCServices/Downloader.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/XPCServices/Installer.xpc/Contents/MacOS/Installer"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/XPCServices/Installer.xpc"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/Updater.app/Contents/MacOS/Updater"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/Updater.app"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/Autoupdate"
codesign --force --sign "$CERT" --timestamp --options runtime "$SPK/Sparkle"
codesign --force --sign "$CERT" --timestamp --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign "$CERT" --timestamp --options runtime "$APP"
```

**2. Build volume icon (if beam.icon/Assets/full-icon.png changed)**
```bash
ICONSET=/tmp/Beacon.iconset; mkdir -p $ICONSET; ICON=beam.icon/Assets/full-icon.png
for s in 16 32 128 256 512; do sips -z $s $s $ICON --out $ICONSET/icon_${s}x${s}.png; done
sips -z 32 32   $ICON --out $ICONSET/icon_16x16@2x.png
sips -z 64 64   $ICON --out $ICONSET/icon_32x32@2x.png
sips -z 256 256 $ICON --out $ICONSET/icon_128x128@2x.png
sips -z 512 512 $ICON --out $ICONSET/icon_256x256@2x.png
cp $ICON $ICONSET/icon_512x512@2x.png
iconutil -c icns $ICONSET -o /Users/kevin/BeaconVolume.icns
```

**3. Create DMG** (asset name is always `Beacon.dmg` — version goes in release title only)
> Note: use an absolute path outside `/tmp` for `--volicon` — create-dmg runs a Finder AppleScript
> that can lose access to `/tmp` files mid-run, causing a silent failure.
```bash
create-dmg --volname "Beacon" --window-size 540 380 --icon-size 128 \
  --icon "Beacon.app" 140 190 --app-drop-link 400 190 \
  --volicon /Users/kevin/BeaconVolume.icns --no-internet-enable \
  /tmp/Beacon.dmg /tmp/Beacon.xcarchive/Products/Applications/Beacon.app
```

**4. Notarize the DMG**
```bash
xcrun notarytool submit /tmp/Beacon.dmg \
  --key "$ASC_KEY_PATH" \
  --key-id $ASC_KEY_ID \
  --issuer $ASC_ISSUER_ID \
  --wait
```
Must say `status: Accepted`. If `Invalid`, run `xcrun notarytool log <submission-id> --key ...` to see errors.

**5. Staple the notarization ticket**
```bash
xcrun stapler staple /tmp/Beacon.dmg
```

**6. Publish to releases repo**
```bash
gh release create vX.Y.Z --repo kevinerikjs/beacon-macos --title "Beacon vX.Y.Z" --notes "..." "/tmp/Beacon.dmg#Beacon.dmg"
```
Asset name is always `Beacon.dmg` so the stable `/releases/latest/download/Beacon.dmg` URL never changes.

**7. Tag the source commit** — tag the last commit in `beam-macos` that was part of the deployed build:
```bash
git tag vX.Y.Z && git push origin vX.Y.Z
```
This marks exactly which source code corresponds to each public release.

**8. Update the Sparkle appcast** — Sparkle checks `https://beamscreen.app/appcast.xml` (served from `beam-web/public/appcast.xml`) to notify existing users of updates. Without this step, users on older versions will never see the update prompt.

Get the EdDSA signature and file size:
```bash
SIGN=~/Library/Developer/Xcode/DerivedData/BeamHost-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update
"$SIGN" /tmp/Beacon.dmg
# outputs: sparkle:edSignature="..." length="..."
```

Then add a new `<item>` block at the top of `beam-web/public/appcast.xml`:
```xml
<item>
  <title>Beacon vX.Y.Z</title>
  <pubDate>Day, DD Mon YYYY 00:00:00 +0000</pubDate>
  <sparkle:version>N</sparkle:version>              <!-- increment integer build number -->
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[<ul><li>...</li></ul>]]></description>
  <enclosure
    url="https://github.com/kevinerikjs/beacon-macos/releases/download/vX.Y.Z/Beacon.dmg"
    sparkle:edSignature="SIGNATURE_FROM_SIGN_UPDATE"
    length="LENGTH_FROM_SIGN_UPDATE"
    type="application/octet-stream"/>
</item>
```

Commit and push `beam-web` — Vercel deploys it automatically and existing users will see the update prompt on next launch or "Check for Updates".

### Web download links (beam-web)
Stable URL: `https://github.com/kevinerikjs/beacon-macos/releases/latest/download/Beacon.dmg`
Files that reference this constant (keep aligned):
- `beam-web/src/components/Hero.tsx` — `MACOS_DOWNLOAD_URL`
- `beam-web/src/components/Download.tsx` — `MACOS_DOWNLOAD_URL`
