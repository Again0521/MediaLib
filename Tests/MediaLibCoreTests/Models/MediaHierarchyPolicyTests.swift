import XCTest
@testable import MediaLibCore

final class MediaHierarchyPolicyTests: XCTestCase {
    func testSnapshotGroupsChildrenByParentID() {
        let items = [
            mediaItem("root", type: .movie),
            mediaItem("episode-2", parentID: "root"),
            mediaItem("episode-1", parentID: "root"),
            mediaItem("orphan", parentID: "missing")
        ]

        let snapshot = MediaHierarchyPolicy.snapshot(for: items)

        XCTAssertEqual(snapshot.childrenByParentID["root"]?.map(\.id), ["episode-2", "episode-1"])
        XCTAssertEqual(snapshot.childrenByParentID["missing"]?.map(\.id), ["orphan"])
        XCTAssertNil(snapshot.childrenByParentID["episode-1"])
    }

    func testPrivateCollectionPrivacyPropagatesThroughNestedDescendantsOnly() {
        let items = [
            mediaItem("vault", type: .privateCollection),
            mediaItem("season", type: .tvShow, parentID: "vault"),
            mediaItem("episode", type: .episode, parentID: "season"),
            mediaItem("public-root", type: .movie),
            mediaItem("public-child", type: .episode, parentID: "public-root")
        ]

        let snapshot = MediaHierarchyPolicy.snapshot(for: items)

        XCTAssertEqual(snapshot.privateItemIDs, ["vault", "season", "episode"])
        XCTAssertFalse(snapshot.privateItemIDs.contains("public-root"))
        XCTAssertFalse(snapshot.privateItemIDs.contains("public-child"))
    }

    func testPrivatePropagationHandlesCyclesWithoutLoopingForever() {
        let items = [
            mediaItem("vault", type: .privateCollection, parentID: "child"),
            mediaItem("child", type: .episode, parentID: "vault")
        ]

        let snapshot = MediaHierarchyPolicy.snapshot(for: items)

        XCTAssertEqual(snapshot.privateItemIDs, ["vault", "child"])
        XCTAssertEqual(snapshot.childrenByParentID["vault"]?.map(\.id), ["child"])
        XCTAssertEqual(snapshot.childrenByParentID["child"]?.map(\.id), ["vault"])
    }

    func testSnapshotWithoutPrivateCollectionsStillBuildsHierarchy() {
        let items = [
            mediaItem("series", type: .tvShow),
            mediaItem("episode", type: .episode, parentID: "series")
        ]

        let snapshot = MediaHierarchyPolicy.snapshot(for: items)

        XCTAssertTrue(snapshot.privateItemIDs.isEmpty)
        XCTAssertEqual(snapshot.childrenByParentID["series"]?.map(\.id), ["episode"])
    }

    func testOrderedChildrenSortsBySeasonEpisodeThenTitle() {
        let children = [
            mediaItem("s2e1", title: "Beta", seasonNumber: 2, episodeNumber: 1),
            mediaItem("s1e2", title: "Gamma", seasonNumber: 1, episodeNumber: 2),
            mediaItem("s1e1b", title: "Beta", seasonNumber: 1, episodeNumber: 1),
            mediaItem("s1e1a", title: "Alpha", seasonNumber: 1, episodeNumber: 1),
            mediaItem("no-season", title: "Prelude", seasonNumber: nil, episodeNumber: nil)
        ]

        XCTAssertEqual(
            MediaHierarchyPolicy.orderedChildren(children).map(\.id),
            ["no-season", "s1e1a", "s1e1b", "s1e2", "s2e1"]
        )
    }

    func testSortedChildrenByParentIDSortsEachParentIndependently() {
        let grouped = [
            "series-a": [
                mediaItem("a2", title: "Episode 2", seasonNumber: 1, episodeNumber: 2),
                mediaItem("a1", title: "Episode 1", seasonNumber: 1, episodeNumber: 1)
            ],
            "series-b": [
                mediaItem("b2", title: "Bravo", seasonNumber: 1, episodeNumber: 1),
                mediaItem("b1", title: "Alpha", seasonNumber: 1, episodeNumber: 1)
            ]
        ]

        let sorted = MediaHierarchyPolicy.sortedChildrenByParentID(grouped)

        XCTAssertEqual(sorted["series-a"]?.map(\.id), ["a1", "a2"])
        XCTAssertEqual(sorted["series-b"]?.map(\.id), ["b1", "b2"])
    }

    private func mediaItem(
        _ id: String,
        type: MediaType = .movie,
        parentID: String? = nil,
        title: String? = nil,
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: title ?? id,
            parentID: parentID,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber
        )
    }
}
