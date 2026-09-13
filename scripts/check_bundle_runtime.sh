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
REALPATH="${MEDIALIB_REALPATH:-/bin/realpath}"
FAILURES=0
RESOLVED_DEPENDENCY=""
RESOLVED_RPATHS=""

fail() {
  echo "error: $*" >&2
  FAILURES=$((FAILURES + 1))
}

if [[ ! -d "$APP_BUNDLE" ]]; then
  echo "error: application bundle does not exist: $APP_BUNDLE" >&2
  exit 1
fi

APP_CANONICAL="$($REALPATH "$APP_BUNDLE")"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/medialib-runtime-check.XXXXXX")"
SEEN_CONTEXTS="$WORK_DIR/seen-contexts.txt"
ALL_REACHED="$WORK_DIR/all-reached.txt"
touch "$SEEN_CONTEXTS" "$ALL_REACHED"
trap 'rm -rf "$WORK_DIR"' EXIT

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

relative_to_bundle() {
  local path="$1"
  printf '%s' "${path#$APP_BUNDLE/}"
}

is_inside_bundle() {
  local path="$1"
  case "$path" in
    "$APP_CANONICAL"|"$APP_CANONICAL"/*) return 0 ;;
    *) return 1 ;;
  esac
}

canonical_existing_path() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  "$REALPATH" "$path"
}

expand_runtime_path() {
  local expression="$1"
  local consumer="$2"
  local executable="$3"
  local candidate=""

  case "$expression" in
    @loader_path)
      candidate="$(dirname "$consumer")"
      ;;
    @loader_path/*)
      candidate="$(dirname "$consumer")/${expression#@loader_path/}"
      ;;
    @executable_path)
      candidate="$(dirname "$executable")"
      ;;
    @executable_path/*)
      candidate="$(dirname "$executable")/${expression#@executable_path/}"
      ;;
    /usr/lib/swift)
      printf '%s' "/usr/lib/swift"
      return 0
      ;;
    /*)
      candidate="$expression"
      ;;
    *)
      return 1
      ;;
  esac

  if [[ -e "$candidate" ]]; then
    canonical_existing_path "$candidate"
    return $?
  fi

  local parent=""
  parent="$(dirname "$candidate")"
  if [[ -d "$parent" ]]; then
    printf '%s/%s' "$(cd "$parent" && pwd -P)" "$(basename "$candidate")"
  else
    printf '%s' "$candidate"
  fi
}

load_rpaths() {
  local consumer="$1"
  local executable="$2"
  local inherited_file="$3"
  local output_file="$4"
  local raw=""
  local expanded=""

  : > "$output_file"
  if ! raw="$("$OTOOL" -l "$consumer" 2>/dev/null)"; then
    fail "unable to inspect LC_RPATH commands: $(relative_to_bundle "$consumer")"
    return 0
  fi

  while IFS= read -r rpath; do
    [[ -n "$rpath" ]] || continue
    if ! expanded="$(expand_runtime_path "$rpath" "$consumer" "$executable")"; then
      fail "unsupported LC_RPATH in $(relative_to_bundle "$consumer"): $rpath"
      continue
    fi
    printf '%s\n' "$expanded" >> "$output_file"
  done < <(printf '%s\n' "$raw" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { wanted=1; next }
    wanted && $1 == "path" {
      line=$0
      sub(/^[[:space:]]*path /, "", line)
      sub(/ \(offset [0-9]+\)$/, "", line)
      print line
      wanted=0
    }
  ')

  [[ -f "$inherited_file" ]] && cat "$inherited_file" >> "$output_file"
  awk '!seen[$0]++' "$output_file" > "$output_file.unique"
  mv "$output_file.unique" "$output_file"
}

resolve_dependency() {
  local consumer="$1"
  local executable="$2"
  local dependency="$3"
  local rpaths_file="$4"
  local candidate=""
  local canonical=""
  local suffix=""

  RESOLVED_DEPENDENCY=""
  RESOLVED_RPATHS=""
  case "$dependency" in
    /System/*|/usr/lib/*)
      RESOLVED_DEPENDENCY="system"
      return 0
      ;;
    /*)
      return 1
      ;;
    @loader_path*|@executable_path*)
      if ! candidate="$(expand_runtime_path "$dependency" "$consumer" "$executable")"; then
        return 1
      fi
      if ! canonical="$(canonical_existing_path "$candidate")"; then
        RESOLVED_DEPENDENCY="$candidate"
        return 1
      fi
      RESOLVED_DEPENDENCY="$canonical"
      return 0
      ;;
    @rpath/*)
      suffix="${dependency#@rpath/}"
      while IFS= read -r rpath; do
        [[ -n "$rpath" ]] || continue
        if [[ -n "$RESOLVED_RPATHS" ]]; then
          RESOLVED_RPATHS="$RESOLVED_RPATHS, $rpath"
        else
          RESOLVED_RPATHS="$rpath"
        fi
        if [[ "$rpath" == "/usr/lib/swift" ]]; then
          if [[ "$suffix" == libswift*.dylib ]]; then
            RESOLVED_DEPENDENCY="system"
            return 0
          fi
          continue
        fi
        candidate="$rpath/$suffix"
        if canonical="$(canonical_existing_path "$candidate" 2>/dev/null)"; then
          RESOLVED_DEPENDENCY="$canonical"
          return 0
        fi
      done < "$rpaths_file"
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

check_architecture() {
  local binary="$1"
  local architectures=""
  if ! architectures="$("$LIPO" -archs "$binary" 2>/dev/null)"; then
    fail "unable to inspect architecture: $(relative_to_bundle "$binary")"
  elif [[ " $architectures " != *" $REQUIRED_ARCH "* ]]; then
    fail "$(relative_to_bundle "$binary") is missing required architecture $REQUIRED_ARCH (found: $architectures)"
  fi
}

walk_dependencies() {
  local consumer="$1"
  local executable="$2"
  local inherited_file="$3"
  local inherited_digest=""
  inherited_digest="$(shasum -a 256 "$inherited_file" | awk '{print $1}')"
  local context_key="$executable|$consumer|$inherited_digest"
  local dependencies=""
  local install_id=""
  local rpaths_file=""
  local dependency=""

  if grep -Fqx "$context_key" "$SEEN_CONTEXTS"; then
    return 0
  fi
  printf '%s\n' "$context_key" >> "$SEEN_CONTEXTS"
  printf '%s\n' "$consumer" >> "$ALL_REACHED"

  check_architecture "$consumer"
  if ! dependencies="$("$OTOOL" -L "$consumer" 2>/dev/null)"; then
    fail "unable to inspect Mach-O dependencies: $(relative_to_bundle "$consumer")"
    return 0
  fi

  rpaths_file="$WORK_DIR/rpaths-$(printf '%s' "$context_key" | shasum -a 256 | awk '{print $1}')"
  load_rpaths "$consumer" "$executable" "$inherited_file" "$rpaths_file"
  install_id="$("$OTOOL" -D "$consumer" 2>/dev/null | awk 'NR == 2 {print}' || true)"

  while IFS= read -r dependency; do
    [[ -n "$dependency" ]] || continue
    [[ -n "$install_id" && "$dependency" == "$install_id" ]] && continue

    if ! resolve_dependency "$consumer" "$executable" "$dependency" "$rpaths_file"; then
      case "$dependency" in
        /*)
          fail "unbundled host dependency in $(relative_to_bundle "$consumer"): $dependency"
          ;;
        @rpath/*)
          fail "unresolved @rpath dependency in $(relative_to_bundle "$consumer"): $dependency (searched: ${RESOLVED_RPATHS:-<no LC_RPATH>})"
          ;;
        @loader_path*|@executable_path*)
          fail "unresolved bundled dependency in $(relative_to_bundle "$consumer"): $dependency"
          ;;
        @*)
          fail "unsupported unresolved load path in $(relative_to_bundle "$consumer"): $dependency"
          ;;
        *)
          fail "unrecognized load path in $(relative_to_bundle "$consumer"): $dependency"
          ;;
      esac
      continue
    fi

    [[ "$RESOLVED_DEPENDENCY" == "system" ]] && continue
    if ! is_inside_bundle "$RESOLVED_DEPENDENCY"; then
      fail "dependency escapes application bundle in $(relative_to_bundle "$consumer"): $dependency"
      continue
    fi
    walk_dependencies "$RESOLVED_DEPENDENCY" "$executable" "$rpaths_file"
  done < <(printf '%s\n' "$dependencies" | sed -E '1d; s/^[[:space:]]+//; s/ \(compatibility version.*$//')
}

EMPTY_RPATHS="$WORK_DIR/empty-rpaths.txt"
: > "$EMPTY_RPATHS"
for executable in MediaLib MediaLibServer ffmpeg ffprobe; do
  binary="$MACOS_DIR/$executable"
  [[ -e "$binary" ]] && walk_dependencies "$binary" "$binary" "$EMPTY_RPATHS"
done

MEDIA_LIB_RPATHS="$WORK_DIR/medialib-entry-rpaths.txt"
if [[ -e "$MACOS_DIR/MediaLib" ]]; then
  load_rpaths "$MACOS_DIR/MediaLib" "$MACOS_DIR/MediaLib" "$EMPTY_RPATHS" "$MEDIA_LIB_RPATHS"
else
  : > "$MEDIA_LIB_RPATHS"
fi
if [[ -n "$LIBMPV_PATH" && -e "$MACOS_DIR/MediaLib" ]]; then
  walk_dependencies "$LIBMPV_PATH" "$MACOS_DIR/MediaLib" "$MEDIA_LIB_RPATHS"
fi

if [[ -d "$FRAMEWORKS_DIR" ]]; then
  while IFS= read -r -d '' binary; do
    if [[ "$("$FILE_TOOL" -b "$binary" 2>/dev/null || true)" == Mach-O* ]] \
      && ! grep -Fqx "$binary" "$ALL_REACHED"; then
      walk_dependencies "$binary" "$MACOS_DIR/MediaLib" "$MEDIA_LIB_RPATHS"
    fi
  done < <(find "$FRAMEWORKS_DIR" -type f -print0)
fi

if [[ $FAILURES -ne 0 ]]; then
  echo "error: bundle runtime validation failed with $FAILURES issue(s)" >&2
  exit 1
fi

echo "bundle-runtime: runpath closure complete ($REQUIRED_ARCH)"
