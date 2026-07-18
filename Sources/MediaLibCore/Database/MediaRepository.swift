import Foundation

/// 服务端资料库的固定排序集合。调用方不能把 SQL 片段带入这个边界。
public enum ServerLibraryDatabaseSort: Sendable {
    case updatedDescending
    case titleAscending
    case yearDescending
    case lastPlayedDescending
}

/// 服务器已认证用户自己的播放状态筛选。此枚举不接受数据库列或任意 SQL，
/// 并只在授权来源筛选之后与 `server_user_media_state` 做绑定用户的连接。
public enum ServerLibraryUserStateFilter: Equatable, Sendable {
    case inProgress
    case watched
    case unwatched
    case history
}

/// 服务器已认证用户自己的偏好筛选。和播放状态一样，用户身份由服务端传入，
/// 客户端不能表达任意列名或查询其他用户。
public enum ServerLibraryUserPreferenceFilter: Sendable {
    case favorite
    case watchlist
    case rated
}

/// 已在 SQLite 内完成授权来源过滤、全文检索、排序和分页的结果。
public struct ServerLibraryDatabasePage: Sendable {
    public let totalItemCount: Int
    public let items: [MediaItem]
}

/// 资料库首页所需的受权摘要与有限卡片。计数和卡片都在 SQLite 内完成，
/// 避免首页为展示 60 张海报而把整个授权媒体库物化到服务进程内存。
public struct ServerLibraryDatabaseHome: Sendable {
    public let totalItemCount: Int
    public let countsByType: [String: Int]
    public let items: [MediaItem]
}

public enum ServerSeriesSeasonSelector: Equatable, Sendable {
    case numbered(Int)
    case unspecified
}

public struct ServerSeriesDatabaseSeason: Equatable, Sendable {
    public let seasonNumber: Int?
    public let episodeCount: Int
    public let watchedCount: Int
    public let inProgressCount: Int
}

public struct ServerSeriesDatabaseOverview: Sendable {
    public let series: MediaItem
    public let totalEpisodeCount: Int
    public let seasons: [ServerSeriesDatabaseSeason]
}

public struct ServerSeriesDatabaseEpisodePage: Sendable {
    public let totalItemCount: Int
    public let items: [MediaItem]
}

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
                        .double(Self.normalizedPlaybackPosition(item.playPosition)),
                        .double(Self.normalizedPlaybackProgress(item.playProgress)),
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
                WHERE \(Self.literalChildPrefixPredicate(for: "source_path"))
                  AND id NOT IN (SELECT id FROM remote_keep_ids)
                """,
                // The slash boundary keeps `emby://host/source` from deleting `emby://host/source2`.
                bindings: Self.literalChildPrefixBindings(for: sourcePathPrefix)
            )
            try database.execute("DELETE FROM remote_keep_ids")
        }
    }

    public func fetchAll() throws -> [MediaItem] {
        try database.query(selectSQL + " ORDER BY title COLLATE NOCASE ASC", map: map(row:))
    }

    public func fetchMusic() throws -> [MediaItem] {
        try database.query(
            selectSQL + """
             WHERE type = ?
             ORDER BY album COLLATE NOCASE ASC, track_number ASC, title COLLATE NOCASE ASC
            """,
            bindings: [.text(MediaType.music.rawValue)],
            map: map(row:)
        )
    }

    public func fetch(id: String) throws -> MediaItem? {
        try database.query(
            selectSQL + " WHERE id = ? LIMIT 1",
            bindings: [.text(id)],
            map: map(row:)
        ).first
    }

    /// 供 HTTP/Mlink 服务端调用的有界资料库查询。授权来源在同一 SQLite 连接的临时表中
    /// 表达，避免把完整媒体库拉入内存后再筛选；FTS 参数始终由受限文本构造，绝不拼入 SQL。
    public func fetchServerLibraryPage(
        allowedSourcePaths: Set<String>,
        type: MediaType?,
        topLevelOnly: Bool,
        searchText: String?,
        offset: Int,
        limit: Int,
        sort: ServerLibraryDatabaseSort,
        userID: String,
        playbackFilter: ServerLibraryUserStateFilter?,
        preferenceFilter: ServerLibraryUserPreferenceFilter? = nil
    ) throws -> ServerLibraryDatabasePage {
        guard !allowedSourcePaths.isEmpty else { return ServerLibraryDatabasePage(totalItemCount: 0, items: []) }
        let safeOffset = max(offset, 0)
        let safeLimit = min(max(limit, 1), 100)
        let ftsQuery = searchText.flatMap(Self.serverFTSQuery)

        return try database.transaction {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS server_library_allowed_source_paths (path TEXT PRIMARY KEY) WITHOUT ROWID")
            try database.execute("DELETE FROM server_library_allowed_source_paths")
            for path in allowedSourcePaths where !path.isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO server_library_allowed_source_paths(path) VALUES (?)",
                    bindings: [.text(path)]
                )
            }

            var from = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path"
            var bindings: [SQLiteValue] = []
            if let playbackFilter {
                let join = playbackFilter == .unwatched ? " LEFT JOIN " : " INNER JOIN "
                from += join + "server_user_media_state AS user_state ON user_state.media_id = item.id AND user_state.user_id = ?"
                bindings.append(.text(userID))
            }
            if preferenceFilter != nil {
                from += " INNER JOIN server_user_media_preferences AS user_preference ON user_preference.media_id = item.id AND user_preference.user_id = ?"
                bindings.append(.text(userID))
            }
            var predicates = ["item.type != ?"]
            bindings.append(.text(MediaType.privateCollection.rawValue))
            if let type {
                predicates.append("item.type = ?")
                bindings.append(.text(type.rawValue))
            } else if topLevelOnly {
                predicates.append("item.parent_id IS NULL")
                predicates.append("item.type != ?")
                bindings.append(.text(MediaType.episode.rawValue))
            }
            if let ftsQuery {
                predicates.append("item.rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)")
                bindings.append(.text(ftsQuery))
            }
            if let playbackFilter {
                switch playbackFilter {
                case .inProgress:
                    predicates.append("user_state.is_watched = 0")
                    predicates.append("user_state.play_progress > 0")
                case .watched:
                    predicates.append("user_state.is_watched = 1")
                case .unwatched:
                    predicates.append("(user_state.media_id IS NULL OR user_state.is_watched = 0)")
                case .history:
                    predicates.append("user_state.play_count > 0")
                }
            }
            if let preferenceFilter {
                switch preferenceFilter {
                case .favorite:
                    predicates.append("user_preference.is_favorite = 1")
                case .watchlist:
                    predicates.append("user_preference.is_watchlist = 1")
                case .rated:
                    predicates.append("user_preference.user_rating IS NOT NULL")
                    predicates.append("user_preference.user_rating > 0")
                }
            }
            let whereClause = " WHERE " + predicates.joined(separator: " AND ")
            let total = try database.query("SELECT COUNT(*) " + from + whereClause, bindings: bindings) { $0.int(0) ?? 0 }.first ?? 0
            var pageBindings = bindings
            pageBindings.append(.int(Int64(safeLimit)))
            pageBindings.append(.int(Int64(safeOffset)))
            let pageSQL = serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: from)
                + whereClause + " ORDER BY " + Self.serverOrderBy(sort) + " LIMIT ? OFFSET ?"
            let items = try database.query(pageSQL, bindings: pageBindings, map: map(row:))
            try database.execute("DELETE FROM server_library_allowed_source_paths")
            return ServerLibraryDatabasePage(totalItemCount: total, items: items)
        }
    }

    /// 供认证首页读取的有界摘要。授权来源仍写入同一连接的临时表，和分页 API
    /// 使用完全相同的资料库边界；不同之处仅是 SQL 聚合分类并限制最近卡片数量。
    public func fetchServerLibraryHome(
        allowedSourcePaths: Set<String>,
        cardLimit: Int = 60
    ) throws -> ServerLibraryDatabaseHome {
        guard !allowedSourcePaths.isEmpty else {
            return ServerLibraryDatabaseHome(totalItemCount: 0, countsByType: [:], items: [])
        }
        let safeLimit = min(max(cardLimit, 1), 100)
        return try database.transaction {
            try database.execute("CREATE TEMP TABLE IF NOT EXISTS server_library_allowed_source_paths (path TEXT PRIMARY KEY) WITHOUT ROWID")
            try database.execute("DELETE FROM server_library_allowed_source_paths")
            for path in allowedSourcePaths where !path.isEmpty {
                try database.execute(
                    "INSERT OR IGNORE INTO server_library_allowed_source_paths(path) VALUES (?)",
                    bindings: [.text(path)]
                )
            }

            let from = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path"
            let visiblePredicate = " WHERE item.type != ?"
            let visibleBindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            let countRows = try database.query(
                "SELECT item.type, COUNT(*) " + from + visiblePredicate + " GROUP BY item.type",
                bindings: visibleBindings
            ) { row in
                (row.string(0) ?? "", row.int(1) ?? 0)
            }
            let countsByType = countRows.reduce(into: [String: Int]()) { counts, row in
                guard !row.0.isEmpty, row.1 > 0 else { return }
                counts[row.0] = row.1
            }
            let items = try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: from)
                    + visiblePredicate
                    + " AND item.parent_id IS NULL AND item.type != ? ORDER BY item.updated_at DESC, item.title COLLATE NOCASE ASC LIMIT ?",
                bindings: visibleBindings + [
                    .text(MediaType.episode.rawValue),
                    .int(Int64(safeLimit))
                ],
                map: map(row:)
            )
            try database.execute("DELETE FROM server_library_allowed_source_paths")
            return ServerLibraryDatabaseHome(
                totalItemCount: countsByType.values.reduce(0, +),
                countsByType: countsByType,
                items: items
            )
        }
    }

    /// 已授权系列首屏。父项和所有季统计都在授权来源临时表内读取，观看数量只连接
    /// 当前用户状态；没有可见剧集的普通媒体不能伪装成系列容器。
    public func fetchServerSeriesOverview(
        allowedSourcePaths: Set<String>,
        seriesID: String,
        userID: String
    ) throws -> ServerSeriesDatabaseOverview? {
        guard !allowedSourcePaths.isEmpty, !seriesID.isEmpty else { return nil }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            defer { try? database.execute("DELETE FROM server_library_allowed_source_paths") }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path"
            guard let series = try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + " WHERE item.id = ? AND item.type != ? AND item.type != ? LIMIT 1",
                bindings: [
                    .text(seriesID),
                    .text(MediaType.privateCollection.rawValue),
                    .text(MediaType.episode.rawValue)
                ],
                map: map(row:)
            ).first else { return nil }

            let rows = try database.query(
                """
                SELECT item.season_number,
                       COUNT(*),
                       SUM(CASE WHEN user_state.is_watched = 1 THEN 1 ELSE 0 END),
                       SUM(CASE WHEN user_state.is_watched = 0 AND user_state.play_progress > 0 THEN 1 ELSE 0 END)
                \(authorizedJoin)
                LEFT JOIN server_user_media_state AS user_state
                  ON user_state.media_id = item.id AND user_state.user_id = ?
                WHERE item.parent_id = ? AND item.type = ?
                GROUP BY item.season_number
                ORDER BY item.season_number IS NULL ASC, item.season_number ASC
                """,
                bindings: [.text(userID), .text(seriesID), .text(MediaType.episode.rawValue)]
            ) { row in
                ServerSeriesDatabaseSeason(
                    seasonNumber: row.int(0),
                    episodeCount: row.int(1) ?? 0,
                    watchedCount: row.int(2) ?? 0,
                    inProgressCount: row.int(3) ?? 0
                )
            }
            let total = rows.reduce(0) { $0 + max($1.episodeCount, 0) }
            guard total > 0 else { return nil }
            return ServerSeriesDatabaseOverview(series: series, totalEpisodeCount: total, seasons: rows)
        }
    }

    /// 单季剧集分页。season 只能由固定 selector 表达，不能携带 SQL 或父级查询；
    /// 单页最多 100 集，避免超长系列一次占满服务进程与浏览器内存。
    public func fetchServerSeriesEpisodePage(
        allowedSourcePaths: Set<String>,
        seriesID: String,
        season: ServerSeriesSeasonSelector,
        offset: Int,
        limit: Int
    ) throws -> ServerSeriesDatabaseEpisodePage {
        guard !allowedSourcePaths.isEmpty, !seriesID.isEmpty else {
            return ServerSeriesDatabaseEpisodePage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            defer { try? database.execute("DELETE FROM server_library_allowed_source_paths") }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path"
            var predicate = " WHERE item.parent_id = ? AND item.type = ?"
            var bindings: [SQLiteValue] = [.text(seriesID), .text(MediaType.episode.rawValue)]
            switch season {
            case let .numbered(number):
                predicate += " AND item.season_number = ?"
                bindings.append(.int(Int64(number)))
            case .unspecified:
                predicate += " AND item.season_number IS NULL"
            }
            let total = try database.query(
                "SELECT COUNT(*) " + authorizedJoin + predicate,
                bindings: bindings
            ) { $0.int(0) ?? 0 }.first ?? 0
            let items = try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + predicate
                    + " ORDER BY item.episode_number IS NULL ASC, item.episode_number ASC, item.title COLLATE NOCASE ASC, item.id ASC LIMIT ? OFFSET ?",
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))],
                map: map(row:)
            )
            return ServerSeriesDatabaseEpisodePage(totalItemCount: total, items: items)
        }
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
            "DELETE FROM media_items WHERE \(Self.literalChildPrefixPredicate(for: "source_path"))",
            bindings: Self.literalChildPrefixBindings(for: sourcePathPrefix)
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
            "DELETE FROM media_items WHERE source_path = ? AND \(Self.literalChildPrefixPredicate(for: "file_path"))",
            bindings: [.text(sourcePath)] + Self.literalChildPrefixBindings(for: filePathPrefix)
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

    /// `deleteItems(ids:)` 的异步、不阻塞主线程版本：在数据库队列上以单个事务执行全部分块删除。
    /// 供批量删除（合并重复项 / 清理失效索引）从 @MainActor 调用而不卡住主线程。
    public func deleteItemsAsync(ids: [String]) async throws {
        guard !ids.isEmpty else { return }
        try await database.transactionAsync {
            try self.deleteItems(ids: ids)
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
        let sanitizedPosition = Self.normalizedPlaybackPosition(position)
        let progress = Self.normalizedPlaybackProgress(position: sanitizedPosition, duration: duration)
        let watchedThreshold = Self.normalizedWatchedThreshold(watchedThreshold)
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
                .double(sanitizedPosition),
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
            bindings: [.optionalDouble(Self.normalizedUserRating(rating)), .optionalDate(Date()), .text(id)]
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
                    .optionalInt(Self.normalizedPositiveInt(metadata.trackNumber)),
                    .optionalInt(Self.normalizedPositiveInt(metadata.year)),
                    .optionalText(metadata.overview),
                    .optionalText(metadata.posterPath),
                    .optionalText(metadata.backdropPath),
                    .optionalDouble(Self.normalizedProviderRating(metadata.rating)),
                    .optionalDouble(Self.seedUserRating(from: Self.normalizedProviderRating(metadata.rating))),
                    .optionalInt(Self.normalizedPositiveInt(metadata.runtime)),
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

    /// 服务端分页可能连接逐用户播放状态表；所有媒体列显式限定为 `item`，
    /// 避免同名 `play_count` / `play_progress` 被 SQLite 解释为歧义列。
    private var serverSelectSQL: String {
        """
        SELECT item.id, item.type, item.title, item.original_title, item.artist, item.album, item.track_number, item.year, item.overview, item.poster_path, item.backdrop_path,
               item.rating, item.user_rating, item.runtime, item.source_path, item.parent_id, item.season_number, item.episode_number,
               item.file_path, item.file_size, item.video_codec, item.audio_codec, item.resolution, item.video_bitrate, item.duration,
               item.loudness_track_gain_db, item.loudness_album_gain_db, item.loudness_track_peak, item.loudness_album_peak,
               item.play_count, item.play_position, item.play_progress, item.watched, item.favorite, item.watchlist, item.external_id, item.metadata_provider, item.collection_title, item.created_at, item.updated_at, item.last_played_at, item.genre
        FROM media_items
        """
    }

    private static func serverOrderBy(_ sort: ServerLibraryDatabaseSort) -> String {
        switch sort {
        case .updatedDescending:
            return "item.updated_at DESC, item.title COLLATE NOCASE ASC, item.id ASC"
        case .titleAscending:
            return "item.title COLLATE NOCASE ASC, item.id ASC"
        case .yearDescending:
            return "CASE WHEN item.year IS NULL THEN 1 ELSE 0 END ASC, item.year DESC, item.title COLLATE NOCASE ASC, item.id ASC"
        case .lastPlayedDescending:
            return "user_state.last_played_at DESC, item.id ASC"
        }
    }

    private static func serverFTSQuery(_ rawValue: String) -> String? {
        let tokens = rawValue
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: { $0.isWhitespace })
            .map(String.init)
            .filter { !$0.isEmpty }
        guard !tokens.isEmpty else { return nil }
        // 每个 token 始终是被双引号包围的词组，内嵌引号加倍；末尾唯一的 `*`
        // 由服务端添加以支持前缀检索，客户端无法注入 MATCH 运算符或字段名。
        return tokens.map { token in
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\"*"
        }.joined(separator: " AND ")
    }

    private func bindings(for item: MediaItem) -> [SQLiteValue] {
        [
            .text(item.id),
            .text(item.type.rawValue),
            .text(item.title),
            .optionalText(item.originalTitle),
            .optionalText(item.artist),
            .optionalText(item.album),
            .optionalInt(Self.normalizedPositiveInt(item.trackNumber)),
            .optionalInt(Self.normalizedPositiveInt(item.year)),
            .optionalText(item.overview),
            .optionalText(item.posterPath),
            .optionalText(item.backdropPath),
            .optionalDouble(Self.normalizedProviderRating(item.rating)),
            .optionalDouble(Self.normalizedUserRating(item.userRating)),
            .optionalInt(Self.normalizedPositiveInt(item.runtime)),
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
            .optionalDouble(Self.normalizedDuration(item.duration)),
            .optionalDouble(Self.normalizedFiniteDouble(item.loudnessTrackGainDB)),
            .optionalDouble(Self.normalizedFiniteDouble(item.loudnessAlbumGainDB)),
            .optionalDouble(Self.normalizedPeak(item.loudnessTrackPeak)),
            .optionalDouble(Self.normalizedPeak(item.loudnessAlbumPeak)),
            .optionalInt(Self.normalizedPlayCount(item.playCount)),
            .double(Self.normalizedPlaybackPosition(item.playPosition)),
            .double(Self.normalizedPlaybackProgress(item.playProgress)),
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
            trackNumber: Self.normalizedPositiveInt(row.int(6)),
            year: Self.normalizedPositiveInt(row.int(7)),
            overview: row.string(8),
            posterPath: row.string(9),
            backdropPath: row.string(10),
            rating: Self.normalizedProviderRating(row.double(11)),
            userRating: Self.normalizedUserRating(row.double(12)),
            runtime: Self.normalizedPositiveInt(row.int(13)),
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
            duration: Self.normalizedDuration(row.double(24)),
            loudnessTrackGainDB: Self.normalizedFiniteDouble(row.double(25)),
            loudnessAlbumGainDB: Self.normalizedFiniteDouble(row.double(26)),
            loudnessTrackPeak: Self.normalizedPeak(row.double(27)),
            loudnessAlbumPeak: Self.normalizedPeak(row.double(28)),
            playCount: Self.normalizedPlayCount(row.int(29)) ?? 0,
            playPosition: Self.normalizedPlaybackPosition(row.double(30) ?? 0),
            playProgress: Self.normalizedPlaybackProgress(row.double(31) ?? 0),
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
        guard let providerRating = normalizedProviderRating(providerRating) else { return nil }
        return min(max((providerRating / 2).rounded(), 1), 5)
    }

    private static func normalizedProviderRating(_ rating: Double?) -> Double? {
        guard let rating, rating.isFinite, rating > 0, rating <= 10 else { return nil }
        return rating
    }

    private static func normalizedUserRating(_ rating: Double?) -> Double? {
        guard let rating, rating.isFinite, rating > 0, rating <= 5 else { return nil }
        return rating
    }

    private static func normalizedPlayCount(_ playCount: Int?) -> Int? {
        guard let playCount else { return nil }
        return max(playCount, 0)
    }

    private static func normalizedPositiveInt(_ value: Int?) -> Int? {
        guard let value, value > 0 else { return nil }
        return value
    }

    private static func normalizedDuration(_ duration: Double?) -> Double? {
        guard let duration, duration.isFinite, duration > 0 else { return nil }
        return duration
    }

    private static func normalizedFiniteDouble(_ value: Double?) -> Double? {
        guard let value, value.isFinite else { return nil }
        return value
    }

    private static func normalizedPeak(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value > 0 else { return nil }
        return value
    }

    private static func normalizedPlaybackPosition(_ position: Double) -> Double {
        guard position.isFinite else { return 0 }
        return max(position, 0)
    }

    private static func normalizedPlaybackProgress(position: Double, duration: Double?) -> Double {
        guard position.isFinite,
              let duration,
              duration.isFinite,
              duration > 0 else {
            return 0
        }
        return min(max(position / duration, 0), 1)
    }

    private static func normalizedPlaybackProgress(_ progress: Double) -> Double {
        guard progress.isFinite else { return 0 }
        return min(max(progress, 0), 1)
    }

    private static func normalizedWatchedThreshold(_ threshold: Double) -> Double {
        guard threshold.isFinite, threshold > 0, threshold <= 1 else { return 0.9 }
        return threshold
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

    private static func literalChildPrefixPredicate(for column: String) -> String {
        "(\(column) = ? OR substr(\(column), 1, ?) = ?)"
    }

    private static func literalChildPrefixBindings(for prefix: String) -> [SQLiteValue] {
        let childPrefix = "\(prefix)/"
        return [.text(prefix), .int(Int64(childPrefix.count)), .text(childPrefix)]
    }

    private static func escapedLikeContainsPattern(for value: String) -> String {
        "%\(escapedLikeLiteral(value))%"
    }

    private func prepareServerAllowedSourcePaths(_ allowedSourcePaths: Set<String>) throws {
        try database.execute("CREATE TEMP TABLE IF NOT EXISTS server_library_allowed_source_paths (path TEXT PRIMARY KEY) WITHOUT ROWID")
        try database.execute("DELETE FROM server_library_allowed_source_paths")
        for path in allowedSourcePaths where !path.isEmpty {
            try database.execute(
                "INSERT OR IGNORE INTO server_library_allowed_source_paths(path) VALUES (?)",
                bindings: [.text(path)]
            )
        }
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
