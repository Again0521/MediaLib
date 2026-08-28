import Foundation

/// 服务端资料库的固定排序集合。调用方不能把 SQL 片段带入这个边界。
///
/// 与 macOS 客户端 `LibrarySortMode` 同词汇。方向由 `ServerLibraryDatabaseSortOrder`
/// 单独表达，"正序"是该键的自然朝向（最近更新 = 由新到旧，标题 = A→Z），
/// 自然朝向只在 `serverOrderBy` 里定义一次。
public enum ServerLibraryDatabaseSort: Sendable {
    case recentlyUpdated
    case dateAdded
    case title
    case year
    case runtime
    case progress
    case score
    case rating
    case lastPlayed

    /// 需要与当前用户绑定的 `server_user_media_state` 连接。
    public var requiresUserState: Bool { self == .progress || self == .lastPlayed }

    /// 需要与当前用户绑定的 `server_user_media_preferences` 连接。
    /// `media_items.user_rating` 是桌面端全局评级，不是这个用户的。
    public var requiresUserPreference: Bool { self == .rating }
}

/// 排序方向。
public enum ServerLibraryDatabaseSortOrder: Sendable {
    case primary
    case reverse
}

/// 一个作用域内实际存在的筛选面。排序键按数据存在与否裁剪，
/// 题材以数据库里原样的 `", "` 组合串返回，拆分留给上层。
public struct ServerLibraryDatabaseFacets: Sendable {
    public let genreValues: [String]
    public let hasRuntime: Bool
    public let hasProviderRating: Bool
    public let hasUserRating: Bool
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

/// 在数据库内完成授权资料库过滤后的人物目录项。头像地址不会离开 Core 层。
public struct ServerPersonDatabaseCard: Sendable {
    public let id: String
    public let name: String
    public let department: String?
    public let mediaCount: Int
}

public struct ServerPeopleDatabasePage: Sendable {
    public let totalItemCount: Int
    public let items: [ServerPersonDatabaseCard]
}

public struct ServerPersonDatabaseProfile: Sendable {
    public let id: String
    public let name: String
    public let biography: String?
    public let birthday: String?
    public let deathday: String?
    public let placeOfBirth: String?
    public let department: String?
}

public struct ServerPersonDatabaseCredit: Sendable {
    public let media: MediaItem
    public let category: String
    public let role: String?
}

public struct ServerPeopleDatabaseCreditsPage: Sendable {
    public let totalItemCount: Int
    public let items: [ServerPersonDatabaseCredit]
}

/// 手动合集在数据库内先与授权媒体源相交。合集的原始项目数不能返回到网页，
/// 因为它可能包含当前账户没有权限看到的项目。
public struct ServerCollectionDatabaseCard: Sendable {
    public let id: String
    public let name: String
    public let mediaCount: Int
}

public struct ServerCollectionsDatabasePage: Sendable {
    public let totalItemCount: Int
    public let items: [ServerCollectionDatabaseCard]
}

public struct ServerCollectionDatabaseDetail: Sendable {
    public let id: String
    public let name: String
    public let totalItemCount: Int
    public let items: [MediaItem]
}

/// 歌单在数据库层的卡片。手动与智能共用，靠 `isSmart` 区分。
public struct ServerPlaylistDatabaseCard: Sendable {
    public let id: String
    public let name: String
    public let trackCount: Int
    public let isSmart: Bool
    public let ruleSummary: String?
}

public struct ServerPlaylistsDatabasePage: Sendable {
    public let totalItemCount: Int
    public let items: [ServerPlaylistDatabaseCard]
}

public struct ServerPlaylistDatabaseDetail: Sendable {
    public let id: String
    public let name: String
    public let isSmart: Bool
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
              play_count, play_position, play_progress, watched, favorite, watchlist, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at, genre, has_lyrics
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
              -- 歌词存在性是每次扫描重新判定的事实，不是"一旦有过就永远有"：
              -- 外挂歌词被删掉之后，这里必须能从 1 落回 0，所以不套 COALESCE。
              has_lyrics = excluded.has_lyrics,
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

    /// 还没有判定过歌词的曲目——用于升级后的后台回补。
    ///
    /// 迁移只把列建出来并填 0，不在启动路径上遍历整个曲库做文件探测：那会把一次
    /// 升级变成一次几分钟的卡死，NAS 上更久。真实值由这里挑出来、在后台补。
    ///
    /// 只挑本地文件：远端（Emby/Jellyfin/Plex）曲目的 `filePath` 是一个流地址，
    /// 对它做 `fileExists` 永远是 false，白跑一趟。
    public func fetchMusicNeedingLyricsProbe(limit: Int) throws -> [MediaItem] {
        try database.query(
            selectSQL + """
             WHERE type = ? AND has_lyrics = 0 AND file_path IS NOT NULL AND file_path LIKE '/%'
             ORDER BY updated_at DESC
             LIMIT ?
            """,
            bindings: [.text(MediaType.music.rawValue), .int(Int64(max(limit, 0)))],
            map: map(row:)
        )
    }

    /// 只写歌词存在性，不碰这一行的其它任何字段。
    ///
    /// 回补跑在后台，期间用户可能正在编辑标签或重新扫描；走完整 upsert 会把内存里
    /// 那份可能已经过时的快照整行写回去，覆盖掉别人刚写的东西。
    public func updateLyricsPresence(_ presence: [String: Bool]) throws {
        guard !presence.isEmpty else { return }
        try database.transaction {
            for (id, hasLyrics) in presence {
                try database.execute(
                    "UPDATE media_items SET has_lyrics = ? WHERE id = ?",
                    bindings: [.bool(hasLyrics), .text(id)]
                )
            }
        }
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
        sortOrder: ServerLibraryDatabaseSortOrder = .primary,
        genre: String? = nil,
        userID: String,
        playbackFilter: ServerLibraryUserStateFilter?,
        preferenceFilter: ServerLibraryUserPreferenceFilter? = nil,
        excludedTypes: Set<MediaType> = [],
        excludesOnlineSourceItems: Bool = false,
        maximumContentRating: String? = nil,
        /// 保险库页面**唯一**的例外。保险库的顶层条目自己就是 `privateCollection`
        /// 类型的容器，其余每一处查询都必须继续把它们挡在外面——那条谓词是保险库
        /// 对首页、分类、搜索的兜底屏障，与逐来源授权互为两道锁。
        includesPrivateCollectionType: Bool = false
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

            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }

            var from = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            var bindings: [SQLiteValue] = []
            // 排序也可能需要这两张按用户分表的连接。两处的绑定用户都写在 ON 上：
            // 移到 WHERE 会把 LEFT JOIN 静默退化成 INNER JOIN，于是"按进度排序"
            // 会让所有没有播放记录的条目从页面上消失。两张表都是
            // PRIMARY KEY(user_id, media_id)，所以加连接不会放大行数，COUNT(*) 仍然正确。
            if playbackFilter != nil || sort.requiresUserState {
                let join = (playbackFilter == nil || playbackFilter == .unwatched) ? " LEFT JOIN " : " INNER JOIN "
                from += join + "server_user_media_state AS user_state ON user_state.media_id = item.id AND user_state.user_id = ?"
                bindings.append(.text(userID))
            }
            if preferenceFilter != nil || sort.requiresUserPreference {
                let join = preferenceFilter == nil ? " LEFT JOIN " : " INNER JOIN "
                from += join + "server_user_media_preferences AS user_preference ON user_preference.media_id = item.id AND user_preference.user_id = ?"
                bindings.append(.text(userID))
            }
            var predicates: [String] = []
            if !includesPrivateCollectionType {
                predicates.append("item.type != ?")
                bindings.append(.text(MediaType.privateCollection.rawValue))
            }
            if excludesOnlineSourceItems { predicates.append(Self.onlineSourceItemPredicate) }
            if let type {
                predicates.append("item.type = ?")
                bindings.append(.text(type.rawValue))
            } else if topLevelOnly {
                predicates.append("item.parent_id IS NULL")
                predicates.append("item.type != ?")
                bindings.append(.text(MediaType.episode.rawValue))
            }
            for excludedType in excludedTypes.sorted(by: { $0.rawValue < $1.rawValue }) where excludedType != .privateCollection {
                predicates.append("item.type != ?")
                bindings.append(.text(excludedType.rawValue))
            }
            if let ftsQuery {
                predicates.append("item.rowid IN (SELECT rowid FROM media_items_fts WHERE media_items_fts MATCH ?)")
                bindings.append(.text(ftsQuery))
            }
            if let genre, !genre.isEmpty {
                // genre 是一列 ", " 分隔的文本。两端补上分隔符后做整词匹配，
                // 否则"动作"会命中"动作捕捉"。转义交给 escapedLikeLiteral，
                // 于是题材名里的 % _ \ 不会变成通配符。
                predicates.append("item.genre IS NOT NULL AND (', ' || item.genre || ', ') LIKE ('%, ' || ? || ', %') ESCAPE '\\'")
                bindings.append(.text(Self.escapedLikeLiteral(genre)))
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
                + whereClause + " ORDER BY " + Self.serverOrderBy(sort, sortOrder) + " LIMIT ? OFFSET ?"
            let items = try database.query(pageSQL, bindings: pageBindings, map: map(row:))
            return ServerLibraryDatabasePage(totalItemCount: total, items: items)
        }
    }

    /// 一个作用域内实际可用的筛选面。
    ///
    /// 网页需要知道该给出哪些排序键和哪些题材，而不是渲染一串永远匹配不到内容的
    /// 选项。四条语句都是有界的：题材走 `DISTINCT`（返回的是不同的**组合串**，
    /// 几十到几百行，不是每条目一行）并硬性 `LIMIT`；三个探针各自 `LIMIT 1`。
    ///
    /// "是否有评级"按传入的 `userID` 查偏好表——评级是每个用户自己的，
    /// 不能因为别人评过分就给这个用户提供该排序。
    public func fetchServerLibraryFacets(
        allowedSourcePaths: Set<String>,
        type: MediaType?,
        topLevelOnly: Bool,
        userID: String,
        excludedTypes: Set<MediaType> = [],
        excludesOnlineSourceItems: Bool = false,
        maximumContentRating: String? = nil,
        maximumDistinctGenreRows: Int = 500
    ) throws -> ServerLibraryDatabaseFacets {
        guard !allowedSourcePaths.isEmpty else {
            return ServerLibraryDatabaseFacets(genreValues: [], hasRuntime: false, hasProviderRating: false, hasUserRating: false)
        }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }

            let from = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            var predicates = ["item.type != ?"]
            var bindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            // 题材下拉必须和它要筛的那个网格用同一套排除，否则本地分类页会列出
            // 只存在于远程条目的题材——选中即空网格。
            if excludesOnlineSourceItems { predicates.append(Self.onlineSourceItemPredicate) }
            if let type {
                predicates.append("item.type = ?")
                bindings.append(.text(type.rawValue))
            } else if topLevelOnly {
                predicates.append("item.parent_id IS NULL")
                predicates.append("item.type != ?")
                bindings.append(.text(MediaType.episode.rawValue))
            }
            for excludedType in excludedTypes.sorted(by: { $0.rawValue < $1.rawValue }) where excludedType != .privateCollection {
                predicates.append("item.type != ?")
                bindings.append(.text(excludedType.rawValue))
            }
            let whereClause = " WHERE " + predicates.joined(separator: " AND ")

            let genreValues = try database.query(
                "SELECT DISTINCT item.genre " + from + whereClause
                    + " AND item.genre IS NOT NULL AND item.genre != '' ORDER BY item.genre LIMIT ?",
                bindings: bindings + [.int(Int64(max(maximumDistinctGenreRows, 1)))]
            ) { $0.string(0) }.compactMap { $0 }

            func exists(_ extraPredicate: String, extraJoin: String = "", extraBindings: [SQLiteValue] = []) throws -> Bool {
                let sql = "SELECT 1 " + from + extraJoin + whereClause + " AND " + extraPredicate + " LIMIT 1"
                return try database.query(sql, bindings: extraBindings + bindings) { _ in true }.first ?? false
            }

            let hasRuntime = try exists("item.runtime IS NOT NULL AND item.runtime > 0")
            let hasProviderRating = try exists("item.rating IS NOT NULL AND item.rating > 0")
            let hasUserRating = try exists(
                "user_preference.user_rating IS NOT NULL AND user_preference.user_rating > 0",
                extraJoin: " INNER JOIN server_user_media_preferences AS user_preference ON user_preference.media_id = item.id AND user_preference.user_id = ?",
                extraBindings: [.text(userID)]
            )

            return ServerLibraryDatabaseFacets(
                genreValues: genreValues,
                hasRuntime: hasRuntime,
                hasProviderRating: hasProviderRating,
                hasUserRating: hasUserRating
            )
        }
    }

    /// 供详情、播放探测和受保护资源端点按 ID 读取单条已授权媒体。
    ///
    /// 这些请求原先先 `fetchAll()` 再在 Swift 内存中过滤 ID；在大库中一次详情
    /// 打开会重复扫描整张媒体表，网页侧看起来就像侧栏或播放器“卡住”。授权来源
    /// 仍在 SQLite 临时表中完成，路径和未授权条目不会离开 Core 层。
    public func fetchServerMediaItem(
        id: String,
        allowedSourcePaths: Set<String>,
        /// 保险库的顶层条目自己就是 `privateCollection` 类型的容器。调用方只有在
        /// 确认这个账号此刻真的能读保险库（已解锁 + 已授权）时才打开它；其余每
        /// 一次读取都继续把这类行挡在外面，与逐来源授权互为两道锁。
        includesPrivateCollectionType: Bool = false,
        maximumContentRating: String? = nil
    ) throws -> MediaItem? {
        guard !id.isEmpty, !allowedSourcePaths.isEmpty else { return nil }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            let typePredicate = includesPrivateCollectionType ? "" : " AND item.type != ?"
            var bindings: [SQLiteValue] = [.text(id)]
            if !includesPrivateCollectionType {
                bindings.append(.text(MediaType.privateCollection.rawValue))
            }
            return try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + " WHERE item.id = ?\(typePredicate) LIMIT 1",
                bindings: bindings,
                map: map(row:)
            ).first
        }
    }

    /// 按一组受保护媒体 ID 读取服务端队列所需的最小集合。
    /// 调用方传入的 ID 只作为绑定参数；最多读取 100 项，避免队列端点被用作
    /// 大规模任意查询入口。
    public func fetchServerMediaItems(
        ids: [String],
        allowedSourcePaths: Set<String>,
        maximumContentRating: String? = nil
    ) throws -> [MediaItem] {
        let uniqueIDs = Array(Set(ids.filter { !$0.isEmpty })).prefix(100)
        guard !uniqueIDs.isEmpty, !allowedSourcePaths.isEmpty else { return [] }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let placeholders = Array(repeating: "?", count: uniqueIDs.count).joined(separator: ",")
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            let bindings = uniqueIDs.map(SQLiteValue.text) + [.text(MediaType.privateCollection.rawValue)]
            return try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + " WHERE item.id IN (" + placeholders + ") AND item.type != ?",
                bindings: bindings,
                map: map(row:)
            )
        }
    }

    /// 音乐专题页的受权读取。它只扫描当前账号可见的音乐行，而不是先把
    /// 整个资料库（含照片、剧集与视频）搬到 Swift 再过滤。音乐页仍可拿到
    /// 完整的艺术家/专辑聚合输入，但不会因此阻塞详情或媒体字节流请求。
    public func fetchServerMusicItems(
        allowedSourcePaths: Set<String>,
        excludesOnlineSourceItems: Bool = false,
        maximumContentRating: String? = nil
    ) throws -> [MediaItem] {
        guard !allowedSourcePaths.isEmpty else { return [] }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            return try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + " WHERE item.type = ?"
                    + (excludesOnlineSourceItems ? " AND \(Self.onlineSourceItemPredicate)" : "")
                    + " ORDER BY item.artist COLLATE NOCASE ASC, item.album COLLATE NOCASE ASC, item.track_number ASC, item.title COLLATE NOCASE ASC, item.id ASC",
                bindings: [.text(MediaType.music.rawValue)],
                map: map(row:)
            )
        }
    }

    /// 播放页只需要当前系列的相邻集。将这个范围限定在 SQL 里，避免在
    /// 大资料库中为了“上一集/下一集”重新读取每一部影片和每一首歌。
    public func fetchServerSeriesEpisodes(
        allowedSourcePaths: Set<String>,
        seriesID: String,
        maximumContentRating: String? = nil
    ) throws -> [MediaItem] {
        guard !allowedSourcePaths.isEmpty, !seriesID.isEmpty else { return [] }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            return try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: authorizedJoin)
                    + " WHERE item.parent_id = ? AND item.type = ? ORDER BY item.season_number IS NULL ASC, item.season_number ASC, item.episode_number IS NULL ASC, item.episode_number ASC, item.title COLLATE NOCASE ASC, item.id ASC",
                bindings: [.text(seriesID), .text(MediaType.episode.rawValue)],
                map: map(row:)
            )
        }
    }

    /// 供认证首页读取的有界摘要。授权来源仍写入同一连接的临时表，和分页 API
    /// 使用完全相同的资料库边界；不同之处仅是 SQL 聚合分类并限制最近卡片数量。
    public func fetchServerLibraryHome(
        allowedSourcePaths: Set<String>,
        cardLimit: Int = 60,
        excludesOnlineSourceItems: Bool = false,
        maximumContentRating: String? = nil
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

            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }

            let from = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
            let visiblePredicate = " WHERE item.type != ?"
                + (excludesOnlineSourceItems ? " AND \(Self.onlineSourceItemPredicate)" : "")
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
        userID: String,
        maximumContentRating: String? = nil
    ) throws -> ServerSeriesDatabaseOverview? {
        guard !allowedSourcePaths.isEmpty, !seriesID.isEmpty else { return nil }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
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
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerSeriesDatabaseEpisodePage {
        guard !allowedSourcePaths.isEmpty, !seriesID.isEmpty else {
            return ServerSeriesDatabaseEpisodePage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let authorizedJoin = "FROM media_items AS item INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path" + ratingJoin
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

    /// 人物目录只通过「至少一部当前用户可见作品」关联人物。所有计数、搜索、排序
    /// 和分页均发生在授权来源临时表内，不能借人物名旁路枚举未授权资料库。
    public func fetchServerPeoplePage(
        allowedSourcePaths: Set<String>,
        searchText: String?,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerPeopleDatabasePage {
        guard !allowedSourcePaths.isEmpty else {
            return ServerPeopleDatabasePage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        let query = searchText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let search = query?.isEmpty == false ? String(query!.prefix(128)) : nil
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let visibleJoin = """
            FROM media_people AS person
            INNER JOIN media_credits AS credit ON credit.person_id = person.id
            INNER JOIN media_items AS item ON item.id = credit.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            var predicate = " WHERE item.type != ?"
            var bindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            if let search {
                predicate += " AND person.name LIKE ? ESCAPE '\\'"
                bindings.append(.text(Self.escapedLikeContainsPattern(for: search)))
            }
            let count = try database.query(
                "SELECT COUNT(DISTINCT person.id) " + visibleJoin + predicate,
                bindings: bindings
            ) { $0.int(0) ?? 0 }.first ?? 0
            let items = try database.query(
                """
                SELECT person.id, person.name, person.known_for_department, COUNT(DISTINCT item.id)
                \(visibleJoin)
                \(predicate)
                GROUP BY person.id, person.name, person.known_for_department
                ORDER BY person.name COLLATE NOCASE ASC, person.id ASC
                LIMIT ? OFFSET ?
                """,
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))]
            ) { row in
                ServerPersonDatabaseCard(
                    id: row.string(0) ?? "",
                    name: row.string(1) ?? "",
                    department: row.string(2),
                    mediaCount: row.int(3) ?? 0
                )
            }.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            return ServerPeopleDatabasePage(totalItemCount: count, items: items)
        }
    }

    /// 仅在该人物至少关联一部授权作品时返回公开人物资料。其 profile_url 未被查询，
    /// 防止页面把浏览者请求直接转发给第三方头像主机。
    public func fetchServerPersonProfile(
        allowedSourcePaths: Set<String>,
        personID: String,
        maximumContentRating: String? = nil
    ) throws -> ServerPersonDatabaseProfile? {
        guard !allowedSourcePaths.isEmpty, !personID.isEmpty else { return nil }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            return try database.query(
                """
                SELECT person.id, person.name, person.biography, person.birthday, person.deathday,
                       person.place_of_birth, person.known_for_department
                FROM media_people AS person
                WHERE person.id = ?
                  AND EXISTS (
                    SELECT 1
                    FROM media_credits AS credit
                    INNER JOIN media_items AS item ON item.id = credit.media_id
                    INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
                    \(ratingJoin)
                    WHERE credit.person_id = person.id AND item.type != ?
                  )
                LIMIT 1
                """,
                bindings: [.text(personID), .text(MediaType.privateCollection.rawValue)]
            ) { row in
                ServerPersonDatabaseProfile(
                    id: row.string(0) ?? "", name: row.string(1) ?? "", biography: row.string(2),
                    birthday: row.string(3), deathday: row.string(4), placeOfBirth: row.string(5),
                    department: row.string(6)
                )
            }.first
        }
    }

    /// 人物作品列表复用同一授权来源临时表，先验证人物可见性再分页。作品媒体列始终
    /// 来自 `item` 别名，角色文字仅作为该作品下的公开演职员展示。
    public func fetchServerPersonCreditsPage(
        allowedSourcePaths: Set<String>,
        personID: String,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerPeopleDatabaseCreditsPage {
        guard !allowedSourcePaths.isEmpty, !personID.isEmpty else {
            return ServerPeopleDatabaseCreditsPage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let from = """
            FROM media_credits AS credit
            INNER JOIN media_items AS item ON item.id = credit.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            let predicate = " WHERE credit.person_id = ? AND item.type != ?"
            let bindings: [SQLiteValue] = [.text(personID), .text(MediaType.privateCollection.rawValue)]
            let total = try database.query("SELECT COUNT(*) " + from + predicate, bindings: bindings) {
                $0.int(0) ?? 0
            }.first ?? 0
            let items = try database.query(
                serverSelectSQL.replacingOccurrences(
                    of: "FROM media_items",
                    with: ", credit.category, credit.role " + from
                )
                    + predicate
                    + " ORDER BY item.year DESC, item.title COLLATE NOCASE ASC, item.id ASC LIMIT ? OFFSET ?",
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))]
            ) { row in
                ServerPersonDatabaseCredit(
                    media: self.map(row: row),
                    category: row.string(Self.mediaColumnCount) ?? "cast",
                    role: row.string(Self.mediaColumnCount + 1)
                )
            }
            return ServerPeopleDatabaseCreditsPage(totalItemCount: total, items: items)
        }
    }

    /// 手动合集目录和合集内项目均使用同一份事务内的授权媒体源临时表。即使合集
    /// 同时含有可见、不可见项目，也只能看到可见子集及其重新计算后的数目。
    public func fetchServerManualCollectionsPage(
        allowedSourcePaths: Set<String>,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerCollectionsDatabasePage {
        guard !allowedSourcePaths.isEmpty else {
            return ServerCollectionsDatabasePage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let visibleJoin = """
            FROM video_manual_collections AS collection
            INNER JOIN video_manual_collection_items AS entry ON entry.collection_id = collection.id
            INNER JOIN media_items AS item ON item.id = entry.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            let predicate = " WHERE item.type != ?"
            let bindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            let total = try database.query(
                "SELECT COUNT(DISTINCT collection.id) " + visibleJoin + predicate,
                bindings: bindings
            ) { $0.int(0) ?? 0 }.first ?? 0
            let items = try database.query(
                """
                SELECT collection.id, collection.name, COUNT(DISTINCT item.id)
                \(visibleJoin)
                \(predicate)
                GROUP BY collection.id, collection.name, collection.updated_at
                ORDER BY collection.updated_at DESC, collection.name COLLATE NOCASE ASC, collection.id ASC
                LIMIT ? OFFSET ?
                """,
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))]
            ) { row in
                ServerCollectionDatabaseCard(
                    id: row.string(0) ?? "", name: row.string(1) ?? "", mediaCount: row.int(2) ?? 0
                )
            }.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            return ServerCollectionsDatabasePage(totalItemCount: total, items: items)
        }
    }

    public func fetchServerManualCollectionDetail(
        allowedSourcePaths: Set<String>,
        collectionID: String,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerCollectionDatabaseDetail? {
        guard !allowedSourcePaths.isEmpty, !collectionID.isEmpty else { return nil }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let from = """
            FROM video_manual_collection_items AS entry
            INNER JOIN media_items AS item ON item.id = entry.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            let predicate = " WHERE entry.collection_id = ? AND item.type != ?"
            let bindings: [SQLiteValue] = [.text(collectionID), .text(MediaType.privateCollection.rawValue)]
            let collectionRows = try database.query(
                """
                SELECT collection.id, collection.name
                FROM video_manual_collections AS collection
                WHERE collection.id = ?
                  AND EXISTS (SELECT 1 \(from) \(predicate))
                LIMIT 1
                """,
                bindings: [.text(collectionID)] + bindings
            ) { ($0.string(0) ?? "", $0.string(1) ?? "") }.first
            guard let collection = collectionRows, !collection.0.isEmpty, !collection.1.isEmpty else { return nil }
            let total = try database.query("SELECT COUNT(*) " + from + predicate, bindings: bindings) {
                $0.int(0) ?? 0
            }.first ?? 0
            let items = try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: from)
                    + predicate
                    + " ORDER BY entry.position ASC, item.id ASC LIMIT ? OFFSET ?",
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))],
                map: map(row:)
            )
            return ServerCollectionDatabaseDetail(id: collection.0, name: collection.1, totalItemCount: total, items: items)
        }
    }

    /// 手动歌单列表，只含请求者有权看到的曲目。
    ///
    /// 与 `fetchServerManualCollectionsPage` 同一套写法，包括那条最容易抄漏的：
    /// 曲目数用 `COUNT(DISTINCT item.id)` 从**可见子集**重新数，而不是取歌单自己
    /// 记的条数。否则一个"32 首"就能告诉别人这里面还有 30 首他看不到的东西。
    /// 一首都看不到的歌单整个不出现。
    public func fetchServerMusicPlaylistsPage(
        allowedSourcePaths: Set<String>,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerPlaylistsDatabasePage {
        guard !allowedSourcePaths.isEmpty else {
            return ServerPlaylistsDatabasePage(totalItemCount: 0, items: [])
        }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let visibleJoin = """
            FROM music_playlists AS playlist
            INNER JOIN music_playlist_items AS entry ON entry.playlist_id = playlist.id
            INNER JOIN media_items AS item ON item.id = entry.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            let predicate = " WHERE item.type = ?"
            let bindings: [SQLiteValue] = [.text(MediaType.music.rawValue)]
            let total = try database.query(
                "SELECT COUNT(DISTINCT playlist.id) " + visibleJoin + predicate,
                bindings: bindings
            ) { $0.int(0) ?? 0 }.first ?? 0
            let items = try database.query(
                """
                SELECT playlist.id, playlist.name, COUNT(DISTINCT item.id)
                \(visibleJoin)
                \(predicate)
                GROUP BY playlist.id, playlist.name, playlist.updated_at
                ORDER BY playlist.updated_at DESC, playlist.name COLLATE NOCASE ASC, playlist.id ASC
                LIMIT ? OFFSET ?
                """,
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))]
            ) { row in
                ServerPlaylistDatabaseCard(
                    id: row.string(0) ?? "", name: row.string(1) ?? "",
                    trackCount: row.int(2) ?? 0, isSmart: false, ruleSummary: nil
                )
            }.filter { !$0.id.isEmpty && !$0.name.isEmpty }
            return ServerPlaylistsDatabasePage(totalItemCount: total, items: items)
        }
    }

    /// 单个手动歌单的曲目，按歌单内顺序。
    public func fetchServerMusicPlaylistDetail(
        allowedSourcePaths: Set<String>,
        playlistID: String,
        offset: Int,
        limit: Int,
        maximumContentRating: String? = nil
    ) throws -> ServerPlaylistDatabaseDetail? {
        guard !allowedSourcePaths.isEmpty, !playlistID.isEmpty else { return nil }
        let safeOffset = min(max(offset, 0), 1_000_000)
        let safeLimit = min(max(limit, 1), 100)
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let from = """
            FROM music_playlist_items AS entry
            INNER JOIN media_items AS item ON item.id = entry.media_id
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            let predicate = " WHERE entry.playlist_id = ? AND item.type = ?"
            let bindings: [SQLiteValue] = [.text(playlistID), .text(MediaType.music.rawValue)]
            // 一首可见曲目都没有的歌单，对这个用户来说不存在——返回 nil 让路由 404，
            // 而不是给一个空列表，那等于承认"确实有这么一个歌单"。
            let found = try database.query(
                """
                SELECT playlist.id, playlist.name
                FROM music_playlists AS playlist
                WHERE playlist.id = ?
                  AND EXISTS (SELECT 1 \(from) \(predicate))
                LIMIT 1
                """,
                bindings: [.text(playlistID)] + bindings
            ) { ($0.string(0) ?? "", $0.string(1) ?? "") }.first
            guard let playlist = found, !playlist.0.isEmpty, !playlist.1.isEmpty else { return nil }
            let total = try database.query("SELECT COUNT(*) " + from + predicate, bindings: bindings) {
                $0.int(0) ?? 0
            }.first ?? 0
            let items = try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: from)
                    + predicate
                    + " ORDER BY entry.position ASC, item.id ASC LIMIT ? OFFSET ?",
                bindings: bindings + [.int(Int64(safeLimit)), .int(Int64(safeOffset))],
                map: map(row:)
            )
            return ServerPlaylistDatabaseDetail(
                id: playlist.0, name: playlist.1, isSmart: false, totalItemCount: total, items: items
            )
        }
    }

    /// 请求者有权看到的全部音乐/视频条目，交给上层用规则求值。
    ///
    /// 智能集合与智能歌单是**规则**不是行，数据库里没有一张"成员表"可以 join。
    /// 规则求值必须落在 Swift 侧，用客户端那份 `VideoSmartCollection.matches` /
    /// `MusicSmartPlaylist` 逻辑——翻成 SQL 会得到第二套实现，漏一条规则就是静默
    /// 算错，而且没有任何东西会报错。
    ///
    /// 授权在这里就收口：交出去的候选集已经过滤过媒体源与保险库，上层再怎么按规则
    /// 筛，也不可能筛出它本来看不到的东西。
    public func fetchServerAuthorizedCandidates(
        allowedSourcePaths: Set<String>,
        type: MediaType?,
        maximumContentRating: String? = nil
    ) throws -> [MediaItem] {
        guard !allowedSourcePaths.isEmpty else { return [] }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            let from = """
            FROM media_items AS item
            INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
            \(ratingJoin)
            """
            var predicate = " WHERE item.type != ?"
            var bindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            if let type {
                predicate += " AND item.type = ?"
                bindings.append(.text(type.rawValue))
            } else {
                // 智能集合是视频概念，音乐与照片不参与。
                predicate += " AND item.type != ? AND item.type != ?"
                bindings.append(.text(MediaType.music.rawValue))
                bindings.append(.text(MediaType.photo.rawValue))
            }
            return try database.query(
                serverSelectSQL.replacingOccurrences(of: "FROM media_items", with: from)
                    + predicate
                    + " ORDER BY item.updated_at DESC, item.id ASC",
                bindings: bindings,
                map: map(row:)
            )
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

    /// `selectSQL` / `serverSelectSQL` 里媒体列的数量。
    ///
    /// 只有这一处查询会在媒体列后面再接自己的列（`credit.category` / `credit.role`），
    /// 而它必须按下标去取。写死 42 / 43 的那一版在给 `media_items` 加第 43 列时
    /// 静默错位：`category` 读到了 `has_lyrics`，于是每个演员的角色都变成了兜底的
    /// "cast"——编译照过，只有一条用例拦下了它。下标从这里推导，就不会再漏。
    private static let mediaColumnCount: Int32 = 43

    private var selectSQL: String {
        """
        SELECT id, type, title, original_title, artist, album, track_number, year, overview, poster_path, backdrop_path,
               rating, user_rating, runtime, source_path, parent_id, season_number, episode_number,
               file_path, file_size, video_codec, audio_codec, resolution, video_bitrate, duration,
               loudness_track_gain_db, loudness_album_gain_db, loudness_track_peak, loudness_album_peak,
               play_count, play_position, play_progress, watched, favorite, watchlist, external_id, metadata_provider, collection_title, created_at, updated_at, last_played_at, genre, has_lyrics
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
               item.play_count, item.play_position, item.play_progress, item.watched, item.favorite, item.watchlist, item.external_id, item.metadata_provider, item.collection_title, item.created_at, item.updated_at, item.last_played_at, item.genre, item.has_lyrics
        FROM media_items
        """
    }

    /// 排序键 + 方向 → 一段固定的 ORDER BY。
    ///
    /// 三条不变量：
    /// * 每个分支都以 `title, id` 收尾，于是同键的条目有稳定顺序，翻页不会重复或漏项。
    /// * 可空的键**两个方向都把 NULL 排在最后**——把"没有年份"的条目在倒序时顶到
    ///   第一页，读起来像是排序坏了。
    /// * `serverOrderBy` 是本文件里唯一定义"正序朝什么方向"的地方。
    private static func serverOrderBy(
        _ sort: ServerLibraryDatabaseSort,
        _ order: ServerLibraryDatabaseSortOrder
    ) -> String {
        let tiebreak = "item.title COLLATE NOCASE ASC, item.id ASC"
        let reversed = order == .reverse
        func direction(_ primary: String) -> String {
            guard reversed else { return primary }
            return primary == "DESC" ? "ASC" : "DESC"
        }
        /// 可空列：先按"是否为空"升序把 NULL 推到末尾，再按值排。
        func nullsLast(_ column: String, _ primary: String) -> String {
            "CASE WHEN \(column) IS NULL THEN 1 ELSE 0 END ASC, \(column) \(direction(primary)), \(tiebreak)"
        }
        switch sort {
        case .recentlyUpdated:
            return "item.updated_at \(direction("DESC")), \(tiebreak)"
        case .dateAdded:
            return "item.created_at \(direction("DESC")), \(tiebreak)"
        case .title:
            return "item.title COLLATE NOCASE \(direction("ASC")), item.id ASC"
        case .year:
            return nullsLast("item.year", "DESC")
        case .runtime:
            return nullsLast("item.runtime", "DESC")
        case .progress:
            // 没有播放记录等同于进度 0，而不是"未知"：LEFT JOIN 的 NULL 在这里
            // 有确定含义，所以它参与排序而不是被推到末尾。
            return "COALESCE(user_state.play_progress, 0) \(direction("DESC")), \(tiebreak)"
        case .score:
            return nullsLast("item.rating", "DESC")
        case .rating:
            return nullsLast("user_preference.user_rating", "DESC")
        case .lastPlayed:
            return nullsLast("user_state.last_played_at", "DESC")
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
            .optionalText(item.genre),
            .bool(item.hasLyrics)
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
            genre: row.string(41),
            hasLyrics: row.bool(42)
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

    /// 资料库里真实出现过的 distinct `source_path`。
    ///
    /// 服务端用它把"授权来源根"展开成具体路径，因此这里只读取列本身、不带任何
    /// 授权判定——调用方负责归属与授权。基数是来源数量级（几十），由
    /// `index_media_items_source_path` 服务。
    public func distinctSourcePaths() throws -> [String] {
        try database.query(
            "SELECT DISTINCT source_path FROM media_items WHERE source_path IS NOT NULL AND source_path <> ''",
            map: { $0.string(0) }
        ).compactMap { $0 }
    }

    /// 按 `source_path` 统计已授权条目数，用于远程来源分组的行内计数。
    ///
    /// 与其它服务端查询一样排除保险库类型；不返回任何标题或路径以外的字段。
    ///
    /// - Parameter topLevelOnly: 是否只数**能在该作用域的浏览页上出现**的条目。
    ///   侧栏徽标必须和点进去看到的条数是同一个数，而作用域浏览页走的是
    ///   `fetchServerLibraryPage(topLevelOnly:)` 的 `parent_id IS NULL AND type != episode`。
    ///   数全部行时，一个 1200 集的 Emby 剧集库徽标写 1200、点进去只有 30 部剧。
    public func itemCountsBySourcePath(
        allowedSourcePaths: Set<String>,
        topLevelOnly: Bool = false,
        maximumContentRating: String? = nil
    ) throws -> [String: Int] {
        guard !allowedSourcePaths.isEmpty else { return [:] }
        return try database.transaction {
            try prepareServerAllowedSourcePaths(allowedSourcePaths)
            let ratingJoin = try prepareServerAllowedContentRatings(maximum: maximumContentRating)
            defer {
                try? database.execute("DELETE FROM server_library_allowed_source_paths")
                clearServerAllowedContentRatings(maximum: maximumContentRating)
            }
            var predicates = ["item.type != ?"]
            var bindings: [SQLiteValue] = [.text(MediaType.privateCollection.rawValue)]
            if topLevelOnly {
                predicates.append("item.parent_id IS NULL")
                predicates.append("item.type != ?")
                bindings.append(.text(MediaType.episode.rawValue))
            }
            let rows = try database.query(
                """
                SELECT item.source_path, COUNT(*) FROM media_items AS item
                INNER JOIN server_library_allowed_source_paths AS allowed ON allowed.path = item.source_path
                \(ratingJoin)
                WHERE \(predicates.joined(separator: " AND ")) GROUP BY item.source_path
                """,
                bindings: bindings,
                map: { ($0.string(0), $0.int(1)) }
            )
            var counts: [String: Int] = [:]
            for (path, count) in rows {
                guard let path, let count else { continue }
                counts[path] = count
            }
            return counts
        }
    }


    /// 排除"无论 `source_path` 写成什么，都明显来自在线媒体服务器"的条目。
    ///
    /// 一级分类的归属主要靠来源路径，但路径并不总是可信：连接器自己的注释就写着
    /// "有些条目（如仅带流地址 filePath 的远程视频）不一定填了 emby:// 的
    /// sourcePath"。同时满足"元数据提供方是某个媒体服务器"和"文件是 http(s) 流"
    /// 两个条件时，它一定不是本地文件——本地条目有真实的文件路径。
    ///
    /// 两个条件必须**同时**成立才排除：只看 provider 会误伤用它刮削元数据的本地
    /// 条目；只看 http 会误伤用户自己添加的 URL 视频源（客户端把那些算本地）。
    /// `COALESCE` 不是可有可无的：`metadata_provider` 为 NULL 时
    /// `NULL IN (...)` 得 NULL，`NOT (NULL AND TRUE)` 仍是 NULL，于是整行被
    /// WHERE 丢掉——那会连"provider 未填但文件是 URL"的本地条目一起误伤，
    /// 与"两个条件必须同时成立"的本意正好相反。
    static let onlineSourceItemPredicate = """
        NOT (
          COALESCE(item.metadata_provider, '') IN ('Emby', 'Jellyfin', 'Plex', 'Mlink')
          AND (
            COALESCE(item.file_path, '') LIKE 'http://%'
            OR COALESCE(item.file_path, '') LIKE 'https://%'
          )
        )
        """

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

    /// Builds a request-scoped allow-list from the distinct rating labels that
    /// actually exist in metadata. The allow-list is joined by SQL callers, so
    /// pagination, counts and aggregates are computed after parental-policy
    /// filtering rather than leaking restricted rows and filtering cards later.
    ///
    /// The number of distinct labels is bounded independently from library size;
    /// unknown and missing labels fail closed whenever a maximum is configured.
    private func prepareServerAllowedContentRatings(maximum: String?) throws -> String {
        guard let maximum else { return "" }
        try database.execute(
            "CREATE TEMP TABLE IF NOT EXISTS server_allowed_content_ratings (value TEXT PRIMARY KEY) WITHOUT ROWID"
        )
        try database.execute("DELETE FROM server_allowed_content_ratings")
        let labels = try database.query(
            "SELECT DISTINCT content_rating FROM media_detail_metadata WHERE content_rating IS NOT NULL LIMIT 1024"
        ) { $0.string(0) }.compactMap { $0 }
        for label in labels where ServerContentRatingAgePolicy.allows(contentRating: label, maximum: maximum) {
            try database.execute(
                "INSERT OR IGNORE INTO server_allowed_content_ratings(value) VALUES (?)",
                bindings: [.text(label)]
            )
        }
        return " INNER JOIN media_detail_metadata AS rating_detail ON rating_detail.media_id = item.id INNER JOIN server_allowed_content_ratings AS allowed_rating ON allowed_rating.value = rating_detail.content_rating"
    }

    private func clearServerAllowedContentRatings(maximum: String?) {
        guard maximum != nil else { return }
        try? database.execute("DELETE FROM server_allowed_content_ratings")
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
