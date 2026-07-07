import Combine
import Foundation
import MediaLibCore

/// 媒体库主体状态容器。
///
/// 只拥有来源、条目和库内容相关 revision；数据库 reload 编排、扫描、健康检查、缓存维护、
/// 远程同步和派生缓存重建仍留在 AppState 过渡层，避免这个 Store 演化成新的库管理 god object。
@MainActor
final class LibraryDomainStore: ObservableObject {
    private(set) var sources: [MediaSource] = []
    private(set) var items: [MediaItem] = []
    private(set) var libraryRevision = 0
    private(set) var posterRevision = 0
    private(set) var favoriteRevision = 0
    private(set) var watchlistRevision = 0
    private(set) var ratingRevision = 0
    private(set) var videoCacheRevision = 0
    private(set) var musicProjectionRevision = 0
    private(set) var musicContentRevision = 0

    func replaceLibrary(sources: [MediaSource], items: [MediaItem]) {
        publish {
            self.sources = sources
            self.items = items
        }
    }

    func replaceSources(_ sources: [MediaSource]) {
        publish { self.sources = sources }
    }

    func replaceItems(_ items: [MediaItem]) {
        publish { self.items = items }
    }

    func setLibraryRevision(_ revision: Int) {
        publish { libraryRevision = revision }
    }

    func setPosterRevision(_ revision: Int) {
        publish { posterRevision = revision }
    }

    func setFavoriteRevision(_ revision: Int) {
        publish { favoriteRevision = revision }
    }

    func setWatchlistRevision(_ revision: Int) {
        publish { watchlistRevision = revision }
    }

    func setRatingRevision(_ revision: Int) {
        publish { ratingRevision = revision }
    }

    func setVideoCacheRevision(_ revision: Int) {
        publish { videoCacheRevision = revision }
    }

    func setMusicProjectionRevision(_ revision: Int) {
        publish { musicProjectionRevision = revision }
    }

    func setMusicContentRevision(_ revision: Int) {
        publish { musicContentRevision = revision }
    }

    func bumpLibraryRevision() {
        setLibraryRevision(libraryRevision + 1)
    }

    func bumpPosterRevision() {
        setPosterRevision(posterRevision + 1)
    }

    func bumpFavoriteRevision() {
        setFavoriteRevision(favoriteRevision + 1)
    }

    func bumpWatchlistRevision() {
        setWatchlistRevision(watchlistRevision + 1)
    }

    func bumpRatingRevision() {
        setRatingRevision(ratingRevision + 1)
    }

    func bumpVideoCacheRevision() {
        setVideoCacheRevision(videoCacheRevision + 1)
    }

    func bumpMusicProjectionRevision() {
        setMusicProjectionRevision(musicProjectionRevision + 1)
    }

    func bumpMusicContentRevision() {
        setMusicContentRevision(musicContentRevision + 1)
    }

    private func publish(_ mutation: () -> Void) {
        objectWillChange.send()
        mutation()
    }
}
