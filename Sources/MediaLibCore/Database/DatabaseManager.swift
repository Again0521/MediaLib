import Foundation
import SQLite3

public final class DatabaseManager {
    private var db: OpaquePointer?
    private let queue = DispatchQueue(label: "MediaLib.DatabaseManager")
    private let queueKey = DispatchSpecificKey<Bool>()
    public let url: URL

    private var isOnQueue: Bool {
        DispatchQueue.getSpecific(key: queueKey) == true
    }

    public init(url: URL) throws {
        self.url = url
        queue.setSpecific(key: queueKey, value: true)
        let result = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK else {
            throw DatabaseError.openFailed(Self.message(for: db))
        }
        try execute("PRAGMA foreign_keys = ON")
        try execute("PRAGMA journal_mode = WAL")
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
          FOREIGN KEY(playlist_id) REFERENCES music_playlists(id) ON DELETE CASCADE,
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
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_type_parent ON media_items(type, parent_id)")
        try execute("CREATE INDEX IF NOT EXISTS index_media_items_favorite ON media_items(favorite)")
        try execute("CREATE UNIQUE INDEX IF NOT EXISTS index_media_sources_path ON media_sources(path)")
        try execute("CREATE INDEX IF NOT EXISTS index_music_playlist_items_position ON music_playlist_items(playlist_id, position)")
        try execute("CREATE INDEX IF NOT EXISTS index_music_playlist_items_media_id ON music_playlist_items(media_id)")
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
