import MediaLibCore
import SwiftUI

// P1：原 EpisodeListView 容器（VStack + LazyVStack + 包裹卡片）已被移除。
// 剧集列表改由 DetailView 的原生 List 直接承载、逐行回收（见 DetailView.body）。
// 此文件现仅保留单行视图 EpisodeRowView 供 List 行复用。

struct EpisodeRowView: View {
    let episode: MediaItem
    let selected: Bool

    var body: some View {
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
                        Text("没有文件路径")
                            .foregroundStyle(.orange)
                    } else if episode.isRemoteResource {
                        Text(episode.metadataProvider == "Emby" ? "Emby 流媒体" : "远程资源")
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
        .staticSurfaceBackground(selected: selected)
    }

    private func durationText(_ duration: Double) -> String {
        let total = Int(duration)
        return "\(total / 60) 分钟"
    }
}
