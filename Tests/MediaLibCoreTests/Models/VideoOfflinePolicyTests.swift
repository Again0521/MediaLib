import XCTest
@testable import MediaLibCore

final class VideoOfflinePolicyTests: XCTestCase {
    func testCacheableVideoCandidateAcceptsHTTPAndHTTPSNonMusicItems() {
        XCTAssertTrue(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .movie, filePath: "https://media.example/movie.mkv")))
        XCTAssertTrue(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .episode, filePath: "HTTP://media.example/episode.mkv")))
    }

    func testCacheableVideoCandidateRejectsMusicMissingAndNonHTTPResources() {
        XCTAssertFalse(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .music, filePath: "https://media.example/song.flac")))
        XCTAssertFalse(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .movie, filePath: nil)))
        XCTAssertFalse(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .movie, filePath: "/Volumes/Movies/local.mkv")))
        XCTAssertFalse(VideoOfflinePolicy.isCacheableVideoCandidate(mediaItem(type: .movie, filePath: "rtsp://camera.example/live")))
    }

    func testLocalNetworkHostRecognizesLoopbackBonjourPrivateIPv4AndIPv6Ranges() {
        let localHosts = [
            "localhost",
            "::1",
            "media.local",
            "10.0.0.8",
            "127.0.0.1",
            "192.168.31.10",
            "172.16.0.1",
            "172.31.255.254",
            "fe80::1",
            "fc00::1234",
            "fd00::1234"
        ]

        for host in localHosts {
            XCTAssertTrue(VideoOfflinePolicy.isLocalNetworkHost(host), host)
        }
    }

    func testLocalNetworkHostRejectsPublicAndOutOfRangeHosts() {
        let publicHosts = [
            "",
            "example.com",
            "8.8.8.8",
            "172.15.255.255",
            "172.32.0.1",
            "10.0.0.256",
            "10.0.0.-1",
            "192.168.1.999",
            "127.0.0.999",
            "100.64.0.1",
            "fdstream.example",
            "fd.example.com",
            "fc.example.com",
            "2001:4860:4860::8888"
        ]

        for host in publicHosts {
            XCTAssertFalse(VideoOfflinePolicy.isLocalNetworkHost(host), host)
        }
    }

    func testNetworkPolicyAllowsRemoteRegardlessOfItemReachability() {
        let item = mediaItem(type: .movie, filePath: nil)

        XCTAssertTrue(VideoOfflinePolicy.networkPolicyAllows(.allowRemote, item: item, wifiAvailable: false))
    }

    func testNetworkPolicyRequiresWiFiWhenConfigured() {
        let item = mediaItem(type: .movie, filePath: "https://media.example/movie.mkv")

        XCTAssertFalse(VideoOfflinePolicy.networkPolicyAllows(.wifiOnly, item: item, wifiAvailable: false))
        XCTAssertTrue(VideoOfflinePolicy.networkPolicyAllows(.wifiOnly, item: item, wifiAvailable: true))
    }

    func testNetworkPolicyLocalNetworkOnlyUsesURLHost() {
        XCTAssertTrue(
            VideoOfflinePolicy.networkPolicyAllows(
                .localNetworkOnly,
                item: mediaItem(type: .movie, filePath: "https://192.168.1.20/movie.mkv"),
                wifiAvailable: true
            )
        )
        XCTAssertFalse(
            VideoOfflinePolicy.networkPolicyAllows(
                .localNetworkOnly,
                item: mediaItem(type: .movie, filePath: "https://stream.example/movie.mkv"),
                wifiAvailable: true
            )
        )
        XCTAssertFalse(
            VideoOfflinePolicy.networkPolicyAllows(
                .localNetworkOnly,
                item: mediaItem(type: .movie, filePath: nil),
                wifiAvailable: true
            )
        )
    }

    func testNextUnwatchedEpisodesPreservesOrderAndExcludesWatchedOrThresholdCompleteItems() {
        let episodes = [
            mediaItem(id: "watched-flag", type: .episode, playProgress: 0.1, watched: true),
            mediaItem(id: "below-threshold", type: .episode, playProgress: 0.79, watched: false),
            mediaItem(id: "at-threshold", type: .episode, playProgress: 0.8, watched: false),
            mediaItem(id: "unstarted", type: .episode, playProgress: 0, watched: false)
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.nextUnwatchedEpisodes(in: episodes, watchedThreshold: 0.8).map(\.id),
            ["below-threshold", "unstarted"]
        )
    }

    func testSeriesCacheStateReturnsNilWhenSeriesHasNoCacheableOrCachedChildren() {
        let children = [
            mediaItem(id: "local", type: .episode, filePath: "/Volumes/Series/e1.mkv"),
            mediaItem(id: "music", type: .music, filePath: "https://media.example/song.flac")
        ]

        XCTAssertNil(VideoOfflinePolicy.seriesCacheState(for: children, cachedItemIDs: []))
    }

    func testSeriesCacheStateReportsNonePartialAndComplete() {
        let children = [
            mediaItem(id: "e1", type: .episode, filePath: "https://media.example/e1.mkv"),
            mediaItem(id: "e2", type: .episode, filePath: "https://media.example/e2.mkv")
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.seriesCacheState(for: children, cachedItemIDs: []),
            Optional.some(VideoSeriesCacheState.none)
        )
        XCTAssertEqual(VideoOfflinePolicy.seriesCacheState(for: children, cachedItemIDs: ["e1"]), .partial)
        XCTAssertEqual(VideoOfflinePolicy.seriesCacheState(for: children, cachedItemIDs: ["e1", "e2"]), .complete)
    }

    func testSeriesCacheStatesSkipsParentsWithoutCandidatesAndKeepsCachedLocalChildAsCandidate() {
        let states = VideoOfflinePolicy.seriesCacheStates(
            childrenByParentID: [
                "empty": [mediaItem(id: "local", type: .episode, filePath: "/Volumes/Series/e1.mkv")],
                "cached-local": [mediaItem(id: "cached-local-child", type: .episode, filePath: "/Volumes/Series/e2.mkv")]
            ],
            cachedItemIDs: ["cached-local-child"]
        )

        XCTAssertEqual(states, ["cached-local": .complete])
    }

    func testSubscriptionCandidatesFullSeriesFiltersUncacheableCachedQueuedAndBlockedNetworkItems() {
        let subscription = subscription(mode: .fullSeries, networkPolicy: .localNetworkOnly)
        let episodes = [
            mediaItem(id: "local-ready", type: .episode, filePath: "https://192.168.1.20/e1.mkv"),
            mediaItem(id: "public-network", type: .episode, filePath: "https://stream.example/e2.mkv"),
            mediaItem(id: "cached", type: .episode, filePath: "https://192.168.1.20/e3.mkv"),
            mediaItem(id: "queued", type: .episode, filePath: "https://192.168.1.20/e4.mkv"),
            mediaItem(id: "local-file", type: .episode, filePath: "/Volumes/Series/e5.mkv")
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.subscriptionCandidates(
                for: subscription,
                episodes: episodes,
                cachedItemIDs: ["cached"],
                queuedItemIDs: ["queued"],
                wifiAvailable: true,
                watchedThreshold: 0.8
            ).map(\.id),
            ["local-ready"]
        )
    }

    func testSubscriptionCandidatesNextEpisodeReturnsOnlyFirstUnwatchedCandidate() {
        let subscription = subscription(mode: .nextEpisode)
        let episodes = [
            mediaItem(id: "finished", type: .episode, filePath: "https://media.example/e1.mkv", playProgress: 0.81),
            mediaItem(id: "next", type: .episode, filePath: "https://media.example/e2.mkv", playProgress: 0.2),
            mediaItem(id: "later", type: .episode, filePath: "https://media.example/e3.mkv", playProgress: 0)
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.subscriptionCandidates(
                for: subscription,
                episodes: episodes,
                cachedItemIDs: [],
                queuedItemIDs: [],
                wifiAvailable: false,
                watchedThreshold: 0.8
            ).map(\.id),
            ["next"]
        )
    }

    func testSubscriptionCandidatesNextUnwatchedHonorsEpisodeLimitAndSeasonFiltersBySeasonNumber() {
        let nextUnwatched = subscription(mode: .nextUnwatched, episodeLimit: 2)
        let seasonTwo = subscription(mode: .season, seasonNumber: 2)
        let episodes = [
            mediaItem(id: "s1e1", type: .episode, filePath: "https://media.example/s1e1.mkv", seasonNumber: 1),
            mediaItem(id: "s1e2", type: .episode, filePath: "https://media.example/s1e2.mkv", seasonNumber: 1),
            mediaItem(id: "s2e1", type: .episode, filePath: "https://media.example/s2e1.mkv", seasonNumber: 2),
            mediaItem(id: "s2e2", type: .episode, filePath: "https://media.example/s2e2.mkv", seasonNumber: 2)
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.subscriptionCandidates(
                for: nextUnwatched,
                episodes: episodes,
                cachedItemIDs: [],
                queuedItemIDs: [],
                wifiAvailable: false,
                watchedThreshold: 0.8
            ).map(\.id),
            ["s1e1", "s1e2"]
        )
        XCTAssertEqual(
            VideoOfflinePolicy.subscriptionCandidates(
                for: seasonTwo,
                episodes: episodes,
                cachedItemIDs: [],
                queuedItemIDs: [],
                wifiAvailable: false,
                watchedThreshold: 0.8
            ).map(\.id),
            ["s2e1", "s2e2"]
        )
    }

    func testPreferredSubscriptionSeasonNumberUsesEpisodeSeasonThenFirstUnwatchedCacheableSeason() {
        let selectedEpisode = mediaItem(id: "selected", type: .episode, seasonNumber: 3)
        let series = mediaItem(id: "series", type: .tvShow)
        let episodes = [
            mediaItem(id: "s1e1", type: .episode, filePath: "https://media.example/s1e1.mkv", seasonNumber: 1, playProgress: 0.9),
            mediaItem(id: "s2e1", type: .episode, filePath: "https://media.example/s2e1.mkv", seasonNumber: 2, playProgress: 0.1)
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.preferredSubscriptionSeasonNumber(
                for: selectedEpisode,
                episodes: episodes,
                watchedThreshold: 0.8
            ),
            3
        )
        XCTAssertEqual(
            VideoOfflinePolicy.preferredSubscriptionSeasonNumber(
                for: series,
                episodes: episodes,
                watchedThreshold: 0.8
            ),
            2
        )
    }

    func testPreferredSubscriptionSeasonNumberFallsBackToFirstCacheableSeasonWhenAllWatched() {
        let series = mediaItem(id: "series", type: .tvShow)
        let episodes = [
            mediaItem(id: "local", type: .episode, filePath: "/Volumes/Series/s1e1.mkv", seasonNumber: 1),
            mediaItem(id: "s2e1", type: .episode, filePath: "https://media.example/s2e1.mkv", seasonNumber: 2, watched: true),
            mediaItem(id: "s3e1", type: .episode, filePath: "https://media.example/s3e1.mkv", seasonNumber: 3, watched: true)
        ]

        XCTAssertEqual(
            VideoOfflinePolicy.preferredSubscriptionSeasonNumber(
                for: series,
                episodes: episodes,
                watchedThreshold: 0.8
            ),
            2
        )
    }

    private func mediaItem(
        id: String = UUID().uuidString,
        type: MediaType,
        filePath: String? = nil,
        seasonNumber: Int? = nil,
        playProgress: Double = 0,
        watched: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: id,
            seasonNumber: seasonNumber,
            filePath: filePath,
            playProgress: playProgress,
            watched: watched
        )
    }

    private func subscription(
        mode: VideoOfflineSubscriptionMode,
        episodeLimit: Int = 3,
        seasonNumber: Int? = nil,
        networkPolicy: VideoOfflineSubscriptionNetworkPolicy = .allowRemote
    ) -> VideoOfflineSubscription {
        VideoOfflineSubscription(
            seriesID: "series",
            seriesTitle: "Series",
            mode: mode,
            episodeLimit: episodeLimit,
            seasonNumber: seasonNumber,
            networkPolicy: networkPolicy
        )
    }
}
