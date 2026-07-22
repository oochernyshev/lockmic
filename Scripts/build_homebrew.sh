#!/usr/bin/env bash
# Build a release LockMic.app suitable for local use and Homebrew cask packaging.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED="${DERIVED_DATA_PATH:-$ROOT/build/DerivedData}"
OUT_DIR="${OUT_DIR:-$ROOT/build}"
APP_NAME="LockMic"
SCHEME="LockMic"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required. Install with: brew install xcodegen" >&2
  exit 1
fi

echo "==> Generating Xcode project"
xcodegen generate

echo "==> Building ${CONFIGURATION}"
xcodebuild \
  -project "${APP_NAME}.xcodeproj" \
  -scheme "${SCHEME}" \
  -configuration "${CONFIGURATION}" \
  -derivedDataPath "${DERIVED}" \
  -destination "platform=macOS" \
  CODE_SIGN_IDENTITY="-" \
  CODE_SIGNING_ALLOWED=YES \
  CODE_SIGNING_REQUIRED=NO \
  build

APP_SRC="${DERIVED}/Build/Products/${CONFIGURATION}/${APP_NAME}.app"
if [[ ! -d "$APP_SRC" ]]; then
  echo "error: expected app not found at $APP_SRC" >&2
  exit 1
fi

mkdir -p "$OUT_DIR"
rm -rf "${OUT_DIR}/${APP_NAME}.app"
cp -R "$APP_SRC" "${OUT_DIR}/${APP_NAME}.app"

# Ad-hoc sign for local/dev; CI should re-sign with Developer ID + notarize.
codesign --force --deep --sign - "${OUT_DIR}/${APP_NAME}.app" 2>/dev/null || true

echo "==> Built ${OUT_DIR}/${APP_NAME}.app"
echo "    Run: open ${OUT_DIR}/${APP_NAME}.app"
echo "    Hotkeys: ⌘⇧M · ⌘F5  |  Menu bar: click to toggle, right-click for menu"
