#!/bin/bash
# Signs dist/"Mac Cleaner.app" (or the bundle given as the first argument).
#
# Usage: scripts/sign-app.sh [APP]
#
# Environment:
#   CODESIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)". When set, the app is signed with
#                       the hardened runtime and a secure timestamp (needed for notarization).
#                       Otherwise it is ad-hoc signed.
#
# scripts/build-app.sh calls this at the end of a build. The release workflow calls it a second time, in
# the job that holds the signing certificate, on the bundle that the secret-free build job produced.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
case "${1:-}" in -h|--help) sed -n '2,12p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac
APP="${1:-$ROOT/dist/Mac Cleaner.app}"
BUNDLE_ID="io.github.baturox.mac-cleaner"
[ -d "$APP" ] || { echo "sign-app.sh: missing $APP" >&2; exit 1; }

# The nested CLI is signed first, then the bundle (no --deep with a real identity).
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  echo "==> Signing with '$CODESIGN_IDENTITY' (hardened runtime)"
  codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
    --identifier "$BUNDLE_ID.cli" "$APP/Contents/Resources/bin/mac-cleaner"
  codesign --force --sign "$CODESIGN_IDENTITY" --options runtime --timestamp \
    --identifier "$BUNDLE_ID" "$APP"
else
  echo "==> Ad-hoc signing (set CODESIGN_IDENTITY for a Developer ID signature)"
  codesign --force --deep --sign - "$APP"
fi
codesign --verify --deep --strict "$APP"
