# Beacon Release Template

Use this for every new Beacon (macOS host app) release.
The full runbook is in `CLAUDE.md`, under "Release Deployment (Public DMG Repo)". When the two disagree, CLAUDE.md wins.

---

## Version Naming

```
major.minor.patch   build number (always increments by 1)

major: breaking protocol change or a full redesign
minor: new features people will notice
patch: bug fixes and polish only
```

Current: v1.8.0 (build 29). Next patch: v1.8.1 (build 30).

---

## Pre-Release Checklist

- [ ] All commits pushed to `beam-macos` main
- [ ] Version bumped: `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in project.pbxproj
- [ ] Version bump committed and pushed
- [ ] Tested on a real Mac with a real iPhone or iPad running Beam

---

## Build & Publish Steps

```bash
# 1. Archive (hardened runtime, Developer ID signed). The provisioning profile carries the
#    HID virtual device entitlement for controller passthrough; without it Gatekeeper kills the app.
xcodebuild archive \
  -project BeamHost.xcodeproj -scheme BeamHost -configuration Release \
  -archivePath /tmp/Beacon.xcarchive \
  CODE_SIGN_IDENTITY="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)" \
  CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM=R4KDRC8S4D \
  PROVISIONING_PROFILE_SPECIFIER="Beacon Developer ID" \
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
  --key "$ASC_KEY_PATH" \
  --key-id $ASC_KEY_ID \
  --issuer $ASC_ISSUER_ID \
  --wait
# Must say: status: Accepted

# 5. Staple
xcrun stapler staple /tmp/Beacon.dmg

# 6. Publish GitHub release (asset always named Beacon.dmg)
gh release create vX.Y.Z \
  --repo kevinerikjs/beacon-macos \
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

Keep it short: plain English, one idea per bullet.

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
  <title>Beacon vX.Y.Z</title>
  <pubDate>Day, DD Mon YYYY 00:00:00 +0000</pubDate>
  <sparkle:version>N</sparkle:version>              <!-- integer build number, always +1 -->
  <sparkle:shortVersionString>X.Y.Z</sparkle:shortVersionString>
  <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
  <description><![CDATA[
    <ul>
      <li><b>Headline.</b> What changed, in a sentence or two.</li>
      <li><b>Fix:</b> what was wrong, now fixed.</li>
    </ul>
  ]]></description>
  <enclosure
    url="https://github.com/kevinerikjs/beacon-macos/releases/download/vX.Y.Z/Beacon.dmg"
    sparkle:edSignature="SIGNATURE_FROM_SIGN_UPDATE"
    length="LENGTH_FROM_SIGN_UPDATE"
    type="application/octet-stream"/>
</item>
```

Then commit and push `beam-web` and deploy the site, so `https://beamscreen.app/appcast.xml` serves the new item. Check it with `curl -s https://beamscreen.app/appcast.xml | head`. Existing users see the update on their next launch or when they choose Check for Updates.

---

## Appcast Description Style

Match the recent releases in `beam-web/public/appcast.xml`:
- Lead each bullet with a short bold headline, then one or two plain sentences about what changed for
  the person using it. Use "Fix:" for fixes.
- Say which Beam version a feature needs, if it needs one.
- No internal names (no "SCKit", "rtc2", "destinationRect", ticket numbers).
- Three or four bullets for a patch is plenty.

**Examples from past releases:**
- `<b>Higher-resolution streaming.</b> Beacon now supports Beam's 1440p, 4K, and display-native quality options, and tells Beam the selected display's maximum resolution.`
- `<b>Picture in Picture from the phone.</b> A Picture in Picture window (Chrome, Safari, QuickTime) now shows up in Beam's window list, so you can lock the stream to just the video.`
- `<b>Fix:</b> after a ⌘ shortcut from the phone, ⌘ no longer stays held for the next keys you type.`
