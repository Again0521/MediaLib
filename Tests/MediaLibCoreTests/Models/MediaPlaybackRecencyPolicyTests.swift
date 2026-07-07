import XCTest
@testable import MediaLibCore

final class MediaPlaybackRecencyPolicyTests: XCTestCase {
    func testLastPlayedAtTakesPriorityOverUpdatedAt() {
        let oldUpdateRecentPlay = mediaItem(id: "played", updatedAt: day(1), lastPlayedAt: day(10))
        let newUpdateNeverPlayed = mediaItem(id: "updated", updatedAt: day(9), lastPlayedAt: nil)

        XCTAssertTrue(MediaPlaybackRecencyPolicy.isMoreRecent(oldUpdateRecentPlay, than: newUpdateNeverPlayed))
        XCTAssertFalse(MediaPlaybackRecencyPolicy.isMoreRecent(newUpdateNeverPlayed, than: oldUpdateRecentPlay))
    }

    func testUpdatedAtIsFallbackWhenLastPlayedAtIsMissing() {
        let newerFallback = mediaItem(id: "newer", updatedAt: day(8), lastPlayedAt: nil)
        let olderFallback = mediaItem(id: "older", updatedAt: day(3), lastPlayedAt: nil)

        XCTAssertTrue(MediaPlaybackRecencyPolicy.isMoreRecent(newerFallback, than: olderFallback))
    }

    func testSortedByMostRecentPlaybackTraceMixesPlayedAndUpdatedFallbackDates() {
        let items = [
            mediaItem(id: "old-play", updatedAt: day(20), lastPlayedAt: day(4)),
            mediaItem(id: "fresh-update", updatedAt: day(12), lastPlayedAt: nil),
            mediaItem(id: "fresh-play", updatedAt: day(1), lastPlayedAt: day(30)),
            mediaItem(id: "middle-play", updatedAt: day(11), lastPlayedAt: day(15))
        ]

        XCTAssertEqual(
            MediaPlaybackRecencyPolicy.sortedByMostRecentPlaybackTrace(items).map(\.id),
            ["fresh-play", "middle-play", "fresh-update", "old-play"]
        )
    }

    func testEqualRecencyDatesDoNotCreateArtificialOrdering() {
        let lhs = mediaItem(id: "lhs", updatedAt: day(5), lastPlayedAt: nil)
        let rhs = mediaItem(id: "rhs", updatedAt: day(4), lastPlayedAt: day(5))

        XCTAssertEqual(MediaPlaybackRecencyPolicy.playbackRecencyDate(for: lhs), day(5))
        XCTAssertEqual(MediaPlaybackRecencyPolicy.playbackRecencyDate(for: rhs), day(5))
        XCTAssertFalse(MediaPlaybackRecencyPolicy.isMoreRecent(lhs, than: rhs))
        XCTAssertFalse(MediaPlaybackRecencyPolicy.isMoreRecent(rhs, than: lhs))
    }

    private func mediaItem(id: String, updatedAt: Date, lastPlayedAt: Date?) -> MediaItem {
        MediaItem(
            id: id,
            type: .movie,
            title: id,
            updatedAt: updatedAt,
            lastPlayedAt: lastPlayedAt
        )
    }

    private func day(_ value: TimeInterval) -> Date {
        Date(timeIntervalSince1970: value * 86_400)
    }
}
