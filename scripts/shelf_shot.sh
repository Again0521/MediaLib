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
swift build >/tmp/shelf_build.log 2>&1 || { echo "BUILD FAILED"; tail -40 /tmp/shelf_build.log; exit 1; }

pkill -f "MediaLib --music" 2>/dev/null || true
sleep 1
.build/debug/MediaLib --music-player-visual-debug-dark --music-scheme-shelf ${EXTRA_ARGS[@]+"${EXTRA_ARGS[@]}"} >/tmp/shelf_run.log 2>&1 &
APP_PID=$!
sleep 9
WID=$(swift "$ROOT_DIR/scripts/shelf_winid.swift" "$APP_PID" 2>/dev/null || true)
if [ -n "$WID" ]; then
  screencapture -x -o -l "$WID" "$OUT_DIR/$NAME"
  echo "Shelf shot: $OUT_DIR/$NAME (wid=$WID pid=$APP_PID)"
else
  echo "WINDOW NOT FOUND (pid=$APP_PID)"
fi
kill "$APP_PID" 2>/dev/null || true
pkill -f "MediaLib --music" 2>/dev/null || true
