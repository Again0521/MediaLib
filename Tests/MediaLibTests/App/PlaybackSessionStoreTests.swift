import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class PlaybackSessionStoreTests: XCTestCase {
    func testActiveItemAndVideoQueueAreOwnedByStore() {
        let store = PlaybackSessionStore()
        let first = makeEpisode(id: "episode-1")
        let second = makeEpisode(id: "episode-2")

        store.setActivePlayerItem(first)
        store.replaceVideoQueue([first, second])

        XCTAssertEqual(store.activePlayerItem?.id, "episode-1")
        XCTAssertEqual(store.videoQueue.map(\.id), ["episode-1", "episode-2"])
    }

    func testPlaybackCommandRequestsAreOwnedByStore() {
        let store = PlaybackSessionStore()

        store.requestCommand(.next)

        XCTAssertEqual(store.playbackCommandRequest?.command, .next)
    }

    func testPlaybackCommandRequestCanBeClearedForFacadeCompatibility() {
        let store = PlaybackSessionStore()
        store.requestCommand(.pause)

        store.setPlaybackCommandRequest(nil)

        XCTAssertNil(store.playbackCommandRequest)
    }

    private func makeEpisode(id: String) -> MediaItem {
        MediaItem(
            id: id,
            type: .episode,
            title: "Episode \(id)",
            fileSize: 2048
        )
    }
}
