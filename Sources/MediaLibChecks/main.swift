import Foundation
import MediaLibCore

func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() {
        fputs("FAILED: \(message)\n", stderr)
        exit(1)
    }
}

for type in MediaType.allCases {
    check(!type.displayName.isEmpty, "MediaType display name should not be empty")
}
check(MediaType.privateCollection.rawValue == "private", "Privacy media type should use stable raw value")
check(AppSettings.defaultHomeTabs.contains(.overview), "Default home tabs should include overview")
check(AppSettings().enabledHomeTabs.count >= 8, "Home should expose expanded configurable tabs")

let embyRemoteItem = MediaItem(
    id: "emby-remote-check",
    type: .episode,
    title: "Remote Episode",
    filePath: "https://emby.example/videos/1/stream.mkv?api_key=token",
    metadataProvider: "Emby"
)
check(embyRemoteItem.isPlayable, "Emby remote stream should be treated as playable")
check(embyRemoteItem.isRemoteResource, "Emby remote stream should be treated as a remote resource")

let legacySettingsData = #"{"enableThumbnailFallback":false}"#.data(using: .utf8)!
let legacySettings = try JSONDecoder().decode(AppSettings.self, from: legacySettingsData)
check(legacySettings.artworkFallbackMode == .none, "Legacy thumbnail fallback switch should map to no artwork fallback")
check(!legacySettings.enabledHomeTabs.isEmpty, "Legacy settings should receive default home tabs")
let automaticScanSettingsData = #"{"automaticScanInterval":"hourly"}"#.data(using: .utf8)!
let automaticScanSettings = try JSONDecoder().decode(AppSettings.self, from: automaticScanSettingsData)
check(automaticScanSettings.automaticScanInterval == .hourly, "Automatic scan interval should round-trip from settings")
check(AppSettings().musicLoudnessNormalization == .track, "Music loudness normalization should default to track mode")
check(AppSettings().musicTransitionMode == .immediate, "Music transition should preserve immediate switching by default")
let musicOutputSettingsData = #"{"musicLoudnessNormalization":"album","musicTransitionMode":"softFade","musicSoftFadeDuration":1.4}"#.data(using: .utf8)!
let musicOutputSettings = try JSONDecoder().decode(AppSettings.self, from: musicOutputSettingsData)
check(musicOutputSettings.musicLoudnessNormalization == .album, "Music loudness mode should decode from settings")
check(musicOutputSettings.musicTransitionMode == .softFade, "Music transition mode should decode from settings")
check(abs(musicOutputSettings.musicSoftFadeDuration - 1.4) < 0.001, "Music soft fade duration should decode from settings")
let attenuatedGain = MusicLoudnessGain.linearGain(
    mode: .track,
    trackGainDB: -6,
    albumGainDB: nil,
    trackPeak: 0.99,
    albumPeak: nil
)
check(abs(attenuatedGain - 0.501) < 0.01, "ReplayGain attenuation should convert decibels to a linear volume")
let peakProtectedGain = MusicLoudnessGain.linearGain(
    mode: .track,
    trackGainDB: 6,
    albumGainDB: nil,
    trackPeak: 1.2,
    albumPeak: nil
)
check(peakProtectedGain <= 0.834, "ReplayGain should never exceed the stored peak limit")
let safelyAmplifiedGain = MusicLoudnessGain.linearGain(
    mode: .track,
    trackGainDB: 6,
    albumGainDB: nil,
    trackPeak: 0.5,
    albumPeak: nil
)
check(safelyAmplifiedGain > 1.9 && safelyAmplifiedGain <= 2, "ReplayGain may safely use headroom when a reliable peak is available")
let unknownPeakGain = MusicLoudnessGain.linearGain(
    mode: .track,
    trackGainDB: 6,
    albumGainDB: nil,
    trackPeak: nil,
    albumPeak: nil
)
check(unknownPeakGain == 1, "ReplayGain should not amplify without a reliable peak")
check(
    MusicQueuePreloadPolicy.nextItemID(
        queueIDs: ["a", "b", "c"],
        currentItemID: "b",
        repeatModeRawValue: "sequential",
        shuffleEnabled: false
    ) == "c",
    "Music preload policy should select the deterministic next track"
)
check(
    MusicQueuePreloadPolicy.nextItemID(
        queueIDs: ["a", "b", "c"],
        currentItemID: "c",
        repeatModeRawValue: "repeatAll",
        shuffleEnabled: false
    ) == "a",
    "Music preload policy should wrap repeat-all queues"
)
check(
    MusicQueuePreloadPolicy.nextItemID(
        queueIDs: ["a"],
        currentItemID: "a",
        repeatModeRawValue: "repeatAll",
        shuffleEnabled: false
    ) == nil,
    "Music preload policy should restart rather than preload a single repeated track"
)
check(
    MusicQueuePreloadPolicy.nextItemID(
        queueIDs: ["a", "b", "c"],
        currentItemID: "b",
        repeatModeRawValue: "sequential",
        shuffleEnabled: true
    ) == nil,
    "Music preload policy should avoid guessing a shuffled next track"
)

let tagDraft = MusicTagDraft(
    title: "  Song Title  ",
    artist: " Artist ",
    album: " Album ",
    trackNumber: 3,
    year: 2026,
    lyrics: " Lyric ",
    artworkPath: " /tmp/cover.jpg ",
    externalID: " recording-1 ",
    metadataProvider: " TestProvider "
)
check(tagDraft.metadataUpdate.title == "Song Title", "MusicTagDraft should trim title")
check(tagDraft.metadataUpdate.metadataProvider == "TestProvider", "MusicTagDraft should keep provider")
check(tagDraft.writableMetadataPairs.contains { $0.0 == "tracknumber" && $0.1 == "3" }, "MusicTagDraft should expose tracknumber")
check(tagDraft.writableMetadataPairs.contains { $0.0 == "lyrics" && $0.1 == "Lyric" }, "MusicTagDraft should expose lyrics")
let musicTagService = MusicTagEditingService()
check(
    musicTagService.canWriteFileTags(for: MediaItem(id: "local-mp3", type: .music, title: "Local", filePath: "/tmp/local.mp3")),
    "MusicTag should allow local supported audio extensions"
)
check(
    !musicTagService.canWriteFileTags(for: MediaItem(id: "remote-mp3", type: .music, title: "Remote", filePath: "https://example.com/track.mp3")),
    "MusicTag should not write remote audio URLs"
)
check(
    !musicTagService.canWriteFileTags(for: MediaItem(id: "unsupported-ape", type: .music, title: "Unsupported", filePath: "/tmp/local.ape")),
    "MusicTag should reject unsupported extensions"
)

let parser = FilenameParser()
let englishEpisode = parser.parse(url: URL(fileURLWithPath: "/TV/Breaking Bad/Season 01/Breaking.Bad.S01E02.1080p.WEB-DL.mkv"))
check(englishEpisode.kind == .episode, "S01E02 should parse as episode")
check(englishEpisode.title == "Breaking Bad", "Episode title should be cleaned")
check(englishEpisode.seasonNumber == 1, "Episode season should parse")
check(englishEpisode.episodeNumber == 2, "Episode number should parse")

let chineseEpisode = parser.parse(url: URL(fileURLWithPath: "/TV/庆余年/Season 01/庆余年 第01季 第02集.mkv"))
check(chineseEpisode.kind == .episode, "Chinese episode should parse")
check(chineseEpisode.seasonNumber == 1, "Chinese season should parse")
check(chineseEpisode.episodeNumber == 2, "Chinese episode should parse")

let movie = parser.parse(url: URL(fileURLWithPath: "/Movies/Inception (2010)/Inception.2010.1080p.BluRay.mkv"))
check(movie.kind == .movie, "Movie should parse as movie")
check(movie.title == "Inception", "Movie title should be cleaned")
check(movie.year == 2010, "Movie year should parse")

let classicA = parser.parse(
    url: URL(fileURLWithPath: "/TV Shows/The Last of Us (2023)/Season 01/The.Last.of.Us.S01E01.1080p.WEB-DL.mkv"),
    sourcePath: "/TV Shows"
)
let classicB = parser.parse(
    url: URL(fileURLWithPath: "/TV Shows/The Last of Us (2023)/Season 01/S01E02 - Infected.mkv"),
    sourcePath: "/TV Shows"
)
check(classicA.title == "The Last of Us", "Classic directory should own show title")
check(classicB.title == "The Last of Us", "Bare SxxExx in Season folder should use show directory")
check(classicA.seriesDirectoryPath == classicB.seriesDirectoryPath, "Classic episodes should share series directory identity")

let tempDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: tempDatabaseURL) }

let database = try DatabaseManager(url: tempDatabaseURL)
let sourceRepository = SourceRepository(database: database)
let mediaRepository = MediaRepository(database: database)
let musicQueueRepository = MusicQueueRepository(database: database)
let musicPlaylistRepository = MusicPlaylistRepository(database: database)
let videoSmartCollectionRepository = VideoSmartCollectionRepository(database: database)
let playbackMarkerRepository = PlaybackMarkerRepository(database: database)
let initialSchemaVersion = try database.schemaVersion()
check(initialSchemaVersion == DatabaseManager.currentSchemaVersion, "Database should migrate to current schema version")
let mediaSourceColumns = try database.query("PRAGMA table_info(media_sources)") { row in row.string(1) ?? "" }
let mediaItemColumns = try database.query("PRAGMA table_info(media_items)") { row in row.string(1) ?? "" }
check(mediaSourceColumns.contains("remote_trace_sync_mode"), "Schema v10 should include Emby trace sync mode")
check(mediaItemColumns.contains("user_rating"), "Schema v10 should include user rating")

let source = MediaSource(
    name: "测试媒体源",
    path: "/Volumes/Media",
    mediaType: .auto,
    includeInMetadataFetch: false,
    preferMetadataWriteToSource: true,
    includeInHealthCheck: false,
    remoteTraceSyncMode: .importOnly
)
try sourceRepository.save(source)
let sources = try sourceRepository.fetchAll()
check(sources.count == 1, "Source should be saved")
check(sources.first?.path == "/Volumes/Media", "Source path should round-trip")
check(sources.first?.includeInMetadataFetch == false, "Source metadata participation should round-trip")
check(sources.first?.preferMetadataWriteToSource == true, "Source metadata write-back preference should round-trip")
check(sources.first?.includeInHealthCheck == false, "Source health participation should round-trip")
check(sources.first?.remoteTraceSyncMode == .importOnly, "Source Emby trace sync mode should round-trip")

let showID = StableID.make(prefix: "show", value: "Breaking Bad")
let show = MediaItem(id: showID, type: .tvShow, title: "Breaking Bad", rating: 8.4, sourcePath: source.path)
let episode = MediaItem(
    id: StableID.make(prefix: "episode", value: "/Volumes/Media/Breaking Bad - S01E01.mkv"),
    type: .episode,
    title: "Breaking Bad",
    sourcePath: source.path,
    parentID: showID,
    seasonNumber: 1,
    episodeNumber: 1,
    filePath: "/Volumes/Media/Breaking Bad - S01E01.mkv",
    fileSize: 1024
)
let loudnessTrack = MediaItem(
    id: "loudness-track",
    type: .music,
    title: "Normalized Track",
    filePath: "/Volumes/Media/Normalized Track.flac",
    loudnessTrackGainDB: -7.25,
    loudnessAlbumGainDB: -5.5,
    loudnessTrackPeak: 0.97,
    loudnessAlbumPeak: 0.99
)
try mediaRepository.upsert(show)
try mediaRepository.upsert(episode)
try mediaRepository.upsert(loudnessTrack)
let shows = try mediaRepository.fetchTopLevel(type: .tvShow)
let episodes = try mediaRepository.fetchChildren(parentID: showID)
check(shows.count == 1, "Show should be fetched")
check(episodes.first?.episodeNumber == 1, "Episode should be linked")
check(shows.first?.rating == 8.4, "Provider score should persist separately from user rating")
check(shows.first?.userRating == nil, "User rating should remain nil until the user rates")
try mediaRepository.updateRating(id: show.id, rating: 4)
let ratedShow = try mediaRepository.fetchTopLevel(type: .tvShow).first
check(ratedShow?.rating == 8.4, "Updating user rating should not overwrite provider score")
check(ratedShow?.userRating == 4, "User rating should persist separately from provider score")
try mediaRepository.updateMetadata(id: show.id, metadata: MediaMetadataUpdate(rating: 9.2))
let metadataRatedShow = try mediaRepository.fetchTopLevel(type: .tvShow).first
check(metadataRatedShow?.rating == 9.2, "Metadata update should refresh provider score")
check(metadataRatedShow?.userRating == 4, "Metadata update should not overwrite existing user rating")
let persistedLoudnessTrack = try mediaRepository.fetchTopLevel(type: .music).first
check(persistedLoudnessTrack?.loudnessTrackGainDB == -7.25, "Track loudness gain should persist")
check(persistedLoudnessTrack?.loudnessAlbumPeak == 0.99, "Album loudness peak should persist")

try mediaRepository.setWatchlist(id: show.id, watchlist: true)
let watchlistedShows = try mediaRepository.fetchTopLevel(type: .tvShow)
check(watchlistedShows.first?.watchlist == true, "Video watchlist state should persist")
try mediaRepository.upsert(show)
let rescannedShows = try mediaRepository.fetchTopLevel(type: .tvShow)
check(rescannedShows.first?.watchlist == true, "Video rescans should preserve local watchlist state")

let smartCollection = try videoSmartCollectionRepository.save(
    VideoSmartCollection(
        name: "最近想看电影",
        mediaScope: .movies,
        stateFilter: .watchlist,
        recency: .thirtyDays
    )
)
let fetchedSmartCollection = try videoSmartCollectionRepository.fetchAll().first
check(fetchedSmartCollection?.id == smartCollection.id, "Video smart collection should persist")
check(fetchedSmartCollection?.mediaScope == .movies, "Video smart collection media scope should round-trip")
check(fetchedSmartCollection?.stateFilter == .watchlist, "Video smart collection state filter should round-trip")

let introMarker = try playbackMarkerRepository.save(
    PlaybackMarker(
        id: "intro-marker",
        mediaID: episode.id,
        kind: .intro,
        title: "片头",
        startTime: 12,
        endTime: 84
    )
)
check(introMarker.isCompleteRange, "Playback intro marker should preserve its complete range")
try playbackMarkerRepository.replaceEmbeddedChapters(
    mediaID: episode.id,
    with: [
        PlaybackMarker(
            id: "embedded-chapter-1",
            mediaID: episode.id,
            kind: .chapter,
            title: "第一章",
            startTime: 0,
            endTime: 320,
            origin: .embedded
        ),
        PlaybackMarker(
            id: "embedded-chapter-2",
            mediaID: episode.id,
            kind: .chapter,
            title: "第二章",
            startTime: 320,
            origin: .embedded
        )
    ]
)
let fetchedPlaybackMarkers = try playbackMarkerRepository.fetch(mediaID: episode.id)
check(fetchedPlaybackMarkers.count == 3, "Playback marker repository should preserve manual ranges and embedded chapters")
check(fetchedPlaybackMarkers.first?.startTime == 0, "Playback markers should sort by start time")
try playbackMarkerRepository.delete(id: introMarker.id)
let playbackMarkersAfterManualDelete = try playbackMarkerRepository.fetch(mediaID: episode.id)
check(
    playbackMarkersAfterManualDelete.allSatisfy { $0.kind == .chapter },
    "Deleting a manual playback marker should preserve embedded chapters"
)
check(fetchedSmartCollection?.recency == .thirtyDays, "Video smart collection recency should round-trip")
var editedSmartCollection = smartCollection
editedSmartCollection.name = "编辑后的想看电影"
_ = try videoSmartCollectionRepository.save(editedSmartCollection)
let editedSmartCollections = try videoSmartCollectionRepository.fetchAll()
check(editedSmartCollections.first?.name == "编辑后的想看电影", "Video smart collection edits should persist")

let queueTrackA = MediaItem(id: "queue-track-a", type: .music, title: "Queue A", filePath: "/tmp/queue-a.mp3")
let queueTrackB = MediaItem(id: "queue-track-b", type: .music, title: "Queue B", filePath: "/tmp/queue-b.mp3")
try mediaRepository.upsert(queueTrackA)
try mediaRepository.upsert(queueTrackB)
try musicQueueRepository.save(
    MusicQueueSnapshot(
        itemIDs: [queueTrackB.id, queueTrackA.id],
        repeatModeRawValue: "repeatAll",
        shuffleEnabled: true
    )
)
let restoredQueue = try musicQueueRepository.fetch()
check(restoredQueue.itemIDs == [queueTrackB.id, queueTrackA.id], "Music queue order should persist")
check(restoredQueue.repeatModeRawValue == "repeatAll", "Music repeat mode should persist")
check(restoredQueue.shuffleEnabled, "Music shuffle state should persist")

let directFetchPlaylist = try musicPlaylistRepository.create(
    name: "Direct Fetch",
    itemIDs: [queueTrackB.id, queueTrackA.id]
)
let fetchedDirectPlaylist = try musicPlaylistRepository.fetch(id: directFetchPlaylist.id)
check(fetchedDirectPlaylist?.name == "Direct Fetch", "Music playlist direct fetch should return the requested playlist")
check(
    fetchedDirectPlaylist?.itemIDs == [queueTrackB.id, queueTrackA.id],
    "Music playlist direct fetch should preserve item order"
)
let missingDirectPlaylist = try musicPlaylistRepository.fetch(id: "missing-playlist")
check(
    missingDirectPlaylist == nil,
    "Music playlist direct fetch should return nil for a missing playlist"
)

let healthDeleteA = MediaItem(id: "health-delete-a", type: .movie, title: "Health Delete A", filePath: "/tmp/health-delete-a.mkv")
let healthDeleteB = MediaItem(id: "health-delete-b", type: .music, title: "Health Delete B", filePath: "/tmp/health-delete-b.mp3")
let healthKeep = MediaItem(id: "health-keep", type: .movie, title: "Health Keep", filePath: "/tmp/health-keep.mkv")
try mediaRepository.upsert(healthDeleteA)
try mediaRepository.upsert(healthDeleteB)
try mediaRepository.upsert(healthKeep)
_ = try playbackMarkerRepository.save(
    PlaybackMarker(mediaID: healthDeleteA.id, kind: .bookmark, title: "临时书签", startTime: 10)
)
try mediaRepository.deleteItems(ids: [healthDeleteA.id, healthDeleteB.id])
let itemsAfterHealthDelete = try mediaRepository.fetchAll()
check(itemsAfterHealthDelete.allSatisfy { $0.id != healthDeleteA.id && $0.id != healthDeleteB.id }, "Health cleanup should delete requested index rows")
check(itemsAfterHealthDelete.contains { $0.id == healthKeep.id }, "Health cleanup should preserve unrequested index rows")
let deletedHealthMarkerCount = try database.query(
    "SELECT COUNT(*) FROM playback_markers WHERE media_id = ?",
    bindings: [.text(healthDeleteA.id)]
) { $0.int(0) ?? 0 }.first ?? 0
check(
    deletedHealthMarkerCount == 0,
    "Deleting a media index should cascade-delete its playback markers"
)

let remoteSourcePath = "emby://example/remote-source"
let remoteItemA = MediaItem(
    id: "remote-item-a",
    type: .movie,
    title: "Remote A",
    sourcePath: remoteSourcePath,
    filePath: "https://emby.example/Videos/a/stream",
    duration: 100,
    playPosition: 40,
    playProgress: 0.4,
    watched: false,
    favorite: true,
    externalID: "a",
    metadataProvider: "Emby"
)
let remoteItemB = MediaItem(
    id: "remote-item-b",
    type: .movie,
    title: "Remote B",
    sourcePath: remoteSourcePath,
    filePath: "https://emby.example/Videos/b/stream",
    externalID: "b",
    metadataProvider: "Emby"
)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [remoteItemA, remoteItemB])
var refreshedRemoteA = remoteItemA
refreshedRemoteA.playPosition = 100
refreshedRemoteA.playProgress = 1
refreshedRemoteA.watched = true
refreshedRemoteA.favorite = false
try mediaRepository.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [refreshedRemoteA])
let refreshedRemoteItems = try mediaRepository.fetchAll().filter { $0.sourcePath?.hasPrefix(remoteSourcePath) == true }
check(refreshedRemoteItems.count == 1, "Remote replacement should remove server items no longer returned")
check(refreshedRemoteItems.first?.watched == true, "Remote replacement should refresh watched state from server")
check(refreshedRemoteItems.first?.favorite == false, "Remote replacement should refresh favorite state from server")
check(refreshedRemoteItems.first?.playPosition == 100, "Remote replacement should refresh playback position from server")
try mediaRepository.setWatchlist(id: refreshedRemoteA.id, watchlist: true)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [refreshedRemoteA])
let remoteItemsAfterWatchlistRefresh = try mediaRepository.fetchAll()
check(
    remoteItemsAfterWatchlistRefresh.first(where: { $0.id == refreshedRemoteA.id })?.watchlist == true,
    "Remote refresh should preserve local watchlist state"
)

let databaseBackupDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Backups-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: databaseBackupDirectory) }
let backupURL = try database.createBackup(in: databaseBackupDirectory)
check(FileManager.default.fileExists(atPath: backupURL.path), "Database backup should create a SQLite snapshot")

try sourceRepository.delete(id: source.id)
try database.execute("DELETE FROM media_items WHERE id = ?", bindings: [.text(queueTrackA.id)])
try musicQueueRepository.save(MusicQueueSnapshot(itemIDs: [queueTrackB.id], repeatModeRawValue: "sequential"))
try database.restore(from: backupURL, safetyBackupDirectory: databaseBackupDirectory)
try database.validateCurrentDatabase()
let sourcesAfterDatabaseRestore = try sourceRepository.fetchAll()
let itemsAfterDatabaseRestore = try mediaRepository.fetchAll()
check(sourcesAfterDatabaseRestore.contains { $0.id == source.id }, "Database restore should recover media sources")
check(itemsAfterDatabaseRestore.contains { $0.id == queueTrackA.id }, "Database restore should recover media items")
check(
    itemsAfterDatabaseRestore.first(where: { $0.id == show.id })?.watchlist == true,
    "Database restore should recover video watchlist state"
)
let queueAfterDatabaseRestore = try musicQueueRepository.fetch()
check(queueAfterDatabaseRestore.itemIDs == [queueTrackB.id, queueTrackA.id], "Database restore should recover queue order")
check(queueAfterDatabaseRestore.repeatModeRawValue == "repeatAll", "Database restore should recover queue state")
let smartCollectionsAfterDatabaseRestore = try videoSmartCollectionRepository.fetchAll()
check(smartCollectionsAfterDatabaseRestore.contains { $0.id == smartCollection.id }, "Database restore should recover video smart collections")
let markersAfterDatabaseRestore = try playbackMarkerRepository.fetch(mediaID: episode.id)
check(markersAfterDatabaseRestore.count == 2, "Database restore should recover playback markers")
try videoSmartCollectionRepository.delete(id: smartCollection.id)
let smartCollectionsAfterDelete = try videoSmartCollectionRepository.fetchAll()
check(smartCollectionsAfterDelete.allSatisfy { $0.id != smartCollection.id }, "Video smart collection should be deletable")

let incompatibleDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Incompatible-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: incompatibleDatabaseURL) }
let incompatibleDatabase = try DatabaseManager(url: incompatibleDatabaseURL)
try incompatibleDatabase.execute("PRAGMA user_version = \(DatabaseManager.currentSchemaVersion + 1)")
let incompatibleBackupURL = try incompatibleDatabase.createBackup(in: databaseBackupDirectory, reason: "incompatible")
do {
    try database.restore(from: incompatibleBackupURL, safetyBackupDirectory: databaseBackupDirectory)
    check(false, "Database restore should reject backups from a newer schema")
} catch DatabaseError.incompatibleSchema(let found, let supported) {
    check(found == DatabaseManager.currentSchemaVersion + 1, "Incompatible backup should report its schema version")
    check(supported == DatabaseManager.currentSchemaVersion, "Incompatible backup should report supported schema version")
}

let legacyDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Legacy-\(UUID().uuidString).sqlite")
let automaticBackupDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-AutomaticBackups-\(UUID().uuidString)", isDirectory: true)
defer {
    try? FileManager.default.removeItem(at: legacyDatabaseURL)
    try? FileManager.default.removeItem(at: automaticBackupDirectory)
}
func prepareLegacyDatabase(at url: URL) throws {
    let legacyDatabase = try DatabaseManager(url: url)
    try legacyDatabase.execute("PRAGMA user_version = 0")
}
try prepareLegacyDatabase(at: legacyDatabaseURL)
let migratedLegacyDatabase = try DatabaseManager(url: legacyDatabaseURL, backupDirectory: automaticBackupDirectory)
let migratedLegacySchemaVersion = try migratedLegacyDatabase.schemaVersion()
check(migratedLegacySchemaVersion == DatabaseManager.currentSchemaVersion, "Legacy database should migrate in order")
let automaticBackups = try FileManager.default.contentsOfDirectory(at: automaticBackupDirectory, includingPropertiesForKeys: nil)
check(
    automaticBackups.contains { $0.lastPathComponent.hasPrefix("MediaLib-auto-pre-migration-") },
    "Schema migration should create an automatic safety backup"
)

let scanRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Library-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: scanRoot) }
let seasonDirectory = scanRoot
    .appendingPathComponent("TV Shows", isDirectory: true)
    .appendingPathComponent("The Last of Us (2023)", isDirectory: true)
    .appendingPathComponent("Season 01", isDirectory: true)
try FileManager.default.createDirectory(at: seasonDirectory, withIntermediateDirectories: true)
try "<tvshow><title>The Last of Us</title><year>2023</year></tvshow>".write(
    to: seasonDirectory.deletingLastPathComponent().appendingPathComponent("tvshow.nfo"),
    atomically: true,
    encoding: .utf8
)
try "<episodedetails><title>Episode One</title></episodedetails>".write(
    to: seasonDirectory.appendingPathComponent("The.Last.of.Us.S01E01.nfo"),
    atomically: true,
    encoding: .utf8
)
try Data("fake-video-1".utf8).write(to: seasonDirectory.appendingPathComponent("The.Last.of.Us.S01E01.mkv"))
try Data("fake-video-2".utf8).write(to: seasonDirectory.appendingPathComponent("S01E02 - Infected.mkv"))

let scanDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Scan-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: scanDatabaseURL) }
let scanDatabase = try DatabaseManager(url: scanDatabaseURL)
let scanRepository = MediaRepository(database: scanDatabase)
let scanner = MediaScanner(thumbnailGenerator: nil, mediaRepository: scanRepository)
let scanSource = MediaSource(
    name: "TV Shows",
    path: scanRoot.appendingPathComponent("TV Shows", isDirectory: true).path,
    mediaType: .tvShow,
    minimumFileSize: 0
)
let summary = await scanner.scan(source: scanSource, settings: AppSettings(enableThumbnailFallback: false)) { _ in }
check(summary.importedItems == 2, "Scanner should import two fake episodes")
let scannedShows = try scanRepository.fetchTopLevel(type: .tvShow)
check(scannedShows.count == 1, "Classic scan should create one show")
check(scannedShows.first?.title == "The Last of Us", "Series tvshow.nfo should define show title")
let scannedEpisodes = try scanRepository.fetchChildren(parentID: scannedShows.first?.id ?? "")
check(scannedEpisodes.count == 2, "Classic scan should attach both episodes to one show")

let incrementalEpisodeURL = seasonDirectory.appendingPathComponent("S01E03 - Long Long Time.mkv")
try Data("fake-video-3".utf8).write(to: incrementalEpisodeURL)
let incrementalAddSummary = await scanner.scanChanges(
    source: scanSource,
    changedPaths: [incrementalEpisodeURL.path],
    settings: AppSettings(enableThumbnailFallback: false)
) { _ in }
check(incrementalAddSummary.importedItems == 1, "Incremental scan should import only the changed media file")
let episodesAfterIncrementalAdd = try scanRepository.fetchChildren(parentID: scannedShows.first?.id ?? "")
check(episodesAfterIncrementalAdd.count == 3, "Incremental scan should preserve existing episodes")

let removedEpisodeURL = seasonDirectory.appendingPathComponent("The.Last.of.Us.S01E01.mkv")
try FileManager.default.removeItem(at: removedEpisodeURL)
_ = await scanner.scanChanges(
    source: scanSource,
    changedPaths: [removedEpisodeURL.path],
    settings: AppSettings(enableThumbnailFallback: false)
) { _ in }
let episodesAfterIncrementalDelete = try scanRepository.fetchChildren(parentID: scannedShows.first?.id ?? "")
check(episodesAfterIncrementalDelete.count == 2, "Incremental delete should remove only the missing file index")
let showsAfterIncrementalDelete = try scanRepository.fetchTopLevel(type: .tvShow)
check(showsAfterIncrementalDelete.count == 1, "Incremental delete should preserve a series that still has episodes")
let remainingEpisodeURLs = [
    seasonDirectory.appendingPathComponent("S01E02 - Infected.mkv"),
    incrementalEpisodeURL
]
for url in remainingEpisodeURLs {
    try FileManager.default.removeItem(at: url)
}
_ = await scanner.scanChanges(
    source: scanSource,
    changedPaths: remainingEpisodeURLs.map(\.path),
    settings: AppSettings(enableThumbnailFallback: false)
) { _ in }
let itemsAfterLastEpisodeDelete = try scanRepository.fetchAll()
check(itemsAfterLastEpisodeDelete.isEmpty, "Incremental delete should remove an orphaned series after its last episode disappears")

let musicRoot = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Music-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: musicRoot) }
let nestedMusicDirectory = musicRoot
    .appendingPathComponent("Mixed Folder", isDirectory: true)
    .appendingPathComponent("Disc 1", isDirectory: true)
try FileManager.default.createDirectory(at: nestedMusicDirectory, withIntermediateDirectories: true)
let nestedTrackURL = nestedMusicDirectory.appendingPathComponent("01 - Nested Song.mp3")
try Data(repeating: 0x01, count: 640 * 1024).write(to: nestedTrackURL)
try Data(repeating: 0x02, count: 12).write(to: nestedMusicDirectory.appendingPathComponent("cover.jpg"))
try Data("[00:01.00]Shared lyric".utf8).write(to: nestedMusicDirectory.appendingPathComponent("lyrics.lrc"))

let musicScanDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-MusicScan-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: musicScanDatabaseURL) }
let musicScanDatabase = try DatabaseManager(url: musicScanDatabaseURL)
let musicScanRepository = MediaRepository(database: musicScanDatabase)
let musicScanner = MediaScanner(thumbnailGenerator: nil, mediaRepository: musicScanRepository)
let musicSource = MediaSource(
    name: "Mixed",
    path: musicRoot.path,
    mediaType: .auto,
    minimumFileSize: 50 * 1024 * 1024
)
let musicSummary = await musicScanner.scan(source: musicSource, settings: AppSettings(enableThumbnailFallback: false)) { _ in }
check(musicSummary.importedItems == 1, "Auto scanner should recurse into nested folders and import audio")
let scannedMusic = try musicScanRepository.fetchTopLevel(type: .music)
check(scannedMusic.count == 1, "Nested audio should be imported as music")
check(scannedMusic.first?.title == "Nested Song", "Music title should fall back to cleaned filename")
check(scannedMusic.first?.album == nil, "Music scan should not infer one album from the folder")
check(scannedMusic.first?.posterPath == nil, "Music without embedded artwork should not reuse folder cover art")

let artworkDirectory = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-Artwork-\(UUID().uuidString)", isDirectory: true)
defer { try? FileManager.default.removeItem(at: artworkDirectory) }
let thumbnailGenerator = ThumbnailGenerator(outputDirectory: artworkDirectory)
let generatedArtwork = await thumbnailGenerator.generateDefaultArtwork(
    mediaID: "default-artwork-check",
    title: "测试默认封面",
    mediaType: .movie,
    aspectRatio: 16.0 / 9.0
)
check(generatedArtwork.map { FileManager.default.fileExists(atPath: $0.path) } == true, "Default artwork should be generated")

print("MediaLibChecks passed")
