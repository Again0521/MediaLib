import XCTest
@testable import MediaLibCore

// StableID 用 FNV-1a 生成稳定标识符；持久化主键依赖它「同输入永远同输出」，故重点测确定性与大小写无关。
final class StableIDTests: XCTestCase {
    func testDeterministicForSameInput() {
        XCTAssertEqual(
            StableID.make(prefix: "item", value: "/Movies/Inception.mkv"),
            StableID.make(prefix: "item", value: "/Movies/Inception.mkv")
        )
    }

    func testCaseInsensitiveValue() {
        // 实现对 value 做 lowercased()，大小写不同应得到相同 ID。
        XCTAssertEqual(
            StableID.make(prefix: "p", value: "ABC"),
            StableID.make(prefix: "p", value: "abc")
        )
    }

    func testPrefixIsPreserved() {
        let id = StableID.make(prefix: "source", value: "anything")
        XCTAssertTrue(id.hasPrefix("source_"))
    }

    func testDifferentValuesProduceDifferentIDs() {
        XCTAssertNotEqual(
            StableID.make(prefix: "p", value: "abc"),
            StableID.make(prefix: "p", value: "abd")
        )
    }

    func testSamePrefixDifferentValueDoNotCollideTrivially() {
        let a = StableID.make(prefix: "p", value: "1")
        let b = StableID.make(prefix: "p", value: "2")
        XCTAssertNotEqual(a, b)
    }

    func testHashIsHexEncoded() {
        let id = StableID.make(prefix: "p", value: "hello")
        let hexPart = id.replacingOccurrences(of: "p_", with: "")
        XCTAssertFalse(hexPart.isEmpty)
        XCTAssertTrue(hexPart.allSatisfy { $0.isHexDigit })
    }
}
