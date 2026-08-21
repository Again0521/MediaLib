import Foundation

/// 单项、当前用户的偏好写入。它刻意不接收 userID 以外的状态主体、来源路径或媒体 URL；
/// 上层 HTTP 边界必须从认证 principal 提供 userID。
public enum ServerUserMediaPreferenceUpdate: Equatable, Sendable {
    case favorite(Bool)
    case watchlist(Bool)
    /// `nil` 明确表示清除评分；合法非空范围为 0–5 星。
    case rating(Double?)
}

public struct ServerUserMediaPreferenceRecord: Equatable, Sendable {
    public let userID: String
    public let mediaID: String
    public let isFavorite: Bool
    public let isWatchlist: Bool
    public let userRating: Double?
    public let updatedAt: Date
}

public enum ServerUserMediaPreferenceRepositoryError: Error, Equatable, Sendable {
    case invalidIdentifier
    case invalidRating
    case mediaNotFound
}

/// 与逐用户播放状态并列的持久化边界。桌面端 `MediaItem.favorite/watchlist/userRating`
/// 仅是本地应用状态，绝不可作为 Web/Mlink 服务端用户偏好的回退值。
public final class ServerUserMediaPreferenceRepository: @unchecked Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetch(userID: String, mediaID: String) throws -> ServerUserMediaPreferenceRecord? {
        let userID = try validatedIdentifier(userID)
        let mediaID = try validatedIdentifier(mediaID)
        return try database.query(
            """
            SELECT user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at
            FROM server_user_media_preferences
            WHERE user_id = ? AND media_id = ?
            """,
            bindings: [.text(userID), .text(mediaID)],
            map: Self.map(row:)
        ).first
    }

    /// 一页 Web/Mlink 卡片使用一次有界查询读取偏好，避免逐卡片数据库访问。
    public func fetch(userID: String, mediaIDs: [String]) throws -> [String: ServerUserMediaPreferenceRecord] {
        let userID = try validatedIdentifier(userID)
        let identifiers = try Array(Set(mediaIDs.map(validatedIdentifier))).sorted()
        guard identifiers.count <= 100 else { throw ServerUserMediaPreferenceRepositoryError.invalidIdentifier }
        guard !identifiers.isEmpty else { return [:] }
        let placeholders = Array(repeating: "?", count: identifiers.count).joined(separator: ",")
        let records = try database.query(
            """
            SELECT user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at
            FROM server_user_media_preferences
            WHERE user_id = ? AND media_id IN (\(placeholders))
            """,
            bindings: [.text(userID)] + identifiers.map(SQLiteValue.text),
            map: Self.map(row:)
        )
        return Dictionary(uniqueKeysWithValues: records.map { ($0.mediaID, $0) })
    }

    /// 这个用户**自己**的全部偏好行。
    ///
    /// 按 ID 批量读取那条路径一次最多 100 项，音乐页却是整库一次渲染（几千行都可能）。
    /// 分成几十次查询只是把同一个问题拆碎；而"这个用户标过的东西"本身就是有界的
    /// ——它随这个人的操作增长，不随资料库增长。上限仍然要有一个，超出部分按
    /// 最近更新截断。
    public func fetchAll(userID: String, limit: Int = 5_000) throws -> [String: ServerUserMediaPreferenceRecord] {
        let userID = try validatedIdentifier(userID)
        let safeLimit = min(max(limit, 1), 20_000)
        let records = try database.query(
            """
            SELECT user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at
            FROM server_user_media_preferences
            WHERE user_id = ?
            ORDER BY updated_at DESC
            LIMIT ?
            """,
            bindings: [.text(userID), .int(Int64(safeLimit))],
            map: Self.map(row:)
        )
        return Dictionary(records.map { ($0.mediaID, $0) }) { first, _ in first }
    }

    @discardableResult
    public func update(
        userID: String,
        mediaID: String,
        preference: ServerUserMediaPreferenceUpdate,
        at date: Date = Date()
    ) throws -> ServerUserMediaPreferenceRecord {
        let userID = try validatedIdentifier(userID)
        let mediaID = try validatedIdentifier(mediaID)
        let timestamp = DateCoding.string(from: date) ?? ""
        let rating: Double?
        if case let .rating(value) = preference {
            guard value == nil || (value!.isFinite && value! > 0 && value! <= 5) else {
                throw ServerUserMediaPreferenceRepositoryError.invalidRating
            }
            rating = value
        } else {
            rating = nil
        }

        return try database.transaction {
            let mediaExists = try database.query(
                "SELECT COUNT(*) FROM media_items WHERE id = ?",
                bindings: [.text(mediaID)]
            ) { $0.int(0) ?? 0 }.first == 1
            guard mediaExists else { throw ServerUserMediaPreferenceRepositoryError.mediaNotFound }

            let sql: String
            let bindings: [SQLiteValue]
            switch preference {
            case let .favorite(value):
                sql = """
                INSERT INTO server_user_media_preferences (user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at)
                VALUES (?, ?, ?, 0, NULL, ?)
                ON CONFLICT(user_id, media_id) DO UPDATE SET is_favorite = excluded.is_favorite, updated_at = excluded.updated_at
                """
                bindings = [.text(userID), .text(mediaID), .bool(value), .text(timestamp)]
            case let .watchlist(value):
                sql = """
                INSERT INTO server_user_media_preferences (user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at)
                VALUES (?, ?, 0, ?, NULL, ?)
                ON CONFLICT(user_id, media_id) DO UPDATE SET is_watchlist = excluded.is_watchlist, updated_at = excluded.updated_at
                """
                bindings = [.text(userID), .text(mediaID), .bool(value), .text(timestamp)]
            case .rating:
                sql = """
                INSERT INTO server_user_media_preferences (user_id, media_id, is_favorite, is_watchlist, user_rating, updated_at)
                VALUES (?, ?, 0, 0, ?, ?)
                ON CONFLICT(user_id, media_id) DO UPDATE SET user_rating = excluded.user_rating, updated_at = excluded.updated_at
                """
                bindings = [.text(userID), .text(mediaID), .optionalDouble(rating), .text(timestamp)]
            }
            try database.execute(sql, bindings: bindings)
            guard let record = try fetch(userID: userID, mediaID: mediaID) else {
                throw ServerUserMediaPreferenceRepositoryError.mediaNotFound
            }
            return record
        }
    }

    private func validatedIdentifier(_ value: String) throws -> String {
        guard !value.isEmpty,
              value.utf8.count <= 512,
              !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { throw ServerUserMediaPreferenceRepositoryError.invalidIdentifier }
        return value
    }

    private static func map(row: SQLiteRow) -> ServerUserMediaPreferenceRecord {
        ServerUserMediaPreferenceRecord(
            userID: row.string(0) ?? "",
            mediaID: row.string(1) ?? "",
            isFavorite: row.bool(2),
            isWatchlist: row.bool(3),
            userRating: row.double(4).flatMap { $0.isFinite && $0 > 0 && $0 <= 5 ? $0 : nil },
            updatedAt: row.date(5) ?? Date(timeIntervalSince1970: 0)
        )
    }
}
