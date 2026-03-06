# Beacon — macOS Host App

Beacon is the macOS menu bar app that captures your screen and audio and streams it to the Beam iOS app over your local network. It uses ScreenCaptureKit for capture, VideoToolbox for H.264 hardware encoding, and Network.framework for streaming.

**iOS client:** [beam-ios](https://github.com/flowtheci/beam-ios) — **Download:** [Beacon.dmg](https://github.com/flowtheci/beacon-releases/releases/latest/download/Beacon.dmg)

---

## Requirements

- macOS 14 Sonoma or later
- Xcode 15+
- Screen Recording permission (the app will prompt on first launch)

## Local Development

```bash
git clone git@github.com:flowtheci/beam-macos.git
cd beam-macos
open BeamHost.xcodeproj
```

Select the `BeamHost` scheme, choose "My Mac" as the destination, and hit Run. The app appears in the menu bar.

> **Note:** The simulator cannot test ScreenCaptureKit or real network streaming — always run on a real Mac.

## Project Structure

```
BeamHost/
├── BeamHostApp.swift        # App entry point (menu bar, LSUIElement)
├── AppState.swift           # Central observable state
├── Capture/
│   ├── ScreenCapture.swift  # ScreenCaptureKit wrapper
│   ├── VideoEncoder.swift   # VideoToolbox H.264 hardware encoder
│   ├── AudioEncoder.swift   # Float32 PCM audio capture
│   └── VideoQualityManager.swift
├── Network/
│   ├── StreamServer.swift   # TCP server, manages client sessions
│   ├── StreamSession.swift  # Per-client stream session
│   └── Protocol.swift       # Shared wire protocol (keep in sync with beam-ios)
├── Pairing/
│   ├── PairingManager.swift
│   └── KeyStore.swift       # Keychain-stored paired device credentials
├── MenuBar/
│   └── StatusItemView.swift # Menu bar dropdown UI
└── Settings/
    └── SettingsView.swift
```

## Branch Strategy

Single `main` branch. All development happens directly on main or in short-lived feature branches merged via PR. No automated CI — releases are cut manually (see below).

## Releasing a New Version

The full signed + notarized release process lives in [`CLAUDE.md`](./CLAUDE.md) under **Release Deployment**. Quick summary:

1. **Archive** with hardened runtime + Developer ID signing:
   ```bash
   xcodebuild archive \
     -project BeamHost.xcodeproj -scheme BeamHost -configuration Release \
     -archivePath /tmp/Beacon.xcarchive \
     CODE_SIGN_IDENTITY="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)" \
     CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=R4KDRC8S4D \
     ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
     "OTHER_CODE_SIGN_FLAGS=--timestamp"
   ```

2. **Create DMG** using `create-dmg` (see CLAUDE.md for full command with volume icon)

3. **Notarize**:
   ```bash
   xcrun notarytool submit /tmp/Beacon.dmg \
     --key ~/Downloads/AuthKey_REDACTED_ASC_KEY_ID.p8 \
     --key-id REDACTED_ASC_KEY_ID \
     --issuer REDACTED_ASC_ISSUER_ID \
     --wait
   ```

4. **Staple**: `xcrun stapler staple /tmp/Beacon.dmg`

5. **Publish** to [beacon-releases](https://github.com/flowtheci/beacon-releases):
   ```bash
   gh release create vX.Y.Z --repo flowtheci/beacon-releases \
     --title "Beacon vX.Y.Z" --notes "..." "/tmp/Beacon.dmg#Beacon.dmg"
   ```

6. **Tag** the source commit: `git tag vX.Y.Z && git push origin vX.Y.Z`

> The stable download URL `https://github.com/flowtheci/beacon-releases/releases/latest/download/Beacon.dmg` always points to the latest release automatically.

## AI Development (Claude Code)

This repo uses `CLAUDE.md` for shared AI agent rules (coding conventions, architecture constraints, release runbook). It's tracked in git and applies to all contributors.

**Install Claude Code:**
```bash
npm install -g @anthropic-ai/claude-code
claude  # run from the repo root
```

**Personal customization:** Create a `CLAUDE.local.md` file in the repo root for your own notes, preferred workflows, or local paths. It's gitignored and never committed — your overrides stay local.

```markdown
# CLAUDE.local.md (example)
- My Xcode DerivedData is on an external SSD at /Volumes/fast/...
- Prefer using xcbeautify for build output
```
