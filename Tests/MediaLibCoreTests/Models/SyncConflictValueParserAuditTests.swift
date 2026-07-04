import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级同步冲突值多源格式兼容与范围校验专项】
/// 审计目标：验证 `SyncConflictValueParser` 在仲裁和同步来自不同远端服务（Emby, Plex, Jellyfin, Trakt）
/// 的布尔型状态（如 `watched`, `favorite`）与星级评分（`user_rating`）时，
/// 能否把多重异构表示法（如 `1/yes/on` 或 `unrated/none`）精细统一；
/// 并在遇到非法评级或越界值（如负数或大于 5 星）时百分之百抛错拦截，杜绝脏数据注入系统。
/// 对应报告问题 ID：TC-REMOTE-002
final class SyncConflictValueParserAuditTests: XCTestCase {

    /// 测试布尔值对多格式同义词的无缝兼容
    func testBooleanParserRecognizesVariousSynonyms() throws {
        let trueValues = ["true", " 1 ", "YES", "y", "On"]
        let falseValues = ["false", "0", "no\n", "N", "off"]
        
        for val in trueValues {
            XCTAssertTrue(try SyncConflictValueParser.boolean(val), "值 \(val) 应正确解析为 true")
        }
        for val in falseValues {
            XCTAssertFalse(try SyncConflictValueParser.boolean(val), "值 \(val) 应正确解析为 false")
        }
    }

    /// 测试布尔值遇到空值或非法字串必须抛错
    func testBooleanParserThrowsOnInvalidOrMissingValue() {
        XCTAssertThrowsError(try SyncConflictValueParser.boolean(nil)) { error in
            XCTAssertEqual(error as? SyncConflictValueParseError, .missingValue)
        }
        XCTAssertThrowsError(try SyncConflictValueParser.boolean("maybe")) { error in
            XCTAssertEqual(error as? SyncConflictValueParseError, .invalidBoolean("maybe"))
        }
    }

    /// 测试用户星级评级的归零清空与 0~5 范围边界钳制
    func testUserRatingParserClampsAndNullifiesCorrectly() throws {
        let nullWords = ["null", "nil", "None", "unrated", "clear", "0"]
        for w in nullWords {
            XCTAssertNil(try SyncConflictValueParser.userRating(w), "字串 \(w) 应当被清理归零为 nil")
        }
        
        XCTAssertEqual(try SyncConflictValueParser.userRating(" 4.5 "), 4.5)
        XCTAssertEqual(try SyncConflictValueParser.userRating("5"), 5.0)
        
        // 越界与异常检测
        XCTAssertThrowsError(try SyncConflictValueParser.userRating("5.1")) { error in
            XCTAssertEqual(error as? SyncConflictValueParseError, .invalidUserRating("5.1"))
        }
        XCTAssertThrowsError(try SyncConflictValueParser.userRating("-1")) { error in
            XCTAssertEqual(error as? SyncConflictValueParseError, .invalidUserRating("-1"))
        }
    }
}
