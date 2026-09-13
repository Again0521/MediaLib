#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <MediaLIB.app>" >&2
  exit 2
fi

APP_BUNDLE="$1"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
SERVER="$MACOS_DIR/MediaLibServer"
FFMPEG="$MACOS_DIR/ffmpeg"
FFPROBE="$MACOS_DIR/ffprobe"
PYTHON="${MEDIALIB_RUNTIME_PYTHON:-/usr/bin/python3}"

for executable in "$MACOS_DIR/MediaLib" "$SERVER" "$FFMPEG" "$FFPROBE" "$PYTHON"; do
  if [[ ! -x "$executable" ]]; then
    echo "error: launch check executable is missing: $executable" >&2
    exit 1
  fi
done

LIBMPV="$(find "$FRAMEWORKS_DIR" -type f -name 'libmpv*.dylib' -print -quit)"
if [[ -z "$LIBMPV" ]]; then
  echo "error: launch check cannot find bundled libmpv" >&2
  exit 1
fi

# Run without developer-machine DYLD overrides. The app's dedicated self-test
# opens bundled libmpv from the actual executable and runpath context.
clean_launch() {
  /usr/bin/env \
    -u DYLD_LIBRARY_PATH \
    -u DYLD_FRAMEWORK_PATH \
    -u DYLD_FALLBACK_LIBRARY_PATH \
    -u DYLD_FALLBACK_FRAMEWORK_PATH \
    -u DYLD_INSERT_LIBRARIES \
    "$@"
}

HEALTH="$(clean_launch "$SERVER" --health)"
DESCRIBE="$(clean_launch "$SERVER" --describe)"
clean_launch "$PYTHON" -c '
import json
import sys
health = json.loads(sys.argv[1])
describe = json.loads(sys.argv[2])
assert health.get("status") == "ok"
assert health.get("apiVersion") == "v1"
assert describe.get("apiVersion") == "v1"
assert "health" in describe.get("capabilities", [])
' "$HEALTH" "$DESCRIBE"

FFMPEG_VERSION="$(clean_launch "$FFMPEG" -version)"
FFPROBE_VERSION="$(clean_launch "$FFPROBE" -version)"
[[ "$FFMPEG_VERSION" == "ffmpeg version "* ]]
[[ "$FFPROBE_VERSION" == "ffprobe version "* ]]
LIBMPV_RESULT="$(clean_launch "$MACOS_DIR/MediaLib" --check-bundled-libmpv)"
[[ "$LIBMPV_RESULT" == "bundle-libmpv: loaded" ]]

echo "bundle-launch: server, media tools and libmpv loaded"
