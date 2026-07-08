import XCTest
import MediaLibCore

// 歌词定位回归测试（审查报告 04 的核心算法）：TimedLyricLine.playbackPosition 是「拖动后落点 / 当前行高亮」
// 的唯一时间→行换算。它在 GUI 目标中，故经 import MediaLibCore 原地测试（不移动产品代码）。
// 这些用例锁定二分查找、重复时间戳合并、边界钳制、progress 比例等当前行为，为后续重构（含下沉 Core）兜底。
final class LyricPositioningTests: XCTestCase {
    private func line(_ time: Double, _ text: String = "x") -> TimedLyricLine {
        TimedLyricLine(time: time, text: text)
    }

    // MARK: - playbackPosition 基本

    func testEmptyLinesReturnNil() {
        XCTAssertNil(TimedLyricLine.playbackPosition(in: [], at: 1.0))
    }

    func testSingleLineAlwaysResolvesToIndexZero() {
        let lines = [line(0)]
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 0)?.lineIndex, 0)
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 99)?.lineIndex, 0)
    }

    func testSelectsLatestLineNotAfterTime() {
        let lines = [line(0), line(10), line(20)]
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 5)?.lineIndex, 0)
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 15)?.lineIndex, 1)
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 25)?.lineIndex, 2)
    }

    func testExactTimestampSelectsThatLine() {
        let lines = [line(0), line(10), line(20)]
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 10)?.lineIndex, 1)
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 20)?.lineIndex, 2)
    }

    func testNegativeTimeClampsToFirstLine() {
        let lines = [line(0), line(10)]
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: -5)?.lineIndex, 0)
    }

    func testPositionFieldsAreConsistent() {
        let lines = [line(0), line(10), line(20)]
        let position = TimedLyricLine.playbackPosition(in: lines, at: 15)
        XCTAssertEqual(position?.lineIndex, 1)
        XCTAssertEqual(position?.startTime, 10)
        XCTAssertEqual(position?.endTime, 20)
        XCTAssertEqual(position?.referenceTime, 15)   // clamp(15, start, end)
    }

    // MARK: - 重复时间戳合并

    func testDuplicateTimestampsAnchorToClusterStart() {
        // 两行共享时间戳 10（ASCII 文本，不触发日中翻译对优选）→ 应锚定到簇首索引 1。
        let lines = [line(0), line(10, "a"), line(10, "b"), line(20)]
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 12)?.lineIndex, 1)
        XCTAssertEqual(TimedLyricLine.playbackPosition(in: lines, at: 10)?.lineIndex, 1)
    }

    // MARK: - activeIndex 与 playbackPosition 一致

    func testActiveIndexMatchesPlaybackPosition() {
        let lines = [line(0), line(8), line(16)]
        for t in stride(from: 0.0, through: 20.0, by: 1.0) {
            XCTAssertEqual(
                TimedLyricLine.activeIndex(in: lines, at: t),
                TimedLyricLine.playbackPosition(in: lines, at: t)?.lineIndex,
                "t=\(t) 两个入口应给出同一行"
            )
        }
    }

    // MARK: - firstTimestampIndex

    func testFirstTimestampIndexAfterTime() {
        let lines = [line(0), line(10), line(20)]
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 5, in: lines), 1)
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 10, in: lines), 2)
        // 实现把入参钳到 max(time,0) 后用严格 > 比较：after:-1 → targetTime 0 → 首个 time>0 的行是 index 1
        // （time==0 的首行被排除）。此为当前行为，锁定之；负 seek 不会发生，该 quirk 影响面为零。
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: -1, in: lines), 1)
        XCTAssertEqual(TimedLyricLine.firstTimestampIndex(after: 0, in: lines), 1)
        XCTAssertNil(TimedLyricLine.firstTimestampIndex(after: 25, in: lines))
    }

    // MARK: - progress（行内比例）

    func testProgressIsHalfwayMidLine() {
        // index 0 的 endTime 取下一时间戳 10，duration=10，currentTime=5 → 0.5。
        let lines = [line(0), line(10)]
        XCTAssertEqual(TimedLyricLine.progress(in: lines, index: 0, currentTime: 5), 0.5, accuracy: 0.0001)
    }

    func testProgressIsZeroAtLineStart() {
        let lines = [line(0), line(10)]
        XCTAssertEqual(TimedLyricLine.progress(in: lines, index: 0, currentTime: 0), 0, accuracy: 0.0001)
    }

    func testProgressZeroWhenIndexNotActive() {
        // currentTime=10 时当前行是 index 1，查询 index 0 的进度应为 0。
        let lines = [line(0), line(10)]
        XCTAssertEqual(TimedLyricLine.progress(in: lines, index: 0, currentTime: 10), 0, accuracy: 0.0001)
    }
}
