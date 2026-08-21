import Foundation

public enum ServerPlaybackStateEvent: String, Sendable {
    case started
    case progress
    case stopped
    case completed
    case reset
}

public struct ServerUserMediaStateRecord: Equatable, Sendable {
    public let userID: String
    public let mediaID: String
    public let playPosition: Double
    public let playProgress: Double
    public let isWatched: Bool
    public let playCount: Int
    public let lastPlayedAt: Date?
    public let updatedAt: Date
}

public enum ServerUserMediaStateRepositoryError: Error, Equatable, Sendable {
    case invalidIdentifier
    case mediaNotFound
}

/// 服务端用户播放状态的唯一持久化边界。它与桌面 `media_items` 上的播放痕迹完全分离，
/// 主键同时包含用户和媒体，避免任一 Web/Mlink 用户覆盖其他用户的续播位置。
public final class ServerUserMediaStateRepository: @unchecked Sendable {
    private static let watchedThreshold = 0.9
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetch(userID: String, mediaID: String) throws -> ServerUserMediaStateRecord? {
        let userID = try validatedIdentifier(userID)
        let mediaID = try validatedIdentifier(mediaID)
        return try database.query(
            """
            SELECT user_id, media_id, play_position, play_progress, is_watched,
                   play_count, last_played_at, updated_at
            FROM server_user_media_state
            WHERE user_id = ? AND media_id = ?
            """,
            bindings: [.text(userID), .text(mediaID)],
            map: Self.map(row:)
        ).first
    }

    /// 一页海报墙只执行一次有界查询，避免逐卡片查询放大数据库占用。
    public func fetch(userID: String, mediaIDs: [String]) throws -> [String: ServerUserMediaStateRecord] {
        let userID = try validatedIdentifier(userID)
        let identifiers = try Array(Set(mediaIDs.map(validatedIdentifier))).sorted()
        guard identifiers.count <= 100 else { throw ServerUserMediaStateRepositoryError.invalidIdentifier }
        guard !identifiers.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        let rows = try database.query(
            """
            SELECT user_id, media_id, play_position, play_progress, is_watched,
                   play_count, last_played_at, updated_at
            FROM server_user_media_state
            WHERE user_id = ? AND media_id IN (\(placeholders))
            """,
            bindings: [.text(userID)] + identifiers.map(SQLiteValue.text),
            map: Self.map(row:)
        )
        return Dictionary(uniqueKeysWithValues: rows.map { ($0.mediaID, $0) })
    }

    /// 这个用户**自己**的全部播放状态行。理由与 `ServerUserMediaPreferenceRepository.fetchAll`
    /// 相同：整页渲染的音乐库没有 100 项这个上界，而一个人播放过的曲目有。
    public func fetchAll(userID: String, limit: Int = 5_000) throws -> [String: ServerUserMediaStateRecord] {
        let userID = try validatedIdentifier(userID)
        let safeLimit = min(max(limit, 1), 20_000)
        let rows = try database.query(
            """
            SELECT user_id, media_id, play_position, play_progress, is_watched,
                   play_count, last_played_at, updated_at
            FROM server_user_media_state
            WHERE user_id = ?
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            bindings: [.text(userID), .int(Int64(safeLimit))],
            map: Self.map(row:)
        )
        return Dictionary(rows.map { ($0.mediaID, $0) }) { first, _ in first }
    }

    @discardableResult
    public func update(
        userID: String,
        mediaID: String,
        event: ServerPlaybackStateEvent,
        position: Double,
        duration: Double?,
        at date: Date = Date()
    ) throws -> ServerUserMediaStateRecord {
        let userID = try validatedIdentifier(userID)
        let mediaID = try validatedIdentifier(mediaID)
        let normalizedPosition = position.isFinite ? max(position, 0) : 0
        let normalizedDuration = duration.flatMap { $0.isFinite && $0 > 0 ? $0 : nil }
        let progress = normalizedDuration.map { min(max(normalizedPosition / $0, 0), 1) } ?? 0
        let reachedEnd = event == .completed || progress >= Self.watchedThreshold
        let storedPosition = event == .reset ? 0 : normalizedPosition
        let storedProgress = event == .reset ? 0 : (event == .completed ? 1 : progress)
        let timestamp = DateCoding.string(from: date) ?? ""

        return try database.transaction {
            let mediaExists = try database.query(
                "SELECT COUNT(*) FROM media_items WHERE id = ?",
                bindings: [.text(mediaID)]
            ) { $0.int(0) ?? 0 }.first == 1
            guard mediaExists else { throw ServerUserMediaStateRepositoryError.mediaNotFound }

            try database.execute(
                """
                INSERT INTO server_user_media_state (
                  user_id, media_id, play_position, play_progress, is_watched,
                  play_count, last_played_at, updated_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                ON CONFLICT(user_id, media_id) DO UPDATE SET
                  play_position = excluded.play_position,
                  play_progress = excluded.play_progress,
                  is_watched = CASE
                    WHEN ? THEN 0
                    WHEN excluded.is_watched = 1 THEN 1
                    ELSE server_user_media_state.is_watched
                  END,
                  play_count = CASE
                    WHEN ? THEN 0
                    WHEN ? THEN server_user_media_state.play_count + 1
                    ELSE server_user_media_state.play_count
                  END,
                  last_played_at = CASE WHEN ? THEN NULL ELSE excluded.last_played_at END,
                  updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(userID), .text(mediaID), .double(storedPosition), .double(storedProgress),
                    .bool(reachedEnd), .int(event == .started ? 1 : 0),
                    event == .reset ? .null : .text(timestamp), .text(timestamp),
                    .bool(event == .reset), .bool(event == .reset), .bool(event == .started),
                    .bool(event == .reset)
                ]
            )
            guard let state = try fetch(userID: userID, mediaID: mediaID) else {
                throw ServerUserMediaStateRepositoryError.mediaNotFound
            }
            return state
        }
    }

    private func validatedIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else {
            throw ServerUserMediaStateRepositoryError.invalidIdentifier
        }
        return value
    }

    private static func map(row: SQLiteRow) -> ServerUserMediaStateRecord {
        ServerUserMediaStateRecord(
            userID: row.string(0) ?? "",
            mediaID: row.string(1) ?? "",
            playPosition: max(row.double(2) ?? 0, 0),
            playProgress: min(max(row.double(3) ?? 0, 0), 1),
            isWatched: row.bool(4),
            playCount: max(row.int(5) ?? 0, 0),
            lastPlayedAt: row.date(6),
            updatedAt: row.date(7) ?? Date(timeIntervalSince1970: 0)
        )
    }
}
