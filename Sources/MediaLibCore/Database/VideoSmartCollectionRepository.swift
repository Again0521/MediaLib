import Foundation

public final class VideoSmartCollectionRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAll() throws -> [VideoSmartCollection] {
        try database.query(
            """
            SELECT id, name, media_scope, state_filter, recency_days, rules_json, show_on_home, created_at, updated_at
            FROM video_smart_collections
            ORDER BY updated_at DESC, name COLLATE NOCASE ASC
            """
        ) { row in
            VideoSmartCollection(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "智能集合",
                mediaScope: VideoSmartCollectionMediaScope(rawValue: row.string(2) ?? "") ?? .all,
                stateFilter: VideoSmartCollectionStateFilter(rawValue: row.string(3) ?? "") ?? .any,
                recency: VideoSmartCollectionRecency(rawValue: row.int(4) ?? 0) ?? .anytime,
                rules: Self.decodeRules(row.string(5)),
                showOnHome: row.bool(6),
                createdAt: row.date(7) ?? Date(),
                updatedAt: row.date(8) ?? Date()
            )
        }
    }

    public func save(_ collection: VideoSmartCollection) throws -> VideoSmartCollection {
        var updated = collection
        updated.name = normalizedName(collection.name)
        updated.rules = VideoSmartCollectionRules(
            matchMode: collection.rules.matchMode,
            year: collection.rules.year,
            providerRating: collection.rules.providerRating,
            userRating: collection.rules.userRating,
            genreKeyword: collection.rules.genreKeyword,
            source: collection.rules.source
        )
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO video_smart_collections (
              id, name, media_scope, state_filter, recency_days, rules_json, show_on_home, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              name = excluded.name,
              media_scope = excluded.media_scope,
              state_filter = excluded.state_filter,
              recency_days = excluded.recency_days,
              rules_json = excluded.rules_json,
              show_on_home = excluded.show_on_home,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(updated.id),
                .text(updated.name),
                .text(updated.mediaScope.rawValue),
                .text(updated.stateFilter.rawValue),
                .int(Int64(updated.recency.rawValue)),
                .optionalText(Self.encodeRules(updated.rules)),
                .bool(updated.showOnHome),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func delete(id: String) throws {
        try database.execute(
            "DELETE FROM video_smart_collections WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "智能集合" : trimmed
    }

    private static func decodeRules(_ value: String?) -> VideoSmartCollectionRules {
        guard let value,
              let data = value.data(using: .utf8),
              let rules = try? JSONDecoder().decode(VideoSmartCollectionRules.self, from: data) else {
            return VideoSmartCollectionRules()
        }
        return rules
    }

    private static func encodeRules(_ rules: VideoSmartCollectionRules) -> String? {
        guard let data = try? JSONEncoder().encode(rules) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
