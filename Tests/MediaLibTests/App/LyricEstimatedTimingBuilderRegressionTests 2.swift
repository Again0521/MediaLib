import XCTest
import MediaLibCore
@testable import MediaLib

final class LyricEstimatedTimingBuilderRegressionTests: XCTestCase {
    func testBuildsEstimatedSegmentsInsideLineBoundaries() throws {
        let sourceLines = [
            TimedLyricLine(time: 0, text: "Hello 世界"),
            TimedLyricLine(time: 4, text: "下一句")
        ]

        let lines = LyricEstimatedTimingBuilder.lines(from: sourceLines, algorithm: .balanced)
        let first = lines[0]
        let lastSegment = try XCTUnwrap(first.segments.last)
        let segmentEnd = lastSegment.time + (lastSegment.durationHint ?? 0)

        XCTAssertEqual(lines.count, 2)
        XCTAssertFalse(first.segments.isEmpty)
        XCTAssertEqual(first.source, .estimated)
        XCTAssertTrue(first.segments.allSatisfy { $0.source == .estimated })
        XCTAssertGreaterThanOrEqual(first.segments[0].time, first.time)
        XCTAssertLessThanOrEqual(segmentEnd, TimedLyricLine.endTime(in: lines, index: 0) + 0.0001)
    }

    func testPreservesExistingExactSegments() {
        let exactSegments = [
            TimedLyricSegment(time: 1.1, text: "Hi", source: .exact, durationHint: 0.2)
        ]
        let sourceLines = [
            TimedLyricLine(time: 1, text: "Hi", segments: exactSegments, source: .exact),
            TimedLyricLine(time: 3, text: "Next")
        ]

        let lines = LyricEstimatedTimingBuilder.lines(from: sourceLines, algorithm: .precise)

        XCTAssertEqual(lines[0].source, .exact)
        XCTAssertEqual(lines[0].segments.count, 1)
        XCTAssertEqual(lines[0].segments[0].time, 1.1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[0].text, "Hi")
        XCTAssertEqual(lines[0].segments[0].source, .exact)
        XCTAssertEqual(lines[0].segments[0].durationHint ?? -1, 0.2, accuracy: 0.0001)
    }

    func testEstimatedSegmentsRemainSortedForMixedScriptsAndPunctuation() {
        let sourceLines = [
            TimedLyricLine(time: 12, text: "Hello, 世界！"),
            TimedLyricLine(time: 16, text: "ending")
        ]

        let line = LyricEstimatedTimingBuilder.lines(from: sourceLines, algorithm: .audioEnergy)[0]
        let times = line.segments.map(\.time)

        XCTAssertGreaterThan(times.count, 1)
        XCTAssertEqual(times, times.sorted())
        XCTAssertTrue(line.segments.contains { $0.text.contains("Hello") })
        XCTAssertTrue(line.segments.contains { $0.text.contains("世界") || $0.text == "世" || $0.text == "界！" })
    }
}
