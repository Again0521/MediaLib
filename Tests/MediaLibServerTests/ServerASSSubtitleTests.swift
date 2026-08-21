import Foundation
import XCTest
@testable import MediaLibServer

/// ASS/SSA → WebVTT。
///
/// 这条路径的故障全都是"服务端 200、播放器里什么都没有"或者"字幕出现在错误的位置"：
/// 一个多余的空行会把后半句变成下一条 cue 的时间轴，一个漏掉的 `\N` 会让两行台词
/// 挤成一行，绘图指令的坐标数字会被当成台词显示。所以逐条钉死在这一层。
final class ServerASSSubtitleTests: XCTestCase {
    private func script(events: String, styles: String = "Style: Default,Arial,20,&H00FFFFFF,2") -> String {
        """
        [Script Info]
        ScriptType: v4.00+

        [V4+ Styles]
        Format: Name, Fontname, Fontsize, PrimaryColour, Alignment
        \(styles)

        [Events]
        Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
        \(events)
        """
    }

    func testConvertsDialogueTimingAndLineBreaks() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: #"Dialogue: 0,0:00:01.50,0:00:03.25,Default,,0,0,0,,第一行\N第二行"#
        )))
        XCTAssertTrue(output.hasPrefix("WEBVTT\n\n"))
        XCTAssertTrue(output.contains("00:00:01.500 --> 00:00:03.250"))
        XCTAssertTrue(output.contains("第一行\n第二行"), "\\N 是换行，不是两个字面字符")
    }

    /// 台词里几乎一定有逗号。按逗号切到第十个字段为止，之后整段都是正文。
    func testKeepsCommasInsideDialogueText() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,你好，世界，再见"
        )))
        XCTAssertTrue(output.contains("你好，世界，再见"))
    }

    func testTranslatesInlineEmphasisAndDropsOtherOverrides() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: #"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\i1\fs40\c&H00FF00&}强调{\i0}正常"#
        )))
        XCTAssertTrue(output.contains("<i>强调</i>正常"))
        XCTAssertFalse(output.contains("fs40"), "字号/颜色没有 WebVTT 对应物，只能丢掉，不能当台词显示")
    }

    /// 矢量绘图块整块丢弃。那些坐标数字不是台词——把它们显示出来比不显示更糟。
    func testDropsVectorDrawingBlocks() {
        let output = ServerASSSubtitle.webVTT(fromASS: script(
            events: #"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\p1}m 0 0 l 100 0 100 100{\p0}"#
        ))
        XCTAssertNil(output, "整份文件只有绘图时没有一句台词，应当明确失败而不是交一份空轨道")
    }

    /// `Comment:` 是作者关掉的行。
    func testSkipsCommentEvents() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(events: """
        Comment: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,这行不该出现
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,这行要出现
        """)))
        XCTAssertFalse(output.contains("这行不该出现"))
        XCTAssertTrue(output.contains("这行要出现"))
    }

    /// 位置是 ASS 与 SRT 的实质差别，也是从前"直接丢文本会产出错位字幕"那句话的
    /// 全部内容。屏幕字（`\an8`）必须落在顶部，不能和台词一起堆在底部。
    func testMapsAlignmentToCueSettings() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(events: """
        Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,{\\an8}顶部屏幕字
        Dialogue: 0,0:00:03.00,0:00:04.00,Default,,0,0,0,,底部台词
        """)))
        let topLine = output.components(separatedBy: "\n").first { $0.contains("00:00:01.000") }
        let bottomLine = output.components(separatedBy: "\n").first { $0.contains("00:00:03.000") }
        XCTAssertEqual(topLine?.contains("line:5%"), true)
        XCTAssertEqual(bottomLine?.contains("line:"), false, "底部是 WebVTT 的默认位置，不必声明")
    }

    /// 样式表里的对齐要生效：大量字幕组把屏幕字做成一个独立 Style 而不是逐行 `\an`。
    func testUsesStyleAlignmentWhenNoInlineOverride() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: "Dialogue: 0,0:00:01.00,0:00:02.00,Sign,,0,0,0,,屏幕字",
            styles: """
            Style: Default,Arial,20,&H00FFFFFF,2
            Style: Sign,Arial,20,&H00FFFFFF,8
            """
        )))
        XCTAssertTrue(output.contains("line:5%"))
    }

    /// WebVTT 要求 cue 按开始时间不降序。ASS 里"台词 + 屏幕字"经常是交错写的。
    func testOrdersCuesByStartTime() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(events: """
        Dialogue: 0,0:00:09.00,0:00:10.00,Default,,0,0,0,,后
        Dialogue: 0,0:00:02.00,0:00:03.00,Default,,0,0,0,,先
        """)))
        let first = try XCTUnwrap(output.range(of: "先"))
        let second = try XCTUnwrap(output.range(of: "后"))
        XCTAssertLessThan(first.lowerBound, second.lowerBound)
    }

    /// 正文里不能出现空行：WebVTT 用空行分隔 cue，出现一个就把后半句变成下一条
    /// cue 的时间轴，整轨从那里开始错乱。
    func testNeverEmitsBlankLinesInsideACue() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: #"Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,上\N\N下"#
        )))
        XCTAssertFalse(output.contains("上\n\n下"))
        XCTAssertTrue(output.contains("上\n下"))
    }

    func testEscapesHTMLSpecialCharacters() throws {
        let output = try XCTUnwrap(ServerASSSubtitle.webVTT(fromASS: script(
            events: "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,a < b & c"
        )))
        XCTAssertTrue(output.contains("a &lt; b &amp; c"))
    }

    /// 结束时间不晚于开始时间的行是坏数据，跳过它而不是交一条零长度 cue。
    func testRejectsNonPositiveDurations() {
        XCTAssertNil(ServerASSSubtitle.webVTT(fromASS: script(
            events: "Dialogue: 0,0:00:05.00,0:00:05.00,Default,,0,0,0,,零长度"
        )))
    }

    /// 归一入口按**内容**判格式：资料库里 `.srt` 里装着 ASS 的文件真实存在，
    /// 按扩展名硬转会产出一份看起来合法、实际错乱的字幕。
    func testPayloadSniffsASSContentRegardlessOfExtension() throws {
        let data = Data(script(
            events: "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,内容嗅探"
        ).utf8)
        let payload = try XCTUnwrap(ServerSubtitleSidecar.webVTTPayload(from: data, pathExtension: "srt"))
        let text = try XCTUnwrap(String(data: payload, encoding: .utf8))
        XCTAssertTrue(text.hasPrefix("WEBVTT"))
        XCTAssertTrue(text.contains("00:00:01.000 --> 00:00:02.000"))
        XCTAssertFalse(text.contains("Dialogue:"), "按 SRT 硬转会把整行原样留下")
    }

    func testPayloadConvertsASSExtension() throws {
        let data = Data(script(
            events: "Dialogue: 0,0:00:01.00,0:00:02.00,Default,,0,0,0,,扩展名"
        ).utf8)
        XCTAssertNotNil(ServerSubtitleSidecar.webVTTPayload(from: data, pathExtension: "ass"))
    }

    /// 不是 ASS、扩展名也不认识的文本一律拒绝——不做任何猜测。
    func testUnknownTextIsRejected() {
        let data = Data("这只是一段普通文本\n没有时间轴".utf8)
        XCTAssertNil(ServerSubtitleSidecar.webVTTPayload(from: data, pathExtension: "txt"))
    }
}
