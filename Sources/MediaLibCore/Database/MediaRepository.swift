import Foundation

public final class MediaRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func upsert(_ item: MediaItem) throws {
        try database.execute(
            """
            INSERT INTO media_items (
              id, type, title, original_title, artist, album, track_number, year, overview, poster_path, backdrop_path,
              rating, runtime, source_path, parent_id, season_number, episode_number,
              file_path, file_size, video_codec, audio_codec, resolution, video_bitrate, duration,
              play_position, play_progress, watched, favorite, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              type = excluded.type,
              title = excluded.title,
              original_title = COALESCE(excluded.original_title, media_items.original_title),
              artist = COALESCE(excluded.artist, media_items.artist),
              album = COALESCE(excluded.album, media_items.album),
              track_number = COALESCE(excluded.track_number, media_items.track_number),
              year = COALESCE(excluded.year, media_items.year),
              overview = COALESCE(excluded.overview, media_items.overview),
              poster_path = COALESCE(excluded.poster_path, media_items.poster_path),
              backdrop_path = COALESCE(excluded.backdrop_path, media_items.backdrop_path),
              rating = COALESCE(excluded.rating, media_items.rating),
              runtime = COALESCE(excluded.runtime, media_items.runtime),
              source_path = excluded.source_path,
              parent_id = excluded.parent_id,
              season_number = excluded.season_number,
              episode_number = excluded.episode_number,
              file_path = excluded.file_path,
              file_size = excluded.file_size,
              video_codec = COALESCE(excluded.video_codec, media_items.video_codec),
              audio_codec = COALESCE(excluded.audio_codec, media_items.audio_codec),
              resolution = COALESCE(excluded.resolution, media_items.resolution),
              video_bitrate = COALESCE(excluded.video_bitrate, media_items.video_bitrate),
              duration = COALESCE(excluded.duration, media_items.duration),
              external_id = COALESCE(excluded.external_id, media_items.external_id),
              metadata_provider = COALESCE(excluded.metadata_provider, media_items.metadata_provider),
              collection_title = COALESCE(excluded.collection_title, media_items.collection_title),
              updated_at = excluded.updated_at
            """,
            bindings: bindings(for: item)
        )
    }

    public func fetchAll() throws -> [MediaItem] {
        try database.query(selectSQL + " ORDER BY title COLLATE NOCASE ASC", map: map(row:))
    }

    public func fetchTopLevel(type: MediaType? = nil) throws -> [MediaItem] {
        if let type {
            return try database.query(
                selectSQL + " WHERE type = ? AND parent_id IS NULL ORDER BY title COLLATE NOCASE ASC",
                bindings: [.text(type.rawValue)],
                map: map(row:)
            )
        }
        return try database.query(
            selectSQL + " WHERE parent_id IS NULL ORDER BY updated_at DESC",
            map: map(row:)
        )
    }

    public func fetchChildren(parentID: String) throws -> [MediaItem] {
        try database.query(
            selectSQL + " WHERE parent_id = ? ORDER BY season_number ASC, episode_number ASC, title COLLATE NOCASE ASC",
            bindings: [.text(parentID)],
            map: map(row:)
        )
    }

    public func deleteItems(sourcePath: String) throws {
        try database.execute("DELETE FROM media_items WHERE source_path = ?", bindings: [.text(sourcePath)])
    }

    public func deleteItems(sourcePathPrefix: String) throws {
        try database.execute(
            "DELETE FROM media_items WHERE source_path = ? OR source_path LIKE ?",
            bindings: [.text(sourcePathPrefix), .text("\(sourcePathPrefix)/%")]
        )
    }

    public func deleteItems(filePath: String, excludingID id: String) throws {
        try database.execute(
            "DELETE FROM media_items WHERE file_path = ? AND id != ?",
            bindings: [.text(filePath), .text(id)]
        )
    }

    public func search(_ query: String) throws -> [MediaItem] {
        let token = "%\(query)%"
        return try database.query(
            selectSQL + " WHERE title LIKE ? OR original_title LIKE ? ORDER BY title COLLATE NOCASE ASC LIMIT 200",
            bindings: [.text(token), .text(token)],
            map: map(row:)
        )
    }

    public func updateArtwork(id: String, posterPath: String?, backdropPath: String?) throws {
        try database.execute(
            "UPDATE media_items SET poster_path = COALESCE(?, poster_path), backdrop_path = COALESCE(?, backdrop_path), updated_at = ? WHERE id = ?",
            bindings: [
                .optionalText(posterPath),
                .optionalText(backdropPath),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func updatePlayback(id: String, position: Double, duration: Double?, watchedThreshold: Double) throws {
        let progress = duration.map { $0 > 0 ? min(max(position / $0, 0), 1) : 0 } ?? 0
        let watched = progress >= watchedThreshold
        try database.execute(
            """
            UPDATE media_items
            SET play_position = ?, play_progress = ?, watched = ?, last_played_at = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .double(position),
                .double(progress),
                .bool(watched),
                .optionalDate(Date()),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func clearPlaybackHistory(id: String) throws {
        try database.execute(
            """
            UPDATE media_items
            SET play_position = 0, play_progress = 0, watched = 0, last_played_at = NULL, updated_at = ?
            WHERE id = ?
            """,
            bindings: [.optionalDate(Date()), .text(id)]
        )
    }

    public func clearPlaybackHistory(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        let now = Date()
        var startIndex = 0
        while startIndex < ids.count {
            let endIndex = Swift.min(startIndex + 400, ids.count)
            let chunk = ids[startIndex..<endIndex]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try database.execute(
                """
                UPDATE media_items
                SET play_position = 0,
                    play_progress = 0,
                    watched = 0,
                    last_played_at = NULL,
                    updated_at = ?
                WHERE id IN (\(placeholders))
                """,
                bindings: [.optionalDate(now)] + chunk.map { .text($0) }
            )
            startIndex = endIndex
        }
    }

    public func setFavorite(id: String, favorite: Bool) throws {
        try database.execute(
            "UPDATE media_items SET favorite = ?, updated_at = ? WHERE id = ?",
            bindings: [.bool(favorite), .optionalDate(Date()), .text(id)]
        )
    }

    public func updateType(id: String, type: MediaType) throws {
        try database.execute(
            "UPDATE media_items SET type = ?, updated_at = ? WHERE id = ?",
            bindings: [.text(type.rawValue), .optionalDate(Date()), .text(id)]
        )
    }

    public func updateRating(id: String, rating: Double?) throws {
        try database.execute(
            "UPDATE media_items SET rating = ?, updated_at = ? WHERE id = ?",
            bindings: [.optionalDouble(rating), .optionalDate(Date()), .text(id)]
        )
    }

    public func updateMetadata(id: String, metadata: MediaMetadataUpdate) throws {
        try database.execute(
            """
            UPDATE media_items
            SET title = COALESCE(?, title),
                original_title = COALESCE(?, original_title),
                artist = COALESCE(?, artist),
                album = COALESCE(?, album),
                track_number = COALESCE(?, track_number),
                year = COALESCE(?, year),
                overview = COALESCE(?, overview),
                poster_path = COALESCE(?, poster_path),
                backdrop_path = COALESCE(?, backdrop_path),
                rating = COALESCE(?, rating),
                runtime = COALESCE(?, runtime),
                external_id = COALESCE(?, external_id),
                metadata_provider = COALESCE(?, metadata_provider),
                collection_title = COALESCE(?, collection_title),
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .optionalText(metadata.title),
                .optionalText(metadata.originalTitle),
                .optionalText(metadata.artist),
                .optionalText(metadata.album),
                .optionalInt(metadata.trackNumber),
                .optionalInt(metadata.year),
                .optionalText(metadata.overview),
                .optionalText(metadata.posterPath),
                .optionalText(metadata.backdropPath),
                .optionalDouble(metadata.rating),
                .optionalInt(metadata.runtime),
                .optionalText(metadata.externalID),
                .optionalText(metadata.metadataProvider),
                .optionalText(metadata.collectionTitle),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func markWatched(id: String, watched: Bool) throws {
        try database.execute(
            "UPDATE media_items SET watched = ?, play_progress = CASE WHEN ? THEN 1 ELSE play_progress END, updated_at = ? WHERE id = ?",
            bindings: [.bool(watched), .bool(watched), .optionalDate(Date()), .text(id)]
        )
    }

    private var selectSQL: String {
        """
        SELECT id, type, title, original_title, artist, album, track_number, year, overview, poster_path, backdrop_path,
               rating, runtime, source_path, parent_id, season_number, episode_number,
               file_path, file_size, video_codec, audio_codec, resolution, video_bitrate, duration,
               play_position, play_progress, watched, favorite, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at
        FROM media_items
        """
    }

    private func bindings(for item: MediaItem) -> [SQLiteValue] {
        [
            .text(item.id),
            .text(item.type.rawValue),
            .text(item.title),
            .optionalText(item.originalTitle),
            .optionalText(item.artist),
            .optionalText(item.album),
            .optionalInt(item.trackNumber),
            .optionalInt(item.year),
            .optionalText(item.overview),
            .optionalText(item.posterPath),
            .optionalText(item.backdropPath),
            .optionalDouble(item.rating),
            .optionalInt(item.runtime),
            .optionalText(item.sourcePath),
            .optionalText(item.parentID),
            .optionalInt(item.seasonNumber),
            .optionalInt(item.episodeNumber),
            .optionalText(item.filePath),
            .optionalInt64(item.fileSize),
            .optionalText(item.videoCodec),
            .optionalText(item.audioCodec),
            .optionalText(item.resolution),
            .optionalInt64(item.videoBitrate),
            .optionalDouble(item.duration),
            .double(item.playPosition),
            .double(item.playProgress),
            .bool(item.watched),
            .bool(item.favorite),
            .optionalText(item.externalID),
            .optionalText(item.metadataProvider),
            .optionalText(item.collectionTitle),
            .optionalDate(item.createdAt),
            .optionalDate(item.updatedAt),
            .optionalDate(item.lastPlayedAt)
        ]
    }

    private func map(row: SQLiteRow) -> MediaItem {
        MediaItem(
            id: row.string(0) ?? UUID().uuidString,
            type: MediaType(rawValue: row.string(1) ?? "") ?? .movie,
            title: row.string(2) ?? "未命名媒体",
            originalTitle: row.string(3),
            artist: row.string(4),
            album: row.string(5),
            trackNumber: row.int(6),
            year: row.int(7),
            overview: row.string(8),
            posterPath: row.string(9),
            backdropPath: row.string(10),
            rating: row.double(11),
            runtime: row.int(12),
            sourcePath: row.string(13),
            parentID: row.string(14),
            seasonNumber: row.int(15),
            episodeNumber: row.int(16),
            filePath: row.string(17),
            fileSize: row.int64(18),
            videoCodec: row.string(19),
            audioCodec: row.string(20),
            resolution: row.string(21),
            videoBitrate: row.int64(22),
            duration: row.double(23),
            playPosition: row.double(24) ?? 0,
            playProgress: row.double(25) ?? 0,
            watched: row.bool(26),
            favorite: row.bool(27),
            externalID: row.string(28),
            metadataProvider: row.string(29),
            collectionTitle: row.string(30),
            createdAt: row.date(31) ?? Date(),
            updatedAt: row.date(32) ?? Date(),
            lastPlayedAt: row.date(33)
        )
    }
}

public struct MediaMetadataUpdate: Sendable {
    public var title: String?
    public var originalTitle: String?
    public var artist: String?
    public var album: String?
    public var trackNumber: Int?
    public var year: Int?
    public var overview: String?
    public var posterPath: String?
    public var backdropPath: String?
    public var rating: Double?
    public var runtime: Int?
    public var externalID: String?
    public var metadataProvider: String?
    public var collectionTitle: String?

    public init(
        title: String? = nil,
        originalTitle: String? = nil,
        artist: String? = nil,
        album: String? = nil,
        trackNumber: Int? = nil,
        year: Int? = nil,
        overview: String? = nil,
        posterPath: String? = nil,
        backdropPath: String? = nil,
        rating: Double? = nil,
        runtime: Int? = nil,
        externalID: String? = nil,
        metadataProvider: String? = nil,
        collectionTitle: String? = nil
    ) {
        self.title = title
        self.originalTitle = originalTitle
        self.artist = artist
        self.album = album
        self.trackNumber = trackNumber
        self.year = year
        self.overview = overview
        self.posterPath = posterPath
        self.backdropPath = backdropPath
        self.rating = rating
        self.runtime = runtime
        self.externalID = externalID
        self.metadataProvider = metadataProvider
        self.collectionTitle = collectionTitle
    }
}
