#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="MediaLib"
DISPLAY_NAME="MediaLIB"
BUNDLE_ID="com.local.MediaLib"
VERSION="1.1.1"
BUILD="3"
DIST_DIR="$ROOT_DIR/dist"
BUILD_ROOT="/private/tmp/MediaLib-package"
APP_BUNDLE="$BUILD_ROOT/$DISPLAY_NAME.app"
APP_COPY="$DIST_DIR/$DISPLAY_NAME.app"
LEGACY_APP_COPY="$DIST_DIR/$APP_NAME.app"
DMG_ROOT="$BUILD_ROOT/dmg-root"
DMG_PATH="$DIST_DIR/$APP_NAME.dmg"

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

if [[ -d "/Applications/Xcode.app/Contents/Developer" ]]; then
  export DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
fi

cd "$ROOT_DIR"

swift scripts/generate_icon.swift

swift build -c release --product "$APP_NAME"

rm -rf "$BUILD_ROOT" "$APP_COPY" "$LEGACY_APP_COPY" "$DMG_PATH"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$DMG_ROOT"

cp "$ROOT_DIR/.build/release/$APP_NAME" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
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
      echo "warning: failed to rewrite dependency $old_path in $target_binary" >&2
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

    if [[ -f "$target_path" ]]; then
      return 0
    fi

    if [[ -n "$framework_path" ]]; then
      cp -R "$framework_path" "$frameworks_dir/$base_name"
      chmod -R u+w "$frameworks_dir/$base_name"
      find "$frameworks_dir/$base_name/Versions" -name site-packages -type l -exec rm {} \; 2>/dev/null || true
      slim_framework_copy "$frameworks_dir/$base_name"
    else
      cp -L "$source_path" "$target_path"
      chmod u+w "$target_path"
    fi

    local child_dep=""
    while IFS= read -r child_dep; do
      [[ "$child_dep" == /System/* || "$child_dep" == /usr/lib/* || "$child_dep" == @* ]] && continue
      [[ -f "$child_dep" ]] || continue
      copy_dependency "$child_dep"
      rewrite_dependency_path "$child_dep" "$(bundled_dependency_reference "$child_dep" "no")" "$target_path"
    done < <(otool -L "$target_path" | awk 'NR > 1 {print $1}')

    install_name_tool -id "$(bundled_dependency_reference "$source_path" "no")" "$target_path" 2>/dev/null || true
  }

  local libmpv_source=""
  if [[ -f "/opt/homebrew/lib/libmpv.2.dylib" ]]; then
    libmpv_source="/opt/homebrew/lib/libmpv.2.dylib"
  elif [[ -f "/usr/local/lib/libmpv.2.dylib" ]]; then
    libmpv_source="/usr/local/lib/libmpv.2.dylib"
  elif [[ -f "/opt/homebrew/lib/libmpv.dylib" ]]; then
    libmpv_source="/opt/homebrew/lib/libmpv.dylib"
  elif [[ -f "/usr/local/lib/libmpv.dylib" ]]; then
    libmpv_source="/usr/local/lib/libmpv.dylib"
  fi

  if [[ -n "$libmpv_source" ]]; then
    copy_dependency "$libmpv_source"
  else
    echo "warning: libmpv was not found; embedded liquid-glass player will require libmpv on the target Mac." >&2
  fi

  local ffmpeg_source=""
  if [[ -x "/opt/homebrew/bin/ffmpeg" ]]; then
    ffmpeg_source="/opt/homebrew/bin/ffmpeg"
  elif [[ -x "/usr/local/bin/ffmpeg" ]]; then
    ffmpeg_source="/usr/local/bin/ffmpeg"
  fi

  if [[ -n "$ffmpeg_source" ]]; then
    local ffmpeg_target="$APP_BUNDLE/Contents/MacOS/ffmpeg"
    cp -L "$ffmpeg_source" "$ffmpeg_target"
    chmod u+w,a+x "$ffmpeg_target"

    local ffmpeg_dep=""
    while IFS= read -r ffmpeg_dep; do
      [[ "$ffmpeg_dep" == /System/* || "$ffmpeg_dep" == /usr/lib/* || "$ffmpeg_dep" == @* ]] && continue
      [[ -f "$ffmpeg_dep" ]] || continue
      copy_dependency "$ffmpeg_dep"
      rewrite_dependency_path "$ffmpeg_dep" "$(bundled_dependency_reference "$ffmpeg_dep" "yes")" "$ffmpeg_target"
    done < <(otool -L "$ffmpeg_target" | awk 'NR > 1 {print $1}')
  else
    echo "warning: ffmpeg was not found; MKV video-frame artwork fallback will use system ffmpeg only if available on the target Mac." >&2
  fi
}

bundle_libmpv_runtime

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
  <key>CFBundleShortVersionString</key>
  <string>$VERSION</string>
  <key>CFBundleVersion</key>
  <string>$BUILD</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>LSApplicationCategoryType</key>
  <string>public.app-category.video</string>
  <key>NSHighResolutionCapable</key>
  <true/>
  <key>NSPrincipalClass</key>
  <string>NSApplication</string>
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

chmod +x "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
plutil -lint "$APP_BUNDLE/Contents/Info.plist"
strip_bundle_metadata "$APP_BUNDLE"
codesign --force --deep --sign - "$APP_BUNDLE" >/dev/null
codesign --verify --deep --strict "$APP_BUNDLE"

cp -R "$APP_BUNDLE" "$DMG_ROOT/$DISPLAY_NAME.app"
strip_bundle_metadata "$DMG_ROOT/$DISPLAY_NAME.app"
ln -s /Applications "$DMG_ROOT/Applications"
hdiutil create -volname "$DISPLAY_NAME" -srcfolder "$DMG_ROOT" -ov -format UDZO "$DMG_PATH"
hdiutil verify "$DMG_PATH"
if ditto --noextattr --noqtn "$APP_BUNDLE" "$APP_COPY"; then
  strip_bundle_metadata "$APP_COPY"
  if ! codesign --verify --deep --strict "$APP_COPY"; then
    echo "warning: APP_COPY strict codesign verification was blocked by filesystem-managed extended attributes; verified source bundle at $APP_BUNDLE instead." >&2
  fi
else
  echo "warning: APP_COPY refresh failed; verified DMG and source bundle remain available." >&2
fi

echo "APP=$APP_BUNDLE"
echo "APP_COPY=$APP_COPY"
echo "DMG=$DMG_PATH"
