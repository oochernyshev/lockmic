#!/usr/bin/env bash
# Package build/LockMic.app into a zip (Homebrew) and a drag-to-Applications DMG.
#
# DMG layout (660×400 window, 128px icons, centered):
#   LockMic.app  →arrow→  Applications
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/LockMic.app"
BG_PNG="${ROOT}/Resources/dmg/background.png"
# Optional override: Resources/dmg/VolumeIcon.icns — otherwise use the app icon
VOL_ICNS_SRC="${ROOT}/Resources/dmg/VolumeIcon.icns"
VERSION="${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || echo "1.2.0")}"
OUT_DIR="${ROOT}/build/dist"
STAGE="${OUT_DIR}/stage"
VOLNAME="LockMic"

# Window & icon geometry — background PNG must be exactly WIN_W×WIN_H pixels
# (Finder maps background pixels 1:1 to window points; a 2× image shows only the top-left).
WIN_W=660
WIN_H=400
WIN_X=200
WIN_Y=120
ICON_SIZE=128
# Icon centers: left of arrow / right of arrow (arrow is centered ~x=330)
ICON_APP_X=150
ICON_APP_Y=175
ICON_APPS_X=510
ICON_APPS_Y=175

if [[ ! -d "$APP" ]]; then
  echo "error: run Scripts/build_homebrew.sh first" >&2
  exit 1
fi

if [[ ! -f "$BG_PNG" ]]; then
  echo "error: missing DMG background: $BG_PNG" >&2
  exit 1
fi

BG_W="$(sips -g pixelWidth "$BG_PNG" 2>/dev/null | awk '/pixelWidth/ {print $2}')"
BG_H="$(sips -g pixelHeight "$BG_PNG" 2>/dev/null | awk '/pixelHeight/ {print $2}')"
if [[ "$BG_W" != "$WIN_W" || "$BG_H" != "$WIN_H" ]]; then
  echo "error: DMG background must be ${WIN_W}×${WIN_H}px (got ${BG_W}×${BG_H})" >&2
  echo "       Finder maps background pixels 1:1 to window points." >&2
  exit 1
fi

# Avoid /Volumes/LockMic 1 collisions (breaks Finder layout scripting)
for vol in "/Volumes/${VOLNAME}" "/Volumes/${VOLNAME} 1" "/Volumes/${VOLNAME} 2"; do
  if [[ -d "$vol" ]]; then
    hdiutil detach "$vol" -force -quiet 2>/dev/null || true
  fi
done

mkdir -p "$OUT_DIR"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"

# --- Zip (app only; used by Homebrew cask) ---
ZIP="${OUT_DIR}/LockMic-${VERSION}.zip"
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$STAGE/LockMic.app" "$ZIP"

echo "==> Created $ZIP"
shasum -a 256 "$ZIP" | tee "${ZIP}.sha256"

# --- DMG ---
DMG="${OUT_DIR}/LockMic-${VERSION}.dmg"
TMP_DMG="${OUT_DIR}/.LockMic-${VERSION}.rw.dmg"
rm -f "$DMG" "$TMP_DMG"

# Fixed-size blank image: room for app + Applications link + background + .DS_Store
hdiutil create \
  -size 100m \
  -fs HFS+ \
  -volname "$VOLNAME" \
  -ov \
  "$TMP_DMG" >/dev/null

ATTACH_OUT="$(hdiutil attach -readwrite -noverify -noautoopen "$TMP_DMG")"
DEVICE="$(echo "$ATTACH_OUT" | awk '/^\/dev\// { print $1; exit }')"
MOUNT_POINT="$(echo "$ATTACH_OUT" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
if [[ -z "$DEVICE" || -z "$MOUNT_POINT" || ! -d "$MOUNT_POINT" ]]; then
  echo "error: failed to mount temporary DMG" >&2
  echo "$ATTACH_OUT" >&2
  rm -f "$TMP_DMG"
  exit 1
fi

cleanup_mount() {
  sync
  hdiutil detach "$DEVICE" -quiet 2>/dev/null || hdiutil detach "$MOUNT_POINT" -force -quiet 2>/dev/null || true
}
trap cleanup_mount EXIT

echo "==> Staging install layout on $MOUNT_POINT"
ditto "$APP" "$MOUNT_POINT/LockMic.app"
ln -s /Applications "$MOUNT_POINT/Applications"

# Hidden folder with background (Finder needs it on-volume)
mkdir -p "$MOUNT_POINT/.background"
cp "$BG_PNG" "$MOUNT_POINT/.background/background.png"
# Hide support files from icon view
if command -v SetFile >/dev/null 2>&1; then
  SetFile -a V "$MOUNT_POINT/.background" 2>/dev/null || true
fi
chflags hidden "$MOUNT_POINT/.background" 2>/dev/null || true

# Volume icon (mounted disk on Desktop / sidebar)
resolve_volume_icns() {
  if [[ -f "$VOL_ICNS_SRC" ]]; then
    echo "$VOL_ICNS_SRC"
    return
  fi
  local app_icns="${APP}/Contents/Resources/AppIcon.icns"
  if [[ -f "$app_icns" ]]; then
    echo "$app_icns"
    return
  fi
  # Build .icns from asset catalog PNGs
  local iconset="${OUT_DIR}/.VolumeIcon.iconset"
  local out_icns="${OUT_DIR}/.VolumeIcon.icns"
  local srcset="${ROOT}/Resources/Assets.xcassets/AppIcon.appiconset"
  local at="@"
  rm -rf "$iconset"
  mkdir -p "$iconset"
  local size
  for size in 16x16 32x32 128x128 256x256 512x512; do
    cp "${srcset}/icon_${size}.png" "${iconset}/icon_${size}.png"
    cp "${srcset}/icon_${size}${at}2x.png" "${iconset}/icon_${size}${at}2x.png"
  done
  iconutil -c icns "$iconset" -o "$out_icns"
  rm -rf "$iconset"
  echo "$out_icns"
}

VOL_ICNS="$(resolve_volume_icns)"
echo "    Volume icon source: $VOL_ICNS"

if [[ ! -L "$MOUNT_POINT/Applications" ]]; then
  echo "error: failed to create Applications symlink on volume" >&2
  exit 1
fi

ls -la "$MOUNT_POINT"

# Force Finder to notice the volume before we script it
open "$MOUNT_POINT"
sleep 0.8

WIN_X2=$((WIN_X + WIN_W))
WIN_Y2=$((WIN_Y + WIN_H))

layout_ok=0
for attempt in 1 2 3 4 5 6 7 8; do
  if osascript <<EOF
tell application "Finder"
  activate
  tell disk "$VOLNAME"
    open
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set sidebar width of container window to 0
    set the bounds of container window to {${WIN_X}, ${WIN_Y}, ${WIN_X2}, ${WIN_Y2}}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to ${ICON_SIZE}
    set text size of viewOptions to 12
    set label position of viewOptions to bottom
    try
      set background picture of viewOptions to file ".background:background.png"
    on error
      set background picture of viewOptions to POSIX file "${MOUNT_POINT}/.background/background.png"
    end try
    set position of item "LockMic.app" of container window to {${ICON_APP_X}, ${ICON_APP_Y}}
    set position of item "Applications" of container window to {${ICON_APPS_X}, ${ICON_APPS_Y}}
    update without registering applications
    delay 1
    -- Re-apply bounds/positions (Finder sometimes resets on first open)
    set the bounds of container window to {${WIN_X}, ${WIN_Y}, ${WIN_X2}, ${WIN_Y2}}
    set position of item "LockMic.app" of container window to {${ICON_APP_X}, ${ICON_APP_Y}}
    set position of item "Applications" of container window to {${ICON_APPS_X}, ${ICON_APPS_Y}}
    close
    open
    delay 0.8
    set the bounds of container window to {${WIN_X}, ${WIN_Y}, ${WIN_X2}, ${WIN_Y2}}
    close
  end tell
end tell
EOF
  then
    layout_ok=1
    break
  fi
  echo "    (Finder layout attempt $attempt failed; retrying…)"
  sleep 0.7
done

if [[ "$layout_ok" -ne 1 ]]; then
  echo "warning: could not fully configure Finder layout; Applications link is still present" >&2
fi

# Volume icon AFTER Finder layout (Finder can clobber/remove it if set earlier)
echo "    Installing volume icon…"
cp "$VOL_ICNS" "$MOUNT_POINT/.VolumeIcon.icns"
if command -v SetFile >/dev/null 2>&1; then
  SetFile -c icnC "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a V "$MOUNT_POINT/.VolumeIcon.icns" 2>/dev/null || true
  SetFile -a C "$MOUNT_POINT" 2>/dev/null || true
fi
if [[ ! -f "$MOUNT_POINT/.VolumeIcon.icns" ]]; then
  echo "error: .VolumeIcon.icns missing on volume before unmount" >&2
  exit 1
fi

# Give Finder time to flush .DS_Store before unmount
sync
sleep 1.5
# Make sure nothing still holds the volume
osascript -e "tell application \"Finder\" to eject disk \"${VOLNAME}\"" 2>/dev/null || true
sleep 0.5
cleanup_mount
trap - EXIT

# Sanity-check RW image still contains the volume icon before compress
ATTACH_CHK="$(hdiutil attach -readonly -noverify -noautoopen "$TMP_DMG")"
CHK_MNT="$(echo "$ATTACH_CHK" | awk -F'\t' '/\/Volumes\// { print $NF; exit }')"
if [[ ! -f "$CHK_MNT/.VolumeIcon.icns" ]]; then
  echo "error: .VolumeIcon.icns lost after detach (before compress)" >&2
  hdiutil detach "$CHK_MNT" -quiet 2>/dev/null || true
  exit 1
fi
echo "    Volume icon OK on RW image ($(stat -f%z "$CHK_MNT/.VolumeIcon.icns") bytes)"
hdiutil detach "$CHK_MNT" -quiet 2>/dev/null || true
sleep 0.3

# Compress
hdiutil convert "$TMP_DMG" -format UDZO -imagekey zlib-level=9 -o "$DMG" >/dev/null
rm -f "$TMP_DMG"

# Also set the .dmg *file* icon in Finder (not just the mounted volume)
if [[ -f "$VOL_ICNS" ]]; then
  if [[ "$VOL_ICNS" != /* ]]; then
    VOL_ICNS="$(cd "$(dirname "$VOL_ICNS")" && pwd)/$(basename "$VOL_ICNS")"
  fi
  DMG_ABS="$DMG"
  [[ "$DMG_ABS" != /* ]] && DMG_ABS="$(cd "$(dirname "$DMG")" && pwd)/$(basename "$DMG")"

  if command -v fileicon >/dev/null 2>&1; then
    fileicon set "$DMG_ABS" "$VOL_ICNS" 2>/dev/null || true
  else
    # AppKit via Swift — no extra deps
    if ! swift -e "
import AppKit
let icns = \"${VOL_ICNS//\"/\\\"}\"
let dmg = \"${DMG_ABS//\"/\\\"}\"
guard let img = NSImage(contentsOfFile: icns) else {
  fputs(\"warning: could not load icns\\n\", stderr)
  exit(0)
}
NSWorkspace.shared.setIcon(img, forFile: dmg)
" 2>/dev/null; then
      echo "    (could not set .dmg file icon; mounted volume icon is still set)"
    fi
  fi
fi
rm -f "${OUT_DIR}/.VolumeIcon.icns"

# Touch so Finder refreshes icon cache
touch "$DMG" 2>/dev/null || true

echo "==> Created $DMG"
shasum -a 256 "$DMG" | tee "${DMG}.sha256"
echo "    Open the DMG → drag LockMic.app onto Applications (follow the arrow)."
echo "    Volume / file icon: LockMic app icon (override with Resources/dmg/VolumeIcon.icns)."
