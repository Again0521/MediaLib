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

    func testCreateBackupAsyncProducesExistingFile() async throws {
        let db = try DatabaseManager(url: dbURL)
        let backupDir = workDir.appendingPathComponent("async-backups", isDirectory: true)

        let backupURL = try await db.createBackupAsync(in: backupDir, reason: "async-unit-test")

        XCTAssertTrue(FileManager.default.fileExists(atPath: backupURL.path))
        XCTAssertTrue(backupURL.lastPathComponent.hasPrefix("MediaLib-async-unit-test-"))
    }

    func testCreateBackupAsyncPropagatesDirectoryCreationFailure() async throws {
        let db = try DatabaseManager(url: dbURL)
        let fileURL = workDir.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: fileURL)

        do {
            _ = try await db.createBackupAsync(in: fileURL, reason: "should-fail")
            XCTFail("Expected backup creation to fail when destination is a file")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testOpeningOlderExistingDatabaseCreatesAutomaticPreMigrationBackup() throws {
        let oldVersion = DatabaseManager.currentSchemaVersion - 1
        do {
            let db = try DatabaseManager(url: dbURL)
            try db.execute("PRAGMA user_version = \(oldVersion)")
        }
        let backupDir = workDir.appendingPathComponent("migration-backups", isDirectory: true)

        let migrated = try DatabaseManager(url: dbURL, backupDirectory: backupDir)

        XCTAssertEqual(try migrated.schemaVersion(), DatabaseManager.currentSchemaVersion)
        let backups = try automaticBackups(in: backupDir)
        XCTAssertEqual(backups.count, 1)
        XCTAssertTrue(
            backups[0].lastPathComponent.hasPrefix(
                "MediaLib-auto-pre-migration-v\(oldVersion)-to-v\(DatabaseManager.currentSchemaVersion)-"
            )
        )
        XCTAssertGreaterThan(fileSize(at: backups[0]), 0)
    }

    func testAutomaticMigrationPrunesOldAutomaticBackupsButKeepsManualBackups() throws {
        let oldVersion = DatabaseManager.currentSchemaVersion - 1
        let backupDir = workDir.appendingPathComponent("pruned-migration-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let manualBackup = backupDir.appendingPathComponent("MediaLib-manual-keep.sqlite")
        try Data("manual".utf8).write(to: manualBackup)

        for index in 0..<7 {
            let oldBackup = backupDir.appendingPathComponent("MediaLib-auto-pre-migration-old-\(index).sqlite")
            try Data("old-\(index)".utf8).write(to: oldBackup)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index + 1))],
                ofItemAtPath: oldBackup.path
            )
        }
        do {
            let db = try DatabaseManager(url: dbURL)
            try db.execute("PRAGMA user_version = \(oldVersion)")
        }

        _ = try DatabaseManager(url: dbURL, backupDirectory: backupDir)

        let backups = try automaticBackups(in: backupDir)
        let backupNames = Set(backups.map(\.lastPathComponent))
        XCTAssertEqual(backups.count, 5)
        XCTAssertTrue(FileManager.default.fileExists(atPath: manualBackup.path))
        XCTAssertTrue(backupNames.contains { $0.hasPrefix("MediaLib-auto-pre-migration-v\(oldVersion)-to-v\(DatabaseManager.currentSchemaVersion)-") })
        XCTAssertTrue(backupNames.contains("MediaLib-auto-pre-migration-old-3.sqlite"))
        XCTAssertTrue(backupNames.contains("MediaLib-auto-pre-migration-old-4.sqlite"))
        XCTAssertTrue(backupNames.contains("MediaLib-auto-pre-migration-old-5.sqlite"))
        XCTAssertTrue(backupNames.contains("MediaLib-auto-pre-migration-old-6.sqlite"))
        XCTAssertFalse(backupNames.contains("MediaLib-auto-pre-migration-old-0.sqlite"))
        XCTAssertFalse(backupNames.contains("MediaLib-auto-pre-migration-old-1.sqlite"))
        XCTAssertFalse(backupNames.contains("MediaLib-auto-pre-migration-old-2.sqlite"))
    }

    private func automaticBackups(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter {
            $0.lastPathComponent.hasPrefix("MediaLib-auto-pre-migration-") &&
                $0.pathExtension == "sqlite"
        }
    }

    private func fileSize(at url: URL) -> Int {
        (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0
    }
}
