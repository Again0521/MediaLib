import Foundation

public final class MusicSmartPlaylistRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAll() throws -> [MusicSmartPlaylist] {
        try database.query(
            """
            SELECT id, name, filter, recency_days, sort, item_limit, created_at, updated_at
            FROM music_smart_playlists
            ORDER BY updated_at DESC, name COLLATE NOCASE ASC
            """
        ) { row in
            MusicSmartPlaylist(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "智能歌单",
                filter: MusicSmartPlaylistFilter(rawValue: row.string(2) ?? "") ?? .any,
                recency: MusicSmartPlaylistRecency(rawValue: row.int(3) ?? 0) ?? .anytime,
                sort: MusicSmartPlaylistSort(rawValue: row.string(4) ?? "") ?? .dateAddedDesc,
                limit: MusicSmartPlaylistLimit(rawValue: row.int(5) ?? 0) ?? .unlimited,
                createdAt: row.date(6) ?? Date(),
                updatedAt: row.date(7) ?? Date()
            )
        }
    }

    public func save(_ playlist: MusicSmartPlaylist) throws -> MusicSmartPlaylist {
        var updated = playlist
        updated.name = normalizedName(playlist.name)
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO music_smart_playlists (
              id, name, filter, recency_days, sort, item_limit, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              filter = excluded.filter,
              recency_days = excluded.recency_days,
              sort = excluded.sort,
              item_limit = excluded.item_limit,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(updated.id),
                .text(updated.name),
                .text(updated.filter.rawValue),
                .int(Int64(updated.recency.rawValue)),
                .text(updated.sort.rawValue),
                .int(Int64(updated.limit.rawValue)),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func delete(id: String) throws {
        try database.execute(
            "DELETE FROM music_smart_playlists WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "智能歌单" : trimmed
    }
}
