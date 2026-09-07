import XCTest
@testable import MediaLibCore

final class DatabaseTransactionAsyncTests: XCTestCase {
    private var dbURL: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-\(UUID().uuidString).sqlite")
        database = try DatabaseManager(url: dbURL)
        try database.execute("CREATE TABLE IF NOT EXISTS t (id INTEGER PRIMARY KEY, v TEXT)")
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func rowCount() throws -> Int {
        try database.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first ?? 0
    }

    func testTransactionAsyncCommitsWrites() async throws {
        try await database.transactionAsync {
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("a")])
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("b")])
        }
        let count = try rowCount()
        XCTAssertEqual(count, 2)
    }

    func testTransactionAsyncRollsBackOnThrow() async throws {
        struct Boom: Error {}
        do {
            try await database.transactionAsync {
                try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("x")])
                throw Boom()
            }
            XCTFail("expected throw")
        } catch is Boom {
            // 预期
        }
        // 抛错应回滚，不留下任何行
        let count = try rowCount()
        XCTAssertEqual(count, 0)
    }

    func testTransactionAsyncReturnsValue() async throws {
        let inserted = try await database.transactionAsync { () -> Int in
            try self.database.execute("INSERT INTO t (v) VALUES (?)", bindings: [.text("z")])
            return 42
        }
        XCTAssertEqual(inserted, 42)
        let count = try rowCount()
        XCTAssertEqual(count, 1)
    }

    func testCancelledTransactionRollsBackBeforeCommit() async throws {
        let blocker = DispatchSemaphore(value: 0)
        let entered = DispatchSemaphore(value: 0)
        let task = Task {
            try await database.transactionAsync {
                try self.database.execute("INSERT INTO t (v) VALUES ('cancelled')")
                entered.signal()
                blocker.wait()
            }
        }
        XCTAssertEqual(entered.wait(timeout: .now() + 2), .success)
        task.cancel()
        blocker.signal()
        do {
            try await task.value
            XCTFail("expected cancellation")
        } catch is CancellationError {
            // Expected: cancellation is checked before COMMIT and the transaction rolls back.
        }
        XCTAssertEqual(try rowCount(), 0)
    }

    func testBackupSnapshotRemainsUsableWithInjectedContentionConfiguration() async throws {
        try database.execute("INSERT INTO t (v) VALUES ('source')")
        let snapshotConnection = try DatabaseManager(
            url: dbURL,
            contentionConfiguration: .init(
                lockWaitMilliseconds: 75,
                backupStepWaitMilliseconds: 90,
                retrySleepMilliseconds: 5
            )
        )
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-backup-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: backupDirectory) }

        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let primaryDatabase = try XCTUnwrap(database)
        let writer = Task.detached {
            try primaryDatabase.transaction {
                try primaryDatabase.execute("INSERT INTO t (v) VALUES ('uncommitted')")
                writerEntered.signal()
                releaseWriter.wait()
            }
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 2), .success)
        defer { releaseWriter.signal() }
        let backupURL = try await snapshotConnection.createBackupAsync(
            in: backupDirectory,
            reason: "contention-test"
        )
        releaseWriter.signal()
        try await writer.value

        let reopened = try DatabaseManager(
            url: backupURL,
            contentionConfiguration: .init(
                lockWaitMilliseconds: 75,
                backupStepWaitMilliseconds: 90,
                retrySleepMilliseconds: 5
            )
        )
        XCTAssertEqual(
            try reopened.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first,
            1,
            "WAL backup must contain a committed snapshot, not the concurrent uncommitted row"
        )
        try await reopened.performAsync {
            try reopened.execute("INSERT INTO t (v) VALUES ('reopened')")
        }
        XCTAssertEqual(
            try reopened.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first,
            2
        )
    }

    func testRestoreKeepsInjectedContentionConfigurationAndRecoversAfterTimeout() async throws {
        try database.execute("INSERT INTO t (v) VALUES ('backup-source')")
        let backupDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-restore-source-\(UUID().uuidString)", isDirectory: true)
        let safetyDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-restore-safety-\(UUID().uuidString)", isDirectory: true)
        let restoredURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("txn-async-restored-\(UUID().uuidString).sqlite")
        defer {
            try? FileManager.default.removeItem(at: backupDirectory)
            try? FileManager.default.removeItem(at: safetyDirectory)
            try? FileManager.default.removeItem(at: restoredURL)
        }

        let backupURL = try database.createBackup(in: backupDirectory, reason: "restore-config")
        let restored = try DatabaseManager(
            url: restoredURL,
            contentionConfiguration: .init(
                lockWaitMilliseconds: 55,
                backupStepWaitMilliseconds: 70,
                retrySleepMilliseconds: 5
            )
        )
        try restored.restore(from: backupURL, safetyBackupDirectory: safetyDirectory)
        XCTAssertEqual(try restored.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first, 1)

        let locker = try DatabaseManager(url: restoredURL)
        let writerEntered = DispatchSemaphore(value: 0)
        let releaseWriter = DispatchSemaphore(value: 0)
        let writer = Task.detached {
            try locker.transaction {
                try locker.execute("INSERT INTO t (v) VALUES ('locker')")
                writerEntered.signal()
                releaseWriter.wait()
            }
        }
        XCTAssertEqual(writerEntered.wait(timeout: .now() + 2), .success)
        defer { releaseWriter.signal() }

        let start = DispatchTime.now().uptimeNanoseconds
        do {
            try await restored.performAsync {
                try restored.execute("INSERT INTO t (v) VALUES ('must-time-out')")
            }
            XCTFail("expected bounded contention timeout after restore")
        } catch let error as DatabaseError {
            XCTAssertTrue(error.isRetryableContention)
        }
        let elapsedMilliseconds = Int((DispatchTime.now().uptimeNanoseconds - start) / 1_000_000)
        XCTAssertGreaterThanOrEqual(elapsedMilliseconds, 45)
        XCTAssertLessThan(elapsedMilliseconds, 500)
        XCTAssertGreaterThanOrEqual(restored.contentionMetrics().timeoutCount, 1)

        releaseWriter.signal()
        try await writer.value
        try await restored.performAsync {
            try restored.execute("INSERT INTO t (v) VALUES ('after-timeout')")
        }
        XCTAssertEqual(try restored.query("SELECT COUNT(*) FROM t") { $0.int(0) ?? 0 }.first, 3)
    }
}
