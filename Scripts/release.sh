#!/usr/bin/env bash
# Cut a LockMic GitHub + Homebrew + website release in one sitting.
#
#   ./Scripts/release.sh 1.4.36 -m "stable Dock badge and faster mute lock"
#   ./Scripts/release.sh 1.4.36 -m "…" --notes-file notes.md
#   ./Scripts/release.sh 1.4.36 -m "…" --no-push   # commit and tag only
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

NEW=""
SUMMARY=""
NOTES_TEXT=""
NOTES_FILE=""
NO_PUSH=0

usage() {
  cat <<'EOF'
Usage: Scripts/release.sh <version> -m <summary> [--notes <text> | --notes-file <path>] [--no-push]

Bumps version files, Release-builds, packages zip/DMG, stamps the Homebrew
cask SHA-256, commits, tags v<version>, pushes main + tag, then creates the
GitHub release with dmg/zip and checksums.

  -m, --message     One-line summary (commit, ARCHITECTURE row, default notes)
  --notes           GitHub release body (markdown)
  --notes-file      Read release body from a file
  --no-push         Commit and tag locally; do not push or call gh
  -h, --help

The working tree must be clean and you must be on main. Requires xcodegen and gh.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -m|--message)
      SUMMARY="${2:-}"
      shift 2
      ;;
    --notes)
      NOTES_TEXT="${2:-}"
      shift 2
      ;;
    --notes-file)
      NOTES_FILE="${2:-}"
      shift 2
      ;;
    --no-push)
      NO_PUSH=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "error: unknown option: $1 (try --help)" >&2
      exit 1
      ;;
    *)
      if [[ -n "$NEW" ]]; then
        echo "error: unexpected argument: $1" >&2
        exit 1
      fi
      NEW="$1"
      shift
      ;;
  esac
done

if [[ -z "$NEW" || -z "$SUMMARY" ]]; then
  usage >&2
  exit 1
fi
if [[ ! "$NEW" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  echo "error: version must be X.Y.Z (got $NEW)" >&2
  exit 1
fi
if [[ "$SUMMARY" == *"|"* ]]; then
  echo "error: -m summary cannot contain | (ARCHITECTURE table row)" >&2
  exit 1
fi
if [[ -n "$NOTES_TEXT" && -n "$NOTES_FILE" ]]; then
  echo "error: use only one of --notes or --notes-file" >&2
  exit 1
fi
if [[ -n "$NOTES_FILE" ]]; then
  NOTES_TEXT="$(cat "$NOTES_FILE")"
fi
if [[ -z "$NOTES_TEXT" ]]; then
  NOTES_TEXT="$(printf '## What’s new\n\n- %s\n' "$SUMMARY")"
fi

escape_re() {
  printf '%s' "$1" | sed 's/[.[\*^$()+?{|]/\\&/g'
}

plist_get() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$2"
}

yml_values() {
  local key="$1"
  grep -E "^[[:space:]]*${key}:" project.yml | sed -E "s/.*${key}:[[:space:]]*\"?([^\"]+)\"?.*/\1/"
}

OLD="$(plist_get CFBundleShortVersionString Resources/Info.plist)"
OLD_BUILD="$(plist_get CFBundleVersion Resources/Info.plist)"
if [[ "$NEW" == "$OLD" ]]; then
  echo "error: already at $NEW" >&2
  exit 1
fi
NEW_BUILD="$((OLD_BUILD + 1))"
OLD_RE="$(escape_re "$OLD")"

require_yml() {
  local key="$1" expect="$2" got n=0
  while IFS= read -r got; do
    n=$((n + 1))
    if [[ "$got" != "$expect" ]]; then
      echo "error: project.yml ${key}=${got} (expected ${expect})" >&2
      exit 1
    fi
  done < <(yml_values "$key")
  if [[ "$n" -ne 2 ]]; then
    echo "error: expected two ${key} entries in project.yml (got ${n})" >&2
    exit 1
  fi
}
require_yml MARKETING_VERSION "$OLD"
require_yml CURRENT_PROJECT_VERSION "$OLD_BUILD"

CASK_VER="$(sed -n 's/^  version "\([^"]*\)"/\1/p' Casks/lockmic.rb | head -1)"
if [[ "$CASK_VER" != "$OLD" ]]; then
  echo "error: Casks/lockmic.rb version $CASK_VER != Info.plist $OLD" >&2
  exit 1
fi

BRANCH="$(git rev-parse --abbrev-ref HEAD)"
if [[ "$BRANCH" != "main" ]]; then
  echo "error: must be on main (now $BRANCH)" >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "error: working tree is dirty; commit or stash first" >&2
  git status --porcelain >&2
  exit 1
fi
if git rev-parse --verify --quiet "refs/tags/v${NEW}"; then
  echo "error: tag v${NEW} already exists" >&2
  exit 1
fi

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen is required (brew install xcodegen)" >&2
  exit 1
fi
if [[ "$NO_PUSH" -eq 0 ]]; then
  if ! command -v gh >/dev/null 2>&1; then
    echo "error: gh is required to publish (brew install gh)" >&2
    exit 1
  fi
  if ! gh auth status >/dev/null 2>&1; then
    echo "error: gh is not logged in (gh auth login)" >&2
    exit 1
  fi
  if gh release view "v${NEW}" >/dev/null 2>&1; then
    echo "error: GitHub release v${NEW} already exists" >&2
    exit 1
  fi
fi

echo "==> $OLD ($OLD_BUILD) → $NEW ($NEW_BUILD)"
echo "    $SUMMARY"

/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $NEW" Resources/Info.plist
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $NEW_BUILD" Resources/Info.plist

perl -pi -e "s/MARKETING_VERSION: \"${OLD_RE}\"/MARKETING_VERSION: \"${NEW}\"/g" project.yml
perl -pi -e "s/CURRENT_PROJECT_VERSION: \"${OLD_BUILD}\"/CURRENT_PROJECT_VERSION: \"${NEW_BUILD}\"/g" project.yml

perl -pi -e "s/(\\*\\*Version:\\*\\* )[0-9]+\\.[0-9]+\\.[0-9]+/\${1}${NEW}/" README.md
perl -pi -e "s/LockMic-[0-9]+\\.[0-9]+\\.[0-9]+\\.zip/LockMic-${NEW}.zip/" README.md

perl -pi -e "s/(Current version:\\*\\* )[0-9]+\\.[0-9]+\\.[0-9]+/\${1}${NEW}/" ARCHITECTURE.md
if ! grep -qF "| **${NEW}** |" ARCHITECTURE.md; then
  # Insert after the last numeric phase-map row (before the trailing HB-2 / Pro rows).
  awk -v ver="$NEW" -v msg="$SUMMARY" '
    NR > 1 {
      print prev
      if (prev ~ /^\| \*\*[0-9]/ && $0 !~ /^\| \*\*[0-9]/ && !done) {
        print "| **" ver "** | " msg " | Done |"
        done = 1
      }
    }
    { prev = $0 }
    END { if (prev != "") print prev }
  ' ARCHITECTURE.md > ARCHITECTURE.md.tmp
  mv ARCHITECTURE.md.tmp ARCHITECTURE.md
fi

perl -pi -e "s/${OLD_RE}/${NEW}/g" website/public/index.html website/public/llms.txt

perl -pi -e "s/^  version \"${OLD_RE}\"/  version \"${NEW}\"/" Casks/lockmic.rb
perl -pi -e "s/LockMic-${OLD_RE}\\.zip/LockMic-${NEW}.zip/g" Casks/lockmic.rb

echo "==> Building Release"
"$ROOT/Scripts/build_homebrew.sh"
APP_PLIST="$ROOT/build/LockMic.app/Contents/Info.plist"
GOT_VER="$(plist_get CFBundleShortVersionString "$APP_PLIST")"
GOT_BUILD="$(plist_get CFBundleVersion "$APP_PLIST")"
if [[ "$GOT_VER" != "$NEW" || "$GOT_BUILD" != "$NEW_BUILD" ]]; then
  echo "error: built app is $GOT_VER ($GOT_BUILD), expected $NEW ($NEW_BUILD)" >&2
  exit 1
fi

echo "==> Packaging"
"$ROOT/Scripts/package_dmg.sh"
ZIP="$ROOT/build/dist/LockMic-${NEW}.zip"
DMG="$ROOT/build/dist/LockMic-${NEW}.dmg"
for f in "$ZIP" "$DMG" "${ZIP}.sha256" "${DMG}.sha256"; do
  if [[ ! -f "$f" ]]; then
    echo "error: missing $f" >&2
    exit 1
  fi
done
HASH="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
perl -pi -e "s/^  sha256 \"[0-9a-fA-F]{64}\"/  sha256 \"${HASH}\"/" Casks/lockmic.rb

echo "==> Checking leftover ${OLD}"
stale=0
for f in \
  Resources/Info.plist \
  project.yml \
  README.md \
  Casks/lockmic.rb \
  website/public/index.html \
  website/public/llms.txt
do
  if grep -n -F "$OLD" "$f"; then
    echo "error: $f still mentions $OLD" >&2
    stale=1
  fi
  if ! grep -q -F "$NEW" "$f"; then
    echo "error: $f does not mention $NEW" >&2
    stale=1
  fi
done
if ! grep -q -F "Current version:** ${NEW}" ARCHITECTURE.md; then
  echo "error: ARCHITECTURE.md header was not bumped" >&2
  stale=1
fi
if [[ "$stale" -ne 0 ]]; then
  exit 1
fi

git add \
  Resources/Info.plist \
  project.yml \
  LockMic.xcodeproj/project.pbxproj \
  README.md \
  ARCHITECTURE.md \
  website/public/index.html \
  website/public/llms.txt \
  Casks/lockmic.rb

if [[ -z "$(git diff --cached --name-only)" ]]; then
  echo "error: nothing to commit after bump" >&2
  exit 1
fi

git commit -m "Release ${NEW}: ${SUMMARY}"
git tag "v${NEW}"
echo "==> Committed and tagged v${NEW}"

if [[ "$NO_PUSH" -eq 1 ]]; then
  echo "    --no-push: not pushing. When ready:"
  echo "    git push origin main && git push origin v${NEW}"
  echo "    gh release create v${NEW} --title \"LockMic ${NEW}\" --notes-file … \\"
  echo "      build/dist/LockMic-${NEW}.dmg build/dist/LockMic-${NEW}.dmg.sha256 \\"
  echo "      build/dist/LockMic-${NEW}.zip build/dist/LockMic-${NEW}.zip.sha256"
  exit 0
fi

echo "==> Pushing main and v${NEW}"
git push origin main
git push origin "v${NEW}"

NOTES_TMP="$(mktemp)"
printf '%s\n' "$NOTES_TEXT" > "$NOTES_TMP"
echo "==> Creating GitHub release"
gh release create "v${NEW}" \
  --title "LockMic ${NEW}" \
  --notes-file "$NOTES_TMP" \
  "$DMG" \
  "${DMG}.sha256" \
  "$ZIP" \
  "${ZIP}.sha256"
rm -f "$NOTES_TMP"

echo "==> Released ${NEW}"
echo "    https://github.com/oochernyshev/lockmic/releases/tag/v${NEW}"
echo "    brew reinstall --cask --yes lockmic"
echo "    xattr -dr com.apple.quarantine /Applications/LockMic.app"
