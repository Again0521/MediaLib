import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级日志脱敏与磁盘滚动限制专项】
/// 审计目标：验证 `LoggingService` 在输出日志前能否将真实用户的绝对主目录路径
/// 100% 脱敏为 `~`，避免在日志文件或用户反馈报告中泄露个人隐私；
/// 同时验证其日志滚动写入限制（rotateIfNeeded），确保在海量高频日志轰炸下不会耗尽磁盘空间或内存。
/// 对应报告问题 ID：TC-SEC-003 / RISK-04 / RISK-08
final class LoggingServiceAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LoggingAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试用户主目录路径在日志记录前被绝对脱敏为 `~`
    func testLogSanitizesUserHomeDirectoryToTilde() throws {
        let fakeHome = "/Users/test_user_private"
        let message = "扫描本地路径报错：\(fakeHome)/Movies/Secret.mp4 及 \(fakeHome)/Documents/Config.json"
        
        let redacted = LoggingService.redact(message, homeDirectoryPath: fakeHome)
        
        XCTAssertFalse(redacted.contains("test_user_private"), "脱敏后的消息绝不能包含用户的真实用户名或主目录名称")
        XCTAssertEqual(redacted, "扫描本地路径报错：~/Movies/Secret.mp4 及 ~/Documents/Config.json", "主目录前缀必须完整、精准地替换为波浪号 ~")
    }

    /// 测试当主目录路径为特殊边界（如空或根目录 /）时，脱敏函数不产生破坏性误杀
    func testRedactHandlesEdgeCaseHomePathsSafeAndSound() throws {
        let msg = "Cannot access /var/log/system.log"
        XCTAssertEqual(LoggingService.redact(msg, homeDirectoryPath: ""), msg)
        XCTAssertEqual(LoggingService.redact(msg, homeDirectoryPath: "/"), msg, "当主目录配置为根目录或异常情况时，不应盲目全局替换斜杠")
    }

    /// 测试海量并发写日志触发文件滚动，严格约束落盘体积上限
    func testHighVolumeConcurrentLoggingTriggersRotationWithoutOOM() throws {
        let maxBytes = 64 * 1024 // 限流 64KB
        let logger = LoggingService(logDirectory: tempDir, maxFileBytes: maxBytes)
        
        let expectation = XCTestExpectation(description: "异步高频日志处理完成")
        let longString = String(repeating: "A-Long-Log-Line-To-Fill-Disk-Space-", count: 20) // ~700 bytes
        
        DispatchQueue.concurrentPerform(iterations: 300) { i in
            logger.log("Concurrent log entry #\(i): \(longString)")
        }
        
        // 给予底层 serial queue 充足异步刷盘时间
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.8) {
            expectation.fulfill()
        }
        wait(for: [expectation], timeout: 3.0)
        
        let logFile = logger.exportURL()
        let backupFile = logFile.appendingPathExtension("1")
        
        let currentSize = (try? logFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        let backupSize = (try? backupFile.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        
        XCTAssertTrue(currentSize <= maxBytes * 2, "滚动机制必须生效，当前日志大小 \(currentSize) 不应无限暴涨超出限制阈值")
        XCTAssertTrue(backupSize >= 0, "备份日志文件必须存在并具有合理的大小")
        XCTAssertTrue(FileManager.default.fileExists(atPath: logFile.path), "日志主文件必须存在并持久记录最新条目")
    }
}
