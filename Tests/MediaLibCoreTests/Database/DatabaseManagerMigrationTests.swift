import XCTest
@testable import MediaLibCore

// 数据库迁移安全网（报告 10 高价值用例）：历史发生过「数据库版本 18 高于支持 9 无法恢复」的版本砖事故。
// 这些用例锁定：① 新库迁到当前版本；② 重开幂等；③ 比应用新的库抛出可识别的 databaseNewerThanApp（供 UI 友好提示，而非损坏）。
final class DatabaseManagerMigrationTests: XCTestCase {
    private var workDir: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibCoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let workDir { try? FileManager.default.removeItem(at: workDir) }
    }

    private var dbURL: URL { workDir.appendingPathComponent("library.sqlite") }

    func testFreshDatabaseMigratesToCurrentVersion() throws {
        let db = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try db.schemaVersion(), DatabaseManager.currentSchemaVersion)
    }

    func testReopeningExistingDatabaseIsIdempotent() throws {
        do {
            let first = try DatabaseManager(url: dbURL)
            XCTAssertEqual(try first.schemaVersion(), DatabaseManager.currentSchemaVersion)
        } // first 释放 → 连接关闭

        let second = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try second.schemaVersion(), DatabaseManager.currentSchemaVersion)
    }

    func testFreshDatabasePassesIntegrityCheck() throws {
        let db = try DatabaseManager(url: dbURL)
        XCTAssertNoThrow(try db.validateCurrentDatabase())
    }

    func testDatabaseNewerThanAppThrowsRecognizableError() throws {
        // 先正常建库迁到当前版本，再把 user_version 人为顶到未来版本，模拟「旧应用打开新库」。
        do {
            let db = try DatabaseManager(url: dbURL)
            try db.execute("PRAGMA user_version = 999")
        }

        XCTAssertThrowsError(try DatabaseManager(url: dbURL)) { error in
            guard case DatabaseError.databaseNewerThanApp(let found, let supported) = error else {
                return XCTFail("应抛出 databaseNewerThanApp，实际为 \(error)")
            }
            XCTAssertEqual(found, 999)
            XCTAssertEqual(supported, DatabaseManager.currentSchemaVersion)
        }
    }

    func testCreateBackupProducesExistingFile() throws {
        let db = try DatabaseManager(url: dbURL)
        let backupDir = workDir.appendingPathComponent("backups", isDirectory: true)
        let backupURL = try db.createBackup(in: backupDir, reason: "unit-test")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
    }
}
