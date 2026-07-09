import MediaLibCore
import SwiftUI

// 剧集列表由 DetailView 的 ScrollView + LazyVStack 承载（原生 List/NSTableView 快速滚动到底会
// 抽搐，已改用与本项目其它长列表一致的方案）；此文件仅保留单行视图 EpisodeRowView 供逐行复用。

struct EpisodeRowView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let episode: MediaItem
    let selected: Bool
    @State private var isHovering = false

    var body: some View {
        let cached = appState.isVideoCached(episode)
        let threshold = appState.settings.watchedThreshold
        let isWatched = episode.watched || episode.playProgress >= threshold
        // 半途观看：有进度但还没看完，给出进度条与“剩余”提示。
        let inProgress = !isWatched && episode.playProgress > 0.015
        let active = selected || (isHovering && !suppressHoverDuringScroll)
        HStack(spacing: 14) {
            episodeThumbnail(isWatched: isWatched, inProgress: inProgress)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    Text("\(episode.episodeLabel)  \(episode.title)")
                        .font(.headline)
                        .lineLimit(1)
                        // 已看的集标题降一档不透明度，让“未看”的集在长列表里更显眼。
                        .opacity(isWatched ? 0.7 : 1)
                    if inProgress {
                        Text("继续观看")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(AppColors.selectedGlassTint.opacity(0.95))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(AppColors.selectedGlassTint.opacity(0.14), in: Capsule())
                    }
                }
                HStack(spacing: 10) {
                    if let duration = episode.duration, duration > 0 {
                        Text(durationText(duration))
                    }
                    if inProgress, let remaining = remainingText {
                        Text(remaining)
                            .foregroundStyle(AppColors.selectedGlassTint.opacity(0.9))
                    }
                    if let resolution = episode.resolution {
                        Text(resolution)
                    }
                    if episode.filePath == nil {
                        Text("路径未记录")
                            .foregroundStyle(.orange)
                    } else if episode.isRemoteResource {
                        // 用实际提供方名（Emby / Jellyfin / Plex）标注流媒体来源，而非只认 Emby。
                        if EmbyService.isMediaServerSourcePath(episode.sourcePath), let provider = episode.metadataProvider, !provider.isEmpty {
                            Text("\(provider) 流媒体")
                        } else {
                            Text("远程资源")
                        }
                    }
                    if cached {
                        Text("已缓存")
                            .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // 单集简介：让剧集列表本身就承载“详情”，无需逐集点开。
                // ★行高统一：简介是否存在（以及存在时 1 行还是 2 行）曾让每行的实际高度各不相同。
                // ScrollView+LazyVStack 靠"预估高度→滚到时再量出真实高度"来排布，一旦真实高度和
                // 预估的不一样，就要在滚动中途纠正内容总高度——正是"划到底再用力上滑，滚动条一伸
                // 一缩、画面跳一下、看起来漏掉一截"的根因（越往下滚，累积误差越大，越容易在快速滑动
                // 时暴露）。用一个不可见的两行占位文字撑出固定高度（ZStack 叠放，占位只决定尺寸不
                // 参与绘制），真正的简介（0/1/2 行、或没有）盖在上面——每一行的高度就完全一致了，
                // 不依赖任何猜出来的像素数字，字号变化（如动态字体）也能一起适配。
                ZStack(alignment: .topLeading) {
                    // 占位必须撑满整行宽度（不能只按占位字符本身的窄宽度算），
                    // 否则真正的简介文字会被这个占位的宽度提前挤到只剩两三个字就换行。
                    Text("占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位占位")
                        .font(.caption)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .hidden()
                    if let overviewText {
                        Text(overviewText)
                            .font(.caption)
                            .foregroundStyle(.secondary.opacity(0.85))
                            .lineLimit(2)
                    }
                }
            }

            Spacer()

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
        }
        // List 行以前会自动拉伸到整行宽度；换成 LazyVStack 后需要显式撑满，
        // 否则右侧 Spacer 撑不到真正的行尾，选中态描边/底色也只会包住内容本身的宽度。
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .appInteractiveSurface(
            active: active,
            selected: selected,
            cornerRadius: AppRadius.control,
            tint: AppColors.pointerLightTint,
            intensity: selected ? 0.86 : 0.62,
            scale: 1.002,
            lift: 1,
            castsHoverShadow: false
        )
        .overlay(alignment: .leading) {
            if selected {
                Capsule()
                    .fill(AppColors.selectedGlassTint.opacity(0.82))
                    .frame(width: 4)
                    .padding(.vertical, 12)
                    .padding(.leading, 3)
            }
        }
        .overlay {
            if selected {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(AppColors.selectedGlassTint.opacity(0.08))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(
                    selected ? AppColors.selectedGlassTint.opacity(0.42) : Color.clear,
                    lineWidth: selected ? 1.2 : 0
                )
        }
        .onHover { hovering in
            isHovering = hovering && !suppressHoverDuringScroll
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { isHovering = false }
        }
    }

    /// 缩略图：在 120×68 的封面上叠加观看状态——已看打勾+轻微压暗，半途看显示底部进度条。
    @ViewBuilder
    private func episodeThumbnail(isWatched: Bool, inProgress: Bool) -> some View {
        let shape = RoundedRectangle(cornerRadius: 6, style: .continuous)
        PosterImage(path: episode.posterPath, title: episode.episodeLabel, mediaType: episode.type)
            .frame(width: 120, height: 68)
            .overlay {
                // 已看：盖一层轻压暗，弱化已消费内容。
                if isWatched {
                    shape.fill(Color.black.opacity(0.32))
                }
            }
            .overlay(alignment: .bottom) {
                // 半途观看：底部一条主题色进度条，直观体现“看到哪”。
                if inProgress {
                    GeometryReader { proxy in
                        ZStack(alignment: .leading) {
                            Rectangle()
                                .fill(Color.black.opacity(0.42))
                            Rectangle()
                                .fill(AppColors.selectedGlassTint)
                                .frame(width: proxy.size.width * CGFloat(min(max(episode.playProgress, 0), 1)))
                        }
                    }
                    .frame(height: 4)
                }
            }
            .overlay(alignment: .topTrailing) {
                // 已看角标：与海报墙一致的勾选语义。
                if isWatched {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 17, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, AppColors.selectedGlassTint)
                        .padding(5)
                        .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                }
            }
            .clipShape(shape)
            .overlay {
                shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.7)
            }
            .pointerInspectTilt(enabled: true, cornerRadius: 6)
    }

    private var overviewText: String? {
        guard let overview = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines), !overview.isEmpty else {
            return nil
        }
        return overview
    }

    /// “剩余 xx 分钟”：基于时长与已播进度估算，给半途观看的集一个明确预期。
    private var remainingText: String? {
        guard let duration = episode.duration, duration > 0 else { return nil }
        let remaining = duration * (1 - min(max(episode.playProgress, 0), 1))
        let minutes = Int((remaining / 60).rounded())
        guard minutes >= 1 else { return "即将看完" }
        return "剩余 \(minutes) 分钟"
    }

    private func durationText(_ duration: Double) -> String {
        let total = Int(duration)
        return "\(total / 60) 分钟"
    }
}
