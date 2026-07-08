import XCTest
import MediaLibCore

final class LyricSeekSynchronizationRegressionTests: XCTestCase {
    private func line(
        _ time: Double,
        _ text: String,
        segments: [TimedLyricSegment] = [],
        source: LyricTimingSource = .estimated
    ) -> TimedLyricLine {
        TimedLyricLine(time: time, text: text, segments: segments, source: source)
    }

    func testPlaybackAnchorPrefersJapaneseOriginalInsideDuplicateTimestampCluster() {
        let lines = [
            line(0, "intro"),
            line(10, "只有离别才是我们的爱"),
            line(10.0002, "さよならだけが僕らの愛だ"),
            line(20, "outro")
        ]

        let position = TimedLyricLine.playbackPosition(in: lines, at: 12)

        XCTAssertEqual(position?.lineIndex, 2)
        XCTAssertEqual(position?.startTime ?? -1, 10.0002, accuracy: 0.0001)
    }

    func testProgressUsesPreferredAnchorForJapaneseChineseTimestampCluster() {
        let lines = [
            line(0, "intro"),
            line(10, "只有离别才是我们的爱"),
            line(10.0002, "さよならだけが僕らの愛だ"),
            line(20, "outro")
        ]

        XCTAssertEqual(TimedLyricLine.progress(in: lines, index: 1, currentTime: 15), 0, accuracy: 0.0001)
        XCTAssertEqual(TimedLyricLine.progress(in: lines, index: 2, currentTime: 15), 0.4999, accuracy: 0.001)
    }

    func testFirstTimestampIndexReturnsClusterStartForNearDuplicateFutureTime() {
        let lines = [
            line(0, "intro"),
            line(10.0001, "line A"),
            line(10.0004, "line B"),
            line(20, "outro")
        ]

        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 9.5, in: lines), 1)
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 10, in: lines), 1)
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 10.0001, in: lines), 2)
    }

    func testPlaybackReferenceTimeIsClampedToGeneratedFinalLineEnd() {
        let lines = [
            line(0, "short"),
            line(10, "final line")
        ]

        let finalEnd = TimedLyricLine.endTime(in: lines, index: 1)
        let position = TimedLyricLine.playbackPosition(in: lines, at: 999)

        XCTAssertEqual(position?.lineIndex, 1)
        XCTAssertEqual(position?.referenceTime ?? -1, finalEnd, accuracy: 0.0001)
    }

    func testVisualEndTimeUsesSegmentDurationButNeverPassesNextLine() {
        let segments = [
            TimedLyricSegment(time: 5.1, text: "he", source: .exact, durationHint: 0.2),
            TimedLyricSegment(time: 9.9, text: "llo", source: .exact, durationHint: 1.5)
        ]
        let lines = [
            line(5, "hello", segments: segments, source: .exact),
            line(10, "next")
        ]

        XCTAssertEqual(TimedLyricLine.visualEndTime(in: lines, index: 0), 10, accuracy: 0.0001)
    }

    func testVisualEndTimeKeepsMinimumReadableWindowForShortSegmentHints() {
        let segments = [
            TimedLyricSegment(time: 5.05, text: "x", source: .exact, durationHint: 0.02)
        ]
        let lines = [
            line(5, "x", segments: segments, source: .exact),
            line(8, "next")
        ]

        XCTAssertEqual(TimedLyricLine.visualEndTime(in: lines, index: 0), 5.35, accuracy: 0.0001)
    }

    func testEffectiveSourceAndBestTimingSourcePreferHighestSegmentRank() {
        let alignedSegments = [
            TimedLyricSegment(time: 1.0, text: "a", source: .estimated),
            TimedLyricSegment(time: 1.4, text: "b", source: .aligned)
        ]
        let exactSegments = [
            TimedLyricSegment(time: 3.0, text: "c", source: .exact)
        ]
        let lines = [
            line(1, "ab", segments: alignedSegments, source: .estimated),
            line(3, "c", segments: exactSegments, source: .aligned)
        ]

        XCTAssertEqual(lines[0].effectiveSource, .aligned)
        XCTAssertEqual(lines[1].effectiveSource, .exact)
        XCTAssertEqual(TimedLyricLine.bestTimingSource(in: lines), .exact)
    }

    func testHighlightEstimatorTreatsLatinWordsAsSingleTimingUnits() {
        let units = LyricHighlightEstimator.timingUnits(for: "Hello, 世界!")

        XCTAssertEqual(units.map(\.originalIndices), [
            [0, 1, 2, 3, 4],
            [7],
            [8]
        ])
    }

    func testHighlightTimingClampsProgressToValidRange() {
        let overrun = LyricHighlightEstimator.timing(for: "abc 世界", progress: 2)
        let underrun = LyricHighlightEstimator.timing(for: "abc 世界", progress: -1)

        XCTAssertEqual(overrun.progress, 1)
        XCTAssertEqual(underrun.progress, 0)
    }
}
