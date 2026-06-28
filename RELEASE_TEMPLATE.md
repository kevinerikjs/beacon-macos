# Beacon Release Template

Use this for every new Beacon (macOS host app) release.
Canonical runbook is in `beam-macos/CLAUDE.md` → "Release Deployment (Public DMG Repo)".

---

## Version Naming

```
major.minor.patch   build number (always increments by 1)

major — breaking protocol change or complete redesign
minor — new user-facing features
patch — bug fixes / polish only
```

Current: v1.1.3 (build 14). Next patch → v1.1.4 (build 15).

---

## Pre-Release Checklist

- [ ] All commits pushed to `beam-macos` main
- [ ] Version bumped: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.pbxproj
- [ ] Version bump committed and pushed
- [ ] Test build on real device (or at minimum Debug build succeeds)

---

## Build & Publish Steps

```bash
# 1. Archive (hardened runtime, Developer ID signed)
xcodebuild archive \
  -project BeamHost.xcodeproj -scheme BeamHost -configuration Release \
  -archivePath /tmp/Beacon.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=R4KDRC8S4D \
  ENABLE_HARDENED_RUNTIME=YES CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  "OTHER_CODE_SIGN_FLAGS=--timestamp"

# 2. Re-sign Sparkle nested binaries (required before notarization)
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
codesign --sign "$CERT" --timestamp --options runtime "$APP/Contents/Frameworks/Sparkle.framework"
codesign --force --deep --sign "$CERT" --timestamp --options runtime "$APP"

# 3. Create DMG (create-dmg has Finder AppleScript issues on macOS 15+, use hdiutil directly)
rm -f /tmp/Beacon.dmg
STAGING=/tmp/beacon_dmg_staging; rm -rf $STAGING; mkdir $STAGING
cp -R "$APP" $STAGING/ && ln -s /Applications $STAGING/Applications
hdiutil create -volname "Beacon" -srcfolder $STAGING -ov -format UDZO /tmp/Beacon.dmg

# 4. Notarize
xcrun notarytool submit /tmp/Beacon.dmg \
  --key ~/Downloads/AuthKey_REDACTED_ASC_KEY_ID.p8 \
  --key-id REDACTED_ASC_KEY_ID \
  --issuer REDACTED_ASC_ISSUER_ID \
  --wait
# Must say: status: Accepted

# 5. Staple
xcrun stapler staple /tmp/Beacon.dmg

# 6. Publish GitHub release (asset always named Beacon.dmg)
gh release create vX.Y.Z \
  --repo kevinerikjs/beacon-releases \
  --title "Beacon vX.Y.Z" \
  --notes "RELEASE_NOTES" \
  "/tmp/Beacon.dmg#Beacon.dmg"

# 7. Tag source commit
git tag vX.Y.Z && git push origin vX.Y.Z

# 8. Get EdDSA signature for Sparkle appcast
SIGN=$(find ~/Library/Developer/Xcode/DerivedData/BeamHost-*/SourcePackages/artifacts/sparkle/Sparkle/bin/sign_update -maxdepth 0 | head -1)
"$SIGN" /tmp/Beacon.dmg
# Copy sparkle:edSignature="..." and length="..."
```

---

## GitHub Release Notes Template

Pattern from past releases — keep it short, plain English bullet points:

**Patch (bug fix):**
```
Fixed: <one-line description of what was wrong and what it affected>
Fixed: <second fix if any>
```

**Minor (new features):**
```
## What's new in Beacon X.Y.0

**<Category>**
- <Feature or fix description>
- <Feature or fix description>

**<Category>**
- <Feature or fix description>
```

---

## Appcast Update (beam-web/public/appcast.xml)

Add a new `<item>` block at the TOP of the `<channel>` (above the previous latest):

```xml
<item>
  <title>Beacon X.Y.Z</title>
  <pubDate>Day, DD Mon YYYY 00:00:00 +0000</pubDate>
  <sparkle:version>N</sparkle:version>              <!-- integer build number, always +1 -->
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[
    <ul>
      <li>Fixed/Added: short user-facing description</li>
      <li>Fixed/Added: ...</li>
    </ul>
  ]]></description>
  <enclosure
    url="https://github.com/kevinerikjs/beacon-releases/releases/download/vX.Y.Z/Beacon.dmg"
    sparkle:edSignature="SIGNATURE_FROM_SIGN_UPDATE"
    length="LENGTH_FROM_SIGN_UPDATE"
    type="application/octet-stream"/>
</item>
```

Then commit and push `beam-web` — Vercel deploys automatically. Existing users will see the update prompt on next launch.

---

## Appcast Description Style

Match the existing tone — short, user-focused:
- Start with "Fixed:" or "Added:" (no emoji)
- One idea per `<li>`
- No internal jargon (no "SCKit", "destinationRect", etc.)
- Max 3-4 bullets for a patch, more ok for a minor release

**Examples from past releases:**
- `Fixed: app failed to launch when installed from DMG`
- `Auto-updates: Beacon now checks for updates on launch`
- `Fixed viewport lock in specific-window mode — locked region was offset and scaled incorrectly`
