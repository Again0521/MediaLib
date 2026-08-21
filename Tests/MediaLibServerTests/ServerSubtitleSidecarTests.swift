import Foundation
import XCTest
@testable import MediaLibServer

/// 外挂字幕的命名解析与格式归一。
///
/// 这两件事决定了网页上"有没有字幕"和"默认选中哪条"：解析错语言会让默认轨选错，
/// 转换出错会让浏览器静默丢掉整条轨道——两种故障在服务端都是 200，只有在播放器
/// 里才看得见，所以必须在这一层钉死。
final class ServerSubtitleSidecarTests: XCTestCase {
    private func descriptor(_ fileName: String, stem: String = "影片", index: Int = 0) -> ServerSubtitleSidecar.Descriptor {
        ServerSubtitleSidecar.descriptor(mediaStem: stem, subtitleFileName: fileName, fallbackIndex: index)
    }

    func testParsesCommonChineseLanguageTokens() {
        XCTAssertEqual(descriptor("影片.chs.srt").language, "zh-Hans")
        XCTAssertEqual(descriptor("影片.sc.vtt").language, "zh-Hans")
        XCTAssertEqual(descriptor("影片.zh-CN.srt").language, "zh-Hans")
        XCTAssertEqual(descriptor("影片.cht.srt").language, "zh-Hant")
        XCTAssertEqual(descriptor("影片.zh-TW.vtt").language, "zh-Hant")
        XCTAssertEqual(descriptor("影片.zh.srt").language, "zh")
    }

    func testParsesOtherLanguagesAndModifiers() {
        XCTAssertEqual(descriptor("影片.eng.srt").language, "en")
        XCTAssertEqual(descriptor("影片.jpn.vtt").language, "ja")
        let forced = descriptor("影片.en.forced.srt")
        XCTAssertEqual(forced.language, "en")
        XCTAssertTrue(forced.label.contains("forced"), "修饰词要进标签，否则两条 en 轨看起来一模一样")
    }

    /// 解析不出语言时必须是 nil。声明一个错的语言会让默认轨选错，
    /// 比不声明更糟。
    func testUnknownTokensYieldNoLanguage() {
        XCTAssertNil(descriptor("影片.导演评论.srt").language)
        XCTAssertNil(descriptor("影片.srt").language)
        XCTAssertNil(descriptor("完全无关的名字.srt").language)
    }

    /// 没有后缀信息时退回带序号的标签，不能是空字符串。
    func testFallsBackToNumberedLabel() {
        XCTAssertEqual(descriptor("影片.vtt", index: 2).label, "字幕 3")
    }

    func testConvertsSRTTimingsToWebVTT() {
        let srt = """
        1
        00:00:01,000 --> 00:00:02,500
        第一行，带逗号

        2
        00:00:03,000 --> 00:00:04,000
        第二行
        """
        let vtt = ServerSubtitleSidecar.webVTT(fromSRT: srt)
        XCTAssertTrue(vtt.hasPrefix("WEBVTT\n\n"), "缺少头部时浏览器会丢掉整条轨道")
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:02.500"))
        XCTAssertTrue(vtt.contains("00:00:03.000 --> 00:00:04.000"))
        // 正文里的逗号不能被一起改成点号。
        XCTAssertTrue(vtt.contains("第一行，带逗号"))
    }

    func testHandlesCRLFAndKeepsInlineTags() {
        let srt = "1\r\n00:00:01,000 --> 00:00:02,000\r\n<i>斜体</i>\r\n"
        let vtt = ServerSubtitleSidecar.webVTT(fromSRT: srt)
        XCTAssertTrue(vtt.contains("00:00:01.000 --> 00:00:02.000"))
        XCTAssertTrue(vtt.contains("<i>斜体</i>"), "SRT 的 <i>/<b> 恰好也是 VTT 支持的标签")
        XCTAssertFalse(vtt.contains("\r"))
    }

    /// 已经是 VTT 的按内容嗅探原样返回，未知扩展名不做任何猜测——把不认识的
    /// 文本按 SRT 硬转会产出一份看似合法、实际错乱的字幕。
    func testPayloadSniffsContentBeforeTrustingExtension() {
        let vtt = Data("WEBVTT\n\n00:00:01.000 --> 00:00:02.000\n你好\n".utf8)
        XCTAssertEqual(ServerSubtitleSidecar.webVTTPayload(from: vtt, pathExtension: ""), vtt)
        XCTAssertEqual(ServerSubtitleSidecar.webVTTPayload(from: vtt, pathExtension: "srt"), vtt)

        let srt = Data("1\n00:00:01,000 --> 00:00:02,000\n你好\n".utf8)
        let converted = ServerSubtitleSidecar.webVTTPayload(from: srt, pathExtension: "srt")
        XCTAssertNotNil(converted)
        XCTAssertTrue(String(data: converted!, encoding: .utf8)!.hasPrefix("WEBVTT"))
        // 不是 VTT、扩展名也不是 srt：拒绝，而不是猜。
        XCTAssertNil(ServerSubtitleSidecar.webVTTPayload(from: srt, pathExtension: "ass"))
    }

    /// UTF-8 BOM 会变成正文第一个字符，让 `WEBVTT` 头部校验失败。
    func testStripsUTF8BOM() {
        let withBOM = Data([0xEF, 0xBB, 0xBF]) + Data("WEBVTT\n\n".utf8)
        let payload = ServerSubtitleSidecar.webVTTPayload(from: withBOM, pathExtension: "vtt")
        XCTAssertEqual(payload, Data("WEBVTT\n\n".utf8))
    }

    /// ASS/SSA 现在也在名单里：它们在 WebVTT 里有可翻译的对应表达（见
    /// `ServerASSSubtitle`），而在中日韩资料库里 `.ass` 恰恰是最常见的外挂格式。
    func testAcceptsVTTSRTAndASSExtensions() {
        XCTAssertEqual(ServerSubtitleSidecar.supportedExtensions, ["vtt", "srt", "ass", "ssa"])
    }
}
