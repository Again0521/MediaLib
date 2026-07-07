import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0/P2级边界与容错专项】
/// 审计目标：验证 `FilenameParser` 与文件遍历器对多语言复杂特殊字符串、
/// 多方括号标签、中日文混搭及超长层级目录的解析精确度与抗崩溃能力。
/// 对应报告问题 ID：TC-SCAN-001 / RISK-09
final class MediaScannerBoundaryAuditTests: XCTestCase {

    /// 测试超复杂动漫发布组混搭全角字符与多重方括号不致正则死循环或提取失误
    func testFilenameParserWithComplexSpecialCharsAndBrackets() {
        let complexFilename = "[BD-1080p] [动漫屋·独家压制] 🔥进击的巨人 Final Season Part 3 [2023] [HEVC_FLAC_2.0][中日双语内嵌] [修正版].mkv"
        let parsed = FilenameParser().parse(url: URL(fileURLWithPath: "/Anime/" + complexFilename))
        
        XCTAssertFalse(parsed.title.isEmpty, "复杂特殊文件名未能正确解析出清洁标题")
        XCTAssertEqual(parsed.title, "进击的巨人 Final Season Part 3", "未能滤除前后多重发布组与技术规格方括号")
        XCTAssertEqual(parsed.year, 2023, "未能正确从方括号中提取发布年份")
    }

    /// 测试连续 50 层方括号嵌套下的正则或算法抗栈溢出/挂起能力
    func testFilenameParserWithExtremeBracketNestingDoesNotHang() {
        let extremeBrackets = String(repeating: "[Tag]", count: 80) + " My Movie Title (2024).mp4"
        
        let start = CFAbsoluteTimeGetCurrent()
        let parsed = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + extremeBrackets))
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        
        XCTAssertLessThan(elapsed, 0.1, "80 重标签文件名处理造成了耗时暴增 (\(elapsed)s)，存在灾难性回溯 (ReDoS) 隐患")
        XCTAssertEqual(parsed.year, 2024)
        XCTAssertEqual(parsed.title, "My Movie Title")
    }

    /// 测试包含 Emoji、各种全半角引号及特殊操作符文件名
    func testFilenameParserWithEmojisAndSymbols() {
        let emojiFile = "🚀🔥✨ [2025新春特别篇] 快乐生活与编程！(2025) #4K UHD.mp4"
        let parsed = FilenameParser().parse(url: URL(fileURLWithPath: "/Movies/" + emojiFile))
        
        XCTAssertEqual(parsed.year, 2025)
        XCTAssertTrue(parsed.title.contains("快乐生活与编程"), "未能正确提取中文字符")
    }
}
