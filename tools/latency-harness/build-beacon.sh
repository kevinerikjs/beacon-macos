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
