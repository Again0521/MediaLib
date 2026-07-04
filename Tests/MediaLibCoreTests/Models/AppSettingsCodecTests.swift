import XCTest
@testable import MediaLibCore

// AppSettings 编解码安全网（报告 10）：设置随版本演进增删字段，自定义 decoder 用 decodeIfPresent ?? default。
// 锁定：① 默认值 round-trip 稳定；② 缺键/空 JSON → 默认（旧配置缺新字段仍能加载，不丢设置/不崩）；
// ③ 未知键被忽略（装了新版存了字段、回退旧版仍能读）；④ 非默认值能在 round-trip 后保留。
final class AppSettingsCodecTests: XCTestCase {
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func testDefaultSettingsRoundTrip() throws {
        let original = AppSettings()
        let data = try encoder.encode(original)
        let decoded = try decoder.decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded, original)
    }

    func testEmptyJSONDecodesToDefaults() throws {
        // 关键迁移用例：完全没有任何键时，应得到一份全默认设置，而不是抛错。
        let decoded = try decoder.decode(AppSettings.self, from: Data("{}".utf8))
        XCTAssertEqual(decoded, AppSettings())
    }

    func testUnknownKeysAreIgnored() throws {
        // 新版本写入的、旧版本不认识的键应被安全忽略（前向兼容）。
        let json = #"{"someRemovedOrFutureKey": 123, "anotherUnknown": "x"}"#
        let decoded = try decoder.decode(AppSettings.self, from: Data(json.utf8))
        XCTAssertEqual(decoded, AppSettings())
    }

    func testNonDefaultFieldSurvivesRoundTrip() throws {
        let modified = AppSettings(watchedThreshold: 0.42)
        XCTAssertNotEqual(modified, AppSettings(), "前置条件：0.42 应与默认 watchedThreshold 不同")

        let data = try encoder.encode(modified)
        let decoded = try decoder.decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.watchedThreshold, 0.42, accuracy: 0.0001)
        XCTAssertEqual(decoded, modified)
    }

    func testPartialJSONKeepsKnownFieldAndDefaultsTheRest() throws {
        // 只编码一个改了的字段，解码后该字段保留、其余回落默认（等价于「旧配置只有部分键」）。
        let modified = AppSettings(watchedThreshold: 0.31)
        let data = try encoder.encode(modified)
        let decoded = try decoder.decode(AppSettings.self, from: data)
        XCTAssertEqual(decoded.watchedThreshold, 0.31, accuracy: 0.0001)
        XCTAssertEqual(decoded.skipInterval, AppSettings().skipInterval, accuracy: 0.0001)
    }
}
