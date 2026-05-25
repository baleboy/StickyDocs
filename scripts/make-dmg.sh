#!/usr/bin/env bash
# Build a distributable .dmg for StickyDocs containing the .app and a
# symlink to /Applications, with the Finder window laid out so the user
# can drag the icon onto Applications.
#
# Uses `dmgbuild` (https://github.com/dmgbuild/dmgbuild), which writes the
# styled .DS_Store directly rather than driving Finder via AppleScript.
# That avoids the Finder-busy / unmount-fails class of bug create-dmg
# hits, and works in headless CI.
#
# Install:
#   pipx install dmgbuild           # or: pip3 install --user dmgbuild
#
# Usage:
#   scripts/make-dmg.sh                       # builds Release .app, then DMGs it
#   scripts/make-dmg.sh path/to/StickyDocs.app
#
# Output: dist/StickyDocs-<version>.dmg

set -euo pipefail

APP_NAME="StickyDocs"
VOL_NAME="StickyDocs"
PROJECT="StickyDocs/StickyDocs.xcodeproj"
SCHEME="StickyDocs"

cd "$(dirname "$0")/.."

if ! command -v dmgbuild >/dev/null 2>&1; then
  echo "error: dmgbuild not found. Install with: pipx install dmgbuild" >&2
  exit 1
fi

APP_SRC="${1:-}"

if [ -z "$APP_SRC" ]; then
  echo "Building Release ${APP_NAME}.app ..."
  BUILD_DIR="$(mktemp -d)"
  xcodebuild \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -derivedDataPath "$BUILD_DIR" \
    -destination 'generic/platform=macOS' \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    CODE_SIGN_IDENTITY= \
    build >/dev/null
  APP_SRC="$BUILD_DIR/Build/Products/Release/${APP_NAME}.app"
fi

if [ ! -d "$APP_SRC" ]; then
  echo "error: app bundle not found at $APP_SRC" >&2
  exit 1
fi

# Absolute path — dmgbuild's settings file reads APP_PATH at evaluation time.
APP_SRC="$(cd "$(dirname "$APP_SRC")" && pwd)/$(basename "$APP_SRC")"

VERSION=$(defaults read "$APP_SRC/Contents/Info" CFBundleShortVersionString 2>/dev/null || echo "dev")

mkdir -p dist
DMG_PATH="dist/${APP_NAME}-${VERSION}.dmg"
rm -f "$DMG_PATH"

# Detach any stale mount with the same name from a prior aborted run.
if [ -d "/Volumes/${VOL_NAME}" ]; then
  hdiutil detach "/Volumes/${VOL_NAME}" -force >/dev/null 2>&1 || true
fi

APP_PATH="$APP_SRC" dmgbuild \
  -s scripts/dmg-settings.py \
  "$VOL_NAME" \
  "$DMG_PATH"

echo "Created $DMG_PATH ($(du -h "$DMG_PATH" | cut -f1))"
