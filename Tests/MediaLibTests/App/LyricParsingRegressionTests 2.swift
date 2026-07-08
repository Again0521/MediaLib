import XCTest
import MediaLibCore
@testable import MediaLib

final class LyricParsingRegressionTests: XCTestCase {
    func testNegativeOffsetClampsLineAndEnhancedSegmentTimesToZero() {
        let lines = LyricSourceParser.parse("[offset:-10000]\n[00:05.00]<00:05.00>Hello")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 0, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments.count, 1)
        XCTAssertEqual(lines[0].segments[0].time, 0, accuracy: 0.0001)
        XCTAssertEqual(lines[0].source, .exact)
    }

    func testMetadataTagsAreIgnoredWhenParsingTimedLyrics() {
        let lines = LyricSourceParser.parse("[ar:artist]\n[ti:title]\n[al:album]\n[00:01.00]Hi")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "Hi")
    }

    func testNearTimestampPlainLinesAreMergedIntoOneDisplayLine() {
        let lines = LyricSourceParser.parse("[00:10.00]Hello\n[00:10.05]World")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 10, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "Hello\nWorld")
        XCTAssertEqual(lines[0].source, .estimated)
        XCTAssertTrue(lines[0].segments.isEmpty)
    }

    func testNearTimestampJapaneseChinesePairStaysSeparateForPlaybackAnchorSelection() {
        let lines = LyricSourceParser.parse("""
        [00:10.00]さよならだけが僕らの愛だ
        [00:10.05]只有离别才是我们的爱
        """)

        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), [
            "さよならだけが僕らの愛だ",
            "只有离别才是我们的爱"
        ])
        XCTAssertEqual(lines.map(\.time), [10, 10])
    }

    func testNearTimestampDuplicateTextIsDeduplicatedAfterWhitespaceNormalization() {
        let lines = LyricSourceParser.parse("[00:10.00]Hello   world\n[00:10.05] Hello world ")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].text, "Hello   world")
    }

    func testEnhancedLRCParsesSegmentsAndMarksLineAsExact() {
        let lines = LyricSourceParser.parse("[00:01.00]<00:01.10>He<00:01.40>llo")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "Hello")
        XCTAssertEqual(lines[0].source, .exact)
        XCTAssertEqual(lines[0].segments.map(\.text), ["He", "llo"])
        XCTAssertEqual(lines[0].segments.map(\.time), [1.1, 1.4])
    }

    func testYRCRelativeSegmentsAreAnchoredToLineStart() {
        let lines = LyricSourceParser.parse("[10000,2000](0,500)你(500,400)好")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 10, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "你好")
        XCTAssertEqual(lines[0].source, .exact)
        XCTAssertEqual(lines[0].segments.map(\.text), ["你", "好"])
        XCTAssertEqual(lines[0].segments[0].time, 10, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[1].time, 10.5, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[0].durationHint ?? -1, 0.5, accuracy: 0.0001)
    }

    func testYRCAbsoluteSegmentsKeepAbsoluteMillisecondTimestamps() {
        let lines = LyricSourceParser.parse("[10000,2000](12000,500)你(12500,400)好")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 10, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[0].time, 12, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[1].time, 12.5, accuracy: 0.0001)
    }

    func testTTMLParsesParagraphsAndRelativeSpanDurations() {
        let lines = LyricSourceParser.parse("""
        <tt>
          <body>
            <div>
              <p begin="00:00:05.000">
                <span begin="0.1s" dur="0.2s">Hi</span>
                <span begin="0.4s" dur="0.3s">!</span>
              </p>
            </div>
          </body>
        </tt>
        """)

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 5, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "Hi!")
        XCTAssertEqual(lines[0].source, .exact)
        XCTAssertEqual(lines[0].segments.map(\.text), ["Hi", "!"])
        XCTAssertEqual(lines[0].segments[0].time, 5.1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[0].durationHint ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[1].time, 5.4, accuracy: 0.0001)
        XCTAssertEqual(lines[0].segments[1].durationHint ?? -1, 0.3, accuracy: 0.0001)
    }

    func testTimedLyricLineParseDelegatesToAppParser() {
        let lines = TimedLyricLine.parse("[00:01.00]Hi")

        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines[0].time, 1, accuracy: 0.0001)
        XCTAssertEqual(lines[0].text, "Hi")
    }
}
