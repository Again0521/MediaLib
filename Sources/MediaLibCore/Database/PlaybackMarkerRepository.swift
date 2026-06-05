import Foundation

public final class PlaybackMarkerRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetch(mediaID: String) throws -> [PlaybackMarker] {
        try database.query(
            """
            SELECT id, media_id, kind, title, start_time, end_time, origin, created_at, updated_at
            FROM playback_markers
            WHERE media_id = ?
            ORDER BY start_time ASC, created_at ASC
            """,
            bindings: [.text(mediaID)],
            map: map(row:)
        )
    }

    @discardableResult
    public func save(_ marker: PlaybackMarker) throws -> PlaybackMarker {
        var updated = marker
        updated.title = normalizedTitle(marker.title, kind: marker.kind)
        updated.startTime = max(marker.startTime, 0)
        updated.endTime = marker.endTime.map { max($0, 0) }
        updated.updatedAt = Date()
        try database.execute(
            """
            INSERT INTO playback_markers (
              id, media_id, kind, title, start_time, end_time, origin, created_at, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              media_id = excluded.media_id,
              kind = excluded.kind,
              title = excluded.title,
              start_time = excluded.start_time,
              end_time = excluded.end_time,
              origin = excluded.origin,
              updated_at = excluded.updated_at
            """,
            bindings: [
                .text(updated.id),
                .text(updated.mediaID),
                .text(updated.kind.rawValue),
                .text(updated.title),
                .double(updated.startTime),
                .optionalDouble(updated.endTime),
                .text(updated.origin.rawValue),
                .optionalDate(updated.createdAt),
                .optionalDate(updated.updatedAt)
            ]
        )
        return updated
    }

    public func replaceEmbeddedChapters(mediaID: String, with chapters: [PlaybackMarker]) throws {
        let existing = try fetch(mediaID: mediaID).filter {
            $0.kind == .chapter && $0.origin == .embedded
        }
        guard !Self.matches(existing, chapters) else { return }
        try database.transaction {
            try database.execute(
                "DELETE FROM playback_markers WHERE media_id = ? AND kind = ? AND origin = ?",
                bindings: [.text(mediaID), .text(PlaybackMarker.Kind.chapter.rawValue), .text(PlaybackMarker.Origin.embedded.rawValue)]
            )
            for chapter in chapters {
                try save(chapter)
            }
        }
    }

    public func delete(id: String) throws {
        try database.execute("DELETE FROM playback_markers WHERE id = ?", bindings: [.text(id)])
    }

    private func normalizedTitle(_ title: String, kind: PlaybackMarker.Kind) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? kind.title : trimmed
    }

    private static func matches(_ lhs: [PlaybackMarker], _ rhs: [PlaybackMarker]) -> Bool {
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).allSatisfy { left, right in
            left.id == right.id &&
                left.title == right.title &&
                abs(left.startTime - right.startTime) < 0.001 &&
                optionalTimesMatch(left.endTime, right.endTime)
        }
    }

    private static func optionalTimesMatch(_ lhs: Double?, _ rhs: Double?) -> Bool {
        switch (lhs, rhs) {
        case (.none, .none):
            return true
        case let (.some(left), .some(right)):
            return abs(left - right) < 0.001
        default:
            return false
        }
    }

    private func map(row: SQLiteRow) -> PlaybackMarker {
        PlaybackMarker(
            id: row.string(0) ?? UUID().uuidString,
            mediaID: row.string(1) ?? "",
            kind: PlaybackMarker.Kind(rawValue: row.string(2) ?? "") ?? .chapter,
            title: row.string(3) ?? "章节",
            startTime: row.double(4) ?? 0,
            endTime: row.double(5),
            origin: PlaybackMarker.Origin(rawValue: row.string(6) ?? "") ?? .manual,
            createdAt: row.date(7) ?? Date(),
            updatedAt: row.date(8) ?? Date()
        )
    }
}
