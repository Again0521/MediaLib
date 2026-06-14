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
              rating, user_rating, runtime, source_path, parent_id, season_number, episode_number,
              file_path, file_size, video_codec, audio_codec, resolution, video_bitrate, duration,
              loudness_track_gain_db, loudness_album_gain_db, loudness_track_peak, loudness_album_peak,
              play_count, play_position, play_progress, watched, favorite, watchlist, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at, genre
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              type = excluded.type,
              title = CASE
                WHEN EXISTS (
                  SELECT 1 FROM metadata_correction_history
                  WHERE media_id = media_items.id
                    AND field_name = 'title'
                    AND undone_at IS NULL
                ) THEN media_items.title
                ELSE excluded.title
              END,
              original_title = COALESCE(excluded.original_title, media_items.original_title),
              artist = COALESCE(excluded.artist, media_items.artist),
              album = COALESCE(excluded.album, media_items.album),
              track_number = COALESCE(excluded.track_number, media_items.track_number),
              year = COALESCE(excluded.year, media_items.year),
              overview = COALESCE(excluded.overview, media_items.overview),
              poster_path = COALESCE(excluded.poster_path, media_items.poster_path),
              backdrop_path = COALESCE(excluded.backdrop_path, media_items.backdrop_path),
              rating = COALESCE(excluded.rating, media_items.rating),
              user_rating = COALESCE(media_items.user_rating, excluded.user_rating),
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
              loudness_track_gain_db = excluded.loudness_track_gain_db,
              loudness_album_gain_db = excluded.loudness_album_gain_db,
              loudness_track_peak = excluded.loudness_track_peak,
              loudness_album_peak = excluded.loudness_album_peak,
              play_count = media_items.play_count,
              external_id = COALESCE(excluded.external_id, media_items.external_id),
              metadata_provider = COALESCE(excluded.metadata_provider, media_items.metadata_provider),
              collection_title = COALESCE(excluded.collection_title, media_items.collection_title),
              genre = COALESCE(excluded.genre, media_items.genre),
              updated_at = excluded.updated_at
            """,
            bindings: bindings(for: item)
        )
    }

    public func replaceRemoteItems(sourcePathPrefix: String, with items: [MediaItem]) throws {
        let sourcePathPrefix = Self.normalizedSourcePathPrefix(sourcePathPrefix)
        let sourcePathLikePattern = Self.escapedLikeChildPattern(for: sourcePathPrefix)
        let keepIDs = Set(items.map(\.id))
        try database.transaction {
            // media_items 上有全局 UNIQUE(file_path) 索引。远端（如 Emby）删除再重连时，
            // 服务器对持久 DeviceId 常会复用同一 token，导致流地址 file_path 与历史残留行完全一致，
            // 而新条目 id 因 sourceID 变化而不同——此时 upsert 的 ON CONFLICT(id) 无法吸收 file_path 冲突，
            // 会抛出唯一约束错误。这里在写入前先清掉与本次导入 file_path 相同但 id 不同的残留行。
            for item in items {
                guard let filePath = item.filePath, !filePath.isEmpty else { continue }
                try database.execute(
                    "DELETE FROM media_items WHERE file_path = ? AND id != ?",
                    bindings: [.text(filePath), .text(item.id)]
                )
            }
            for item in items {
                try upsert(item)
                try database.execute(
                    """
                    UPDATE media_items
                    SET play_position = ?,
                        play_progress = ?,
                        watched = ?,
                        favorite = ?,
                        last_played_at = ?,
                        updated_at = ?
                    WHERE id = ?
                    """,
                    bindings: [
                        .double(item.playPosition),
                        .double(item.playProgress),
                        .bool(item.watched),
                        .bool(item.favorite),
                        .optionalDate(item.lastPlayedAt),
                        .optionalDate(item.updatedAt),
                        .text(item.id)
                    ]
                )
            }

            try database.execute("CREATE TEMP TABLE IF NOT EXISTS remote_keep_ids (id TEXT PRIMARY KEY)")
            try database.execute("DELETE FROM remote_keep_ids")
            for id in keepIDs {
                try database.execute("INSERT OR IGNORE INTO remote_keep_ids (id) VALUES (?)", bindings: [.text(id)])
            }
            try database.execute(
                """
                DELETE FROM media_items
                WHERE (source_path = ? OR source_path LIKE ? ESCAPE '\\')
                  AND id NOT IN (SELECT id FROM remote_keep_ids)
                """,
                // The slash boundary keeps `emby://host/source` from deleting `emby://host/source2`.
                bindings: [.text(sourcePathPrefix), .text(sourcePathLikePattern)]
            )
            try database.execute("DELETE FROM remote_keep_ids")
        }
    }

    public func fetchAll() throws -> [MediaItem] {
        try database.query(selectSQL + " ORDER BY title COLLATE NOCASE ASC", map: map(row:))
    }

    public func fetch(id: String) throws -> MediaItem? {
        try database.query(
            selectSQL + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)],
            map: map(row:)
        ).first
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
        let sourcePathPrefix = Self.normalizedSourcePathPrefix(sourcePathPrefix)
        try database.execute(
            "DELETE FROM media_items WHERE source_path = ? OR source_path LIKE ? ESCAPE '\\'",
            bindings: [.text(sourcePathPrefix), .text(Self.escapedLikeChildPattern(for: sourcePathPrefix))]
        )
    }

    public func deleteItems(sourcePath: String, excludingIDs ids: Set<String>) throws {
        guard !ids.isEmpty else {
            try deleteItems(sourcePath: sourcePath)
            return
        }
        try database.transaction {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS scan_keep_ids (id TEXT PRIMARY KEY)")
            try database.execute("DELETE FROM scan_keep_ids")
            for id in ids {
                try database.execute("INSERT OR IGNORE INTO scan_keep_ids (id) VALUES (?)", bindings: [.text(id)])
            }
            try database.execute(
                "DELETE FROM media_items WHERE source_path = ? AND id NOT IN (SELECT id FROM scan_keep_ids)",
                bindings: [.text(sourcePath)]
            )
            try database.execute("DELETE FROM scan_keep_ids")
        }
    }

    public func deleteItems(filePath: String, excludingID id: String) throws {
        try database.execute(
            "DELETE FROM media_items WHERE file_path = ? AND id != ?",
            bindings: [.text(filePath), .text(id)]
        )
    }

    public func deleteItems(filePath: String) throws {
        try database.execute("DELETE FROM media_items WHERE file_path = ?", bindings: [.text(filePath)])
    }

    public func deleteItems(filePathPrefix: String, sourcePath: String) throws {
        try database.execute(
            "DELETE FROM media_items WHERE source_path = ? AND (file_path = ? OR file_path LIKE ? ESCAPE '\\')",
            bindings: [.text(sourcePath), .text(filePathPrefix), .text(Self.escapedLikeChildPattern(for: filePathPrefix))]
        )
    }

    public func deleteOrphanParents(sourcePath: String) throws {
        try database.execute(
            """
            DELETE FROM media_items
            WHERE source_path = ?
              AND file_path IS NULL
              AND NOT EXISTS (
                  SELECT 1 FROM media_items AS children
                  WHERE children.parent_id = media_items.id
              )
            """,
            bindings: [.text(sourcePath)]
        )
    }

    public func deleteItems(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        var startIndex = 0
        while startIndex < ids.count {
            let endIndex = Swift.min(startIndex + 400, ids.count)
            let chunk = ids[startIndex..<endIndex]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try database.execute(
                """
                WITH RECURSIVE delete_tree(id) AS (
                    SELECT id FROM media_items WHERE id IN (\(placeholders))
                    UNION
                    SELECT child.id
                    FROM media_items AS child
                    JOIN delete_tree AS parent ON child.parent_id = parent.id
                )
                DELETE FROM media_items WHERE id IN (SELECT id FROM delete_tree)
                """,
                bindings: chunk.map { .text($0) }
            )
            startIndex = endIndex
        }
    }

    public func search(_ query: String) throws -> [MediaItem] {
        let token = Self.escapedLikeContainsPattern(for: query)
        return try database.query(
            selectSQL + " WHERE title LIKE ? ESCAPE '\\' OR original_title LIKE ? ESCAPE '\\' ORDER BY title COLLATE NOCASE ASC LIMIT 200",
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
        // 已看只置位、不复位：重看一部已看影片的开头不应把「已看」刷回未看
        // （主流媒体库 Plex/Emby 的口径）。取消已看走显式的标记接口。
        let reachedThreshold = progress >= watchedThreshold
        try database.execute(
            """
            UPDATE media_items
            SET play_position = ?, play_progress = ?, watched = CASE WHEN ? THEN 1 ELSE watched END, last_played_at = ?, updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .double(position),
                .double(progress),
                .bool(reachedThreshold),
                .optionalDate(Date()),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func incrementPlayCount(id: String) throws {
        try database.execute(
            "UPDATE media_items SET play_count = COALESCE(play_count, 0) + 1 WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    public func resetPlayCount(id: String) throws {
        try database.execute(
            "UPDATE media_items SET play_count = 0 WHERE id = ?",
            bindings: [.text(id)]
        )
    }

    public func resetPlayCounts(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        var startIndex = 0
        while startIndex < ids.count {
            let endIndex = Swift.min(startIndex + 400, ids.count)
            let chunk = ids[startIndex..<endIndex]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ", ")
            try database.execute(
                "UPDATE media_items SET play_count = 0 WHERE id IN (\(placeholders))",
                bindings: chunk.map { .text($0) }
            )
            startIndex = endIndex
        }
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

    public func setWatchlist(id: String, watchlist: Bool) throws {
        try database.execute(
            "UPDATE media_items SET watchlist = ?, updated_at = ? WHERE id = ?",
            bindings: [.bool(watchlist), .optionalDate(Date()), .text(id)]
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
            "UPDATE media_items SET user_rating = ?, updated_at = ? WHERE id = ?",
            bindings: [.optionalDouble(rating), .optionalDate(Date()), .text(id)]
        )
    }

    @discardableResult
    public func updateMetadata(id: String, metadata: MediaMetadataUpdate) throws -> [MetadataCorrectionFieldChange] {
        try database.transaction {
            let before = try fetch(id: id)
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
                    user_rating = COALESCE(user_rating, ?),
                    runtime = COALESCE(?, runtime),
                    external_id = COALESCE(?, external_id),
                    metadata_provider = COALESCE(?, metadata_provider),
                    collection_title = COALESCE(?, collection_title),
                    genre = COALESCE(?, genre),
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
                    .optionalDouble(Self.seedUserRating(from: metadata.rating)),
                    .optionalInt(metadata.runtime),
                    .optionalText(metadata.externalID),
                    .optionalText(metadata.metadataProvider),
                    .optionalText(metadata.collectionTitle),
                    .optionalText(metadata.genre),
                    .optionalDate(Date()),
                    .text(id)
                ]
            )
            guard let before, let after = try fetch(id: id) else { return [] }
            return Self.metadataChanges(before: before, after: after)
        }
    }

    public func restoreMetadataValues(id: String, values: [MetadataCorrectionField: String?]) throws {
        guard !values.isEmpty else { return }
        let ordered = values.sorted { $0.key.rawValue < $1.key.rawValue }
        let assignments = ordered
            .map { "\($0.key.databaseColumn) = ?" }
            .joined(separator: ", ")
        try database.execute(
            """
            UPDATE media_items
            SET \(assignments),
                updated_at = ?
            WHERE id = ?
            """,
            bindings: ordered.map { Self.sqliteValue(for: $0.key, encodedValue: $0.value) } + [
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    public func markWatched(id: String, watched: Bool, clearWatchlistWhenWatched: Bool = false) throws {
        try database.execute(
            """
            UPDATE media_items
            SET watched = ?,
                play_position = CASE WHEN ? THEN play_position ELSE 0 END,
                play_progress = CASE WHEN ? THEN 1 ELSE 0 END,
                last_played_at = CASE WHEN ? THEN last_played_at ELSE NULL END,
                watchlist = CASE WHEN ? AND ? AND type != ? THEN 0 ELSE watchlist END,
                updated_at = ?
            WHERE id = ?
            """,
            bindings: [
                .bool(watched),
                .bool(watched),
                .bool(watched),
                .bool(watched),
                .bool(watched),
                .bool(clearWatchlistWhenWatched),
                .text(MediaType.music.rawValue),
                .optionalDate(Date()),
                .text(id)
            ]
        )
    }

    private var selectSQL: String {
        """
        SELECT id, type, title, original_title, artist, album, track_number, year, overview, poster_path, backdrop_path,
               rating, user_rating, runtime, source_path, parent_id, season_number, episode_number,
               file_path, file_size, video_codec, audio_codec, resolution, video_bitrate, duration,
               loudness_track_gain_db, loudness_album_gain_db, loudness_track_peak, loudness_album_peak,
               play_count, play_position, play_progress, watched, favorite, watchlist, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at, genre
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
            .optionalDouble(item.userRating),
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
            .optionalDouble(item.loudnessTrackGainDB),
            .optionalDouble(item.loudnessAlbumGainDB),
            .optionalDouble(item.loudnessTrackPeak),
            .optionalDouble(item.loudnessAlbumPeak),
            .optionalInt(item.playCount),
            .double(item.playPosition),
            .double(item.playProgress),
            .bool(item.watched),
            .bool(item.favorite),
            .bool(item.watchlist),
            .optionalText(item.externalID),
            .optionalText(item.metadataProvider),
            .optionalText(item.collectionTitle),
            .optionalDate(item.createdAt),
            .optionalDate(item.updatedAt),
            .optionalDate(item.lastPlayedAt),
            .optionalText(item.genre)
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
            userRating: row.double(12),
            runtime: row.int(13),
            sourcePath: row.string(14),
            parentID: row.string(15),
            seasonNumber: row.int(16),
            episodeNumber: row.int(17),
            filePath: row.string(18),
            fileSize: row.int64(19),
            videoCodec: row.string(20),
            audioCodec: row.string(21),
            resolution: row.string(22),
            videoBitrate: row.int64(23),
            duration: row.double(24),
            loudnessTrackGainDB: row.double(25),
            loudnessAlbumGainDB: row.double(26),
            loudnessTrackPeak: row.double(27),
            loudnessAlbumPeak: row.double(28),
            playCount: row.int(29) ?? 0,
            playPosition: row.double(30) ?? 0,
            playProgress: row.double(31) ?? 0,
            watched: row.bool(32),
            favorite: row.bool(33),
            watchlist: row.bool(34),
            externalID: row.string(35),
            metadataProvider: row.string(36),
            collectionTitle: row.string(37),
            createdAt: row.date(38) ?? Date(),
            updatedAt: row.date(39) ?? Date(),
            lastPlayedAt: row.date(40),
            genre: row.string(41)
        )
    }

    private static func seedUserRating(from providerRating: Double?) -> Double? {
        guard let providerRating, providerRating.isFinite, providerRating > 0 else { return nil }
        return min(max((providerRating / 2).rounded(), 1), 5)
    }

    private static func metadataChanges(before: MediaItem, after: MediaItem) -> [MetadataCorrectionFieldChange] {
        MetadataCorrectionField.allCases.compactMap { field in
            let oldValue = field.encodedValue(from: before)
            let newValue = field.encodedValue(from: after)
            guard oldValue != newValue else { return nil }
            return MetadataCorrectionFieldChange(field: field, oldValue: oldValue, newValue: newValue)
        }
    }

    private static func sqliteValue(for field: MetadataCorrectionField, encodedValue: String?) -> SQLiteValue {
        guard let encodedValue else { return .null }
        switch field.storageKind {
        case .text:
            return .text(encodedValue)
        case .integer:
            return Int64(encodedValue).map(SQLiteValue.int) ?? .null
        case .real:
            return Double(encodedValue).map(SQLiteValue.double) ?? .null
        }
    }

    private static func normalizedSourcePathPrefix(_ sourcePathPrefix: String) -> String {
        var normalized = sourcePathPrefix
        while normalized.count > 1,
              normalized.hasSuffix("/"),
              !normalized.hasSuffix("://") {
            normalized.removeLast()
        }
        return normalized
    }

    private static func escapedLikeChildPattern(for prefix: String) -> String {
        "\(escapedLikeLiteral(prefix))/%"
    }

    private static func escapedLikeContainsPattern(for value: String) -> String {
        "%\(escapedLikeLiteral(value))%"
    }

    private static func escapedLikeLiteral(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "\\", "%", "_":
                escaped.append("\\")
            default:
                break
            }
            escaped.append(character)
        }
        return escaped
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
    public var genre: String?

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
        collectionTitle: String? = nil,
        genre: String? = nil
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
        self.genre = genre
    }
}
