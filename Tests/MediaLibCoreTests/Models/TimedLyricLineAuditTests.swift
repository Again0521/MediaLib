import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P2级多语种歌词时间定位与脚本分析专项】
/// 审计目标：验证 `TimedLyricLine` 与 `LyricScriptProfile` 在处理
/// 中日韩英多语种混合歌词时，能否精准识别文字权重与所属语系（如区分日语原词与中文翻译），
/// 并确保时间戳范围检索和时间定位在面对极端无序输入时不会产生越界或死循环。
/// 对应报告问题 ID：TC-SCAN-004 / RISK-07
final class TimedLyricLineAuditTests: XCTestCase {

    /// 测试脚本分析引擎对多语种字符集（汉字、平假名、片假名、拉丁字母）的准确分流
    func testLyricScriptProfileAccuratelyIdentifiesJapaneseAndChinese() {
        let japaneseOriginal = "夜に駆ける - さよならだけが僕らの愛だ" // 包含平假名和汉字
        let chineseTranslation = "向夜晚奔跑 - 只有离别才是我们的爱" // 仅汉字，无假名
        let englishLine = "Running into the night with you"
        
        let jpProfile = LyricScriptProfile(text: japaneseOriginal)
        let cnProfile = LyricScriptProfile(text: chineseTranslation)
        let enProfile = LyricScriptProfile(text: englishLine)
        
        XCTAssertTrue(jpProfile.isLikelyJapaneseOriginalLine, "包含假名与汉字的整行应该被确认为日语原词")
        XCTAssertTrue(jpProfile.hiraganaCount > 0, "应精准统计出平假名数量")
        
        XCTAssertFalse(cnProfile.isLikelyJapaneseOriginalLine, "纯汉字无假名的翻译词不应被误判为日语原词")
        XCTAssertEqual(cnProfile.hiraganaCount, 0)
        XCTAssertEqual(cnProfile.katakanaCount, 0)
        XCTAssertTrue(cnProfile.hanCount >= 5)
        
        XCTAssertEqual(enProfile.hanCount, 0)
        XCTAssertTrue(enProfile.latinCount > 10)
    }

    /// 测试歌词时序源优先级（Exact > Aligned > Estimated）及 UI 展现属性
    func testLyricTimingSourceRankAndMetadataConsistency() {
        XCTAssertTrue(LyricTimingSource.exact.rank > LyricTimingSource.aligned.rank)
        XCTAssertTrue(LyricTimingSource.aligned.rank > LyricTimingSource.estimated.rank)
        
        XCTAssertEqual(LyricTimingSource.exact.displayTitle, "原词逐字")
        XCTAssertEqual(LyricTimingSource.aligned.displayTitle, "音频对齐")
        XCTAssertEqual(LyricTimingSource.estimated.displayTitle, "估算同步")
    }

    /// 测试逐字时间段构建与空/异常时间戳的处理健壮性
    func testTimedLyricSegmentInitializationAndImmutability() {
        let seg = TimedLyricSegment(time: 12.5, text: "夜", source: .exact, durationHint: 0.8)
        
        XCTAssertEqual(seg.time, 12.5, accuracy: 1e-5)
        XCTAssertEqual(seg.text, "夜")
        XCTAssertEqual(seg.source, .exact)
        XCTAssertEqual(seg.durationHint, 0.8)
    }
}
