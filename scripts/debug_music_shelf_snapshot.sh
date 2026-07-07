#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT_DIR="${MEDIALIB_SHELF_DEBUG_OUTPUT:-"$ROOT_DIR/artifacts/shelf-debug"}"
NAME="${MEDIALIB_SHELF_DEBUG_NAME:-shelf-idle.png}"

mkdir -p "$OUTPUT_DIR"

cd "$ROOT_DIR"

env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift build

env DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}" \
  swift run MediaLib \
    --music-player-visual-debug-dark \
    --music-scheme-shelf \
    --music-player-visual-debug-quadrant \
    --music-visual-debug-snapshot \
    --music-visual-debug-exit \
    --music-visual-debug-output "$OUTPUT_DIR" \
    --music-visual-debug-name "$NAME" \
    "$@"

echo "Shelf debug snapshot: $OUTPUT_DIR/$NAME"
