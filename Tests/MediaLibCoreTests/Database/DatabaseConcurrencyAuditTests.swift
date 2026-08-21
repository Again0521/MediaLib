import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级风险专项】
/// 审计目标：验证 `DatabaseManager` 内部串行同步队列 (`queue.sync`) 在高并发多任务写入下，
/// 是否会引发 UI 主队列长久阻塞或由于调度交替发生死锁。
/// 对应报告问题 ID：P0-1 (RISK-01)
final class DatabaseConcurrencyAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-DB-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("audit_library.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    /// 测试高并发多任务连续写和交叉读操作不崩溃、生死锁
    func testHighConcurrencyReadWriteDoesNotDeadlockOrThrow() throws {
        let db = try DatabaseManager(url: dbURL)
        
        // 创建模拟表
        try db.execute("""
            CREATE TABLE IF NOT EXISTS audit_test_media (
                id TEXT PRIMARY KEY,
                title TEXT,
                play_count INTEGER
            )
        """)

        let writeGroup = DispatchGroup()
        let readGroup = DispatchGroup()
        let concurrentQueue = DispatchQueue(label: "audit.concurrent.test", attributes: .concurrent)

        let totalWriters = 20
        let writesPerWriter = 50
        var writeErrors: [Error] = []
        let writeErrorLock = NSLock()

        // 发起高并发写
        for w in 0..<totalWriters {
            writeGroup.enter()
            concurrentQueue.async {
                do {
                    for i in 0..<writesPerWriter {
                        let id = "item-\(w)-\(i)"
                        try db.execute(
                            "INSERT OR REPLACE INTO audit_test_media (id, title, play_count) VALUES (?, ?, ?)",
                            bindings: [.text(id), .text("Title \(id)"), .int(Int64(i))]
                        )
                    }
                } catch {
                    writeErrorLock.lock()
                    writeErrors.append(error)
                    writeErrorLock.unlock()
                }
                writeGroup.leave()
            }
        }

        // 发起并发读（模拟主线程及试图刷新频次）
        var readErrors: [Error] = []
        let readErrorLock = NSLock()
        let totalReaders = 10
        let readsPerReader = 30

        for _ in 0..<totalReaders {
            readGroup.enter()
            concurrentQueue.async {
                do {
                    for _ in 0..<readsPerReader {
                        _ = try db.query("SELECT count(*) as cnt FROM audit_test_media") { row in
                            row.int(0)
                        }
                    }
                } catch {
                    readErrorLock.lock()
                    readErrors.append(error)
                    readErrorLock.unlock()
                }
                readGroup.leave()
            }
        }

        let writeTimeoutResult = writeGroup.wait(timeout: .now() + 15.0)
        let readTimeoutResult = readGroup.wait(timeout: .now() + 15.0)

        XCTAssertEqual(writeTimeoutResult, .success, "高并发写入未能预期完成，内部同步队列可能已发生死锁或极严重阻塞")
        XCTAssertEqual(readTimeoutResult, .success, "高并发读取未能预期完成，主线程或调用线程存在硬卡死风险")
        XCTAssertTrue(writeErrors.isEmpty, "并发写操作期间抛出了异常: \(writeErrors)")
        XCTAssertTrue(readErrors.isEmpty, "并发读操作期间抛出了异常: \(readErrors)")

        // 最终验证总记录数
        let totalRecords = try db.query("SELECT count(*) FROM audit_test_media") { $0.int(0) }.first ?? 0
        XCTAssertEqual(totalRecords, totalWriters * writesPerWriter, "写入的总数据行数出现半写入或数据丢失")
    }

    /// 测试主线程发起大量同步查询的响应延迟（审计 queue.sync 的 UI 延迟代价）
    func testMainThreadSyncLatencyUnderBackgroundHeavyWrites() async throws {
        let db = try DatabaseManager(url: dbURL)
        try db.execute("CREATE TABLE IF NOT EXISTS latency_test (id TEXT PRIMARY KEY, val TEXT)")

        let backgroundTask = Task.detached(priority: .background) {
            for i in 0..<1000 {
                try? db.execute("INSERT OR REPLACE INTO latency_test (id, val) VALUES (?, ?)", bindings: [.text("id-\(i)"), .text("long_string_payload_\(i)")])
            }
        }

        // 测量主调用线程连续发起 50 次单条读取的时长
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<50 {
            _ = try? db.query("SELECT val FROM latency_test WHERE id = ?", bindings: [.text("id-\(i)")]) { $0.string(0) }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        _ = await backgroundTask.result
        XCTAssertLessThan(elapsed, 1.0, "主调用线程由于 queue.sync 等待后台大吞吐写入产生了超过 1 秒的延迟，存在触发 macOS 彩球卡死的阻断风险")
    }
}
