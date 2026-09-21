#!/bin/bash
# Builds the harness Beacon (Debug, local phoros) signed with the Developer ID. An ad-hoc
# signature changes on every build and macOS then revokes Screen Recording for the new
# binary (TCC keys on the code requirement); the Developer ID requirement is stable, so the
# grant survives rebuilds. Output: $BEACON_APP (default .scratch/dd-beacon-local).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DD="${BEACON_DD:-/Volumes/yuh/business/.scratch/dd-beacon-local}"
[ "${1:-}" = --clean ] && rm -rf "$DD/SourcePackages"
cd "$HERE/../.."
xcodebuild -workspace tools/latency-harness/Harness.xcworkspace -scheme BeamHost -configuration Debug \
  -derivedDataPath "$DD" \
  CODE_SIGN_IDENTITY="Developer ID Application: KEVIN ERIK IIN (R4KDRC8S4D)" CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM=R4KDRC8S4D PROVISIONING_PROFILE_SPECIFIER="Beacon Developer ID" build 2>&1 \
  | grep -E '^\*\* BUILD|error:' | head -5
# Prime the fresh binary: its first launch stalls for seconds while macOS verifies the new
# signature, which made the first harness run after every build time out. Launch, wait, kill.
APP="$DD/Build/Products/Debug/Beacon.app"
pkill -x Beacon 2>/dev/null || true
(BEACON_HARNESS=1 BEACON_HARNESS_LOG=/tmp/beacon-prime.log BEACON_EXP=synthetic nohup "$APP/Contents/MacOS/Beacon" >/dev/null 2>&1 &)
for i in $(seq 1 40); do nc -z 127.0.0.1 7979 2>/dev/null && break; sleep 0.25; done
sleep 3
pkill -x Beacon 2>/dev/null || true
sleep 1
echo "primed"
