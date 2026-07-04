import XCTest
import MediaLibCore
@testable import MediaLib   // LyricSourceParser 仍在 GUI 目标；TimedLyricLine 已下沉 Core

// LRC 解析回归测试（报告 04）：LyricSourceParser.parse 是「歌词文本 → [TimedLyricLine]」的唯一入口。
// 经 @testable import MediaLib 原地测试（解析器在 GUI 目标）。锁定标准 LRC、多时间戳展开、排序、小数秒、offset 等当前行为。
final class LyricParsingTests: XCTestCase {
    func testEmptyAndWhitespaceReturnEmpty() {
        XCTAssertTrue(LyricSourceParser.parse("").isEmpty)
        XCTAssertTrue(LyricSourceParser.parse("   \n\t ").isEmpty)
    }

    func testPlainTextWithoutTimestampsReturnsEmpty() {
        // 无时间戳的纯文本不构成「带时轴歌词」，解析为空。
        XCTAssertTrue(LyricSourceParser.parse("just some lyrics\nwithout any timestamps").isEmpty)
    }

    func testSingleTimestampLine() {
        let lines = LyricSourceParser.parse("[00:05.00]Hello")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.time ?? -1, 5.0, accuracy: 0.0001)
        XCTAssertEqual(lines.first?.text, "Hello")
    }

    func testMinutesAreParsed() {
        let lines = LyricSourceParser.parse("[01:30.00]X")
        XCTAssertEqual(lines.first?.time ?? -1, 90.0, accuracy: 0.0001)
    }

    func testMultipleTimestampsOnOneLineExpand() {
        let lines = LyricSourceParser.parse("[00:01.00][00:03.00]Repeat")
        XCTAssertEqual(lines.count, 2)
        XCTAssertEqual(lines.map(\.text), ["Repeat", "Repeat"])
        XCTAssertEqual(lines[0].time, 1.0, accuracy: 0.0001)
        XCTAssertEqual(lines[1].time, 3.0, accuracy: 0.0001)
    }

    func testLinesAreSortedByTime() {
        let lines = LyricSourceParser.parse("[00:10.00]B\n[00:05.00]A")
        XCTAssertEqual(lines.map(\.text), ["A", "B"])
        XCTAssertEqual(lines.map(\.time), [5.0, 10.0])
    }

    func testFractionalSecondsScaleByDigitCount() {
        // 实现：小数部分 = 数字 / 10^位数。故 .50→0.5，.250→0.25，.5→0.5。
        XCTAssertEqual(LyricSourceParser.parse("[00:05.50]X").first?.time ?? -1, 5.5, accuracy: 0.0001)
        XCTAssertEqual(LyricSourceParser.parse("[00:05.250]X").first?.time ?? -1, 5.25, accuracy: 0.0001)
        XCTAssertEqual(LyricSourceParser.parse("[00:05.5]X").first?.time ?? -1, 5.5, accuracy: 0.0001)
    }

    func testEmptyTextTimestampIsFiltered() {
        XCTAssertTrue(LyricSourceParser.parse("[00:05.00]   ").isEmpty)
    }

    func testOffsetTagIsAddedToTimes() {
        // 本实现把 [offset:ms] 直接加到时间上（正值=更晚）；锁定该行为。
        let lines = LyricSourceParser.parse("[offset:1000]\n[00:05.00]Hi")
        XCTAssertEqual(lines.count, 1)
        XCTAssertEqual(lines.first?.time ?? -1, 6.0, accuracy: 0.0001)
    }

    func testParseIntegratesWithPlaybackPosition() {
        // 解析 → 定位 端到端：第 2 行在 t=7 时应为当前行。
        let lines = LyricSourceParser.parse("[00:00.00]one\n[00:05.00]two\n[00:10.00]three")
        XCTAssertEqual(lines.count, 3)
        XCTAssertEqual(TimedLyricLine.activeIndex(in: lines, at: 7.0), 1)
        XCTAssertEqual(TimedLyricLine.activeIndex(in: lines, at: 11.0), 2)
    }
}
