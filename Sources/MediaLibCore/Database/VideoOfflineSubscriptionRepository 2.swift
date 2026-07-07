import Foundation

public final class VideoOfflineSubscriptionRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAll() throws -> [VideoOfflineSubscription] {
        try database.query(
            """
            SELECT id, series_id, series_title, mode, episode_limit, season_number, quality_id,
                   enabled, paused_until, expires_at, network_policy, created_at, updated_at
            FROM video_offline_subscriptions
            ORDER BY updated_at DESC, series_title COLLATE NOCASE ASC
            """
        ) { row in
            Self.map(row)
        }
    }

    public func fetch(seriesID: String) throws -> VideoOfflineSubscription? {
        try database.query(
            """
            SELECT id, series_id, series_title, mode, episode_limit, season_number, quality_id,
                   enabled, paused_until, expires_at, network_policy, created_at, updated_at
            FROM video_offline_subscriptions
            WHERE series_id = ?
            LIMIT 1
            """,
            bindings: [.text(seriesID)]
        ) { row in
            Self.map(row)
        }.first
    }

    public func fetchExpired(now: Date = Date()) throws -> [VideoOfflineSubscription] {
        try database.query(
            """
            SELECT id, series_id, series_title, mode, episode_limit, season_number, quality_id,
                   enabled, paused_until, expires_at, network_policy, created_at, updated_at
            FROM video_offline_subscriptions
            WHERE expires_at IS NOT NULL AND expires_at <= ?
            ORDER BY expires_at ASC, updated_at DESC
            """,
            bindings: [.optionalDate(now)]
        ) { row in
            Self.map(row)
        }
    }

    public func save(_ subscription: VideoOfflineSubscription) throws -> VideoOfflineSubscription {
        let now = Date()
        let updated = VideoOfflineSubscription(
            id: subscription.id,
            seriesID: subscription.seriesID,
            seriesTitle: subscription.seriesTitle,
            mode: subscription.mode,
            episodeLimit: subscription.episodeLimit,
            seasonNumber: subscription.seasonNumber,
            qualityID: subscription.qualityID,
            enabled: subscription.enabled,
            pausedUntil: subscription.pausedUntil,
            expiresAt: subscription.expiresAt,
            networkPolicy: subscription.networkPolicy,
            createdAt: subscription.createdAt,
            updatedAt: now
        )
        try database.execute(
            """
            INSERT INTO video_offline_subscriptions (
              id, series_id, series_title, mode, episode_limit, season_number, quality_id,
              enabled, paused_until, expires_at, network_policy, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(series_id) DO UPDATE SET
              series_title = excluded.series_title,
              mode = excluded.mode,
              episode_limit = excluded.episode_limit,
              season_number = excluded.season_number,
              quality_id = excluded.quality_id,
              enabled = excluded.enabled,
              paused_until = excluded.paused_until,
              expires_at = excluded.expires_at,
              network_policy = excluded.network_policy,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(updated.id),
                .text(updated.seriesID),
                .text(updated.seriesTitle),
                .text(updated.mode.rawValue),
                .int(Int64(updated.episodeLimit)),
                .optionalInt(updated.seasonNumber),
                .optionalText(updated.qualityID),
                .bool(updated.enabled),
                .optionalDate(updated.pausedUntil),
                .optionalDate(updated.expiresAt),
                .text(updated.networkPolicy.rawValue),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt)
            ]
        )
        return try fetch(seriesID: updated.seriesID) ?? updated
    }

    public func delete(seriesID: String) throws {
        try database.execute(
            "DELETE FROM video_offline_subscriptions WHERE series_id = ?",
            bindings: [.text(seriesID)]
        )
    }

    public func deleteExpired(now: Date = Date()) throws -> Int {
        let expired = try fetchExpired(now: now)
        guard !expired.isEmpty else { return 0 }
        try database.execute(
            "DELETE FROM video_offline_subscriptions WHERE expires_at IS NOT NULL AND expires_at <= ?",
            bindings: [.optionalDate(now)]
        )
        return expired.count
    }

    private static func map(_ row: SQLiteRow) -> VideoOfflineSubscription {
        VideoOfflineSubscription(
            id: row.string(0) ?? UUID().uuidString,
            seriesID: row.string(1) ?? "",
            seriesTitle: row.string(2) ?? "未命名系列",
            mode: VideoOfflineSubscriptionMode(rawValue: row.string(3) ?? "") ?? .nextEpisode,
            episodeLimit: row.int(4) ?? 3,
            seasonNumber: row.int(5),
            qualityID: row.string(6),
            enabled: row.bool(7),
            pausedUntil: row.date(8),
            expiresAt: row.date(9),
            networkPolicy: VideoOfflineSubscriptionNetworkPolicy(rawValue: row.string(10) ?? "") ?? .allowRemote,
            createdAt: row.date(11) ?? Date(),
            updatedAt: row.date(12) ?? Date()
        )
    }
}
