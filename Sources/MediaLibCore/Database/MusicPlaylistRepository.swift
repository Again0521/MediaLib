import Foundation

public final class MusicPlaylistRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAll() throws -> [MusicPlaylist] {
        let playlists = try database.query(
            """
            SELECT id, name, created_at, updated_at
            FROM music_playlists
            ORDER BY updated_at DESC, name COLLATE NOCASE ASC
            """
        ) { row in
            MusicPlaylist(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "新歌单",
                itemIDs: [],
                createdAt: row.date(2) ?? Date(),
                updatedAt: row.date(3) ?? Date()
            )
        }

        let itemRows = try database.query(
            """
            SELECT playlist_id, media_id
            FROM music_playlist_items
            ORDER BY playlist_id, position ASC
            """
        ) { row in
            (playlistID: row.string(0) ?? "", mediaID: row.string(1) ?? "")
        }

        let itemIDsByPlaylistID = Dictionary(grouping: itemRows, by: \.playlistID)
            .mapValues { rows in rows.map(\.mediaID).filter { !$0.isEmpty } }

        return playlists.map { playlist in
            var copy = playlist
            copy.itemIDs = itemIDsByPlaylistID[playlist.id] ?? []
            return copy
        }
    }

    public func create(name: String, itemIDs: [String] = []) throws -> MusicPlaylist {
        let now = Date()
        let playlist = MusicPlaylist(
            name: normalizedName(name),
            itemIDs: uniqueItemIDs(itemIDs),
            createdAt: now,
            updatedAt: now
        )

        try database.execute(
            """
            INSERT INTO music_playlists (id, name, created_at, updated_at)
            VALUES (?, ?, ?, ?)
            """,
            bindings: [
                .text(playlist.id),
                .text(playlist.name),
                .optionalDate(playlist.createdAt),
                .optionalDate(playlist.updatedAt)
            ]
        )
        try appendItems(playlist.itemIDs, toPlaylistID: playlist.id, updatedAt: now)
        return try fetch(id: playlist.id) ?? playlist
    }

    public func add(itemIDs: [String], toPlaylistID playlistID: String) throws -> MusicPlaylist? {
        let now = Date()
        try appendItems(uniqueItemIDs(itemIDs), toPlaylistID: playlistID, updatedAt: now)
        return try fetch(id: playlistID)
    }

    public func rename(id playlistID: String, name: String) throws -> MusicPlaylist? {
        let now = Date()
        try database.execute(
            """
            UPDATE music_playlists
            SET name = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .text(normalizedName(name)),
                .optionalDate(now),
                .text(playlistID)
            ]
        )
        return try fetch(id: playlistID)
    }

    public func delete(id playlistID: String) throws {
        try database.execute(
            "DELETE FROM music_playlists WHERE id = ?",
            bindings: [.text(playlistID)]
        )
    }

    public func remove(itemIDs: [String], fromPlaylistID playlistID: String) throws -> MusicPlaylist? {
        let removals = Set(uniqueItemIDs(itemIDs))
        guard !removals.isEmpty else { return try fetch(id: playlistID) }
        guard let current = try fetch(id: playlistID) else { return nil }
        return try replaceItems(
            current.itemIDs.filter { !removals.contains($0) },
            inPlaylistID: playlistID
        )
    }

    public func replaceItems(_ itemIDs: [String], inPlaylistID playlistID: String) throws -> MusicPlaylist? {
        let now = Date()
        let uniqueIDs = uniqueItemIDs(itemIDs)
        try database.transaction {
            try database.execute(
                "DELETE FROM music_playlist_items WHERE playlist_id = ?",
                bindings: [.text(playlistID)]
            )
            for (position, itemID) in uniqueIDs.enumerated() {
                try database.execute(
                    """
                    INSERT INTO music_playlist_items (playlist_id, media_id, position, added_at)
                    VALUES (?, ?, ?, ?)
                    """,
                    bindings: [
                        .text(playlistID),
                        .text(itemID),
                        .int(Int64(position)),
                        .optionalDate(now)
                    ]
                )
            }
            try database.execute(
                "UPDATE music_playlists SET updated_at = ? WHERE id = ?",
                bindings: [.optionalDate(now), .text(playlistID)]
            )
        }
        return try fetch(id: playlistID)
    }

    public func fetch(id: String) throws -> MusicPlaylist? {
        guard var playlist = try database.query(
            """
            SELECT id, name, created_at, updated_at
            FROM music_playlists
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)],
            map: { row in
                MusicPlaylist(
                    id: row.string(0) ?? UUID().uuidString,
                    name: row.string(1) ?? "新歌单",
                    itemIDs: [],
                    createdAt: row.date(2) ?? Date(),
                    updatedAt: row.date(3) ?? Date()
                )
            }
        ).first else {
            return nil
        }

        playlist.itemIDs = try database.query(
            """
            SELECT media_id
            FROM music_playlist_items
            WHERE playlist_id = ?
            ORDER BY position ASC
            """,
            bindings: [.text(id)]
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty }
        return playlist
    }

    private func appendItems(_ itemIDs: [String], toPlaylistID playlistID: String, updatedAt: Date) throws {
        guard !itemIDs.isEmpty else {
            try database.execute(
                "UPDATE music_playlists SET updated_at = ? WHERE id = ?",
                bindings: [.optionalDate(updatedAt), .text(playlistID)]
            )
            return
        }

        let currentMaxPosition = try database.query(
            "SELECT COALESCE(MAX(position), -1) FROM music_playlist_items WHERE playlist_id = ?",
            bindings: [.text(playlistID)]
        ) { row in
            row.int(0) ?? -1
        }.first ?? -1

        for (offset, itemID) in itemIDs.enumerated() {
            try database.execute(
                """
                INSERT OR IGNORE INTO music_playlist_items (playlist_id, media_id, position, added_at)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(playlistID),
                    .text(itemID),
                    .int(Int64(currentMaxPosition + offset + 1)),
                    .optionalDate(updatedAt)
                ]
            )
        }

        try database.execute(
            "UPDATE music_playlists SET updated_at = ? WHERE id = ?",
            bindings: [.optionalDate(updatedAt), .text(playlistID)]
        )
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "新歌单" : trimmed
    }

    private func uniqueItemIDs(_ itemIDs: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for itemID in itemIDs where !itemID.isEmpty {
            guard seen.insert(itemID).inserted else { continue }
            result.append(itemID)
        }
        return result
    }
}
