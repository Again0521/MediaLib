import XCTest
@testable import MediaLib

final class MpvVideoSnapshotReaderTests: XCTestCase {
    func testPlayerTimelineTimePreservesPlaybackTimeWithoutOffset() {
        XCTAssertEqual(MpvVideoSnapshotReader.playerTimelineTime(for: 12.5, offset: 0), 12.5)
        XCTAssertEqual(MpvVideoSnapshotReader.playerTimelineTime(for: -3, offset: 0), -3)
    }

    func testPlayerTimelineTimeAddsPositiveOffsetAndClampsNegativePlaybackTime() {
        XCTAssertEqual(MpvVideoSnapshotReader.playerTimelineTime(for: 12.5, offset: 100), 112.5)
        XCTAssertEqual(MpvVideoSnapshotReader.playerTimelineTime(for: -3, offset: 100), 100)
    }

    func testMpvChapterKeepsIdentityTitleAndTimelineTime() {
        let chapter = MpvChapter(id: 2, title: "Opening", time: 42.25)

        XCTAssertEqual(chapter.id, 2)
        XCTAssertEqual(chapter.title, "Opening")
        XCTAssertEqual(chapter.time, 42.25)
    }
}
