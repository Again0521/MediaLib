import MediaLibCore
import SwiftUI

struct VideoCacheMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem

    var body: some View {
        let choices = appState.videoCacheQualityChoices(for: item)
        let hasCachedVideo = appState.includesCachedVideo(item)
        if choices.count > 1 {
            Menu {
                ForEach(choices) { choice in
                    Button {
                        appState.cacheVideo(item, qualityID: choice.id)
                    } label: {
                        Label("\(choice.label) · \(choice.detail)", systemImage: choice.id == "original" ? "sparkles.tv" : "rectangle.compress.vertical")
                    }
                }
            } label: {
                Label(hasCachedVideo ? "重新缓存到本地" : "缓存到本地", systemImage: "arrow.down.circle")
            }
        } else if let choice = choices.first {
            Button {
                appState.cacheVideo(item, qualityID: choice.id)
            } label: {
                Label(hasCachedVideo ? "重新缓存到本地" : "缓存到本地", systemImage: "arrow.down.circle")
            }
        }

        if hasCachedVideo {
            Button(role: .destructive) {
                appState.deleteVideoCache(item)
            } label: {
                Label("删除缓存文件", systemImage: "trash")
            }
        }
    }
}
