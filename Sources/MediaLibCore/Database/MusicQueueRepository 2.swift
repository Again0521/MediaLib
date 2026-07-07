import Foundation

public final class MusicQueueRepository: @unchecked Sendable {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetch() throws -> MusicQueueSnapshot {
        let state = try database.query(
            """
            SELECT repeat_mode, shuffle_enabled, updated_at
            FROM music_queue_state
            WHERE id = 1
            """
        ) { row in
            MusicQueueSnapshot(
                repeatModeRawValue: row.string(0) ?? "sequential",
                shuffleEnabled: row.bool(1),
                updatedAt: row.date(2) ?? Date()
            )
        }.first ?? MusicQueueSnapshot()

        let itemIDs = try database.query(
            """
            SELECT media_id
            FROM music_queue_items
            ORDER BY position ASC
            """
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty }

        var snapshot = state
        snapshot.itemIDs = itemIDs
        return snapshot
    }

    public func save(_ snapshot: MusicQueueSnapshot) throws {
        let itemIDs = uniqueItemIDs(snapshot.itemIDs)
        let updatedAt = Date()

        try database.transaction {
            try database.execute(
                """
                INSERT INTO music_queue_state (id, repeat_mode, shuffle_enabled, updated_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  repeat_mode = excluded.repeat_mode,
                  shuffle_enabled = excluded.shuffle_enabled,
                  updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(snapshot.repeatModeRawValue),
                    .bool(snapshot.shuffleEnabled),
                    .optionalDate(updatedAt)
                ]
            )
            try database.execute("DELETE FROM music_queue_items")
            for (position, itemID) in itemIDs.enumerated() {
                try database.execute(
                    """
                    INSERT INTO music_queue_items (media_id, position, added_at)
                    VALUES (?, ?, ?)
                    """,
                    bindings: [
                        .text(itemID),
                        .int(Int64(position)),
                        .optionalDate(updatedAt)
                    ]
                )
            }
        }
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
