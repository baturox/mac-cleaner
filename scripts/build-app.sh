#!/bin/bash
# Builds "dist/Mac Cleaner.app" (universal binary, CLI embedded, signed).
#
# Usage: scripts/build-app.sh [--open] [--debug]
#
#   --open    open the app when done
#   --debug   debug build instead of release (host architecture only)
#
# Environment:
#   CODESIGN_IDENTITY   e.g. "Developer ID Application: Name (TEAMID)". When set, the app is signed with
#                       the hardened runtime and a secure timestamp (needed for notarization).
#                       Otherwise it is ad-hoc signed.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

CONFIG=release
OPEN_AFTER=0
for arg in "$@"; do
  case "$arg" in
    --open) OPEN_AFTER=1 ;;
    --debug) CONFIG=debug ;;
    -h|--help) sed -n '2,13p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "build-app.sh: unknown option '$arg' (try --help)" >&2; exit 2 ;;
  esac
done

APP_NAME="Mac Cleaner"
EXECUTABLE="MacCleaner"
BUNDLE_ID="io.github.baturox.mac-cleaner"
DIST="$ROOT/dist"
APP="$DIST/$APP_NAME.app"

VERSION="$(tr -d '[:space:]' < VERSION)"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-+.][0-9A-Za-z.-]+)?$ ]] || { echo "VERSION '$VERSION' is not a semantic version" >&2; exit 1; }
CLI_VERSION="$(sed -n 's/^let cliVersion = "\(.*\)"$/\1/p' Sources/CLI/Version.swift)"
if [ "$CLI_VERSION" != "$VERSION" ]; then
  echo "Version mismatch: VERSION says $VERSION but Sources/CLI/Version.swift says ${CLI_VERSION:-<missing>}" >&2
  exit 1
fi
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
YEAR="$(date +%Y)"

echo "==> Building $APP_NAME $VERSION ($BUILD_NUMBER), $CONFIG"

# 1. Compile. Universal (arm64 + x86_64) for release; fall back to the host architecture if that fails.
ARCH_FLAGS=()
if [ "$CONFIG" = release ]; then ARCH_FLAGS=(--arch arm64 --arch x86_64); fi
if ! swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}; then
  if [ ${#ARCH_FLAGS[@]} -gt 0 ]; then
    echo "WARNING: universal build failed; building for $(uname -m) only." >&2
    ARCH_FLAGS=()
    swift build -c "$CONFIG"
  else
    exit 1
  fi
fi
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"
for b in "$EXECUTABLE" mac-cleaner; do
  [ -x "$BIN_DIR/$b" ] || { echo "Missing build product: $BIN_DIR/$b" >&2; exit 1; }
done

# 2. Assemble the bundle.
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/bin"
cp "$BIN_DIR/$EXECUTABLE" "$APP/Contents/MacOS/$EXECUTABLE"
cp "$BIN_DIR/mac-cleaner" "$APP/Contents/Resources/bin/mac-cleaner"
if [ -f Resources/AppIcon.icns ]; then
  cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
else
  echo "WARNING: Resources/AppIcon.icns missing; run 'swift scripts/make-icon.swift'." >&2
fi
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleExecutable</key><string>$EXECUTABLE</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Copyright © $YEAR baturox. MIT License.</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
    <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST
plutil -lint "$APP/Contents/Info.plist" >/dev/null

# 3. Sign. The nested CLI is signed first, then the bundle (no --deep with a real identity).
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

echo "==> Built: $APP"
lipo -archs "$APP/Contents/MacOS/$EXECUTABLE" | sed 's/^/    architectures: /'
if [ "$OPEN_AFTER" = 1 ]; then open "$APP"; fi
