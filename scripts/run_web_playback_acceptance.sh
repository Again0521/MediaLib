#!/bin/bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd -P)"
cd "$ROOT_DIR"
BROWSER=""
VIEWPORT=""
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser) BROWSER="${2:-}"; shift 2 ;;
    --viewport) VIEWPORT="${2:-}"; shift 2 ;;
    --out-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
    *) echo "error: unknown argument: $1" >&2; exit 2 ;;
  esac
done

case "$BROWSER" in chromium|webkit) ;;
  *) echo "error: --browser must be chromium or webkit" >&2; exit 2 ;;
esac
if [[ ! "$VIEWPORT" =~ ^[0-9]{3,4}x[0-9]{3,4}$ ]]; then
  echo "error: --viewport must use WIDTHxHEIGHT" >&2
  exit 2
fi
if [[ -z "$OUTPUT_DIR" ]]; then
  echo "error: --out-dir is required" >&2
  exit 2
fi

mkdir -p "$OUTPUT_DIR"
if find "$OUTPUT_DIR" -mindepth 1 -maxdepth 1 -print -quit | grep -q .; then
  echo "error: --out-dir must be empty to prevent stale or unredacted evidence uploads" >&2
  exit 2
fi
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd -P)"
TEMP_PARENT="${RUNNER_TEMP:-/private/tmp}"
FIXTURE_ROOT="$(mktemp -d "$TEMP_PARENT/medialib-browser-acceptance.XXXXXX")"
SCRATCH_PATH="$FIXTURE_ROOT/swift-build"
PASSWORD_FILE="$FIXTURE_ROOT/browser-password"
# Keep raw server diagnostics inside the disposable fixture. They may contain
# local scratch paths and therefore must not be uploaded with redacted evidence.
SERVER_LOG="$FIXTURE_ROOT/server.log"
REPORT_PATH="$OUTPUT_DIR/report.json"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  case "$FIXTURE_ROOT" in
    "$TEMP_PARENT"/medialib-browser-acceptance.*) rm -rf "$FIXTURE_ROOT" ;;
  esac
}
trap cleanup EXIT INT TERM

printf '%s' 'playback matrix fixture password' > "$PASSWORD_FILE"
chmod 600 "$PASSWORD_FILE"

"$ROOT_DIR/scripts/generate_media_matrix.sh" "$FIXTURE_ROOT/media"

# Preserve an independent scratch build while avoiding unnecessary network fetches
# when a validated SwiftPM repository cache is already available locally.
if [[ -d "$ROOT_DIR/.build/repositories" ]]; then
  mkdir -p "$SCRATCH_PATH/repositories"
  ditto "$ROOT_DIR/.build/repositories" "$SCRATCH_PATH/repositories"
fi

swift build --scratch-path "$SCRATCH_PATH" --product MediaLibServer
env \
  MEDIALIB_WEB_PLAYBACK_FIXTURE=1 \
  MEDIALIB_WEB_PLAYBACK_FIXTURE_DIR="$FIXTURE_ROOT" \
  swift test --scratch-path "$SCRATCH_PATH" \
    --filter testPreparePlaybackMatrixBrowserFixtureWhenExplicitlyRequested

PORT="$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')"
env \
  MEDIALIB_SERVER_DATA_DIR="$FIXTURE_ROOT" \
  MEDIALIB_SERVER_HOST=127.0.0.1 \
  MEDIALIB_SERVER_PORT="$PORT" \
  MEDIALIB_SERVER_ID=medialib-browser-acceptance \
  MEDIALIB_SERVER_NAME='MediaLIB Browser Acceptance' \
  MEDIALIB_SERVER_NETWORK_ACCESS_MODE=loopback \
  "$SCRATCH_PATH/debug/MediaLibServer" --serve > "$SERVER_LOG" 2>&1 &
SERVER_PID="$!"

SERVER_ORIGIN="http://127.0.0.1:$PORT"
READY=0
for _ in {1..150}; do
  if curl -fsS "$SERVER_ORIGIN/login" >/dev/null 2>&1; then
    READY=1
    break
  fi
  if ! kill -0 "$SERVER_PID" 2>/dev/null; then
    echo "error: MediaLibServer exited before readiness" >&2
    exit 1
  fi
  sleep 0.1
done
if [[ "$READY" != "1" ]]; then
  echo "error: MediaLibServer did not become ready within 15 seconds" >&2
  exit 1
fi

export MEDIALIB_ACCEPTANCE_REVISION="${GITHUB_SHA:-$(git -C "$ROOT_DIR" rev-parse --verify HEAD)}"
export MEDIALIB_ACCEPTANCE_FFMPEG_VERSION="$(ffmpeg -version | head -n 1)"
export MEDIALIB_ACCEPTANCE_OS_VERSION="$(sw_vers -productVersion)"
export MEDIALIB_ACCEPTANCE_XCODE_VERSION="$(xcodebuild -version | tr '\n' ' ' | sed 's/[[:space:]]*$//')"
export MEDIALIB_PLAYWRIGHT_VERSION="$(node -p "require('./node_modules/playwright/package.json').version" 2>/dev/null || true)"

node "$ROOT_DIR/scripts/web_playback_baseline.mjs" \
  --server "$SERVER_ORIGIN" \
  --password-file "$PASSWORD_FILE" \
  --manifest "$FIXTURE_ROOT/matrix-manifest.json" \
  --browser "$BROWSER" \
  --viewport "$VIEWPORT" \
  --out "$REPORT_PATH"

cp "$FIXTURE_ROOT/matrix-manifest.json" "$OUTPUT_DIR/matrix-manifest.json"
printf '%s\n' "$MEDIALIB_ACCEPTANCE_FFMPEG_VERSION" > "$OUTPUT_DIR/ffmpeg-version.txt"
