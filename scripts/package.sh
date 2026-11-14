#!/bin/bash
# Packages dist/"Mac Cleaner.app" (run scripts/build-app.sh first) into release artifacts:
#
#   dist/MacCleaner-<version>.dmg                      drag-to-Applications disk image
#   dist/MacCleaner-<version>.zip                      the app, signatures preserved (ditto)
#   dist/mac-cleaner-<version>-macos-universal.tar.gz  the command-line tool only
#   dist/SHA256SUMS
#
# Notarization runs only when credentials are present AND the app was signed with a Developer ID
# (CODESIGN_IDENTITY at build time):
#   NOTARY_PROFILE                                    a keychain profile made with
#                                                     `xcrun notarytool store-credentials`
#   or NOTARY_KEY_PATH + NOTARY_KEY_ID + NOTARY_ISSUER_ID   an App Store Connect API key
# Without them the artifacts are NOT notarized and Gatekeeper will warn on first launch.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
case "${1:-}" in -h|--help) sed -n '2,15p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;; esac

VERSION="$(tr -d '[:space:]' < VERSION)"
DIST="$ROOT/dist"
APP="$DIST/Mac Cleaner.app"
DMG="$DIST/MacCleaner-$VERSION.dmg"
ZIP="$DIST/MacCleaner-$VERSION.zip"
TGZ="$DIST/mac-cleaner-$VERSION-macos-universal.tar.gz"
VOLNAME="Mac Cleaner"

[ -d "$APP" ] || { echo "Missing $APP; run scripts/build-app.sh first." >&2; exit 1; }
BUILT_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
[ "$BUILT_VERSION" = "$VERSION" ] || { echo "App is version $BUILT_VERSION but VERSION says $VERSION; rebuild." >&2; exit 1; }

NOTARIZE=0
NOTARY_ARGS=()
if [ -n "${NOTARY_PROFILE:-}" ]; then
  NOTARIZE=1; NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
elif [ -n "${NOTARY_KEY_PATH:-}" ] && [ -n "${NOTARY_KEY_ID:-}" ] && [ -n "${NOTARY_ISSUER_ID:-}" ]; then
  NOTARIZE=1; NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
fi
if [ "$NOTARIZE" = 1 ] && [ -z "${CODESIGN_IDENTITY:-}" ]; then
  echo "Notary credentials are set but CODESIGN_IDENTITY is not; notarization needs a Developer ID signature." >&2
  exit 1
fi

rm -f "$DMG" "$ZIP" "$TGZ" "$DIST/SHA256SUMS"

# 1. Notarize the app first so the stapled ticket ends up inside every artifact.
if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing the app (this waits for Apple, usually a few minutes)"
  TMPZIP="$(mktemp -d)/notarize.zip"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$TMPZIP"
  xcrun notarytool submit "$TMPZIP" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$APP"
  rm -f "$TMPZIP"
fi

# 2. zip (ditto keeps signatures, symlinks and extended attributes intact).
echo "==> $(basename "$ZIP")"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# 3. dmg with an /Applications symlink.
echo "==> $(basename "$DMG")"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$VOLNAME" -srcfolder "$STAGE" -fs HFS+ -format UDZO -imagekey zlib-level=9 -ov -quiet "$DMG"
if [ -n "${CODESIGN_IDENTITY:-}" ]; then
  codesign --force --sign "$CODESIGN_IDENTITY" --timestamp "$DMG"
fi
if [ "$NOTARIZE" = 1 ]; then
  echo "==> Notarizing the disk image"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
fi

# 4. CLI-only tarball.
echo "==> $(basename "$TGZ")"
CLISTAGE="$(mktemp -d)"
cp "$APP/Contents/Resources/bin/mac-cleaner" "$CLISTAGE/mac-cleaner"
cp LICENSE "$CLISTAGE/LICENSE"
tar -czf "$TGZ" -C "$CLISTAGE" mac-cleaner LICENSE
rm -rf "$CLISTAGE"

# 5. Checksums.
( cd "$DIST" && shasum -a 256 "$(basename "$DMG")" "$(basename "$ZIP")" "$(basename "$TGZ")" > SHA256SUMS )
echo "==> SHA256SUMS"
cat "$DIST/SHA256SUMS"

if [ "$NOTARIZE" = 1 ]; then
  echo "Notarized and stapled."
else
  cat <<'NOTICE'

NOT NOTARIZED: these artifacts are not notarized by Apple (no credentials were provided).
Gatekeeper will warn on first launch: right-click the app and choose Open, or run
  xattr -dr com.apple.quarantine "/Applications/Mac Cleaner.app"
NOTICE
fi
