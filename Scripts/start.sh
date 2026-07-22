#!/usr/bin/env bash
# Start or restart LockMic (kills any running instance first).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="${ROOT}/build/LockMic.app"
BUILD_SCRIPT="${ROOT}/Scripts/build_homebrew.sh"

REBUILD=0
for arg in "$@"; do
  case "$arg" in
    -b|--build|rebuild) REBUILD=1 ;;
    -h|--help)
      cat <<'EOF'
Usage: Scripts/start.sh [options]

Start or restart LockMic from build/LockMic.app.

Options:
  -b, --build, rebuild   Rebuild the app before launching
  -h, --help             Show this help

Examples:
  ./Scripts/start.sh           # restart existing build
  ./Scripts/start.sh --build   # rebuild then start
EOF
      exit 0
      ;;
    *)
      echo "error: unknown option: $arg (try --help)" >&2
      exit 1
      ;;
  esac
done

if [[ "$REBUILD" -eq 1 ]] || [[ ! -d "$APP" ]]; then
  if [[ ! -d "$APP" ]]; then
    echo "==> App not found; building…"
  else
    echo "==> Rebuilding…"
  fi
  "$BUILD_SCRIPT"
fi

if [[ ! -d "$APP" ]]; then
  echo "error: expected app missing at $APP" >&2
  exit 1
fi

if pgrep -x LockMic >/dev/null 2>&1; then
  echo "==> Stopping LockMic…"
  killall LockMic 2>/dev/null || true
  # Wait until the process exits (up to ~3s)
  for _ in $(seq 1 30); do
    pgrep -x LockMic >/dev/null 2>&1 || break
    sleep 0.1
  done
  if pgrep -x LockMic >/dev/null 2>&1; then
    echo "==> Force-stopping LockMic…"
    killall -9 LockMic 2>/dev/null || true
    sleep 0.2
  fi
fi

echo "==> Starting LockMic…"
open "$APP"
echo "    Menu bar icon · click to toggle · right-click for menu · hotkeys ⌘⇧M · ⌘F5"
