import Foundation

public final class MusicLibraryProjectionRepository {
    private let database: DatabaseManager

    public init(database: DatabaseManager) {
        self.database = database
    }

    public func fetchSnapshot() throws -> MusicLibraryProjectionSnapshot {
        let rebuiltAt = try projectionRebuiltAt()
        let albums = try database.query(
            """
            SELECT id, title, artist, title_key, artist_key, track_count, favorite_count,
                   remote_count, play_count, total_duration, cover_path, latest_updated_at
            FROM music_album_index
            ORDER BY title COLLATE NOCASE ASC, artist COLLATE NOCASE ASC
            """
        ) { row in
            let id = row.string(0) ?? ""
            return MusicAlbumSummary(
                id: id,
                title: row.string(1) ?? Self.unknownAlbum,
                artist: row.string(2) ?? Self.unknownArtist,
                titleKey: row.string(3) ?? "",
                artistKey: row.string(4) ?? "",
                trackCount: row.int(5) ?? 0,
                favoriteCount: row.int(6) ?? 0,
                remoteCount: row.int(7) ?? 0,
                playCount: row.int(8) ?? 0,
                totalDuration: row.double(9),
                coverPath: row.string(10),
                latestUpdatedAt: row.date(11) ?? .distantPast,
                trackIDs: []
            )
        }
        let artists = try database.query(
            """
            SELECT id, name, name_key, track_count, album_count, favorite_count,
                   remote_count, play_count, cover_path, latest_updated_at
            FROM music_artist_index
            ORDER BY name COLLATE NOCASE ASC
            """
        ) { row in
            let id = row.string(0) ?? ""
            return MusicArtistSummary(
                id: id,
                name: row.string(1) ?? Self.unknownArtist,
                nameKey: row.string(2) ?? "",
                trackCount: row.int(3) ?? 0,
                albumCount: row.int(4) ?? 0,
                favoriteCount: row.int(5) ?? 0,
                remoteCount: row.int(6) ?? 0,
                playCount: row.int(7) ?? 0,
                coverPath: row.string(8),
                latestUpdatedAt: row.date(9) ?? .distantPast,
                trackIDs: []
            )
        }
        return MusicLibraryProjectionSnapshot(albums: albums, artists: artists, rebuiltAt: rebuiltAt)
    }

    public func fetchSnapshotAsync() async throws -> MusicLibraryProjectionSnapshot {
        try await database.transactionAsync {
            try self.fetchSnapshot()
        }
    }

    public func albumTrackIDs(albumID: String) throws -> [String] {
        try relationIDs(
            table: "music_album_track_index",
            ownerColumn: "album_id",
            ownerID: albumID
        )
    }

    public func artistTrackIDs(artistID: String) throws -> [String] {
        try relationIDs(
            table: "music_artist_track_index",
            ownerColumn: "artist_id",
            ownerID: artistID
        )
    }

    public func needsBackfill() throws -> Bool {
        try maintenancePlan() == .bootstrap
    }

    public func maintenancePlan() throws -> MusicProjectionMaintenancePlan {
        let state = try database.query(
            "SELECT music_item_count, latest_music_updated_at FROM music_projection_state WHERE id = 1 LIMIT 1"
        ) { row in
            (count: row.int(0) ?? 0, latest: row.string(1))
        }.first
        let current = try musicLibraryState()
        guard current.count > 0 else {
            return (state?.count ?? 0) == 0 ? .none : .incremental
        }
        guard let state else { return .bootstrap }
        if state.count != current.count { return .incremental }
        return (state.latest ?? "") != (current.latest ?? "") ? .incremental : .none
    }

    public func needsBackfillAsync() async throws -> Bool {
        try await database.transactionAsync {
            try self.needsBackfill()
        }
    }

    public func maintenancePlanAsync() async throws -> MusicProjectionMaintenancePlan {
        try await database.transactionAsync {
            try self.maintenancePlan()
        }
    }

    public func rebuildAll() async throws -> MusicProjectionRebuildResult {
        try await database.transactionAsync {
            let tracks = try MediaRepository(database: self.database).fetchMusic()
            let rebuiltAt = Date()
            let rebuiltAtValue = DateCoding.string(from: rebuiltAt) ?? ""

            let albumGroups = Dictionary(grouping: tracks) { track in
                MusicAlbumGroupingKey(
                    title: Self.displayAlbum(track.album),
                    artist: Self.displayArtist(track.artist)
                )
            }
            let artistGroups = Dictionary(grouping: tracks) { track in
                MusicArtistGroupingKey(name: Self.displayArtist(track.artist))
            }

            try self.database.execute("DELETE FROM music_album_track_index")
            try self.database.execute("DELETE FROM music_artist_track_index")
            try self.database.execute("DELETE FROM music_album_index")
            try self.database.execute("DELETE FROM music_artist_index")

            for (key, groupTracks) in albumGroups {
                let sortedTracks = Self.albumTracks(groupTracks)
                let summary = Self.albumSummary(for: key, tracks: sortedTracks, rebuiltAt: rebuiltAt)
                try self.insertAlbum(summary, rebuiltAtValue: rebuiltAtValue)
                for (offset, track) in sortedTracks.enumerated() {
                    try self.database.execute(
                        """
                        INSERT INTO music_album_track_index (album_id, media_id, position, track_number, title)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(summary.id),
                            .text(track.id),
                            .int(Int64(offset)),
                            .optionalInt(track.trackNumber),
                            .text(track.title)
                        ]
                    )
                }
            }

            for (key, groupTracks) in artistGroups {
                let sortedTracks = Self.artistTracks(groupTracks)
                let summary = Self.artistSummary(for: key, tracks: sortedTracks, rebuiltAt: rebuiltAt)
                try self.insertArtist(summary, rebuiltAtValue: rebuiltAtValue)
                for (offset, track) in sortedTracks.enumerated() {
                    try self.database.execute(
                        """
                        INSERT INTO music_artist_track_index (artist_id, media_id, position, title)
                        VALUES (?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(summary.id),
                            .text(track.id),
                            .int(Int64(offset)),
                            .text(track.title)
                        ]
                    )
                }
            }

            let current = try self.musicLibraryState()
            try self.database.execute(
                """
                INSERT INTO music_projection_state (id, music_item_count, latest_music_updated_at, rebuilt_at)
                VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET
                  music_item_count = excluded.music_item_count,
                  latest_music_updated_at = excluded.latest_music_updated_at,
                  rebuilt_at = excluded.rebuilt_at
                """,
                bindings: [
                    .int(Int64(current.count)),
                    .optionalText(current.latest),
                    .text(rebuiltAtValue)
                ]
            )

            return MusicProjectionRebuildResult(
                musicItemCount: tracks.count,
                albumCount: albumGroups.count,
                artistCount: artistGroups.count,
                rebuiltAt: rebuiltAt
            )
        }
    }

    public func synchronizeIncremental() async throws -> MusicProjectionIncrementalResult {
        try await database.transactionAsync {
            let tracks = try MediaRepository(database: self.database).fetchMusic()
            let rebuiltAt = Date()
            let rebuiltAtValue = DateCoding.string(from: rebuiltAt) ?? ""
            let currentState = try self.musicLibraryState()
            let previousState = try self.projectionState()
            let previousLatest = previousState?.latest ?? ""
            let indexedTrackIDs = try self.indexedMusicTrackIDs()
            let currentTracksByID = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            let currentTrackIDs = Set(currentTracksByID.keys)

            let changedTrackIDs = Set(tracks.compactMap { track -> String? in
                let updatedValue = DateCoding.string(from: track.updatedAt) ?? ""
                guard updatedValue > previousLatest || !indexedTrackIDs.contains(track.id) else { return nil }
                return track.id
            })
            let deletedTrackIDs = indexedTrackIDs.subtracting(currentTrackIDs)
            let affectedTrackIDs = changedTrackIDs.union(deletedTrackIDs)

            guard let previousState else {
                try self.updateProjectionState(currentState, rebuiltAtValue: rebuiltAtValue)
                return MusicProjectionIncrementalResult(
                    musicItemCount: tracks.count,
                    affectedAlbumCount: 0,
                    affectedArtistCount: 0,
                    rebuiltAt: rebuiltAt
                )
            }

            var affectedAlbumIDs = try self.relationOwnerIDs(
                table: "music_album_track_index",
                ownerColumn: "album_id",
                mediaIDs: affectedTrackIDs
            )
            var affectedArtistIDs = try self.relationOwnerIDs(
                table: "music_artist_track_index",
                ownerColumn: "artist_id",
                mediaIDs: affectedTrackIDs
            )
            let stateChanged = previousState.count != currentState.count ||
                (previousState.latest ?? "") != (currentState.latest ?? "")
            if affectedTrackIDs.isEmpty, stateChanged {
                affectedAlbumIDs.formUnion(try self.allOwnerIDs(ownerTable: "music_album_index"))
                affectedArtistIDs.formUnion(try self.allOwnerIDs(ownerTable: "music_artist_index"))
                affectedAlbumIDs.formUnion(tracks.map(Self.albumID(for:)))
                affectedArtistIDs.formUnion(tracks.map(Self.artistID(for:)))
            }
            affectedAlbumIDs.formUnion(try self.emptyOwnerIDs(
                ownerTable: "music_album_index",
                relationTable: "music_album_track_index",
                ownerColumn: "album_id"
            ))
            affectedArtistIDs.formUnion(try self.emptyOwnerIDs(
                ownerTable: "music_artist_index",
                relationTable: "music_artist_track_index",
                ownerColumn: "artist_id"
            ))

            for id in changedTrackIDs {
                guard let track = currentTracksByID[id] else { continue }
                affectedAlbumIDs.insert(Self.albumID(for: track))
                affectedArtistIDs.insert(Self.artistID(for: track))
            }

            let tracksByAlbumID = Dictionary(grouping: tracks, by: Self.albumID(for:))
            let tracksByArtistID = Dictionary(grouping: tracks, by: Self.artistID(for:))

            for albumID in affectedAlbumIDs {
                try self.database.execute(
                    "DELETE FROM music_album_track_index WHERE album_id = ?",
                    bindings: [.text(albumID)]
                )
                guard let groupTracks = tracksByAlbumID[albumID], !groupTracks.isEmpty else {
                    try self.database.execute(
                        "DELETE FROM music_album_index WHERE id = ?",
                        bindings: [.text(albumID)]
                    )
                    continue
                }
                let sortedTracks = Self.albumTracks(groupTracks)
                guard let first = sortedTracks.first else { continue }
                let summary = Self.albumSummary(
                    for: MusicAlbumGroupingKey(
                        title: Self.displayAlbum(first.album),
                        artist: Self.displayArtist(first.artist)
                    ),
                    tracks: sortedTracks,
                    rebuiltAt: rebuiltAt
                )
                try self.insertAlbum(summary, rebuiltAtValue: rebuiltAtValue)
                for (offset, track) in sortedTracks.enumerated() {
                    try self.database.execute(
                        """
                        INSERT INTO music_album_track_index (album_id, media_id, position, track_number, title)
                        VALUES (?, ?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(summary.id),
                            .text(track.id),
                            .int(Int64(offset)),
                            .optionalInt(track.trackNumber),
                            .text(track.title)
                        ]
                    )
                }
            }

            for artistID in affectedArtistIDs {
                try self.database.execute(
                    "DELETE FROM music_artist_track_index WHERE artist_id = ?",
                    bindings: [.text(artistID)]
                )
                guard let groupTracks = tracksByArtistID[artistID], !groupTracks.isEmpty else {
                    try self.database.execute(
                        "DELETE FROM music_artist_index WHERE id = ?",
                        bindings: [.text(artistID)]
                    )
                    continue
                }
                let sortedTracks = Self.artistTracks(groupTracks)
                guard let first = sortedTracks.first else { continue }
                let summary = Self.artistSummary(
                    for: MusicArtistGroupingKey(name: Self.displayArtist(first.artist)),
                    tracks: sortedTracks,
                    rebuiltAt: rebuiltAt
                )
                try self.insertArtist(summary, rebuiltAtValue: rebuiltAtValue)
                for (offset, track) in sortedTracks.enumerated() {
                    try self.database.execute(
                        """
                        INSERT INTO music_artist_track_index (artist_id, media_id, position, title)
                        VALUES (?, ?, ?, ?)
                        """,
                        bindings: [
                            .text(summary.id),
                            .text(track.id),
                            .int(Int64(offset)),
                            .text(track.title)
                        ]
                    )
                }
            }

            try self.updateProjectionState(currentState, rebuiltAtValue: rebuiltAtValue)
            return MusicProjectionIncrementalResult(
                musicItemCount: tracks.count,
                affectedAlbumCount: affectedAlbumIDs.count,
                affectedArtistCount: affectedArtistIDs.count,
                rebuiltAt: rebuiltAt
            )
        }
    }

    private func projectionRebuiltAt() throws -> Date? {
        try database.query(
            "SELECT rebuilt_at FROM music_projection_state WHERE id = 1 LIMIT 1"
        ) { row in
            row.date(0)
        }.first ?? nil
    }

    private func musicLibraryState() throws -> (count: Int, latest: String?) {
        try database.query(
            "SELECT COUNT(*), MAX(updated_at) FROM media_items WHERE type = ?",
            bindings: [.text(MediaType.music.rawValue)]
        ) { row in
            (count: row.int(0) ?? 0, latest: row.string(1))
        }.first ?? (0, nil)
    }

    private func projectionState() throws -> (count: Int, latest: String?)? {
        try database.query(
            "SELECT music_item_count, latest_music_updated_at FROM music_projection_state WHERE id = 1 LIMIT 1"
        ) { row in
            (count: row.int(0) ?? 0, latest: row.string(1))
        }.first
    }

    private func updateProjectionState(
        _ state: (count: Int, latest: String?),
        rebuiltAtValue: String
    ) throws {
        try database.execute(
            """
            INSERT INTO music_projection_state (id, music_item_count, latest_music_updated_at, rebuilt_at)
            VALUES (1, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
              music_item_count = excluded.music_item_count,
              latest_music_updated_at = excluded.latest_music_updated_at,
              rebuilt_at = excluded.rebuilt_at
            """,
            bindings: [
                .int(Int64(state.count)),
                .optionalText(state.latest),
                .text(rebuiltAtValue)
            ]
        )
    }

    private func relationIDs(table: String, ownerColumn: String, ownerID: String) throws -> [String] {
        try database.query(
            "SELECT media_id FROM \(table) WHERE \(ownerColumn) = ? ORDER BY position",
            bindings: [.text(ownerID)]
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty }
    }

    private func indexedMusicTrackIDs() throws -> Set<String> {
        Set(try database.query(
            """
            SELECT media_id FROM music_album_track_index
            UNION
            SELECT media_id FROM music_artist_track_index
            """
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty })
    }

    private func relationOwnerIDs(
        table: String,
        ownerColumn: String,
        mediaIDs: Set<String>
    ) throws -> Set<String> {
        guard !mediaIDs.isEmpty else { return [] }
        var ids = Set<String>()
        for mediaID in mediaIDs {
            let owners = try database.query(
                "SELECT \(ownerColumn) FROM \(table) WHERE media_id = ?",
                bindings: [.text(mediaID)]
            ) { row in
                row.string(0) ?? ""
            }
            ids.formUnion(owners.filter { !$0.isEmpty })
        }
        return ids
    }

    private func emptyOwnerIDs(
        ownerTable: String,
        relationTable: String,
        ownerColumn: String
    ) throws -> Set<String> {
        Set(try database.query(
            """
            SELECT owner.id
            FROM \(ownerTable) AS owner
            WHERE NOT EXISTS (
              SELECT 1 FROM \(relationTable) AS relation
              WHERE relation.\(ownerColumn) = owner.id
            )
            """
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty })
    }

    private func allOwnerIDs(ownerTable: String) throws -> Set<String> {
        Set(try database.query(
            "SELECT id FROM \(ownerTable)"
        ) { row in
            row.string(0) ?? ""
        }.filter { !$0.isEmpty })
    }

    // 重建先 DELETE 全表再写入，正常情况下不会撞 id；用 OR REPLACE 保证幂等——
    // 极端归一化边界下撞 id 时保留后写入者，而不是让整个重建事务失败并
    // 无限重试（曾导致「音乐索引更新失败：UNIQUE constraint failed」连续多日）。
    private func insertAlbum(_ summary: MusicAlbumSummary, rebuiltAtValue: String) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO music_album_index (
              id, title, artist, title_key, artist_key, track_count, favorite_count,
              remote_count, play_count, total_duration, cover_path, latest_updated_at, rebuilt_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(summary.id),
                .text(summary.title),
                .text(summary.artist),
                .text(summary.titleKey),
                .text(summary.artistKey),
                .int(Int64(summary.trackCount)),
                .int(Int64(summary.favoriteCount)),
                .int(Int64(summary.remoteCount)),
                .int(Int64(summary.playCount)),
                .optionalDouble(summary.totalDuration),
                .optionalText(summary.coverPath),
                .optionalDate(summary.latestUpdatedAt),
                .text(rebuiltAtValue)
            ]
        )
    }

    private func insertArtist(_ summary: MusicArtistSummary, rebuiltAtValue: String) throws {
        try database.execute(
            """
            INSERT OR REPLACE INTO music_artist_index (
              id, name, name_key, track_count, album_count, favorite_count,
              remote_count, play_count, cover_path, latest_updated_at, rebuilt_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            bindings: [
                .text(summary.id),
                .text(summary.name),
                .text(summary.nameKey),
                .int(Int64(summary.trackCount)),
                .int(Int64(summary.albumCount)),
                .int(Int64(summary.favoriteCount)),
                .int(Int64(summary.remoteCount)),
                .int(Int64(summary.playCount)),
                .optionalText(summary.coverPath),
                .optionalDate(summary.latestUpdatedAt),
                .text(rebuiltAtValue)
            ]
        )
    }

    private static func albumSummary(
        for key: MusicAlbumGroupingKey,
        tracks: [MediaItem],
        rebuiltAt: Date
    ) -> MusicAlbumSummary {
        MusicAlbumSummary(
            id: "album|\(key.artistKey)|\(key.titleKey)",
            title: key.title,
            artist: key.artist,
            titleKey: key.titleKey,
            artistKey: key.artistKey,
            trackCount: tracks.count,
            favoriteCount: tracks.filter(\.favorite).count,
            remoteCount: tracks.filter(\.isRemoteResource).count,
            playCount: tracks.reduce(0) { $0 + ($1.playCount ?? 0) },
            totalDuration: durationSum(tracks),
            coverPath: tracks.first(where: { $0.posterPath?.isEmpty == false })?.posterPath,
            latestUpdatedAt: tracks.map(\.updatedAt).max() ?? rebuiltAt,
            trackIDs: tracks.map(\.id)
        )
    }

    private static func artistSummary(
        for key: MusicArtistGroupingKey,
        tracks: [MediaItem],
        rebuiltAt: Date
    ) -> MusicArtistSummary {
        let albumKeys = Set(tracks.map { normalizedKey(displayAlbum($0.album)) })
        return MusicArtistSummary(
            id: "artist|\(key.nameKey)",
            name: key.name,
            nameKey: key.nameKey,
            trackCount: tracks.count,
            albumCount: albumKeys.count,
            favoriteCount: tracks.filter(\.favorite).count,
            remoteCount: tracks.filter(\.isRemoteResource).count,
            playCount: tracks.reduce(0) { $0 + ($1.playCount ?? 0) },
            coverPath: tracks.first(where: { $0.posterPath?.isEmpty == false })?.posterPath,
            latestUpdatedAt: tracks.map(\.updatedAt).max() ?? rebuiltAt,
            trackIDs: tracks.map(\.id)
        )
    }

    private static func albumTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        tracks.sorted {
            if ($0.trackNumber ?? 0) != ($1.trackNumber ?? 0) {
                return ($0.trackNumber ?? 0) < ($1.trackNumber ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    private static func artistTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        tracks.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private static func durationSum(_ tracks: [MediaItem]) -> Double? {
        let values = tracks.compactMap(\.duration).filter(\.isFinite)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +)
    }

    private static func albumID(for track: MediaItem) -> String {
        let titleKey = normalizedKey(displayAlbum(track.album))
        let artistKey = normalizedKey(displayArtist(track.artist))
        return "album|\(artistKey)|\(titleKey)"
    }

    private static func artistID(for track: MediaItem) -> String {
        "artist|\(normalizedKey(displayArtist(track.artist)))"
    }

    private static let unknownArtist = "未知艺术家"
    private static let unknownAlbum = "未知专辑"

    public static func displayArtist(_ value: String?) -> String {
        normalizedDisplay(value) ?? unknownArtist
    }

    public static func displayAlbum(_ value: String?) -> String {
        normalizedDisplay(value) ?? unknownAlbum
    }

    private static func normalizedDisplay(_ value: String?) -> String? {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func normalizedKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private struct MusicAlbumGroupingKey: Hashable {
        let title: String
        let artist: String
        let titleKey: String
        let artistKey: String

        init(title: String, artist: String) {
            self.title = title
            self.artist = artist
            self.titleKey = MusicLibraryProjectionRepository.normalizedKey(title)
            self.artistKey = MusicLibraryProjectionRepository.normalizedKey(artist)
        }

        static func == (lhs: MusicAlbumGroupingKey, rhs: MusicAlbumGroupingKey) -> Bool {
            lhs.titleKey == rhs.titleKey && lhs.artistKey == rhs.artistKey
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(titleKey)
            hasher.combine(artistKey)
        }
    }

    private struct MusicArtistGroupingKey: Hashable {
        let name: String
        let nameKey: String

        init(name: String) {
            self.name = name
            self.nameKey = MusicLibraryProjectionRepository.normalizedKey(name)
        }

        static func == (lhs: MusicArtistGroupingKey, rhs: MusicArtistGroupingKey) -> Bool {
            lhs.nameKey == rhs.nameKey
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(nameKey)
        }
    }
}
