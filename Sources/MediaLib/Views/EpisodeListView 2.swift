import MediaLibCore
import SwiftUI

// 剧集列表由 DetailView 的原生 List 直接承载并逐行回收，避免超长列表常驻视图。
// 此文件现仅保留单行视图 EpisodeRowView 供 List 行复用。

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
                        Text(episode.metadataProvider == "Emby" ? "Emby 流媒体" : "远程资源")
                    }
                    if cached {
                        Text("已缓存")
                            .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)

                // 单集简介：让剧集列表本身就承载“详情”，无需逐集点开。
                if let overview = episode.overview?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !overview.isEmpty {
                    Text(overview)
                        .font(.caption)
                        .foregroundStyle(.secondary.opacity(0.85))
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer()

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
        }
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
