import XCTest
@testable import MediaLibCore

final class HomeVideoProjectionPolicyTests: XCTestCase {
    func testAvailableHomeTabsIncludesOnlyTabsBackedByCurrentSnapshots() {
        let tabs = HomeVideoProjectionPolicy.availableHomeTabs(
            HomeTabAvailabilityInput(
                homeVideoItems: [
                    item(id: "movie", type: .movie, favorite: true),
                    item(id: "anime", type: .anime, playProgress: 0.1),
                    item(id: "doc", type: .documentary, watched: true),
                    item(id: "other", type: .other)
                ],
                nextUpItems: [item(id: "next", type: .episode)],
                continueWatchingItems: [item(id: "continue", type: .movie)],
                offlineVideoItems: [item(id: "offline", type: .movie)],
                musicTracks: [item(id: "song", type: .music)],
                privateTopLevelItems: [item(id: "private", type: .privateCollection)],
                watchedThreshold: 0.8
            )
        )

        XCTAssertTrue(tabs.contains(.overview))
        XCTAssertTrue(tabs.contains(.nextUp))
        XCTAssertTrue(tabs.contains(.continueWatching))
        XCTAssertTrue(tabs.contains(.offline))
        XCTAssertTrue(tabs.contains(.recent))
        XCTAssertTrue(tabs.contains(.movies))
        XCTAssertTrue(tabs.contains(.anime))
        XCTAssertTrue(tabs.contains(.documentaries))
        XCTAssertTrue(tabs.contains(.music))
        XCTAssertTrue(tabs.contains(.other))
        XCTAssertTrue(tabs.contains(.favorites))
        XCTAssertTrue(tabs.contains(.unwatched))
        XCTAssertTrue(tabs.contains(.privacy))
        XCTAssertFalse(tabs.contains(.tvShows))
        XCTAssertFalse(tabs.contains(.variety))
        XCTAssertFalse(tabs.contains(.homeVideos))
    }

    func testAvailableHomeTabsKeepsOverviewWhenEverythingElseIsEmpty() {
        let tabs = HomeVideoProjectionPolicy.availableHomeTabs(
            HomeTabAvailabilityInput(
                homeVideoItems: [],
                nextUpItems: [],
                continueWatchingItems: [],
                offlineVideoItems: [],
                musicTracks: [],
                privateTopLevelItems: [],
                watchedThreshold: 0.8
            )
        )

        XCTAssertEqual(tabs, [.overview])
    }

    func testAvailableHomeTabsTreatsThresholdReachedItemsAsWatchedForUnwatchedTab() {
        let tabs = HomeVideoProjectionPolicy.availableHomeTabs(
            HomeTabAvailabilityInput(
                homeVideoItems: [
                    item(id: "threshold", type: .movie, playProgress: 0.8)
                ],
                nextUpItems: [],
                continueWatchingItems: [],
                offlineVideoItems: [],
                musicTracks: [],
                privateTopLevelItems: [],
                watchedThreshold: 0.8
            )
        )

        XCTAssertTrue(tabs.contains(.movies))
        XCTAssertFalse(tabs.contains(.unwatched))
    }

    func testAvailableHomeTabsTreatsNonFiniteProgressAsUnwatchedAndInvalidThresholdAsDefault() {
        let tabs = HomeVideoProjectionPolicy.availableHomeTabs(
            HomeTabAvailabilityInput(
                homeVideoItems: [
                    item(id: "invalid-progress", type: .movie, playProgress: .infinity)
                ],
                nextUpItems: [],
                continueWatchingItems: [],
                offlineVideoItems: [],
                musicTracks: [],
                privateTopLevelItems: [],
                watchedThreshold: .nan
            )
        )

        XCTAssertTrue(tabs.contains(.movies))
        XCTAssertTrue(tabs.contains(.unwatched))
    }

    func testNextUpItemsReturnsEpisodeAfterLastFinishedEpisode() {
        let series = item(id: "series", type: .tvShow)
        let episodes = [
            item(id: "e1", type: .episode, watched: true),
            item(id: "e2", type: .episode, playProgress: 0.85),
            item(id: "e3", type: .episode, playProgress: 0.2),
            item(id: "e4", type: .episode, playProgress: 0)
        ]

        XCTAssertEqual(
            HomeVideoProjectionPolicy.nextUpItems(
                from: [series],
                childrenByParentID: ["series": episodes],
                watchedThreshold: 0.8,
                limit: 12
            ).map(\.id),
            ["e3"]
        )
    }

    func testNextUpItemsSkipsUnstartedFinishedAndAlreadyCompleteSeries() {
        let unstarted = item(id: "unstarted", type: .tvShow)
        let complete = item(id: "complete", type: .tvShow)
        let nextAlreadyFinished = item(id: "next-finished", type: .tvShow)

        XCTAssertEqual(
            HomeVideoProjectionPolicy.nextUpItems(
                from: [unstarted, complete, nextAlreadyFinished],
                childrenByParentID: [
                    "unstarted": [
                        item(id: "u1", type: .episode, playProgress: 0),
                        item(id: "u2", type: .episode, playProgress: 0)
                    ],
                    "complete": [
                        item(id: "c1", type: .episode, watched: true)
                    ],
                    "next-finished": [
                        item(id: "n1", type: .episode, watched: true),
                        item(id: "n2", type: .episode, watched: true),
                        item(id: "n3", type: .episode, playProgress: 0.95)
                    ]
                ],
                watchedThreshold: 0.8,
                limit: 12
            ),
            []
        )
    }

    func testNextUpItemsTreatsNonFiniteProgressAsUnfinished() {
        let series = item(id: "series", type: .tvShow)
        let episodes = [
            item(id: "e1", type: .episode, watched: true),
            item(id: "e2", type: .episode, playProgress: .infinity),
            item(id: "e3", type: .episode, playProgress: 0.1)
        ]

        XCTAssertEqual(
            HomeVideoProjectionPolicy.nextUpItems(
                from: [series],
                childrenByParentID: ["series": episodes],
                watchedThreshold: 0.8,
                limit: 12
            ).map(\.id),
            ["e2"]
        )
    }

    func testNextUpItemsUsesDefaultThresholdWhenThresholdIsNonFinite() {
        let series = item(id: "series", type: .tvShow)
        let episodes = [
            item(id: "e1", type: .episode, playProgress: 0.95),
            item(id: "e2", type: .episode, playProgress: 0.5)
        ]

        for threshold in [Double.nan, .infinity, -.infinity] {
            XCTAssertEqual(
                HomeVideoProjectionPolicy.nextUpItems(
                    from: [series],
                    childrenByParentID: ["series": episodes],
                    watchedThreshold: threshold,
                    limit: 12
                ).map(\.id),
                ["e2"]
            )
        }
    }

    func testNextUpItemsHonorsLimitAndInputOrder() {
        let first = item(id: "first", type: .tvShow)
        let second = item(id: "second", type: .tvShow)

        XCTAssertEqual(
            HomeVideoProjectionPolicy.nextUpItems(
                from: [first, second],
                childrenByParentID: [
                    "first": [
                        item(id: "f1", type: .episode, watched: true),
                        item(id: "f2", type: .episode)
                    ],
                    "second": [
                        item(id: "s1", type: .episode, watched: true),
                        item(id: "s2", type: .episode)
                    ]
                ],
                watchedThreshold: 0.8,
                limit: 1
            ).map(\.id),
            ["f2"]
        )
    }

    private func item(
        id: String,
        type: MediaType,
        playProgress: Double = 0,
        watched: Bool = false,
        favorite: Bool = false
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: id,
            playProgress: playProgress,
            watched: watched,
            favorite: favorite
        )
    }
}
