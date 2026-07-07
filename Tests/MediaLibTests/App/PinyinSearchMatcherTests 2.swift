import XCTest
@testable import MediaLib

// 搜索匹配回归测试：PinyinSearchMatcher 支撑全局/音乐搜索的「子串 + 全拼 + 首字母」匹配（用户最常用入口）。
// 在 GUI 目标，经 @testable import MediaLib 测试。拼音用 CFStringTransform（macOS 稳定），锁定文档承诺的行为。
final class PinyinSearchMatcherTests: XCTestCase {
    func testEmptyQueryMatchesEverything() {
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "", in: ["anything"]))
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "   ", in: ["anything"]))
    }

    func testLatinSubstringMatchIsCaseInsensitive() {
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "break", in: ["Breaking Bad"]))
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "BREAK", in: ["Breaking Bad"]))
    }

    func testNonMatchingQueryReturnsFalse() {
        XCTAssertFalse(PinyinSearchMatcher.matches(query: "zzz", in: ["Breaking Bad"]))
    }

    func testLatinInitialsMatch() {
        // 文档承诺："bb" 命中 "Breaking Bad"（首字母）。
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "bb", in: ["Breaking Bad"]))
    }

    func testFullPinyinMatchesChinese() {
        // "北京" → 拼音 "beijing"。
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "beijing", in: ["北京"]))
    }

    func testPinyinInitialsMatchChinese() {
        // "北京" → 首字母 "bj"。
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "bj", in: ["北京"]))
    }

    func testCJKQueryUsesSubstringNotPinyin() {
        // 中文 query 直接走子串匹配。
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "京", in: ["北京"]))
        XCTAssertFalse(PinyinSearchMatcher.matches(query: "沪", in: ["北京"]))
    }

    func testNilAndEmptyFieldsAreSkipped() {
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "box", in: [nil, "", "a box here"]))
        XCTAssertFalse(PinyinSearchMatcher.matches(query: "box", in: [nil, ""]))
    }

    func testMatchesAcrossMultipleFields() {
        // 任意一项命中即算命中（如 title 不中但 artist 中）。
        XCTAssertTrue(PinyinSearchMatcher.matches(query: "mozart", in: ["Symphony No.40", "Mozart"]))
    }
}
