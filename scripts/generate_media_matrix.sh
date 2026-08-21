#!/bin/bash
# 生成 P0 的固定媒体样本矩阵。
#
# 存在的理由：性能基线必须跑在**同一批**样本上，否则两次测量之间的差异分不清
# 是代码变了还是素材变了。这里的每个样本都由确定性合成源（testsrc2 + sine）
# 生成，不含任何用户媒体，可随时重建且逐字节可复现。
#
# 样本刻意做得很短（4 秒；4K HDR 2 秒），因为被测的是容器解析、首帧、seek 与
# Range 行为，不是长片解码吞吐。
#
#   scripts/generate_media_matrix.sh <输出目录>
#
# 输出目录必须在系统临时目录内：这些是验收夹具，不能落进用户资料库。

set -euo pipefail

OUTPUT_DIR="${1:-}"
if [ -z "$OUTPUT_DIR" ]; then
  echo "用法: scripts/generate_media_matrix.sh <输出目录>" >&2
  exit 2
fi
case "$OUTPUT_DIR" in
  /tmp/*|/private/tmp/*|/var/folders/*|/private/var/folders/*) ;;
  *)
    echo "error: 媒体矩阵只能写入系统临时目录，收到：$OUTPUT_DIR" >&2
    exit 2
    ;;
esac

command -v ffmpeg >/dev/null 2>&1 || { echo "error: 需要 ffmpeg" >&2; exit 2; }

mkdir -p "$OUTPUT_DIR"

DURATION=4
SMALL_SIZE=640x360
UHD_SIZE=3840x2160

# 合成源固定随机种子与帧率，保证重复运行产出同一批样本。
video_source() {
  local size="$1" duration="$2"
  echo "-f lavfi -i testsrc2=size=${size}:rate=24:duration=${duration}"
}
audio_source() {
  local duration="$1"
  echo "-f lavfi -i sine=frequency=440:sample_rate=48000:duration=${duration}"
}

render() {
  local name="$1"; shift
  local target="$OUTPUT_DIR/$name"
  if [ -f "$target" ]; then
    echo "  跳过（已存在）: $name"
    return
  fi
  echo "  生成: $name"
  # shellcheck disable=SC2086
  ffmpeg -hide_banner -loglevel error -y "$@" "$target"
}

echo "生成媒体样本矩阵 → $OUTPUT_DIR"

# 1. MP4 H.264/AAC —— 浏览器直放的基准样本，所有目标浏览器都应原生解码。
render "matrix-01-h264-aac.mp4" \
  $(video_source "$SMALL_SIZE" "$DURATION") $(audio_source "$DURATION") \
  -c:v libx264 -preset veryfast -pix_fmt yuv420p -c:a aac -b:a 128k -movflags +faststart

# 2. MP4 HEVC/AAC —— Safari 原生支持，Chromium 视平台而定，用来区分"容器可读"
#    与"编码可解"。`hvc1` tag 是 Apple 平台识别 HEVC 的必要条件。
render "matrix-02-hevc-aac.mp4" \
  $(video_source "$SMALL_SIZE" "$DURATION") $(audio_source "$DURATION") \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 -c:a aac -b:a 128k -movflags +faststart

# 3. MKV HEVC/AAC —— 容器是主要变量：HTMLMediaElement 不支持 Matroska，
#    这个样本的预期结果就是"直放失败且原因可解释"，不是"想办法让它能播"。
render "matrix-03-hevc-aac.mkv" \
  $(video_source "$SMALL_SIZE" "$DURATION") $(audio_source "$DURATION") \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -c:a aac -b:a 128k

# 4. MKV HEVC/TrueHD —— 容器与音频都不被浏览器支持，是四级策略里最需要
#    "仅转音频"的那一类；当前只用来确认失败是显式的。
render "matrix-04-hevc-truehd.mkv" \
  $(video_source "$SMALL_SIZE" "$DURATION") $(audio_source "$DURATION") \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p -c:a truehd -ac 2 -strict -2

# 5. WebM VP9/Opus —— Chromium 原生，Safari 支持有限，用来验证按浏览器能力
#    而不是按扩展名做判断。
render "matrix-05-vp9-opus.webm" \
  $(video_source "$SMALL_SIZE" "$DURATION") $(audio_source "$DURATION") \
  -c:v libvpx-vp9 -b:v 300k -speed 8 -pix_fmt yuv420p -c:a libopus -b:a 96k

# 6. 4K HDR HEVC —— 分辨率与 HDR 元数据同时变化，用来观察首帧与 seek 的
#    Range 行为在大帧上的差异。时长压到 2 秒以免夹具体积失控。
render "matrix-06-4k-hdr-hevc.mp4" \
  $(video_source "$UHD_SIZE" 2) $(audio_source 2) \
  -c:v libx265 -preset ultrafast -pix_fmt yuv420p10le -tag:v hvc1 \
  -color_primaries bt2020 -color_trc smpte2084 -colorspace bt2020nc \
  -x265-params "colorprim=bt2020:transfer=smpte2084:colormatrix=bt2020nc" \
  -c:a aac -b:a 128k -movflags +faststart

# 7. 外挂字幕样本 —— 与 01 同名的 WebVTT sidecar，覆盖"字幕不得抢占首帧"这条
#    时序约束的可观察面。
VTT_TARGET="$OUTPUT_DIR/matrix-01-h264-aac.vtt"
if [ ! -f "$VTT_TARGET" ]; then
  echo "  生成: matrix-01-h264-aac.vtt"
  cat > "$VTT_TARGET" <<'VTT'
WEBVTT

00:00:00.500 --> 00:00:02.000
外挂字幕样本第一行

00:00:02.000 --> 00:00:03.500
外挂字幕样本第二行
VTT
fi

echo
echo "样本矩阵："
for file in "$OUTPUT_DIR"/matrix-*; do
  size=$(stat -f%z "$file")
  printf '  %-32s %10d bytes\n' "$(basename "$file")" "$size"
done
