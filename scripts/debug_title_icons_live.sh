#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

OUT="$ROOT/Build/TitleIconLiveDebug"
APP="$ROOT/dist/MediaLIB.app"
CAPTURE_TIMEOUT="${CAPTURE_TIMEOUT:-35}"

rm -rf "$OUT"
mkdir -p "$OUT"

node scripts/debug_title_icons.mjs
scripts/package_dmg.sh

DESTINATIONS=(
  "video-tvShows"
  "music-albums"
  "music-artists"
  "music-playlists"
  "music-recent"
  "album-videos"
  "sources"
  "health"
  "settings"
)

run_capture() {
  local destination="$1"
  local image="$OUT/$destination.png"
  local report="$OUT/$destination.json"
  local elapsed=0

  rm -f "$image" "$report"

  /usr/bin/open -W -n "$APP" --args \
    --debug-live-title-icons \
    --debug-live-title-icons-destination "$destination" \
    --debug-live-title-icons-output "$OUT" &
  local open_pid="$!"

  while kill -0 "$open_pid" 2>/dev/null; do
    if [[ -s "$image" && -s "$report" ]]; then
      wait "$open_pid" 2>/dev/null || true
      return 0
    fi
    if (( elapsed >= CAPTURE_TIMEOUT )); then
      echo "error: timeout waiting for live title icon capture: $destination" >&2
      pkill -x MediaLib 2>/dev/null || true
      wait "$open_pid" 2>/dev/null || true
      return 1
    fi
    sleep 1
    elapsed=$((elapsed + 1))
  done

  wait "$open_pid" 2>/dev/null || true
  if [[ ! -s "$image" || ! -s "$report" ]]; then
    echo "error: app exited without live capture output: $destination" >&2
    return 1
  fi
}

for destination in "${DESTINATIONS[@]}"; do
  echo "Capturing live app title icon: $destination"
  run_capture "$destination"
done

echo "Live title icon captures written to $OUT"
