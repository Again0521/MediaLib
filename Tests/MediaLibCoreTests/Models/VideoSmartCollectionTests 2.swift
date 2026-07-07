import XCTest
@testable import MediaLibCore

// 智能视频集合规则求值回归测试（真实功能逻辑，此前零覆盖）：VideoSmartCollection.matches 决定一个条目
// 是否归入某智能集合——范围/状态/年份/评分/题材/来源 + 全部/任一 匹配模式。锁定当前求值语义。
final class VideoSmartCollectionTests: XCTestCase {
    private func item(
        type: MediaType = .movie,
        year: Int? = nil,
        favorite: Bool = false,
        watchlist: Bool = false,
        watched: Bool = false,
        playProgress: Double = 0,
        sourcePath: String? = nil,
        metadataProvider: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: UUID().uuidString, type: type, title: "t",
            year: year,
            sourcePath: sourcePath,
            playProgress: playProgress,
            watched: watched, favorite: favorite, watchlist: watchlist,
            metadataProvider: metadataProvider
        )
    }

    // MARK: - 媒体范围 includes

    func testScopeAllIncludesVideoTypesExcludesMusicEpisodePrivate() {
        let scope = VideoSmartCollectionMediaScope.all
        for t: MediaType in [.movie, .tvShow, .anime, .documentary, .variety, .homeVideo, .other] {
            XCTAssertTrue(scope.includes(t), "\(t) 应在 .all 范围内")
        }
        for t: MediaType in [.music, .episode, .privateCollection] {
            XCTAssertFalse(scope.includes(t), "\(t) 不应在 .all 范围内")
        }
    }

    func testNarrowScopesMatchOnlyTheirType() {
        XCTAssertTrue(VideoSmartCollectionMediaScope.movies.includes(.movie))
        XCTAssertFalse(VideoSmartCollectionMediaScope.movies.includes(.tvShow))
        XCTAssertTrue(VideoSmartCollectionMediaScope.tvShows.includes(.tvShow))
        XCTAssertFalse(VideoSmartCollectionMediaScope.tvShows.includes(.movie))
    }

    // MARK: - 默认集合（无任何条件）

    func testDefaultCollectionMatchesAnyInScopeItem() {
        let collection = VideoSmartCollection(name: "全部视频")
        XCTAssertTrue(collection.matches(item(type: .movie), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(type: .music), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(type: .episode), watchedThreshold: 0.9))
    }

    // MARK: - 状态过滤

    func testFavoritesStateFilter() {
        let collection = VideoSmartCollection(name: "喜欢", stateFilter: .favorites)
        XCTAssertTrue(collection.matches(item(favorite: true), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(favorite: false), watchedThreshold: 0.9))
    }

    func testWatchlistStateFilter() {
        let collection = VideoSmartCollection(name: "想看", stateFilter: .watchlist)
        XCTAssertTrue(collection.matches(item(watchlist: true), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(watchlist: false), watchedThreshold: 0.9))
    }

    func testWatchedStateFilterByFlagOrProgressThreshold() {
        let collection = VideoSmartCollection(name: "已观看", stateFilter: .watched)
        XCTAssertTrue(collection.matches(item(watched: true), watchedThreshold: 0.9))
        XCTAssertTrue(collection.matches(item(playProgress: 0.95), watchedThreshold: 0.9))   // 进度达阈值
        XCTAssertFalse(collection.matches(item(watched: false, playProgress: 0.5), watchedThreshold: 0.9))
    }

    func testUnwatchedStateFilter() {
        let collection = VideoSmartCollection(name: "未观看", stateFilter: .unwatched)
        XCTAssertTrue(collection.matches(item(watched: false, playProgress: 0.1), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(watched: true), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(playProgress: 0.95), watchedThreshold: 0.9))
    }

    // MARK: - 年份规则

    func testYearRuleSince2020() {
        let collection = VideoSmartCollection(name: "新片", rules: VideoSmartCollectionRules(year: .since2020))
        XCTAssertTrue(collection.matches(item(year: 2021), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(year: 2019), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(year: nil), watchedThreshold: 0.9))   // 无年份不满足具体年份规则
    }

    // MARK: - 匹配模式 全部 / 任一

    func testMatchModeAllRequiresEveryCondition() {
        let collection = VideoSmartCollection(
            name: "喜欢且新", stateFilter: .favorites,
            rules: VideoSmartCollectionRules(matchMode: .all, year: .since2020)
        )
        XCTAssertTrue(collection.matches(item(year: 2021, favorite: true), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(year: 2019, favorite: true), watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(item(year: 2021, favorite: false), watchedThreshold: 0.9))
    }

    func testMatchModeAnyNeedsOneCondition() {
        let collection = VideoSmartCollection(
            name: "喜欢或新", stateFilter: .favorites,
            rules: VideoSmartCollectionRules(matchMode: .any, year: .since2020)
        )
        XCTAssertTrue(collection.matches(item(year: 2021, favorite: false), watchedThreshold: 0.9))   // 仅年份
        XCTAssertTrue(collection.matches(item(year: 2019, favorite: true), watchedThreshold: 0.9))    // 仅喜欢
        XCTAssertFalse(collection.matches(item(year: 2019, favorite: false), watchedThreshold: 0.9))  // 都不满足
    }

    func testSourceRuleClassifiesRemoteSourcePathsCaseInsensitively() {
        let remoteCollection = VideoSmartCollection(
            name: "远程",
            rules: VideoSmartCollectionRules(source: .emby)
        )
        let localCollection = VideoSmartCollection(
            name: "本地",
            rules: VideoSmartCollectionRules(source: .local)
        )
        let mixedCaseRemote = item(sourcePath: "Jellyfin://Server/Library/Item")
        let providerRemote = item(metadataProvider: "PLEX")
        let local = item(sourcePath: "/Volumes/Media/Movie.mkv")

        XCTAssertTrue(remoteCollection.matches(mixedCaseRemote, watchedThreshold: 0.9))
        XCTAssertTrue(remoteCollection.matches(providerRemote, watchedThreshold: 0.9))
        XCTAssertFalse(remoteCollection.matches(local, watchedThreshold: 0.9))
        XCTAssertFalse(localCollection.matches(mixedCaseRemote, watchedThreshold: 0.9))
        XCTAssertTrue(localCollection.matches(local, watchedThreshold: 0.9))
    }
}
