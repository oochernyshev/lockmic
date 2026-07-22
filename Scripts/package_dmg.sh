#!/usr/bin/env bash
# Package build/LockMic.app into a zip (and optional DMG) for GitHub Releases / Homebrew.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/LockMic.app"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.2.0")}"
OUT_DIR="${ROOT}/build/dist"
STAGE="${OUT_DIR}/stage"

if [[ ! -d "$APP" ]]; then
  echo "error: run Scripts/build_homebrew.sh first" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

ZIP="${OUT_DIR}/LockMic-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/LockMic.app" "$ZIP"

echo "==> Created $ZIP"
shasum -a 256 "$ZIP" | tee "${ZIP}.sha256"

# Optional DMG (requires no external tools)
DMG="${OUT_DIR}/LockMic-${VERSION}.dmg"
rm -f "$DMG"
hdiutil create -volname "LockMic" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
echo "==> Created $DMG"
shasum -a 256 "$DMG" | tee "${DMG}.sha256"
