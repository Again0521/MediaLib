#!/usr/bin/env bash
# Reusable shelf screenshot helper: builds debug, launches the shelf debug binary,
# finds its window via CGWindowList (keyed on PID), screencaptures it live (Metal-safe),
# then kills the app. Live screencapture is required because offscreen cacheDisplay
# returns nil for the Metal backdrop layer.
#
# Usage: bash scripts/shelf_shot.sh <output_name.png> [extra debug args...]
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="$ROOT_DIR/artifacts/shelf-debug"
NAME="${1:-shelf.png}"; shift || true
EXTRA_ARGS=("$@")
mkdir -p "$OUT_DIR"
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"

cd "$ROOT_DIR"
RUN_DIR="$(mktemp -d "${TMPDIR:-/tmp}/medialib-shelf.XXXXXX")"
APP_PID=""
cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" 2>/dev/null || true
    wait "$APP_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
echo "Logs: $RUN_DIR"
swift build >"$RUN_DIR/build.log" 2>&1 || { echo "BUILD FAILED"; tail -40 "$RUN_DIR/build.log"; exit 1; }

.build/debug/MediaLib --music-player-visual-debug-dark --music-scheme-shelf ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} >"$RUN_DIR/run.log" 2>&1 &
APP_PID=$!
sleep 9
WID=$(swift "$ROOT_DIR/scripts/shelf_winid.swift" "$APP_PID" 2>/dev/null || true)
if [ -n "$WID" ]; then
  screencapture -x -o -l "$WID" "$OUT_DIR/$NAME"
  echo "Shelf shot: $OUT_DIR/$NAME (wid=$WID pid=$APP_PID)"
else
  echo "WINDOW NOT FOUND (pid=$APP_PID)"
  exit 1
fi
