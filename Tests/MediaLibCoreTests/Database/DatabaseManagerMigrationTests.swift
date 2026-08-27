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

    /// 歌词存在性能写进去、能读回来，而且能从"有"改回"没有"。
    ///
    /// 这一列是加在一条 43 列、按位置绑定的 upsert 上的：少一个占位符、绑错一个
    /// 位置，症状不是编译失败，而是从这条语句往后每一列都读到上一列的值。所以
    /// 这里连同前后几列一起断言，位置错位会立刻暴露。
    ///
    /// 「改回没有」单独验一次：外挂歌词被删掉之后必须能落回 0，如果那条
    /// ON CONFLICT 写成了 COALESCE，这个用例就会挂。
    func testLyricsPresenceRoundTripsAndCanBeClearedAgain() throws {
        let db = try DatabaseManager(url: dbURL)
        let repository = MediaRepository(database: db)
        let track = MediaItem(
            id: "track-1",
            type: .music,
            title: "有歌词的曲目",
            artist: "艺术家",
            album: "专辑",
            sourcePath: "/tmp/music",
            filePath: "/tmp/music/track.mp3",
            genre: "流行",
            hasLyrics: true
        )
        try repository.upsert(track)

        let stored = try XCTUnwrap(try repository.fetch(id: "track-1"))
        XCTAssertTrue(stored.hasLyrics)
        // 相邻列没有整体挪位。
        XCTAssertEqual(stored.genre, "流行")
        XCTAssertEqual(stored.title, "有歌词的曲目")
        XCTAssertEqual(stored.artist, "艺术家")
        XCTAssertEqual(stored.filePath, "/tmp/music/track.mp3")

        var cleared = stored
        cleared.hasLyrics = false
        try repository.upsert(cleared)
        XCTAssertEqual(try repository.fetch(id: "track-1")?.hasLyrics, false, "外挂歌词被删掉后必须能落回 false")
    }

    /// 老库升级后，这一列存在、既有行落到 0，且不需要重新扫描就能打开。
    func testUpgradedDatabaseGainsLyricsColumnDefaultingToFalse() throws {
        do {
            let db = try DatabaseManager(url: dbURL)
            let repository = MediaRepository(database: db)
            try repository.upsert(MediaItem(
                id: "legacy-track", type: .music, title: "升级前就存在的曲目",
                sourcePath: "/tmp/music", filePath: "/tmp/music/legacy.mp3"
            ))
            // 退回 28，模拟一个还没有这一列认知的旧库。
            try db.execute("PRAGMA user_version = 28")
        }

        let upgraded = try DatabaseManager(url: dbURL)
        XCTAssertEqual(try upgraded.schemaVersion(), DatabaseManager.currentSchemaVersion)
        let repository = MediaRepository(database: upgraded)
        let legacy = try XCTUnwrap(try repository.fetch(id: "legacy-track"))
        XCTAssertFalse(legacy.hasLyrics, "迁移只建列填 0，真实值由扫描或后台回补写入")
        XCTAssertEqual(legacy.title, "升级前就存在的曲目")
    }

    func testFreshDatabasePassesIntegrityCheck() throws {
        let db = try DatabaseManager(url: dbURL)
        XCTAssertNoThrow(try db.validateCurrentDatabase())
    }

    func testVersion24CreatesServerIdentityAuditPlaybackStateAndPendingLocalAdministrator() throws {
        let db = try DatabaseManager(url: dbURL)
        let expectedTables = Set([
            "server_users", "server_roles", "server_role_permissions", "server_user_roles",
            "server_credentials", "server_library_grants", "server_devices", "server_auth_sessions",
            "server_security_events", "server_user_media_state"
        ])
        let actualTables = Set(try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name LIKE 'server_%'"
        ) { $0.string(0) ?? "" })

        XCTAssertTrue(expectedTables.isSubset(of: actualTables))
        let administrator = try db.query(
            """
            SELECT username, requires_initial_password
            FROM server_users WHERE id = 'server-user-local-admin'
            """
        ) { ($0.string(0) ?? "", $0.bool(1)) }.first
        XCTAssertEqual(administrator?.0, "admin")
        XCTAssertEqual(administrator?.1, true)
        XCTAssertEqual(
            try db.query("SELECT COUNT(*) FROM server_credentials") { $0.int(0) ?? -1 }.first,
            0,
            "迁移不得生成默认密码或伪造密码摘要"
        )
        let credentialColumns = Set(try db.query("PRAGMA table_info(server_credentials)") {
            $0.string(1) ?? ""
        })
        XCTAssertTrue(Set([
            "failed_attempt_count", "locked_until", "last_failed_at", "last_login_at"
        ]).isSubset(of: credentialColumns))
        XCTAssertEqual(
            try db.query(
                """
                SELECT COUNT(*) FROM server_user_roles
                WHERE user_id = 'server-user-local-admin' AND role_id = 'server-role-admin'
                """
            ) { $0.int(0) ?? 0 }.first,
            1
        )
        let auditColumns = Set(try db.query("PRAGMA table_info(server_security_events)") {
            $0.string(1) ?? ""
        })
        XCTAssertTrue(Set([
            "id", "occurred_at", "category", "action", "outcome", "actor_user_id",
            "target_user_id", "session_id", "device_id", "detail_code"
        ]).isSubset(of: auditColumns))
        XCTAssertFalse(auditColumns.contains("password"))
        XCTAssertFalse(auditColumns.contains("token"))
        XCTAssertFalse(auditColumns.contains("path"))
        let playbackColumns = Set(try db.query("PRAGMA table_info(server_user_media_state)") {
            $0.string(1) ?? ""
        })
        XCTAssertEqual(playbackColumns, Set([
            "user_id", "media_id", "play_position", "play_progress", "is_watched",
            "play_count", "last_played_at", "updated_at"
        ]))
        XCTAssertFalse(playbackColumns.contains("session_id"))
        XCTAssertFalse(playbackColumns.contains("file_path"))
    }

    func testVersion25MaintainsPathFreeFullTextIndexAcrossWrites() throws {
        let db = try DatabaseManager(url: dbURL)
        let repository = MediaRepository(database: db)
        let indexNames = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'media_items_fts'"
        ) { $0.string(0) ?? "" }
        XCTAssertEqual(indexNames, ["media_items_fts"])

        try repository.upsert(MediaItem(
            id: "fts-item", type: .movie, title: "Amélie", artist: "Yann",
            sourcePath: "/library", filePath: "/private/never-exposed/movie.mkv", genre: "Romance"
        ))
        XCTAssertEqual(
            try db.query(
                "SELECT id FROM media_items WHERE rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)",
                bindings: [.text("amelie*")]
            ) { $0.string(0) ?? "" },
            ["fts-item"]
        )

        try repository.upsert(MediaItem(
            id: "fts-item", type: .movie, title: "Moonlit Garden", artist: "Yann",
            sourcePath: "/library", filePath: "/private/never-exposed/movie.mkv", genre: "Drama"
        ))
        XCTAssertEqual(
            try db.query(
                "SELECT COUNT(*) FROM media_items_fts WHERE media_items_fts MATCH ?",
                bindings: [.text("amelie*")]
            ) { $0.int(0) ?? -1 }.first,
            0
        )
        XCTAssertEqual(
            try db.query(
                "SELECT COUNT(*) FROM media_items_fts WHERE media_items_fts MATCH ?",
                bindings: [.text("moonlit*")]
            ) { $0.int(0) ?? -1 }.first,
            1
        )
        try db.execute("DELETE FROM media_items WHERE id = ?", bindings: [.text("fts-item")])
        XCTAssertEqual(
            try db.query("SELECT COUNT(*) FROM media_items_fts") { $0.int(0) ?? -1 }.first,
            0
        )
    }

    func testVersion26CreatesPathFreePerUserMediaPreferences() throws {
        let db = try DatabaseManager(url: dbURL)
        let columns = Set(try db.query("PRAGMA table_info(server_user_media_preferences)") { $0.string(1) ?? "" })
        XCTAssertEqual(columns, Set(["user_id", "media_id", "is_favorite", "is_watchlist", "user_rating", "updated_at"]))
        XCTAssertFalse(columns.contains("file_path"))
        XCTAssertFalse(columns.contains("session_id"))
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

    func testCreateBackupReplacesExistingBackupAndRestoresSecurePermissions() throws {
        let timestamp = "20260707-010101-000"
        let db = try DatabaseManager(url: dbURL, backupTimestampProvider: { timestamp })
        let backupDir = workDir.appendingPathComponent("locked-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        let existingBackup = backupDir.appendingPathComponent("MediaLib-collision-\(timestamp).sqlite")
        try Data("stale backup".utf8).write(to: existingBackup)

        let backupURL = try db.createBackup(in: backupDir, reason: "collision")

        XCTAssertEqual(backupURL, existingBackup)
        XCTAssertNotEqual(try Data(contentsOf: backupURL), Data("stale backup".utf8))
        let directoryPermissions = (try FileManager.default.attributesOfItem(atPath: backupDir.path)[.posixPermissions] as? NSNumber)?.intValue
        let filePermissions = (try FileManager.default.attributesOfItem(atPath: backupURL.path)[.posixPermissions] as? NSNumber)?.intValue
        XCTAssertEqual(directoryPermissions, 0o700)
        XCTAssertEqual(filePermissions, 0o600)
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

    func testAutomaticMigrationReportsPruneRemoveFailure() throws {
        let oldVersion = DatabaseManager.currentSchemaVersion - 1
        do {
            let db = try DatabaseManager(url: dbURL)
            try db.execute("PRAGMA user_version = \(oldVersion)")
        }
        let backupDir = workDir.appendingPathComponent("locked-prune-backups", isDirectory: true)
        try FileManager.default.createDirectory(at: backupDir, withIntermediateDirectories: true)
        for index in 0..<5 {
            let oldBackup = backupDir.appendingPathComponent("MediaLib-auto-pre-migration-old-\(index).sqlite")
            try Data("old-\(index)".utf8).write(to: oldBackup)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSince1970: Double(index + 10))],
                ofItemAtPath: oldBackup.path
            )
        }
        let lockedBackup = backupDir.appendingPathComponent("MediaLib-auto-pre-migration-locked.sqlite", isDirectory: true)
        try FileManager.default.createDirectory(at: lockedBackup, withIntermediateDirectories: true)
        try Data("locked".utf8).write(to: lockedBackup.appendingPathComponent("payload"))
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: lockedBackup.path)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: lockedBackup.path)
        defer {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: lockedBackup.path)
        }

        XCTAssertThrowsError(
            try DatabaseManager(
                url: dbURL,
                backupDirectory: backupDir,
                backupTimestampProvider: { "20260707-010101-001" }
            )
        ) { error in
            guard case DatabaseError.backupFailed(let message) = error else {
                return XCTFail("Expected backupFailed, got \(error)")
            }
            XCTAssertTrue(message.contains("自动迁移备份清理失败"))
            XCTAssertTrue(message.contains(lockedBackup.lastPathComponent))
        }
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
