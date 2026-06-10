import Foundation

public final class VideoManualCollectionRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchAll() throws -> [VideoManualCollection] {
        let collections = try database.query(
            """
            SELECT id, name, show_on_home, created_at, updated_at
            FROM video_manual_collections
            ORDER BY updated_at DESC, name COLLATE NOCASE ASC
            """
        ) { row in
            VideoManualCollection(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "新集合",
                itemIDs: [],
                showOnHome: row.bool(2),
                createdAt: row.date(3) ?? Date(),
                updatedAt: row.date(4) ?? Date()
            )
        }

        let itemRows = try database.query(
            """
            SELECT collection_id, media_id
            FROM video_manual_collection_items
            ORDER BY collection_id, position ASC
            """
        ) { row in
            (collectionID: row.string(0) ?? "", mediaID: row.string(1) ?? "")
        }

        let itemIDsByCollectionID = Dictionary(grouping: itemRows, by: \.collectionID)
            .mapValues { rows in rows.map(\.mediaID).filter { !$0.isEmpty } }

        return collections.map { collection in
            var copy = collection
            copy.itemIDs = itemIDsByCollectionID[collection.id] ?? []
            return copy
        }
    }

    public func fetch(id: String) throws -> VideoManualCollection? {
        let collectionRows = try database.query(
            """
            SELECT id, name, show_on_home, created_at, updated_at
            FROM video_manual_collections
            WHERE id = ?
            LIMIT 1
            """,
            bindings: [.text(id)]
        ) { row in
            VideoManualCollection(
                id: row.string(0) ?? UUID().uuidString,
                name: row.string(1) ?? "新集合",
                itemIDs: [],
                showOnHome: row.bool(2),
                createdAt: row.date(3) ?? Date(),
                updatedAt: row.date(4) ?? Date()
            )
        }
        guard var collection = collectionRows.first else {
            return nil
        }

        collection.itemIDs = try database.query(
            """
            SELECT media_id
            FROM video_manual_collection_items
            WHERE collection_id = ?
            ORDER BY position ASC
            """,
            bindings: [.text(id)]
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty }
        return collection
    }

    public func save(_ collection: VideoManualCollection) throws -> VideoManualCollection {
        var updated = collection
        updated.name = normalizedName(collection.name)
        updated.itemIDs = uniqueItemIDs(collection.itemIDs)
        updated.updatedAt = Date()

        try database.transaction {
            try database.execute(
                """
                INSERT INTO video_manual_collections (id, name, show_on_home, created_at, updated_at)
                VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  name = excluded.name,
                  show_on_home = excluded.show_on_home,
                  updated_at = excluded.updated_at
                """,
                bindings: [
                    .text(updated.id),
                    .text(updated.name),
                    .bool(updated.showOnHome),
                    .optionalDate(updated.createdAt),
                    .optionalDate(updated.updatedAt)
                ]
            )
            try replaceItemRows(collectionID: updated.id, itemIDs: updated.itemIDs, updatedAt: updated.updatedAt)
        }
        return try fetch(id: updated.id) ?? updated
    }

    public func create(name: String, itemIDs: [String] = []) throws -> VideoManualCollection {
        let now = Date()
        let collection = VideoManualCollection(
            name: normalizedName(name),
            itemIDs: uniqueItemIDs(itemIDs),
            createdAt: now,
            updatedAt: now
        )
        return try save(collection)
    }

    public func delete(id: String) throws {
        try database.execute(
            "DELETE FROM video_manual_collections WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    public func add(itemIDs: [String], toCollectionID collectionID: String) throws -> VideoManualCollection? {
        let newIDs = uniqueItemIDs(itemIDs)
        guard !newIDs.isEmpty else { return try fetch(id: collectionID) }
        guard var collection = try fetch(id: collectionID) else { return nil }
        collection.itemIDs = uniqueItemIDs(collection.itemIDs + newIDs)
        return try save(collection)
    }

    public func remove(itemIDs: [String], fromCollectionID collectionID: String) throws -> VideoManualCollection? {
        let removals = Set(uniqueItemIDs(itemIDs))
        guard !removals.isEmpty else { return try fetch(id: collectionID) }
        guard var collection = try fetch(id: collectionID) else { return nil }
        collection.itemIDs = collection.itemIDs.filter { !removals.contains($0) }
        return try save(collection)
    }

    private func replaceItemRows(collectionID: String, itemIDs: [String], updatedAt: Date) throws {
        try database.execute(
            "DELETE FROM video_manual_collection_items WHERE collection_id = ?",
            bindings: [.text(collectionID)]
        )
        for (position, itemID) in uniqueItemIDs(itemIDs).enumerated() {
            try database.execute(
                """
                INSERT INTO video_manual_collection_items (collection_id, media_id, position, added_at)
                VALUES (?, ?, ?, ?)
                """,
                bindings: [
                    .text(collectionID),
                    .text(itemID),
                    .int(Int64(position)),
                    .optionalDate(updatedAt)
                ]
            )
        }
    }

    private func normalizedName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "新集合" : trimmed
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
