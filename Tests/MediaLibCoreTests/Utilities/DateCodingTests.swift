import XCTest
@testable import MediaLibCore

// DateCoding 是 DB/同步层日期的统一 ISO8601（含毫秒）编解码；round-trip 与 nil/空串/非法串的边界最关键。
final class DateCodingTests: XCTestCase {
    func testRoundTripPreservesMillisecondPrecision() {
        let original = Date(timeIntervalSince1970: 1_700_000_000.123)
        guard let encoded = DateCoding.string(from: original),
              let decoded = DateCoding.date(from: encoded) else {
            return XCTFail("round-trip 不应返回 nil")
        }
        XCTAssertEqual(decoded.timeIntervalSince1970, original.timeIntervalSince1970, accuracy: 0.001)
    }

    func testNilDateEncodesToNil() {
        XCTAssertNil(DateCoding.string(from: nil))
    }

    func testNilAndEmptyStringDecodeToNil() {
        XCTAssertNil(DateCoding.date(from: nil))
        XCTAssertNil(DateCoding.date(from: ""))
        XCTAssertNil(DateCoding.date(from: " \n\t "))
    }

    func testDateDecodingTrimsWhitespaceAroundISO8601String() throws {
        let decoded = try XCTUnwrap(DateCoding.date(from: " \n1970-01-01T00:00:00.000Z\t"))

        XCTAssertEqual(decoded.timeIntervalSince1970, 0, accuracy: 0.001)
    }

    func testInvalidStringDecodesToNil() {
        XCTAssertNil(DateCoding.date(from: "not-a-real-date"))
        XCTAssertNil(DateCoding.date(from: "2026/06/24"))   // 非 ISO8601 分隔符
    }

    func testEncodedStringIsISO8601() {
        let date = Date(timeIntervalSince1970: 0)   // 1970-01-01T00:00:00Z
        let encoded = DateCoding.string(from: date)
        XCTAssertEqual(encoded?.hasPrefix("1970-01-01T"), true)
    }
}
