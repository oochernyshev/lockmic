#!/usr/bin/env bash
# Sign and notarize the direct-distribution app, then optionally notarize its DMG.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${APP_PATH:-$ROOT/build/LockMic.app}"
DMG=""
CHECK_ONLY=0
IDENTITY="${DEVELOPER_ID_APPLICATION:-}"

usage() {
  cat <<'EOF'
Usage: Scripts/notarize_release.sh [--check] [--app <path>] [--dmg <path>]

Environment:
  DEVELOPER_ID_APPLICATION  Exact "Developer ID Application: ..." identity.
                            Auto-detected when exactly one is installed.
  NOTARYTOOL_PROFILE        Keychain profile created with
                            `xcrun notarytool store-credentials`.
                            Defaults to `lockmic-notary` when no Apple ID
                            credentials are provided.

Or, for CI/non-interactive use:
  APPLE_ID
  APPLE_TEAM_ID
  APPLE_APP_SPECIFIC_PASSWORD

Without --dmg, signs, notarizes, staples, and verifies the app. With --dmg,
submits and staples the already-packaged disk image as a second step.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --check)
      CHECK_ONLY=1
      shift
      ;;
    --app)
      APP="${2:-}"
      shift 2
      ;;
    --dmg)
      DMG="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "error: unknown option: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [[ -z "$IDENTITY" ]]; then
  identities="$(
    security find-identity -v -p codesigning 2>/dev/null |
      sed -n 's/.*"\(Developer ID Application:[^"]*\)".*/\1/p'
  )"
  identity_count="$(printf '%s\n' "$identities" | sed '/^$/d' | wc -l | tr -d ' ')"
  if [[ "$identity_count" -eq 1 ]]; then
    IDENTITY="$identities"
  elif [[ "$identity_count" -eq 0 ]]; then
    echo "error: no Developer ID Application certificate is installed" >&2
    echo "       Create/download it in the Apple Developer portal, then install it in Keychain." >&2
    exit 1
  else
    echo "error: multiple Developer ID Application certificates found; set DEVELOPER_ID_APPLICATION" >&2
    printf '%s\n' "$identities" | sed 's/^/       /' >&2
    exit 1
  fi
fi

if ! security find-identity -v -p codesigning | grep -Fq "\"${IDENTITY}\""; then
  echo "error: signing identity is not available in Keychain: $IDENTITY" >&2
  exit 1
fi

NOTARY_ARGS=()
if [[ -n "${NOTARYTOOL_PROFILE:-}" ]]; then
  NOTARY_ARGS=(--keychain-profile "$NOTARYTOOL_PROFILE")
elif [[ -n "${APPLE_ID:-}" && -n "${APPLE_TEAM_ID:-}" && -n "${APPLE_APP_SPECIFIC_PASSWORD:-}" ]]; then
  NOTARY_ARGS=(
    --apple-id "$APPLE_ID"
    --team-id "$APPLE_TEAM_ID"
    --password "$APPLE_APP_SPECIFIC_PASSWORD"
  )
else
  NOTARY_ARGS=(--keychain-profile lockmic-notary)
fi

if [[ "$CHECK_ONLY" -eq 1 ]]; then
  echo "==> Validating notarization credentials"
  xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json >/dev/null
  echo "==> Developer ID identity and notarization credentials are valid"
  echo "    $IDENTITY"
  exit 0
fi

if [[ -n "$DMG" ]]; then
  if [[ ! -f "$DMG" ]]; then
    echo "error: disk image not found: $DMG" >&2
    exit 1
  fi
  echo "==> Notarizing $(basename "$DMG")"
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"
  exit 0
fi

if [[ ! -d "$APP" ]]; then
  echo "error: app not found: $APP" >&2
  exit 1
fi

echo "==> Signing $(basename "$APP")"
codesign \
  --force \
  --options runtime \
  --timestamp \
  --entitlements "$ROOT/Resources/LockMic.entitlements" \
  --sign "$IDENTITY" \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"

NOTARY_TMP="$(mktemp -d "${TMPDIR:-/tmp}/LockMic-notary.XXXXXX")"
SUBMISSION_ZIP="$NOTARY_TMP/LockMic.zip"
trap 'rm -rf "$NOTARY_TMP"' EXIT
ditto -c -k --sequesterRsrc --keepParent "$APP" "$SUBMISSION_ZIP"

echo "==> Notarizing $(basename "$APP")"
xcrun notarytool submit "$SUBMISSION_ZIP" "${NOTARY_ARGS[@]}" --wait
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Signed and notarized $APP"
