#!/usr/bin/env bash
set -euo pipefail

resolve_script_dir() {
  local source="${BASH_SOURCE[0]}"
  local dir=""
  while [[ -L "$source" ]]; do
    dir="$(cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd)"
    source="$(readlink "$source")"
    [[ "$source" != /* ]] && source="$dir/$source"
  done
  cd -P "$(dirname "$source")" >/dev/null 2>&1 && pwd
}

SCRIPT_DIR="$(resolve_script_dir)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd -P)"
APP_NAME="MediaLib"
SERVER_NAME="MediaLibServer"
DISPLAY_NAME="MediaLIB"
BUNDLE_ID="com.local.MediaLib"
DIST_DIR="$ROOT_DIR/dist"
ROOT_HASH="$(printf '%s' "$ROOT_DIR" | shasum -a 256 | awk '{print substr($1, 1, 12)}')"
PACKAGE_INSTANCE="${MEDIALIB_PACKAGE_INSTANCE:-default}"
if [[ ! "$PACKAGE_INSTANCE" =~ ^[A-Za-z0-9_-]+$ ]]; then
  echo "error: MEDIALIB_PACKAGE_INSTANCE may only contain letters, numbers, _ and -" >&2
  exit 2
fi
BUILD_ROOT="/private/tmp/MediaLib-package-$(id -u)-$ROOT_HASH-$PACKAGE_INSTANCE"
APP_BUNDLE="$BUILD_ROOT/$DISPLAY_NAME.app"
APP_COPY="$DIST_DIR/$DISPLAY_NAME.app"
LEGACY_APP_COPY="$DIST_DIR/$APP_NAME.app"
DMG_ROOT="$BUILD_ROOT/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"
DMG_RW_PATH="$BUILD_ROOT/$APP_NAME-rw.dmg"
TEMP_DMG_PATH="$BUILD_ROOT/$APP_NAME.dmg"
CANDIDATE_DMG_PATH="$DIST_DIR/.$APP_NAME-$PACKAGE_INSTANCE.candidate.dmg"
PACKAGE_LOCK_PATH="$DIST_DIR/.medialib-package.lock"
DMG_MOUNT="$BUILD_ROOT/dmg-mount"
VERIFY_MOUNT="$BUILD_ROOT/verify-mount"
DMG_BACKGROUND="$DMG_ROOT/.background/dmg-background.png"
DMG_VOLUME_ICON="$DMG_ROOT/.VolumeIcon.icns"
SWIFT_MODULE_CACHE="/private/tmp/MediaLib-package-module-cache-$(id -u)-$ROOT_HASH-$PACKAGE_INSTANCE"
SWIFT_BUILD_DIR="$BUILD_ROOT/swiftpm-build"
SWIFTPM_CACHE_ROOT="/private/tmp/MediaLib-swiftpm-cache-$(id -u)-$ROOT_HASH-$PACKAGE_INSTANCE"
SWIFTPM_CONFIG_ROOT="/private/tmp/MediaLib-swiftpm-config-$(id -u)-$ROOT_HASH-$PACKAGE_INSTANCE"
SWIFTPM_SECURITY_ROOT="/private/tmp/MediaLib-swiftpm-security-$(id -u)-$ROOT_HASH-$PACKAGE_INSTANCE"
PACKAGE_JOBS="${MEDIALIB_PACKAGE_JOBS:-2}"
if [[ ! "$PACKAGE_JOBS" =~ ^[1-9][0-9]*$ ]]; then
  echo "error: MEDIALIB_PACKAGE_JOBS must be a positive integer" >&2
  exit 2
fi
SEED_LOCAL_REPOSITORIES="${MEDIALIB_PACKAGE_SEED_LOCAL_REPOSITORIES:-0}"
if [[ "$SEED_LOCAL_REPOSITORIES" != "0" && "$SEED_LOCAL_REPOSITORIES" != "1" ]]; then
  echo "error: MEDIALIB_PACKAGE_SEED_LOCAL_REPOSITORIES must be 0 or 1" >&2
  exit 2
fi

if [[ "${MEDIALIB_PACKAGE_DMG_PRINT_PATHS_ONLY:-0}" == "1" ]]; then
  printf 'SCRIPT_DIR=%s\n' "$SCRIPT_DIR"
  printf 'ROOT_DIR=%s\n' "$ROOT_DIR"
  printf 'BUILD_ROOT=%s\n' "$BUILD_ROOT"
  printf 'SWIFT_MODULE_CACHE=%s\n' "$SWIFT_MODULE_CACHE"
  printf 'SWIFT_BUILD_DIR=%s\n' "$SWIFT_BUILD_DIR"
  exit 0
fi

RELEASE_METADATA_TOOL="$ROOT_DIR/scripts/release_metadata.py"
/usr/bin/python3 "$RELEASE_METADATA_TOOL" --root "$ROOT_DIR" --check
VERSION="$(/usr/bin/python3 "$RELEASE_METADATA_TOOL" --root "$ROOT_DIR" --get productVersion)"
BUILD="$(/usr/bin/python3 "$RELEASE_METADATA_TOOL" --root "$ROOT_DIR" --get buildNumber)"

required_runtime_path() {
  local label="$1"
  local kind="$2"
  shift 2
  local explicitly_configured="0"
  local configured_path=""

  case "$label" in
    libmpv)
      if [[ "${MEDIALIB_LIBMPV_PATH+x}" == "x" ]]; then
        explicitly_configured="1"
        configured_path="$MEDIALIB_LIBMPV_PATH"
      fi
      ;;
    ffmpeg)
      if [[ "${MEDIALIB_FFMPEG_PATH+x}" == "x" ]]; then
        explicitly_configured="1"
        configured_path="$MEDIALIB_FFMPEG_PATH"
      fi
      ;;
    ffprobe)
      if [[ "${MEDIALIB_FFPROBE_PATH+x}" == "x" ]]; then
        explicitly_configured="1"
        configured_path="$MEDIALIB_FFPROBE_PATH"
      fi
      ;;
  esac

  local candidate=""
  if [[ "$explicitly_configured" == "1" ]]; then
    candidate="$configured_path"
    if [[ "$kind" == "executable" && -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
    if [[ "$kind" == "file" && -f "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  else
    for candidate in "$@"; do
      if [[ "$kind" == "executable" && -x "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [[ "$kind" == "file" && -f "$candidate" ]]; then
        printf '%s\n' "$candidate"
        return 0
      fi
    done
  fi

  echo "error: required $label was not found; complete MediaLIB packages must bundle libmpv, ffmpeg, and ffprobe" >&2
  return 1
}

LIBMPV_SOURCE="$(required_runtime_path libmpv file \
  /opt/homebrew/lib/libmpv.2.dylib \
  /usr/local/lib/libmpv.2.dylib \
  /opt/homebrew/lib/libmpv.dylib \
  /usr/local/lib/libmpv.dylib)"
FFMPEG_SOURCE="$(required_runtime_path ffmpeg executable /opt/homebrew/bin/ffmpeg /usr/local/bin/ffmpeg)"
FFPROBE_SOURCE="$(required_runtime_path ffprobe executable /opt/homebrew/bin/ffprobe /usr/local/bin/ffprobe)"

if [[ "${MEDIALIB_PACKAGE_DMG_PREFLIGHT_ONLY:-0}" == "1" ]]; then
  printf 'runtime-preflight: complete\nlibmpv=%s\nffmpeg=%s\nffprobe=%s\n' \
    "$LIBMPV_SOURCE" "$FFMPEG_SOURCE" "$FFPROBE_SOURCE"
  exit 0
fi

strip_bundle_metadata() {
  local target="$1"
  dot_clean -m "$target" 2>/dev/null || true
  xattr -cr "$target" 2>/dev/null || true
  find "$target" -exec xattr -cs {} + 2>/dev/null || true
  xattr -rd com.apple.FinderInfo "$target" 2>/dev/null || true
  xattr -rd 'com.apple.fileprovider.fpfs#P' "$target" 2>/dev/null || true
  xattr -rd com.apple.provenance "$target" 2>/dev/null || true
  find "$target" -exec xattr -ds com.apple.FinderInfo {} + 2>/dev/null || true
  find "$target" -exec xattr -ds 'com.apple.fileprovider.fpfs#P' {} + 2>/dev/null || true
  find "$target" -exec xattr -ds com.apple.provenance {} + 2>/dev/null || true
}

# hdiutil is still required here to create a Finder-layout DMG on the current
# supported macOS images. Recent macOS releases print a migration notice for
# its create/convert subcommands; suppress only that exact notice and preserve
# every other diagnostic (including real image creation failures).
run_hdiutil() {
  hdiutil "$@" 2> >(sed -E "/^hdiutil: WARNING: .* is deprecated\. Please use 'diskutil image /d" >&2)
}

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi
REUSE_EXISTING_RELEASE_BUILD="${MEDIALIB_PACKAGE_REUSE_BUILD:-0}"
if [[ "$REUSE_EXISTING_RELEASE_BUILD" != "0" && "$REUSE_EXISTING_RELEASE_BUILD" != "1" ]]; then
  echo "error: MEDIALIB_PACKAGE_REUSE_BUILD must be 0 or 1" >&2
  exit 2
fi
# Acquire ownership before touching instance scratch paths or registering cleanup.
# A rejected concurrent invocation must leave the active build and mounts alone.
mkdir -p "$DIST_DIR"
if ! /usr/bin/shlock -p "$$" -f "$PACKAGE_LOCK_PATH"; then
  echo "error: another MediaLIB package operation owns $PACKAGE_LOCK_PATH" >&2
  exit 1
fi
cleanup_release_artifacts() {
  hdiutil detach "$DMG_MOUNT" -quiet 2>/dev/null || true
  hdiutil detach "$VERIFY_MOUNT" -quiet 2>/dev/null || true
  rm -f "$CANDIDATE_DMG_PATH" "$PACKAGE_LOCK_PATH"
}
trap cleanup_release_artifacts EXIT
if [[ "$REUSE_EXISTING_RELEASE_BUILD" == "0" ]]; then
  rm -rf "$SWIFT_MODULE_CACHE" "$BUILD_ROOT"
else
  # 复用已成功的 release 二进制时，只清理本次 app/DMG 封装中间物；
  # 保留 swiftpm-build，避免重跑数分钟的全模块优化编译。
  rm -rf "$APP_BUNDLE" "$DMG_ROOT" "$DMG_RW_PATH" "$TEMP_DMG_PATH" "$DMG_MOUNT" "$VERIFY_MOUNT"
fi
rm -f "$CANDIDATE_DMG_PATH"
mkdir -p "$SWIFT_MODULE_CACHE" "$SWIFT_BUILD_DIR" "$SWIFTPM_CACHE_ROOT" "$SWIFTPM_CONFIG_ROOT" "$SWIFTPM_SECURITY_ROOT"
# CI and release machines may already have complete bare SwiftPM repositories
# under the package's ordinary scratch directory. Opt-in seeding copies only
# those immutable Git object stores into this isolated release scratch path;
# products and checkouts are still rebuilt from Package.resolved. This avoids
# restarting a large GitHub clone after a transient early EOF without turning
# the release build into a reuse of debug or previous release binaries.
if [[ "$REUSE_EXISTING_RELEASE_BUILD" == "0" \
  && "$SEED_LOCAL_REPOSITORIES" == "1" \
  && -d "$ROOT_DIR/.build/repositories" ]]; then
  mkdir -p "$SWIFT_BUILD_DIR/repositories"
  cp -R "$ROOT_DIR/.build/repositories/." "$SWIFT_BUILD_DIR/repositories/"
fi
export CLANG_MODULE_CACHE_PATH="$SWIFT_MODULE_CACHE"
export SWIFT_MODULECACHE_PATH="$SWIFT_MODULE_CACHE"

swift_package_args=(
  --package-path "$ROOT_DIR"
  --scratch-path "$SWIFT_BUILD_DIR"
  --cache-path "$SWIFTPM_CACHE_ROOT"
  --config-path "$SWIFTPM_CONFIG_ROOT"
  --security-path "$SWIFTPM_SECURITY_ROOT"
  --manifest-cache local
  --disable-dependency-cache
  --jobs "$PACKAGE_JOBS"
  -c release
)

cd "$ROOT_DIR"

# Icons are versioned build inputs. Regenerate them explicitly when artwork changes.
for icon in AppIcon.icns AppIcon.png AppIconDark.png; do
  if [[ ! -s "$ROOT_DIR/Sources/MediaLib/Resources/$icon" ]]; then
    echo "error: missing app icon $icon; run scripts/generate_icon.swift from the project root" >&2
    exit 1
  fi
done

# macOS 会给源码里的图标资源(PNG/icns)悄悄挂上 com.apple.macl / com.apple.provenance 等扩展属性
# （TCC 访问、下载来源标记等），SPM 打包资源 bundle 时会连同这些属性一起拷进 .build，随后
# 内建的 codesign 步骤对含此类「detritus」的 bundle 会直接失败：
#   "resource fork, Finder information, or similar detritus not allowed"
# 因此在 swift build 之前，先把源码资源目录里的扩展属性清干净（每次都清，因为系统会反复挂回来）。
find "$ROOT_DIR/Sources" -type d -name Resources -exec xattr -cr {} + 2>/dev/null || true
if [[ "$REUSE_EXISTING_RELEASE_BUILD" == "0" ]]; then
  swift build "${swift_package_args[@]}" --product "$APP_NAME"
  swift build "${swift_package_args[@]}" --product "$SERVER_NAME"
fi
SWIFT_PRODUCT_DIR="$(swift build "${swift_package_args[@]}" --show-bin-path)"
SWIFT_PRODUCT_BINARY="$SWIFT_PRODUCT_DIR/$APP_NAME"
SWIFT_SERVER_BINARY="$SWIFT_PRODUCT_DIR/$SERVER_NAME"
if [[ ! -x "$SWIFT_PRODUCT_BINARY" ]]; then
  echo "error: expected release product was not produced at $SWIFT_PRODUCT_BINARY" >&2
  exit 1
fi
if [[ ! -x "$SWIFT_SERVER_BINARY" ]]; then
  echo "error: expected release product was not produced at $SWIFT_SERVER_BINARY" >&2
  exit 1
fi

mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DMG_ROOT"

cp "$SWIFT_PRODUCT_BINARY" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$SWIFT_SERVER_BINARY" "$APP_BUNDLE/Contents/MacOS/$SERVER_NAME"
cp "$ROOT_DIR/Sources/MediaLib/Resources/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
cp "$ROOT_DIR/Sources/MediaLib/Resources/AppIcon.png" "$APP_BUNDLE/Contents/Resources/AppIcon.png"
cp "$ROOT_DIR/Sources/MediaLib/Resources/AppIconDark.png" "$APP_BUNDLE/Contents/Resources/AppIconDark.png"

bundle_libmpv_runtime() {
  local frameworks_dir="$APP_BUNDLE/Contents/Frameworks"
  mkdir -p "$frameworks_dir"

  rewrite_dependency_path() {
    local old_path="$1"
    local new_path="$2"
    local target_binary="$3"
    if ! install_name_tool -change "$old_path" "$new_path" "$target_binary"; then
      echo "error: failed to rewrite dependency $old_path in $target_binary" >&2
      return 1
    fi
  }

  framework_bundle_path() {
    local source_path="$1"
    if [[ "$source_path" == *".framework/"* ]]; then
      echo "${source_path%%.framework/*}.framework"
    fi
  }

  bundled_dependency_reference() {
    local source_path="$1"
    local executable_consumer="$2"
    local prefix="@loader_path"
    if [[ "$executable_consumer" == "yes" ]]; then
      prefix="@loader_path/../Frameworks"
    fi

    local framework_path
    framework_path="$(framework_bundle_path "$source_path")"
    if [[ -n "$framework_path" ]]; then
      local framework_name
      framework_name="$(basename "$framework_path")"
      local framework_relative_path="${source_path#$framework_path/}"
      echo "$prefix/$framework_name/$framework_relative_path"
    else
      echo "$prefix/$(basename "$source_path")"
    fi
  }

  slim_framework_copy() {
    local framework_copy="$1"
    local framework_name
    framework_name="$(basename "$framework_copy")"

    case "$framework_name" in
      Python.framework)
        # Homebrew's VapourSynth dependency links against the Python framework
        # binary, but MediaLIB does not execute Python. Keep the loadable
        # framework skeleton and drop the stdlib, docs, tests, headers and tools
        # that otherwise add tens of megabytes to the app bundle.
        find "$framework_copy" -name "__pycache__" -type d -prune -exec rm -rf {} + 2>/dev/null || true
        rm -rf \
          "$framework_copy/Headers" \
          "$framework_copy/Versions/"*/Headers \
          "$framework_copy/Versions/"*/bin \
          "$framework_copy/Versions/"*/include \
          "$framework_copy/Versions/"*/lib \
          "$framework_copy/Versions/"*/share \
          "$framework_copy/Versions/"*/_CodeSignature \
          "$framework_copy/Versions/"*/Resources/Python.app \
          2>/dev/null || true
        ;;
    esac
  }

  copy_dependency() {
    local source_path="$1"
    local framework_path
    framework_path="$(framework_bundle_path "$source_path")"
    local base_name
    local target_path

    if [[ -n "$framework_path" ]]; then
      base_name="$(basename "$framework_path")"
      target_path="$frameworks_dir/$base_name/${source_path#$framework_path/}"
    else
      base_name="$(basename "$source_path")"
      target_path="$frameworks_dir/$base_name"
    fi

    if [[ -n "$framework_path" && -d "$frameworks_dir/$base_name" ]]; then
      return 0
    fi

    if [[ -f "$target_path" ]]; then
      return 0
    fi

    if [[ -n "$framework_path" ]]; then
      cp -R "$framework_path" "$frameworks_dir/$base_name"
      chmod -R u+w "$frameworks_dir/$base_name"
      rm -rf "$frameworks_dir/$base_name/$base_name"
      find "$frameworks_dir/$base_name/Versions" -name site-packages -type l -exec rm {} \; 2>/dev/null || true
      slim_framework_copy "$frameworks_dir/$base_name"
    else
      cp -L "$source_path" "$target_path"
      chmod u+w "$target_path"
    fi

    # install_name_tool 改写前先移除来源二进制附带的旧签名；最终 bundle 会统一重签，
    # 这样不会在打包过程中反复输出“修改将使签名失效”的误导性警告。
    codesign --remove-signature "$target_path" >/dev/null 2>&1 || true

    local child_dep=""
    while IFS= read -r child_dep; do
      [[ "$child_dep" == /System/* || "$child_dep" == /usr/lib/* || "$child_dep" == @* ]] && continue
      if [[ ! -f "$child_dep" ]]; then
        echo "error: unresolved dependency $child_dep required by $source_path" >&2
        return 1
      fi
      copy_dependency "$child_dep"
      rewrite_dependency_path "$child_dep" "$(bundled_dependency_reference "$child_dep" "no")" "$target_path"
    done < <(otool -L "$target_path" | sed -E '1d; s/^[[:space:]]+//; s/ \(compatibility version.*$//')

    install_name_tool -id "$(bundled_dependency_reference "$source_path" "no")" "$target_path" 2>/dev/null || true
  }

  copy_dependency "$LIBMPV_SOURCE"

  local tool_source=""
  local tool_name=""
  for tool_name in ffmpeg ffprobe; do
    if [[ "$tool_name" == "ffmpeg" ]]; then
      tool_source="$FFMPEG_SOURCE"
    else
      tool_source="$FFPROBE_SOURCE"
    fi
    local tool_target="$APP_BUNDLE/Contents/MacOS/$tool_name"
    cp -L "$tool_source" "$tool_target"
    chmod u+w,a+x "$tool_target"
    codesign --remove-signature "$tool_target" >/dev/null 2>&1 || true

    local tool_dep=""
    while IFS= read -r tool_dep; do
      [[ "$tool_dep" == /System/* || "$tool_dep" == /usr/lib/* || "$tool_dep" == @* ]] && continue
      if [[ ! -f "$tool_dep" ]]; then
        echo "error: unresolved dependency $tool_dep required by $tool_name" >&2
        return 1
      fi
      copy_dependency "$tool_dep"
      rewrite_dependency_path "$tool_dep" "$(bundled_dependency_reference "$tool_dep" "yes")" "$tool_target"
    done < <(otool -L "$tool_target" | sed -E '1d; s/^[[:space:]]+//; s/ \(compatibility version.*$//')
  done
}

bundle_libmpv_runtime

PACKAGE_ARCHITECTURE="${MEDIALIB_PACKAGE_ARCHITECTURE:-$(uname -m)}"
"$ROOT_DIR/scripts/check_bundle_runtime.sh" "$APP_BUNDLE" "$PACKAGE_ARCHITECTURE"

cat > "$APP_BUNDLE/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>zh-Hans</string>
  <key>CFBundleExecutable</key>
  <string>$APP_NAME</string>
  <key>CFBundleIconFile</key>
  <string>AppIcon</string>
  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundleDisplayName</key>
  <string>$DISPLAY_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
  <!-- 相册「系统照片」来源：读取 macOS 系统「照片」App 图库需要的用途说明。 -->
  <key>NSPhotoLibraryUsageDescription</key>
  <string>MediaLIB 需要访问你的照片图库，以在「相册」中浏览系统照片与录像。</string>
  <!-- 声明可打开的媒体文档类型：作为「系统默认视频/音乐播放器」的前提，
       设置页的「设为默认」按钮按这些声明向 LaunchServices 注册。 -->
  <key>CFBundleDocumentTypes</key>
  <array>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Video File</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Default</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.movie</string>
        <string>public.video</string>
        <string>public.mpeg-4</string>
        <string>com.apple.quicktime-movie</string>
        <string>public.avi</string>
        <string>org.matroska.mkv</string>
        <string>public.mpeg</string>
        <string>public.mpeg-2-transport-stream</string>
        <string>org.webmproject.webm</string>
        <string>com.microsoft.windows-media-wmv</string>
      </array>
    </dict>
    <dict>
      <key>CFBundleTypeName</key>
      <string>Audio File</string>
      <key>CFBundleTypeRole</key>
      <string>Viewer</string>
      <key>LSHandlerRank</key>
      <string>Default</string>
      <key>LSItemContentTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.mp3</string>
        <string>public.mpeg-4-audio</string>
        <string>org.xiph.flac</string>
        <string>com.apple.m4a-audio</string>
        <string>public.aiff-audio</string>
        <string>com.microsoft.waveform-audio</string>
        <string>org.xiph.ogg</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
PLIST
/usr/bin/python3 "$RELEASE_METADATA_TOOL" --root "$ROOT_DIR" \
  --write-info-plist "$APP_BUNDLE/Contents/Info.plist"

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
chmod +x "$APP_BUNDLE/Contents/MacOS/$SERVER_NAME"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
strip_bundle_metadata "$APP_BUNDLE"

# 默认使用可离线严格验证的 ad-hoc 签名。自签名证书即使存在于钥匙串中，也可能
# 不具备受信任链或在无交互构建环境中无法解析，不能成为发布流程的默认依赖。
# 若已配置受信任的 Developer ID / Apple Development 身份，可显式传入其名称。
CODESIGN_IDENTITY="${MEDIALIB_CODESIGN_IDENTITY:--}"
if [[ "$CODESIGN_IDENTITY" == "-" ]]; then
  echo "codesign: 使用可严格验证的 ad-hoc 签名。"
else
  echo "codesign: 使用显式配置的签名身份「${CODESIGN_IDENTITY}」。"
fi
codesign --force --deep --sign "$CODESIGN_IDENTITY" "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"
"$ROOT_DIR/scripts/check_bundle_launch.sh" "$APP_BUNDLE"

# These hashes describe the signed binaries. Keep the inventory and manifest
# outside the sealed .app to avoid a signature/resource-hash cycle.
DEPENDENCY_INVENTORY="$DMG_ROOT/MediaLibDependencyInventory.txt"
BUILD_MANIFEST="$DMG_ROOT/MediaLibBuildManifest.json"
/usr/bin/python3 "$ROOT_DIR/scripts/check_dependency_inventory.py" \
  generate "$APP_BUNDLE" "$DEPENDENCY_INVENTORY"
DEPENDENCY_DIGEST="$(shasum -a 256 "$DEPENDENCY_INVENTORY" | awk '{print $1}')"
GIT_COMMIT="$(git -C "$ROOT_DIR" rev-parse --verify HEAD)"
if [[ -n "$(git -C "$ROOT_DIR" status --porcelain --untracked-files=normal)" ]]; then
  GIT_DIRTY="true"
else
  GIT_DIRTY="false"
fi
SWIFT_TOOLCHAIN_VERSION="$(swift --version | head -n 1)"
LIBMPV_VERSION="$(otool -L "$LIBMPV_SOURCE" | sed -n '2s/.*current version \([^)]*\)).*/ABI \1/p')"
if [[ -z "$LIBMPV_VERSION" ]]; then
  LIBMPV_VERSION="$(basename "$LIBMPV_SOURCE")"
fi
FFMPEG_VERSION="$("$FFMPEG_SOURCE" -version | awk 'NR == 1 {print $3}')"
FFPROBE_VERSION="$("$FFPROBE_SOURCE" -version | awk 'NR == 1 {print $3}')"
"$ROOT_DIR/scripts/generate_build_manifest.swift" \
  "$BUILD_MANIFEST" \
  "$VERSION" "$BUILD" "$GIT_COMMIT" "$GIT_DIRTY" "$PACKAGE_ARCHITECTURE" \
  "$SWIFT_TOOLCHAIN_VERSION" "$LIBMPV_VERSION" "$FFMPEG_VERSION" "$FFPROBE_VERSION" \
  "$DEPENDENCY_DIGEST"
/usr/bin/python3 "$ROOT_DIR/scripts/check_dependency_inventory.py" \
  verify "$APP_BUNDLE" "$DEPENDENCY_INVENTORY" "$BUILD_MANIFEST"

cp -R "$APP_BUNDLE" "$DMG_ROOT/$DISPLAY_NAME.app"
strip_bundle_metadata "$DMG_ROOT/$DISPLAY_NAME.app"
/usr/bin/python3 "$ROOT_DIR/scripts/check_dependency_inventory.py" \
  verify "$DMG_ROOT/$DISPLAY_NAME.app" "$DEPENDENCY_INVENTORY" "$BUILD_MANIFEST"
ln -s /Applications "$DMG_ROOT/Applications"
cp "$ROOT_DIR/Sources/MediaLib/Resources/AppIcon.icns" "$DMG_VOLUME_ICON"
swift "$ROOT_DIR/scripts/generate_dmg_background.swift" "$DMG_BACKGROUND"
strip_bundle_metadata "$DMG_ROOT"
DMG_SIZE_MB=$(du -sm "$DMG_ROOT" | awk '{print $1}')
DMG_SIZE_MB=$((DMG_SIZE_MB + 96))
run_hdiutil create "$DMG_RW_PATH" -volname "$DISPLAY_NAME" -size "${DMG_SIZE_MB}m" -fs HFS+ -ov
mkdir -p "$DMG_MOUNT"
hdiutil attach "$DMG_RW_PATH" -mountpoint "$DMG_MOUNT" -nobrowse -quiet
ditto --noextattr --noqtn "$DMG_ROOT/" "$DMG_MOUNT/"
python3 "$ROOT_DIR/scripts/write_dmg_ds_store.py" "$DMG_MOUNT"
SetFile -a V "$DMG_MOUNT/.background" 2>/dev/null || true
SetFile -a C "$DMG_MOUNT" 2>/dev/null || true
SetFile -a V "$DMG_MOUNT/.VolumeIcon.icns" 2>/dev/null || true
bless --folder "$DMG_MOUNT" --openfolder "$DMG_MOUNT" 2>/dev/null || true
sync
hdiutil detach "$DMG_MOUNT" -quiet
run_hdiutil convert "$DMG_RW_PATH" -format UDZO -imagekey zlib-level=9 -ov -o "$TEMP_DMG_PATH"
hdiutil verify "$TEMP_DMG_PATH"

# Release evidence must come from the immutable image, not the mutable staging
# bundle. Mount read-only and repeat runtime closure, manifest, plist and strict
# signature validation before the official artifact can be replaced.
mkdir -p "$VERIFY_MOUNT"
hdiutil attach "$TEMP_DMG_PATH" -mountpoint "$VERIFY_MOUNT" -nobrowse -readonly -quiet
MOUNTED_APP="$VERIFY_MOUNT/$DISPLAY_NAME.app"
"$ROOT_DIR/scripts/check_bundle_runtime.sh" "$MOUNTED_APP" "$PACKAGE_ARCHITECTURE"
plutil -lint "$MOUNTED_APP/Contents/Info.plist"
/usr/bin/python3 "$ROOT_DIR/scripts/check_dependency_inventory.py" \
  verify "$MOUNTED_APP" \
  "$VERIFY_MOUNT/MediaLibDependencyInventory.txt" \
  "$VERIFY_MOUNT/MediaLibBuildManifest.json"
codesign --verify --deep --strict "$MOUNTED_APP"
"$ROOT_DIR/scripts/check_bundle_launch.sh" "$MOUNTED_APP"
hdiutil detach "$VERIFY_MOUNT" -quiet

# Keep the last known-good public DMG until every validation above succeeds.
# The candidate is copied onto dist's filesystem and renamed over the public
# path so the final replacement is atomic for readers of dist/MediaLib.dmg.
"$ROOT_DIR/scripts/publish_verified_dmg.sh" "$TEMP_DMG_PATH" "$CANDIDATE_DMG_PATH" "$DMG_PATH"
# The signed application is delivered only inside the verified DMG. A loose
# .app copied to the workspace can acquire Finder metadata asynchronously,
# which makes it unverifiable after the fact and creates a misleading second
# distribution artifact. Keep dist deterministic and leave no stale copy.
rm -rf "$APP_COPY" "$LEGACY_APP_COPY"

echo "APP=$APP_BUNDLE"
echo "DMG=$DMG_PATH"
