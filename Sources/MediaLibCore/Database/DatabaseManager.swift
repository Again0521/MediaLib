import Foundation
import SQLite3

public final class DatabaseManager {
    public static let currentSchemaVersion = 8

    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "MediaLib.DatabaseManager")
    private let queueKey = DispatchSpecificKey<Bool>()
    public let url: URL

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    public init(url: URL, backupDirectory: URL? = nil) throws {
        self.url = url
        let existingDatabase = FileManager.default.fileExists(atPath: url.path) &&
            ((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) > 0
        queue.setSpecific(key: queueKey, value: true)
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            throw DatabaseError.openFailed(Self.message(for: db))
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
        let storedVersion = try schemaVersion()
        guard storedVersion <= Self.currentSchemaVersion else {
            throw DatabaseError.incompatibleSchema(found: storedVersion, supported: Self.currentSchemaVersion)
        }
        if existingDatabase, storedVersion < Self.currentSchemaVersion, let backupDirectory {
            _ = try createBackup(in: backupDirectory, reason: "auto-pre-migration-v\(storedVersion)-to-v\(Self.currentSchemaVersion)")
            try Self.pruneAutomaticBackups(in: backupDirectory, keeping: 5)
        }
        try migrate()
    }

    deinit {
        sqlite3_close(db)
    }

    public func execute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        if isOnQueue {
            try unsafeExecute(sql, bindings: bindings)
        } else {
            try queue.sync { try self.unsafeExecute(sql, bindings: bindings) }
        }
    }

    public func query<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        if isOnQueue {
            return try unsafeQuery(sql, bindings: bindings, map: map)
        } else {
            return try queue.sync { try self.unsafeQuery(sql, bindings: bindings, map: map) }
        }
    }

    /// 在单次 queue.sync 内以 BEGIN IMMEDIATE/COMMIT 包裹 block，保证原子性。
    /// block 内可继续调用 execute/query，检测到已在队列上后直接执行，不会死锁。
    /// 若 block 抛出异常则自动 ROLLBACK。
    public func transaction<T>(_ block: () throws -> T) throws -> T {
        if isOnQueue {
            // 嵌套调用：已在事务上下文中，直接执行
            return try block()
        }
        return try queue.sync {
            try self.unsafeExecute("BEGIN IMMEDIATE TRANSACTION")
            do {
                let result = try block()
                try self.unsafeExecute("COMMIT")
                return result
            } catch {
                try? self.unsafeExecute("ROLLBACK")
                throw error
            }
        }
    }

    public func schemaVersion() throws -> Int {
        try query("PRAGMA user_version") { row in
            row.int(0) ?? 0
        }.first ?? 0
    }

    @discardableResult
    public func createBackup(in directory: URL, reason: String = "manual") throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let safeReason = reason
            .lowercased()
            .map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" }
        let timestamp = Self.backupTimestamp()
        let backupURL = directory.appendingPathComponent("MediaLib-\(String(safeReason))-\(timestamp).sqlite")
        if isOnQueue {
            try unsafeBackupCurrent(to: backupURL)
        } else {
            try queue.sync {
                try self.unsafeBackupCurrent(to: backupURL)
            }
        }
        return backupURL
    }

    public func restore(from backupURL: URL, safetyBackupDirectory: URL) throws {
        guard backupURL.standardizedFileURL != url.standardizedFileURL else {
            throw DatabaseError.backupFailed("不能从当前正在使用的数据库文件恢复。")
        }
        try validateBackup(at: backupURL)
        _ = try createBackup(in: safetyBackupDirectory, reason: "auto-pre-restore")

        try queue.sync {
            try self.unsafeExecute("PRAGMA wal_checkpoint(TRUNCATE)")
            try self.unsafeRestore(from: backupURL)
            try self.unsafeExecute("PRAGMA foreign_keys = ON")
            try self.unsafeExecute("PRAGMA journal_mode = WAL")
        }
        try migrate()
        try validateCurrentDatabase()
    }

    public func validateCurrentDatabase() throws {
        let result = try query("PRAGMA integrity_check") { row in
            row.string(0) ?? ""
        }
        guard result.count == 1, result.first?.lowercased() == "ok" else {
            throw DatabaseError.integrityCheckFailed(result.joined(separator: "; "))
        }
    }

    private func unsafeExecute(_ sql: String, bindings: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.message(for: db))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_DONE { return }
            if result == SQLITE_ROW { continue }
            throw DatabaseError.stepFailed(Self.message(for: db))
        }
    }

    private func unsafeQuery<T>(
        _ sql: String,
        bindings: [SQLiteValue] = [],
        map: (SQLiteRow) throws -> T
    ) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(Self.message(for: db))
        }
        defer { sqlite3_finalize(statement) }
        try bind(bindings, to: statement)
        var rows: [T] = []
        while true {
            let result = sqlite3_step(statement)
            if result == SQLITE_ROW {
                rows.append(try map(SQLiteRow(statement: statement)))
            } else if result == SQLITE_DONE {
                return rows
            } else {
                throw DatabaseError.stepFailed(Self.message(for: db))
            }
        }
    }

    private func bind(_ bindings: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in bindings.enumerated() {
            let index = Int32(offset + 1)
            let result: Int32
            switch value {
            case .null:
                result = sqlite3_bind_null(statement, index)
            case .text(let text):
                result = sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
            case .int(let int):
                result = sqlite3_bind_int64(statement, index, int)
            case .double(let double):
                result = sqlite3_bind_double(statement, index, double)
            case .bool(let bool):
                result = sqlite3_bind_int(statement, index, bool ? 1 : 0)
            }
            guard result == SQLITE_OK else {
                throw DatabaseError.bindFailed(Self.message(for: db))
            }
        }
    }

    private func migrate() throws {
        var version = try schemaVersion()
        guard version <= Self.currentSchemaVersion else {
            throw DatabaseError.incompatibleSchema(found: version, supported: Self.currentSchemaVersion)
        }
        if version < 1 {
            try transaction {
                try migrateToVersion1()
                try execute("PRAGMA user_version = 1")
            }
            version = 1
        }
        if version < 2 {
            try transaction {
                try migrateToVersion2()
                try execute("PRAGMA user_version = 2")
            }
            version = 2
        }
        if version < 3 {
            try transaction {
                try migrateToVersion3()
                try execute("PRAGMA user_version = 3")
            }
            version = 3
        }
        if version < 4 {
            try transaction {
                try migrateToVersion4()
                try execute("PRAGMA user_version = 4")
            }
            version = 4
        }
        if version < 5 {
            try transaction {
                try migrateToVersion5()
                try execute("PRAGMA user_version = 5")
            }
            version = 5
        }
        if version < 6 {
            try transaction {
                try migrateToVersion6()
                try execute("PRAGMA user_version = 6")
            }
            version = 6
        }
        if version < 7 {
            try transaction {
                try migrateToVersion7()
                try execute("PRAGMA user_version = 7")
            }
            version = 7
        }
        if version < 8 {
            try transaction {
                try migrateToVersion8()
                try execute("PRAGMA user_version = 8")
            }
            version = 8
        }
        guard version == Self.currentSchemaVersion else {
            throw DatabaseError.incompatibleSchema(found: version, supported: Self.currentSchemaVersion)
        }
    }

    private func migrateToVersion1() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS media_items (
          id TEXT PRIMARY KEY,
          type TEXT NOT NULL,
          title TEXT NOT NULL,
          original_title TEXT,
          artist TEXT,
          album TEXT,
          track_number INTEGER,
          year INTEGER,
          overview TEXT,
          poster_path TEXT,
          backdrop_path TEXT,
          rating REAL,
          runtime INTEGER,
          source_path TEXT,
          parent_id TEXT,
          season_number INTEGER,
          episode_number INTEGER,
          file_path TEXT,
          file_size INTEGER,
          video_codec TEXT,
          audio_codec TEXT,
          resolution TEXT,
          duration REAL,
          play_count INTEGER DEFAULT 0,
          play_position REAL DEFAULT 0,
          play_progress REAL DEFAULT 0,
          watched INTEGER DEFAULT 0,
          favorite INTEGER DEFAULT 0,
          external_id TEXT,
          metadata_provider TEXT,
          created_at TEXT,
          updated_at TEXT,
          last_played_at TEXT
        )
        """)

        try addColumnIfMissing(table: "media_items", column: "artist", definition: "artist TEXT")
        try addColumnIfMissing(table: "media_items", column: "album", definition: "album TEXT")
        try addColumnIfMissing(table: "media_items", column: "track_number", definition: "track_number INTEGER")
        try addColumnIfMissing(table: "media_items", column: "external_id", definition: "external_id TEXT")
        try addColumnIfMissing(table: "media_items", column: "metadata_provider", definition: "metadata_provider TEXT")
        try addColumnIfMissing(table: "media_items", column: "video_bitrate", definition: "video_bitrate INTEGER")
        try addColumnIfMissing(table: "media_items", column: "collection_title", definition: "collection_title TEXT")
        try addColumnIfMissing(table: "media_items", column: "play_count", definition: "play_count INTEGER DEFAULT 0")

        try execute("""
        CREATE TABLE IF NOT EXISTS media_sources (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          path TEXT NOT NULL,
          media_type TEXT,
          recursive INTEGER DEFAULT 1,
          auto_scan INTEGER DEFAULT 1,
          minimum_file_size INTEGER DEFAULT 52428800,
          ignore_hidden_files INTEGER DEFAULT 1,
          read_nfo INTEGER DEFAULT 1,
          prefer_local_artwork INTEGER DEFAULT 1,
          network_scraping_enabled INTEGER DEFAULT 1,
          screenshot_fallback_enabled INTEGER DEFAULT 1,
          created_at TEXT,
          updated_at TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS images_cache (
          id TEXT PRIMARY KEY,
          media_id TEXT,
          type TEXT,
          original_url TEXT,
          local_path TEXT,
          created_at TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS scan_tasks (
          id TEXT PRIMARY KEY,
          source_id TEXT,
          status TEXT,
          total_files INTEGER,
          processed_files INTEGER,
          error_message TEXT,
          created_at TEXT,
          finished_at TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS music_playlists (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          created_at TEXT,
          updated_at TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS music_playlist_items (
          playlist_id TEXT NOT NULL,
          media_id TEXT NOT NULL,
          position INTEGER NOT NULL,
          added_at TEXT,
          PRIMARY KEY(playlist_id, media_id),
          FOREIGN KEY(playlist_id) REFERENCES music_playlists(id) ON DELETE CASCADE
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS music_queue_state (
          id INTEGER PRIMARY KEY CHECK (id = 1),
          repeat_mode TEXT NOT NULL DEFAULT 'sequential',
          shuffle_enabled INTEGER NOT NULL DEFAULT 0,
          updated_at TEXT
        )
        """)

        try execute("""
        CREATE TABLE IF NOT EXISTS music_queue_items (
          media_id TEXT PRIMARY KEY,
          position INTEGER NOT NULL,
          added_at TEXT,
          FOREIGN KEY(media_id) REFERENCES media_items(id) ON DELETE CASCADE
        )
        """)

        try execute("CREATE UNIQUE INDEX IF NOT EXISTS index_media_items_file_path ON media_items(file_path) WHERE file_path IS NOT NULL")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_parent_id ON media_items(parent_id)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_type ON media_items(type)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_source_path ON media_items(source_path)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_title_nocase ON media_items(title COLLATE NOCASE)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_updated_at ON media_items(updated_at)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_last_played_at ON media_items(last_played_at)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_play_count ON media_items(play_count)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_type_parent ON media_items(type, parent_id)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_favorite ON media_items(favorite)")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS index_media_sources_path ON media_sources(path)")
        try execute("CREATE INDEX IF NOT EXISTS index_music_playlist_items_position ON music_playlist_items(playlist_id, position)")
        try execute("CREATE INDEX IF NOT EXISTS index_music_playlist_items_media_id ON music_playlist_items(media_id)")
        try execute("CREATE INDEX IF NOT EXISTS index_music_queue_items_position ON music_queue_items(position)")
    }

    private func migrateToVersion2() throws {
        try addColumnIfMissing(table: "media_items", column: "watchlist", definition: "watchlist INTEGER DEFAULT 0")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_watchlist ON media_items(watchlist)")
        try execute("""
        CREATE TABLE IF NOT EXISTS video_smart_collections (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          media_scope TEXT NOT NULL DEFAULT 'all',
          state_filter TEXT NOT NULL DEFAULT 'any',
          recency_days INTEGER NOT NULL DEFAULT 0,
          created_at TEXT,
          updated_at TEXT
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS index_video_smart_collections_updated_at ON video_smart_collections(updated_at)")
    }

    private func migrateToVersion3() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS playback_markers (
          id TEXT PRIMARY KEY,
          media_id TEXT NOT NULL,
          kind TEXT NOT NULL,
          title TEXT NOT NULL,
          start_time REAL NOT NULL,
          end_time REAL,
          origin TEXT NOT NULL DEFAULT 'manual',
          created_at TEXT,
          updated_at TEXT,
          FOREIGN KEY(media_id) REFERENCES media_items(id) ON DELETE CASCADE
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS index_playback_markers_media_time ON playback_markers(media_id, start_time)")
        try execute("CREATE INDEX IF NOT EXISTS index_playback_markers_media_kind ON playback_markers(media_id, kind)")
    }

    private func migrateToVersion4() throws {
        try addColumnIfMissing(table: "media_items", column: "loudness_track_gain_db", definition: "loudness_track_gain_db REAL")
        try addColumnIfMissing(table: "media_items", column: "loudness_album_gain_db", definition: "loudness_album_gain_db REAL")
        try addColumnIfMissing(table: "media_items", column: "loudness_track_peak", definition: "loudness_track_peak REAL")
        try addColumnIfMissing(table: "media_items", column: "loudness_album_peak", definition: "loudness_album_peak REAL")
    }

    private func migrateToVersion5() throws {
        try execute("""
        CREATE TABLE IF NOT EXISTS music_smart_playlists (
          id TEXT PRIMARY KEY,
          name TEXT NOT NULL,
          filter TEXT NOT NULL DEFAULT 'any',
          recency_days INTEGER NOT NULL DEFAULT 0,
          sort TEXT NOT NULL DEFAULT 'dateAddedDesc',
          item_limit INTEGER NOT NULL DEFAULT 0,
          created_at TEXT,
          updated_at TEXT
        )
        """)
        try execute("CREATE INDEX IF NOT EXISTS index_music_smart_playlists_updated_at ON music_smart_playlists(updated_at)")
    }

    private func migrateToVersion6() throws {
        try addColumnIfMissing(table: "media_items", column: "user_rating", definition: "user_rating INTEGER")
    }

    private func migrateToVersion7() throws {
        try addColumnIfMissing(table: "media_sources", column: "include_in_metadata_fetch", definition: "include_in_metadata_fetch INTEGER DEFAULT 1")
        try addColumnIfMissing(table: "media_sources", column: "include_in_health_check", definition: "include_in_health_check INTEGER DEFAULT 1")
    }

    private func migrateToVersion8() throws {
        try addColumnIfMissing(table: "media_items", column: "genre", definition: "genre TEXT")
    }

    private func validateBackup(at backupURL: URL) throws {
        guard FileManager.default.fileExists(atPath: backupURL.path) else {
            throw DatabaseError.backupFailed("选择的备份文件不存在。")
        }
        var sourceDB: OpaquePointer?
        let openResult = sqlite3_open_v2(backupURL.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let sourceDB else {
            defer { sqlite3_close(sourceDB) }
            throw DatabaseError.backupFailed(Self.message(for: sourceDB))
        }
        defer { sqlite3_close(sourceDB) }
        let version = try Self.pragmaInt("user_version", database: sourceDB)
        guard version <= Self.currentSchemaVersion else {
            throw DatabaseError.incompatibleSchema(found: version, supported: Self.currentSchemaVersion)
        }
        let integrity = try Self.pragmaStrings("integrity_check", database: sourceDB)
        guard integrity.count == 1, integrity.first?.lowercased() == "ok" else {
            throw DatabaseError.integrityCheckFailed(integrity.joined(separator: "; "))
        }
    }

    private func unsafeBackupCurrent(to backupURL: URL) throws {
        try? FileManager.default.removeItem(at: backupURL)
        var destinationDB: OpaquePointer?
        let openResult = sqlite3_open_v2(
            backupURL.path,
            &destinationDB,
            SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        )
        guard openResult == SQLITE_OK, let destinationDB else {
            defer { sqlite3_close(destinationDB) }
            throw DatabaseError.backupFailed(Self.message(for: destinationDB))
        }
        defer { sqlite3_close(destinationDB) }
        try Self.copyDatabase(from: db, to: destinationDB)
        let integrity = try Self.pragmaStrings("integrity_check", database: destinationDB)
        guard integrity.count == 1, integrity.first?.lowercased() == "ok" else {
            try? FileManager.default.removeItem(at: backupURL)
            throw DatabaseError.integrityCheckFailed(integrity.joined(separator: "; "))
        }
    }

    private func unsafeRestore(from backupURL: URL) throws {
        var sourceDB: OpaquePointer?
        let openResult = sqlite3_open_v2(backupURL.path, &sourceDB, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
        guard openResult == SQLITE_OK, let sourceDB else {
            defer { sqlite3_close(sourceDB) }
            throw DatabaseError.backupFailed(Self.message(for: sourceDB))
        }
        defer { sqlite3_close(sourceDB) }
        try Self.copyDatabase(from: sourceDB, to: db)
    }

    private static func copyDatabase(from source: OpaquePointer?, to destination: OpaquePointer?) throws {
        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw DatabaseError.backupFailed(Self.message(for: destination))
        }
        let stepResult = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard stepResult == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw DatabaseError.backupFailed(Self.message(for: destination))
        }
    }

    private static func pragmaInt(_ name: String, database: OpaquePointer?) throws -> Int {
        try pragmaStrings(name, database: database).first.flatMap(Int.init) ?? 0
    }

    private static func pragmaStrings(_ name: String, database: OpaquePointer?) throws -> [String] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "PRAGMA \(name)", -1, &statement, nil) == SQLITE_OK else {
            throw DatabaseError.prepareFailed(message(for: database))
        }
        defer { sqlite3_finalize(statement) }
        var result: [String] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_ROW {
                if let value = sqlite3_column_text(statement, 0) {
                    result.append(String(cString: value))
                }
            } else if step == SQLITE_DONE {
                return result
            } else {
                throw DatabaseError.stepFailed(message(for: database))
            }
        }
    }

    private static func backupTimestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: Date())
    }

    private static func pruneAutomaticBackups(in directory: URL, keeping limit: Int) throws {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey]
        let backups = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )
        .filter { $0.lastPathComponent.hasPrefix("MediaLib-auto-pre-migration-") && $0.pathExtension == "sqlite" }
        .sorted {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs > rhs
        }
        for backup in backups.dropFirst(max(limit, 0)) {
            try? FileManager.default.removeItem(at: backup)
        }
    }

    private func addColumnIfMissing(table: String, column: String, definition: String) throws {
        let rows = try query("PRAGMA table_info(\(table))") { row in
            row.string(1)
        }
        guard !rows.contains(where: { $0 == column }) else { return }
        try execute("ALTER TABLE \(table) ADD COLUMN \(definition)")
    }

    private static func message(for db: OpaquePointer?) -> String {
        guard let message = sqlite3_errmsg(db) else { return "未知错误" }
        return String(cString: message)
    }
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public struct SQLiteRow {
    fileprivate let statement: OpaquePointer?

    public func string(_ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        guard let cString = sqlite3_column_text(statement, index) else { return nil }
        return String(cString: cString)
    }

    public func int(_ index: Int32) -> Int? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Int(sqlite3_column_int64(statement, index))
    }

    public func int64(_ index: Int32) -> Int64? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_int64(statement, index)
    }

    public func double(_ index: Int32) -> Double? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return sqlite3_column_double(statement, index)
    }

    public func bool(_ index: Int32) -> Bool {
        sqlite3_column_int(statement, index) == 1
    }

    public func date(_ index: Int32) -> Date? {
        DateCoding.date(from: string(index))
    }
}
