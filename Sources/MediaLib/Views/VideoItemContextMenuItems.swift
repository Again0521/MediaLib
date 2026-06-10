import MediaLibCore
import SwiftUI

struct VideoItemContextMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    var showsDeletePlaybackHistory = false
    var currentManualCollectionID: String?

    var body: some View {
        if item.type != .episode {
            Button {
                appState.play(item)
            } label: {
                Label("播放", systemImage: "play.fill")
            }
            .disabled(item.filePath == nil && appState.children(for: item).isEmpty)
        }

        VideoCacheMenuItems(item: item)
        VideoManualCollectionMenuItems(items: [item], currentCollectionID: currentManualCollectionID)

        if item.type == .music, item.filePath != nil {
            Button {
                appState.startRadio(seed: item)
            } label: {
                Label("开始电台", systemImage: "dot.radiowaves.left.and.right")
            }
        }

        if let deletionTarget = playbackHistoryDeletionTarget {
            Button(role: .destructive) {
                appState.clearPlaybackHistory(deletionTarget)
            } label: {
                Label(
                    deletionTarget.id == item.id ? "删除播放记录" : "删除本系列播放记录",
                    systemImage: "clock.badge.xmark"
                )
            }
        }

        markWatchedMenuItems

        Button {
            appState.toggleWatchlist(item)
        } label: {
            Label(item.watchlist ? "移出想看" : "加入想看", systemImage: item.watchlist ? "bookmark.slash" : "bookmark")
        }

        Button {
            appState.toggleFavorite(item)
        } label: {
            Label(item.favorite ? "取消喜欢" : "喜欢", systemImage: item.favorite ? "heart.slash" : "heart")
        }

        if item.metadataProvider != "Emby" {
            Menu {
                ForEach(Self.reclassificationTypes, id: \.self) { type in
                    Button {
                        appState.reclassify(item, as: type)
                    } label: {
                        Label(type.displayName, systemImage: type.systemImage)
                    }
                }
            } label: {
                Label("重新分类", systemImage: "tray.and.arrow.down")
            }
        }

        Menu {
            Button {
                appState.updateRating(item, rating: nil)
            } label: {
                Label("清除评级", systemImage: "star.slash")
            }
            Divider()
            ForEach(1...5, id: \.self) { rating in
                Button {
                    appState.updateRating(item, rating: Double(rating))
                } label: {
                    Label(String(repeating: "★", count: rating), systemImage: rating >= 4 ? "star.fill" : "star")
                }
            }
        } label: {
            Label("评级", systemImage: "star")
        }
    }

    @ViewBuilder
    private var markWatchedMenuItems: some View {
        let episodes = appState.children(for: item)
        if episodes.isEmpty {
            if item.watched {
                Button {
                    appState.markWatched(item, watched: false)
                } label: {
                    Label("清除已观看", systemImage: "eye.slash")
                }
            } else {
                Button {
                    appState.markWatched(item, watched: true)
                } label: {
                    Label("标记为已观看", systemImage: "eye")
                }
            }
        } else {
            let watchedThreshold = appState.settings.watchedThreshold
            let hasWatchedMark = item.watched || episodes.contains { $0.watched || $0.playProgress >= watchedThreshold }
            Button {
                appState.markAllWatched(episodes + [item], watched: true)
            } label: {
                Label("标记整个系列为已观看", systemImage: "eye.fill")
            }
            if hasWatchedMark {
                Button {
                    appState.markAllWatched(episodes + [item], watched: false)
                } label: {
                    Label("清除已观看", systemImage: "eye.slash")
                }
            }
        }
    }

    private var playbackHistoryDeletionTarget: MediaItem? {
        guard showsDeletePlaybackHistory else { return nil }
        if item.hasPlaybackTrace {
            return item
        }
        guard item.type == .episode,
              let parentID = item.parentID,
              let parent = appState.items.first(where: { $0.id == parentID }) else {
            return nil
        }
        let hasSeriesTrace = parent.hasPlaybackTrace || appState.children(for: parent).contains(where: \.hasPlaybackTrace)
        return hasSeriesTrace ? parent : nil
    }

    private static var reclassificationTypes: [MediaType] {
        [.movie, .tvShow, .anime, .documentary, .variety, .music, .other, .privateCollection]
    }
}
