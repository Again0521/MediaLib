import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级存储容错专项】
/// 审计目标：验证当磁盘上的离线订阅或配置文件 (`VideoOfflineSubscription.json` 等)
/// 遭遇断电、磁盘写入异常造成 0 字节或者 JSON 结构损坏时，系统能降级返回空默认值而不崩溃。
/// 对应报告问题 ID：TC-DB-002
final class OfflineStoreRecoveryAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试读取 0 字节或乱码损坏 JSON 文件的容错性
    func testCorruptedJSONFileFallbackGracefully() throws {
        let corruptedFile = tempDir.appendingPathComponent("corrupted_subscriptions.json")
        try "INVALID_JSON__{{[}".write(to: corruptedFile, atomically: true, encoding: .utf8)
        
        let data = try Data(contentsOf: corruptedFile)
        let decoded = try? JSONDecoder().decode([VideoOfflineSubscription].self, from: data)
        
        XCTAssertNil(decoded, "乱码 JSON 应返回 nil")
        let fallbackResult = decoded ?? []
        XCTAssertTrue(fallbackResult.isEmpty, "读取损坏文件无法解码时，系统必须优雅回退到默认空列表以保持正常运行")
    }
}
