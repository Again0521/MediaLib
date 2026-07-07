import Combine
import XCTest
@testable import MediaLib
@testable import MediaLibCore

@MainActor
final class MusicQueueStoreTests: XCTestCase {
    private var cancellables: Set<AnyCancellable> = []

    override func tearDown() {
        cancellables.removeAll()
        super.tearDown()
    }

    func testQueueRepeatAndShuffleAreOwnedByStore() {
        let store = MusicQueueStore()
        let first = makeTrack(id: "track-1")
        let second = makeTrack(id: "track-2")

        store.replaceQueue([first, second])
        store.setRepeatMode(.repeatAll)
        store.setShuffleEnabled(true)

        XCTAssertEqual(store.queue.map(\.id), ["track-1", "track-2"])
        XCTAssertEqual(store.repeatMode, .repeatAll)
        XCTAssertTrue(store.shuffleEnabled)
    }

    func testScrollAnchorIsEphemeralAndDoesNotPublish() {
        let store = MusicQueueStore()
        var publishCount = 0
        store.objectWillChange
            .sink { _ in publishCount += 1 }
            .store(in: &cancellables)

        store.scrollAnchorID = "track-2"

        XCTAssertEqual(store.scrollAnchorID, "track-2")
        XCTAssertEqual(publishCount, 0)
    }

    private func makeTrack(id: String) -> MediaItem {
        MediaItem(
            id: id,
            type: .music,
            title: "Track \(id)",
            fileSize: 1024
        )
    }
}
