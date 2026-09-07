import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级风险专项】
/// 审计目标：验证 `DatabaseManager` 内部串行同步队列 (`queue.sync`) 在高并发多任务写入下，
/// 是否会引发 UI 主队列长久阻塞或由于调度交替发生死锁。
/// 对应报告问题 ID：P0-1 (RISK-01)
final class DatabaseConcurrencyAuditTests: XCTestCase {
    private final class InvocationCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0

        func increment() {
            lock.lock()
            count += 1
            lock.unlock()
        }

        var value: Int {
            lock.lock()
            defer { lock.unlock() }
            return count
        }
    }

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

    private func waitUntilContention(on database: DatabaseManager) async -> Bool {
        for _ in 0..<200 {
            if database.contentionMetrics().contentionCount > 0 { return true }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        return false
    }

    func testIndependentConnectionWaitsForWriterThenExecutesTransactionExactlyOnce() async throws {
        let first = try DatabaseManager(url: dbURL)
        let second = try DatabaseManager(
            url: dbURL,
            contentionConfiguration: .init(lockWaitMilliseconds: 800, retrySleepMilliseconds: 5)
        )
        try first.execute("CREATE TABLE lock_test (id TEXT PRIMARY KEY)")
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try first.transaction {
                try first.execute("INSERT INTO lock_test VALUES ('holder')")
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 2), .success)
        defer { releaseLock.signal() }

        let invocationCount = InvocationCounter()
        let writer = Task {
            try await second.transactionAsync {
                invocationCount.increment()
                try second.execute("INSERT INTO lock_test VALUES ('waiter')")
            }
        }
        let observedContention = await waitUntilContention(on: second)
        XCTAssertTrue(observedContention)
        releaseLock.signal()
        try await writer.value
        try await holder.value

        XCTAssertEqual(invocationCount.value, 1, "busy wait must not replay the transaction closure")
        XCTAssertEqual(
            try second.query("SELECT COUNT(*) FROM lock_test") { $0.int(0) ?? 0 }.first,
            2
        )
        let metrics = second.contentionMetrics()
        XCTAssertGreaterThanOrEqual(metrics.contentionCount, 1)
        XCTAssertGreaterThan(metrics.waitedMilliseconds, 0)
        XCTAssertEqual(metrics.timeoutCount, 0)
    }

    func testIndependentConnectionTimesOutWithStructuredCodeAndAtomicRollback() async throws {
        let first = try DatabaseManager(url: dbURL)
        let second = try DatabaseManager(
            url: dbURL,
            contentionConfiguration: .init(lockWaitMilliseconds: 60, retrySleepMilliseconds: 5)
        )
        try first.execute("CREATE TABLE timeout_test (id TEXT PRIMARY KEY)")
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try first.transaction {
                try first.execute("INSERT INTO timeout_test VALUES ('holder')")
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 2), .success)
        defer { releaseLock.signal() }

        do {
            try await second.transactionAsync {
                try second.execute("INSERT INTO timeout_test VALUES ('must-rollback')")
            }
            XCTFail("expected bounded contention failure")
        } catch let error as DatabaseError {
            guard case let .contention(operation, code, extendedCode) = error else {
                return XCTFail("unexpected database error: \(error)")
            }
            XCTAssertEqual(operation, "step")
            XCTAssertTrue(code == 5 || code == 6)
            XCTAssertEqual(extendedCode & 0xff, code)
            XCTAssertTrue(error.isRetryableContention)
            XCTAssertFalse(error.localizedDescription.contains(dbURL.path))
            XCTAssertFalse(error.localizedDescription.contains("INSERT"))
        }
        XCTAssertEqual(
            try second.query("SELECT COUNT(*) FROM timeout_test WHERE id = 'must-rollback'") { $0.int(0) ?? 0 }.first,
            0
        )
        let metrics = second.contentionMetrics()
        XCTAssertGreaterThanOrEqual(metrics.contentionCount, 1)
        XCTAssertGreaterThanOrEqual(metrics.timeoutCount, 1)
        releaseLock.signal()
        try await holder.value
    }

    @MainActor
    func testMainActorRemainsSchedulableWhileAsyncDatabaseWriteWaits() async throws {
        let first = try DatabaseManager(url: dbURL)
        let second = try DatabaseManager(
            url: dbURL,
            contentionConfiguration: .init(lockWaitMilliseconds: 800, retrySleepMilliseconds: 5)
        )
        try first.execute("CREATE TABLE main_actor_test (id TEXT PRIMARY KEY)")
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let holder = Task.detached {
            try first.transaction {
                try first.execute("INSERT INTO main_actor_test VALUES ('holder')")
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 2), .success)
        defer { releaseLock.signal() }
        let writer = Task {
            try await second.performAsync {
                try second.execute("INSERT INTO main_actor_test VALUES ('waiter')")
            }
        }
        let observedContention = await waitUntilContention(on: second)
        XCTAssertTrue(observedContention)

        let heartbeat = expectation(description: "main actor heartbeat")
        DispatchQueue.main.async { heartbeat.fulfill() }
        await fulfillment(of: [heartbeat], timeout: 1)

        releaseLock.signal()
        try await writer.value
        try await holder.value
    }

    func testDesktopScanWriterAndServerPlaybackProgressSerializeAcrossConnections() async throws {
        let desktop = try DatabaseManager(url: dbURL)
        let server = try DatabaseManager(
            url: dbURL,
            contentionConfiguration: .init(lockWaitMilliseconds: 800, retrySleepMilliseconds: 5)
        )
        try MediaRepository(database: desktop).upsert(MediaItem(id: "movie-1", type: .movie, title: "Before Scan"))
        let lockAcquired = DispatchSemaphore(value: 0)
        let releaseLock = DispatchSemaphore(value: 0)
        let scan = Task.detached {
            try desktop.transaction {
                try desktop.execute(
                    "UPDATE media_items SET title = ? WHERE id = ?",
                    bindings: [.text("After Scan"), .text("movie-1")]
                )
                lockAcquired.signal()
                releaseLock.wait()
            }
        }
        XCTAssertEqual(lockAcquired.wait(timeout: .now() + 2), .success)
        defer { releaseLock.signal() }
        let progress = Task {
            try await server.performAsync {
                try ServerUserMediaStateRepository(database: server).update(
                    userID: ServerIdentityRepository.initialAdministratorUserID,
                    mediaID: "movie-1",
                    event: .progress,
                    position: 30,
                    duration: 100
                )
            }
        }
        let observedContention = await waitUntilContention(on: server)
        XCTAssertTrue(observedContention)
        releaseLock.signal()
        let state = try await progress.value
        try await scan.value

        XCTAssertEqual(state.playProgress, 0.3, accuracy: 0.0001)
        XCTAssertEqual(
            try server.query("SELECT title FROM media_items WHERE id = 'movie-1'") { $0.string(0) }.first,
            "After Scan"
        )
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
