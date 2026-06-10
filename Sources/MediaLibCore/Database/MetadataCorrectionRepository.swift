import Foundation

public final class MetadataCorrectionRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    @discardableResult
    public func record(
        mediaID: String,
        changes: [MetadataCorrectionFieldChange],
        source: String,
        batchID: String = UUID().uuidString,
        createdAt: Date = Date()
    ) throws -> [MetadataCorrectionRecord] {
        let meaningfulChanges = changes.filter { $0.oldValue != $0.newValue }
        guard !meaningfulChanges.isEmpty else { return [] }
        let records = meaningfulChanges.map {
            MetadataCorrectionRecord(
                batchID: batchID,
                mediaID: mediaID,
                field: $0.field,
                oldValue: $0.oldValue,
                newValue: $0.newValue,
                source: source,
                createdAt: createdAt
            )
        }
        try database.transaction {
            for record in records {
                try save(record)
            }
        }
        return records
    }

    public func activeCountsByMediaID() throws -> [String: Int] {
        let rows = try database.query(
            """
            SELECT media_id, COUNT(*)
            FROM metadata_correction_history
            WHERE undone_at IS NULL
            GROUP BY media_id
            """
        ) { row in
            (row.string(0) ?? "", row.int(1) ?? 0)
        }
        return Dictionary(uniqueKeysWithValues: rows.filter { !$0.0.isEmpty })
    }

    public func activeRecordCount() throws -> Int {
        try database.query(
            "SELECT COUNT(*) FROM metadata_correction_history WHERE undone_at IS NULL"
        ) { row in
            row.int(0) ?? 0
        }.first ?? 0
    }

    public func fetchActiveBatches(limit: Int = 100) throws -> [MetadataCorrectionBatchSummary] {
        try database.query(
            """
            SELECT batch_id, media_id, source, MAX(created_at) AS latest_created_at, COUNT(*), GROUP_CONCAT(field_name, ','), MAX(rowid) AS latest_rowid
            FROM metadata_correction_history
            WHERE undone_at IS NULL
            GROUP BY batch_id, media_id
            ORDER BY latest_created_at DESC, latest_rowid DESC
            LIMIT ?
            """,
            bindings: [.int(Int64(max(limit, 1)))]
        ) { row in
            let fields = (row.string(5) ?? "")
                .split(separator: ",")
                .compactMap { MetadataCorrectionField(rawValue: String($0)) }
            return MetadataCorrectionBatchSummary(
                batchID: row.string(0) ?? "",
                mediaID: row.string(1) ?? "",
                source: row.string(2) ?? "unknown",
                createdAt: row.date(3) ?? Date(),
                fieldCount: row.int(4) ?? fields.count,
                fields: fields
            )
        }
    }

    public func latestUndoableBatch(mediaID: String) throws -> [MetadataCorrectionRecord] {
        let batchIDs = try database.query(
            """
            SELECT batch_id
            FROM metadata_correction_history
            WHERE media_id = ? AND undone_at IS NULL
            ORDER BY created_at DESC, rowid DESC
            LIMIT 1
            """,
            bindings: [.text(mediaID)]
        ) { row in
            row.string(0)
        }
        guard let rawBatchID = batchIDs.first,
              let batchID = rawBatchID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !batchID.isEmpty else {
            return []
        }
        return try records(batchID: batchID, mediaID: mediaID)
    }

    public func records(batchID: String, mediaID: String) throws -> [MetadataCorrectionRecord] {
        return try database.query(
            """
            SELECT id, batch_id, media_id, field_name, old_value, new_value, source, created_at, undone_at
            FROM metadata_correction_history
            WHERE batch_id = ? AND media_id = ? AND undone_at IS NULL
            ORDER BY created_at ASC, rowid ASC
            """,
            bindings: [.text(batchID), .text(mediaID)],
            map: map(row:)
        )
    }

    public func markBatchUndone(batchID: String, undoneAt: Date = Date()) throws {
        try database.execute(
            """
            UPDATE metadata_correction_history
            SET undone_at = ?
            WHERE batch_id = ? AND undone_at IS NULL
            """,
            bindings: [.optionalDate(undoneAt), .text(batchID)]
        )
    }

    private func save(_ record: MetadataCorrectionRecord) throws {
        try database.execute(
            """
            INSERT INTO metadata_correction_history (
              id, batch_id, media_id, field_name, old_value, new_value, source, created_at, undone_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              batch_id = excluded.batch_id,
              media_id = excluded.media_id,
              field_name = excluded.field_name,
              old_value = excluded.old_value,
              new_value = excluded.new_value,
              source = excluded.source,
              created_at = excluded.created_at,
              undone_at = excluded.undone_at
            """,
            bindings: [
                .text(record.id),
                .text(record.batchID),
                .text(record.mediaID),
                .text(record.field.rawValue),
                .optionalText(record.oldValue),
                .optionalText(record.newValue),
                .text(record.source),
                .optionalDate(record.createdAt),
                .optionalDate(record.undoneAt)
            ]
        )
    }

    private func map(row: SQLiteRow) -> MetadataCorrectionRecord {
        MetadataCorrectionRecord(
            id: row.string(0) ?? UUID().uuidString,
            batchID: row.string(1) ?? "",
            mediaID: row.string(2) ?? "",
            field: MetadataCorrectionField(rawValue: row.string(3) ?? "") ?? .title,
            oldValue: row.string(4),
            newValue: row.string(5),
            source: row.string(6) ?? "unknown",
            createdAt: row.date(7) ?? Date(),
            undoneAt: row.date(8)
        )
    }
}
