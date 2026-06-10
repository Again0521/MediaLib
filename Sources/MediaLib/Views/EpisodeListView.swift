import MediaLibCore
import SwiftUI

// 剧集列表由 DetailView 的原生 List 直接承载并逐行回收，避免超长列表常驻视图。
// 此文件现仅保留单行视图 EpisodeRowView 供 List 行复用。

struct EpisodeRowView: View {
    @EnvironmentObject private var appState: AppState
    let episode: MediaItem
    let selected: Bool

    var body: some View {
        let cached = appState.isVideoCached(episode)
        HStack(spacing: 14) {
            PosterImage(path: episode.posterPath, title: episode.episodeLabel, mediaType: episode.type)
                .frame(width: 120, height: 68)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .pointerInspectTilt(enabled: true, cornerRadius: 6)

            VStack(alignment: .leading, spacing: 6) {
                Text("\(episode.episodeLabel)  \(episode.title)")
                    .font(.headline)
                    .lineLimit(1)
                HStack(spacing: 10) {
                    if let duration = episode.duration, duration > 0 {
                        Text(durationText(duration))
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
            }

            Spacer()

            Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(selected ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
        }
        .padding(10)
        .staticSurfaceBackground(selected: selected, thickness: selected ? 1.36 : 1.18)
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
    }

    private func durationText(_ duration: Double) -> String {
        let total = Int(duration)
        return "\(total / 60) 分钟"
    }
}
