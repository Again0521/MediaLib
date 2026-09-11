#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 2 ]]; then
  echo "usage: $0 <MediaLIB.app> <required-architecture>" >&2
  exit 2
fi

APP_BUNDLE="$1"
REQUIRED_ARCH="$2"
MACOS_DIR="$APP_BUNDLE/Contents/MacOS"
FRAMEWORKS_DIR="$APP_BUNDLE/Contents/Frameworks"
OTOOL="${MEDIALIB_OTOOL:-/usr/bin/otool}"
LIPO="${MEDIALIB_LIPO:-/usr/bin/lipo}"
FILE_TOOL="${MEDIALIB_FILE:-/usr/bin/file}"
FAILURES=0

fail() {
  echo "error: $*" >&2
  FAILURES=$((FAILURES + 1))
}

for executable in MediaLib MediaLibServer ffmpeg ffprobe; do
  if [[ ! -x "$MACOS_DIR/$executable" ]]; then
    fail "required executable is missing or not executable: Contents/MacOS/$executable"
  fi
done

LIBMPV_PATH=""
if [[ -d "$FRAMEWORKS_DIR" ]]; then
  LIBMPV_PATH="$(find "$FRAMEWORKS_DIR" -type f -name 'libmpv*.dylib' -print -quit)"
fi
if [[ -z "$LIBMPV_PATH" ]]; then
  fail "required libmpv runtime is missing from Contents/Frameworks"
fi

check_dependency() {
  local consumer="$1"
  local dependency="$2"
  local resolved=""

  case "$dependency" in
    /System/*|/usr/lib/*)
      return 0
      ;;
    /*)
      fail "unbundled host dependency in ${consumer#$APP_BUNDLE/}: $dependency"
      return 0
      ;;
    @loader_path/*)
      resolved="$(dirname "$consumer")/${dependency#@loader_path/}"
      ;;
    @executable_path/*)
      resolved="$MACOS_DIR/${dependency#@executable_path/}"
      ;;
    @rpath/*)
      local suffix="${dependency#@rpath/}"
      if [[ -e "$FRAMEWORKS_DIR/$suffix" ]]; then
        return 0
      fi
      resolved="$(find "$FRAMEWORKS_DIR" -path "*/$suffix" -print -quit 2>/dev/null || true)"
      if [[ -z "$resolved" && "$suffix" == libswift*.dylib ]]; then
        if "$OTOOL" -l "$consumer" 2>/dev/null \
          | awk '/LC_RPATH/{getline; getline; if ($2 == "/usr/lib/swift") found=1} END {exit !found}'; then
          return 0
        fi
      fi
      ;;
    @*)
      fail "unsupported unresolved load path in ${consumer#$APP_BUNDLE/}: $dependency"
      return 0
      ;;
    *)
      fail "unrecognized load path in ${consumer#$APP_BUNDLE/}: $dependency"
      return 0
      ;;
  esac

  if [[ -z "$resolved" || ! -e "$resolved" ]]; then
    fail "unresolved bundled dependency in ${consumer#$APP_BUNDLE/}: $dependency"
  fi
}

check_macho() {
  local binary="$1"
  local dependencies=""
  if ! dependencies="$("$OTOOL" -L "$binary" 2>/dev/null)"; then
    fail "unable to inspect Mach-O dependencies: ${binary#$APP_BUNDLE/}"
    return 0
  fi

  local architectures=""
  if ! architectures="$("$LIPO" -archs "$binary" 2>/dev/null)"; then
    fail "unable to inspect architecture: ${binary#$APP_BUNDLE/}"
  elif [[ " $architectures " != *" $REQUIRED_ARCH "* ]]; then
    fail "${binary#$APP_BUNDLE/} is missing required architecture $REQUIRED_ARCH (found: $architectures)"
  fi

  local dependency=""
  local install_id=""
  install_id="$("$OTOOL" -D "$binary" 2>/dev/null | awk 'NR == 2 {print}' || true)"
  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    [[ -n "$install_id" && "$dependency" == "$install_id" ]] && continue
    check_dependency "$binary" "$dependency"
  done < <(printf '%s\n' "$dependencies" | sed -E '1d; s/^[[:space:]]+//; s/ \(compatibility version.*$//')
}

for executable in MediaLib MediaLibServer ffmpeg ffprobe; do
  [[ -e "$MACOS_DIR/$executable" ]] && check_macho "$MACOS_DIR/$executable"
done

if [[ -d "$FRAMEWORKS_DIR" ]]; then
  while IFS= read -r -d '' binary; do
    if [[ "$("$FILE_TOOL" -b "$binary" 2>/dev/null || true)" == Mach-O* ]]; then
      check_macho "$binary"
    fi
  done < <(find "$FRAMEWORKS_DIR" -type f -print0)
fi

if [[ $FAILURES -ne 0 ]]; then
  echo "error: bundle runtime validation failed with $FAILURES issue(s)" >&2
  exit 1
fi

echo "bundle-runtime: complete ($REQUIRED_ARCH)"
