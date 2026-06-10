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
check(AppSettings.defaultHomeTabs.contains(.offline), "Default home tabs should include offline entry")
check(AppSettings().enabledHomeTabs.count >= 8, "Home should expose expanded configurable tabs")

let embyRemoteItem = MediaItem(
    id: "emby-remote-check",
    type: .episode,
    title: "Remote Episode",
    filePath: "https://emby.example/videos/1/stream.mkv?api_key=token",
    metadataProvider: "Emby"
)
check(embyRemoteItem.isRemoteResource, "Emby remote stream should be treated as a remote resource")
let jellyfinSource = MediaSource(name: "Jellyfin", path: "jellyfin://jellyfin.example/source-id")
check(jellyfinSource.sourceKind == .jellyfin, "Jellyfin source path should map to the Jellyfin source kind")
check(jellyfinSource.displayPath == "jellyfin://jellyfin.example/source-id", "Jellyfin display path should be sanitized like other remote sources")
let plexSource = MediaSource(name: "Plex", path: "plex://plex.example/source-id")
check(plexSource.sourceKind == .plex, "Plex source path should map to the Plex source kind")
check(plexSource.displayPath == "plex://plex.example/source-id", "Plex display path should be sanitized like other remote sources")

let legacySettingsData = #"{"enableThumbnailFallback":false}"#.data(using: .utf8)!
let legacySettings = try JSONDecoder().decode(AppSettings.self, from: legacySettingsData)
check(legacySettings.artworkFallbackMode == .none, "Legacy thumbnail fallback switch should map to no artwork fallback")
check(!legacySettings.enabledHomeTabs.isEmpty, "Legacy settings should receive default home tabs")
let legacyHomeTabsData = #"{"enabledHomeTabs":["overview","nextUp","continueWatching","recent","movies","tvShows","anime","documentaries","variety","music","other","favorites","unwatched"]}"#.data(using: .utf8)!
let legacyHomeTabsSettings = try JSONDecoder().decode(AppSettings.self, from: legacyHomeTabsData)
check(legacyHomeTabsSettings.enabledHomeTabs.contains(.offline), "Legacy default home tabs should migrate to include offline entry")
let automaticScanSettingsData = #"{"automaticScanInterval":"hourly"}"#.data(using: .utf8)!
let automaticScanSettings = try JSONDecoder().decode(AppSettings.self, from: automaticScanSettingsData)
check(automaticScanSettings.automaticScanInterval == .hourly, "Automatic scan interval should round-trip from settings")
check(AppSettings().musicLoudnessNormalization == .track, "Music loudness normalization should default to track mode")
check(AppSettings().musicTransitionMode == .immediate, "Music transition should preserve immediate switching by default")
check(AppSettings().videoCacheSizeLimitGB == 0, "Video cache size limit should be unlimited by default")
check(AppSettings().videoTrackpadGesturesEnabled, "Video trackpad gestures should be enabled by default")
check(AppSettings().videoAspectOverride == .source, "Video aspect override should follow source by default")
check(AppSettings().videoCropMode == .none, "Video crop mode should be disabled by default")
check(AppSettings().videoDeinterlaceMode == .off, "Video deinterlace mode should be disabled by default")
check(AppSettings().videoRotationMode == .source, "Video rotation should be disabled by default")
let videoAdjustmentSettingsData = #"{"videoDefaultAudioDelay":8,"videoDefaultSubtitleDelay":-8,"videoDefaultSubtitleScale":3,"videoDefaultSubtitlePosition":20,"videoAspectOverride":"sixteenByNine","videoCropMode":"balanced","videoDeinterlaceMode":"auto","videoRotationMode":"clockwise90"}"#.data(using: .utf8)!
let videoAdjustmentSettings = try JSONDecoder().decode(AppSettings.self, from: videoAdjustmentSettingsData)
check(videoAdjustmentSettings.videoDefaultAudioDelay == 3, "Video audio delay should clamp to the supported range")
check(videoAdjustmentSettings.videoDefaultSubtitleDelay == -3, "Video subtitle delay should clamp to the supported range")
check(videoAdjustmentSettings.videoDefaultSubtitleScale == 1.5, "Video subtitle scale should clamp to the supported range")
check(videoAdjustmentSettings.videoDefaultSubtitlePosition == 70, "Video subtitle position should clamp to the supported range")
check(videoAdjustmentSettings.videoAspectOverride == .sixteenByNine, "Video aspect override should decode from settings")
check(videoAdjustmentSettings.videoCropMode == .balanced, "Video crop mode should decode from settings")
check(videoAdjustmentSettings.videoDeinterlaceMode == .auto, "Video deinterlace mode should decode from settings")
check(videoAdjustmentSettings.videoRotationMode == .clockwise90, "Video rotation mode should decode from settings")
check(!AppSettings().videoLoopCurrentItem, "Video single item loop should be disabled by default")
let videoLoopSettingsData = #"{"videoLoopCurrentItem":true}"#.data(using: .utf8)!
let videoLoopSettings = try JSONDecoder().decode(AppSettings.self, from: videoLoopSettingsData)
check(videoLoopSettings.videoLoopCurrentItem, "Video single item loop should decode from settings")
check(AppSettings().resolvedVideoKeyboardShortcuts(for: .playPause).count >= 2, "Video player should keep alternate play/pause shortcuts")
check(AppSettings().videoPlayerShortcutAction(for: VideoKeyboardShortcut(keyCode: 11, characters: "b")) == .cycleABLoopPoint, "Video A-B loop shortcut should resolve by default")
check(AppSettings().videoPlayerShortcutAction(for: VideoKeyboardShortcut(keyCode: 11, characters: "b", modifiers: .shift)) == .clearABLoop, "Video A-B clear shortcut should resolve by default")
check(AppSettings().videoPlayerShortcutAction(for: VideoKeyboardShortcut(keyCode: 34, characters: "i")) == .showPlaybackInfo, "Video playback info shortcut should resolve by default")
check(AppSettings().videoPlayerShortcutAction(for: VideoKeyboardShortcut(keyCode: 6, characters: "z")) == .subtitleDelayDown, "Video subtitle delay shortcut should resolve by default")
check(AppSettings().videoPlayerShortcutAction(for: VideoKeyboardShortcut(keyCode: 2, characters: "d")) == .cycleDeinterlaceMode, "Video deinterlace shortcut should resolve by default")
var shortcutSettings = AppSettings()
let customPlayShortcut = VideoKeyboardShortcut(keyCode: 7, characters: "x")
shortcutSettings.setVideoKeyboardShortcuts([customPlayShortcut], for: .playPause)
check(shortcutSettings.videoPlayerShortcutAction(for: customPlayShortcut) == .playPause, "Custom video shortcut should resolve to the assigned action")
let defaultMuteShortcut = VideoKeyboardShortcut(keyCode: 46, characters: "m")
shortcutSettings.setVideoKeyboardShortcuts([defaultMuteShortcut], for: .playPause)
check(shortcutSettings.videoPlayerShortcutAction(for: defaultMuteShortcut) == .playPause, "Duplicate shortcut should move to the latest assigned action")
check(shortcutSettings.resolvedVideoKeyboardShortcuts(for: .mute).isEmpty, "Duplicate shortcut assignment should clear the old action")
let musicOutputSettingsData = #"{"musicLoudnessNormalization":"album","musicTransitionMode":"softFade","musicSoftFadeDuration":1.4}"#.data(using: .utf8)!
let musicOutputSettings = try JSONDecoder().decode(AppSettings.self, from: musicOutputSettingsData)
check(musicOutputSettings.musicLoudnessNormalization == .album, "Music loudness mode should decode from settings")
check(musicOutputSettings.musicTransitionMode == .softFade, "Music transition mode should decode from settings")
check(abs(musicOutputSettings.musicSoftFadeDuration - 1.4) < 0.001, "Music soft fade duration should decode from settings")
let videoCacheLimitSettingsData = #"{"videoCacheSizeLimitGB":50}"#.data(using: .utf8)!
let videoCacheLimitSettings = try JSONDecoder().decode(AppSettings.self, from: videoCacheLimitSettingsData)
check(videoCacheLimitSettings.videoCacheSizeLimitGB == 50, "Video cache size limit should decode from settings")
let hugeVideoCacheLimitSettingsData = #"{"videoCacheSizeLimitGB":99999}"#.data(using: .utf8)!
let hugeVideoCacheLimitSettings = try JSONDecoder().decode(AppSettings.self, from: hugeVideoCacheLimitSettingsData)
check(hugeVideoCacheLimitSettings.videoCacheSizeLimitGB == 4096, "Video cache size limit should clamp extreme values")
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
let sidecarSamples = ["track.lrc", "subtitle.ass", "movie.cue", "poster.heic"]
for sample in sidecarSamples {
    let url = URL(fileURLWithPath: "/Media/\(sample)")
    check(parser.isSidecarMetadataFile(url), "\(sample) should be treated as sidecar metadata")
    check(!parser.isMediaFile(url, preferredType: .auto), "\(sample) should never be imported as media")
}
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

let localStoryboardBuckets = VideoFramePreviewGenerator.storyboardBuckets(duration: 7_200, preferCoarse: false)
let coarseStoryboardBuckets = VideoFramePreviewGenerator.storyboardBuckets(duration: 7_200, preferCoarse: true)
check(localStoryboardBuckets.count > 80 && localStoryboardBuckets.count <= 100, "Storyboard buckets should keep long local videos finite")
check(coarseStoryboardBuckets.count > 70 && coarseStoryboardBuckets.count < localStoryboardBuckets.count, "Coarse storyboard buckets should use fewer segments")
check(Set(localStoryboardBuckets).count == localStoryboardBuckets.count, "Storyboard buckets should be unique")
check(localStoryboardBuckets == localStoryboardBuckets.sorted(), "Storyboard buckets should be sorted")
check(
    VideoFramePreviewGenerator.bucket(for: 64, duration: 7_200, preferCoarse: false) ==
        VideoFramePreviewGenerator.bucket(for: 70, duration: 7_200, preferCoarse: false),
    "Nearby preview times should share the same storyboard bucket"
)
let traktPayload = TraktSyncPayloadBuilder.buildPayload(from: [
    .movie(tmdbID: 550),
    .movie(tmdbID: 603),
    .movie(tmdbID: 550),
    .show(tmdbID: 1400),
    .episode(showTmdbID: 1396, season: 1, episode: 2),
    .episode(showTmdbID: 1396, season: 1, episode: 1),
    .episode(showTmdbID: 1396, season: 1, episode: 2),
    .show(tmdbID: 1399),
    .show(tmdbID: 1399)
])
let traktPayloadData = try JSONSerialization.data(withJSONObject: traktPayload, options: [.sortedKeys])
let traktPayloadText = String(data: traktPayloadData, encoding: .utf8) ?? ""
check(
    traktPayloadText.contains(#""movies":[{"ids":{"tmdb":550}},{"ids":{"tmdb":603}}]"#),
    "Trakt payload should sort and deduplicate TMDB movie refs"
)
check(
    traktPayloadText.contains(#""episodes":[{"number":1},{"number":2}]"#),
    "Trakt payload should sort and deduplicate episode refs"
)
check(
    traktPayloadText.contains(#""shows":[{"ids":{"tmdb":1399}},{"ids":{"tmdb":1400}},{"ids":{"tmdb":1396},"seasons""#),
    "Trakt payload should sort and deduplicate standalone show refs"
)
let parsedTrueSyncValue = try SyncConflictValueParser.boolean("yes")
let parsedFalseSyncValue = try SyncConflictValueParser.boolean("0")
let parsedUserRating = try SyncConflictValueParser.userRating("4.5")
let parsedZeroUserRating = try SyncConflictValueParser.userRating("0")
let parsedNullUserRating = try SyncConflictValueParser.userRating("null")
check(parsedTrueSyncValue, "Sync conflict parser should accept yes as true")
check(!parsedFalseSyncValue, "Sync conflict parser should accept 0 as false")
check(parsedUserRating == 4.5, "Sync conflict parser should accept user ratings in 0-5 scale")
check(parsedZeroUserRating == nil, "Sync conflict parser should treat 0 user rating as clearing the rating")
check(parsedNullUserRating == nil, "Sync conflict parser should treat null user rating as clearing the rating")
var rejectedInvalidUserRating = false
do {
    _ = try SyncConflictValueParser.userRating("8")
} catch {
    rejectedInvalidUserRating = true
}
check(rejectedInvalidUserRating, "Sync conflict parser should reject user ratings outside 0-5")

let tempDatabaseURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("MediaLibChecks-\(UUID().uuidString).sqlite")
defer { try? FileManager.default.removeItem(at: tempDatabaseURL) }

let database = try DatabaseManager(url: tempDatabaseURL)
let sourceRepository = SourceRepository(database: database)
let mediaRepository = MediaRepository(database: database)
let musicQueueRepository = MusicQueueRepository(database: database)
let musicPlaylistRepository = MusicPlaylistRepository(database: database)
let videoSmartCollectionRepository = VideoSmartCollectionRepository(database: database)
let videoManualCollectionRepository = VideoManualCollectionRepository(database: database)
let videoOfflineSubscriptionRepository = VideoOfflineSubscriptionRepository(database: database)
let playbackMarkerRepository = PlaybackMarkerRepository(database: database)
let metadataCorrectionRepository = MetadataCorrectionRepository(database: database)
let remoteConnectorAccountRepository = RemoteConnectorAccountRepository(database: database)
let syncConflictRepository = SyncConflictRepository(database: database)
let initialSchemaVersion = try database.schemaVersion()
check(initialSchemaVersion == DatabaseManager.currentSchemaVersion, "Database should migrate to current schema version")
let mediaSourceColumns = try database.query("PRAGMA table_info(media_sources)") { row in row.string(1) ?? "" }
let mediaItemColumns = try database.query("PRAGMA table_info(media_items)") { row in row.string(1) ?? "" }
let manualCollectionTables = try database.query(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name IN ('video_manual_collections', 'video_manual_collection_items')"
) { row in row.string(0) ?? "" }
let offlineSubscriptionTables = try database.query(
    "SELECT name FROM sqlite_master WHERE type = 'table' AND name = 'video_offline_subscriptions'"
) { row in row.string(0) ?? "" }
let manualCollectionColumns = try database.query("PRAGMA table_info(video_manual_collections)") { row in row.string(1) ?? "" }
let smartCollectionColumns = try database.query("PRAGMA table_info(video_smart_collections)") { row in row.string(1) ?? "" }
let offlineSubscriptionColumns = try database.query("PRAGMA table_info(video_offline_subscriptions)") { row in row.string(1) ?? "" }
check(mediaSourceColumns.contains("remote_trace_sync_mode"), "Schema v10 should include Emby trace sync mode")
check(mediaItemColumns.contains("user_rating"), "Schema v10 should include user rating")
check(manualCollectionTables.count == 2, "Schema v11 should include video manual collection tables")
check(smartCollectionColumns.contains("rules_json"), "Schema v12 should include video smart collection rules JSON")
check(manualCollectionColumns.contains("show_on_home"), "Schema v13 should include manual collection home publishing")
check(smartCollectionColumns.contains("show_on_home"), "Schema v13 should include smart collection home publishing")
check(mediaSourceColumns.contains("selected_emby_library_ids"), "Schema v14 should include Emby library selection")
check(offlineSubscriptionTables.count == 1, "Schema v15 should include video offline subscription table")
check(offlineSubscriptionColumns.contains("quality_id"), "Schema v15 should include offline subscription quality preference")
check(offlineSubscriptionColumns.contains("season_number"), "Schema v16 should include offline subscription season target")
check(offlineSubscriptionColumns.contains("paused_until"), "Schema v16 should include offline subscription pause state")
check(offlineSubscriptionColumns.contains("expires_at"), "Schema v16 should include offline subscription expiry")
check(offlineSubscriptionColumns.contains("network_policy"), "Schema v16 should include offline subscription network policy")
let playbackMarkerColumns = try database.query("PRAGMA table_info(playback_markers)") { row in row.string(1) ?? "" }
check(playbackMarkerColumns.contains("review_status"), "Schema v17 should include playback marker review status")
check(playbackMarkerColumns.contains("detector_identifier"), "Schema v17 should include playback marker detector identifier")
check(playbackMarkerColumns.contains("confidence"), "Schema v17 should include playback marker confidence")
let batchTables = try database.query(
    """
    SELECT name FROM sqlite_master
    WHERE type = 'table'
      AND name IN (
        'metadata_correction_history',
        'sync_conflicts',
        'remote_connector_accounts'
      )
    """
) { row in row.string(0) ?? "" }
check(batchTables.count == 3, "Schema v18 should include metadata, sync, and connector tables")

let source = MediaSource(
    name: "测试媒体源",
    path: "/Volumes/Media",
    mediaType: .auto,
    includeInMetadataFetch: false,
    preferMetadataWriteToSource: true,
    includeInHealthCheck: false,
    remoteTraceSyncMode: .importOnly,
    selectedEmbyLibraryIDs: ["movies", "tvshows"]
)
try sourceRepository.save(source)
let sources = try sourceRepository.fetchAll()
check(sources.count == 1, "Source should be saved")
check(sources.first?.path == "/Volumes/Media", "Source path should round-trip")
check(sources.first?.includeInMetadataFetch == false, "Source metadata participation should round-trip")
check(sources.first?.preferMetadataWriteToSource == true, "Source metadata write-back preference should round-trip")
check(sources.first?.includeInHealthCheck == false, "Source health participation should round-trip")
check(sources.first?.remoteTraceSyncMode == .importOnly, "Source Emby trace sync mode should round-trip")
check(sources.first?.selectedEmbyLibraryIDs == ["movies", "tvshows"], "Source Emby library selection should round-trip")

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
let collectionOnlyMovie = MediaItem(
    id: "manual-collection-only",
    type: .movie,
    title: "Collection Only",
    year: 2022,
    rating: 8.6,
    userRating: 4,
    sourcePath: source.path,
    genre: "动作, 科幻"
)
try mediaRepository.upsert(show)
try mediaRepository.upsert(episode)
try mediaRepository.upsert(loudnessTrack)
try mediaRepository.upsert(collectionOnlyMovie)
let literalSearchItem = MediaItem(
    id: "literal-search-under_score",
    type: .movie,
    title: "Under_score",
    sourcePath: source.path,
    filePath: "/Volumes/Media/Under_score.mkv"
)
try mediaRepository.upsert(literalSearchItem)
let literalUnderscoreSearch = try mediaRepository.search("_")
check(
    literalUnderscoreSearch.contains { $0.id == literalSearchItem.id },
    "Search should find literal underscore titles"
)
check(
    literalUnderscoreSearch.allSatisfy { $0.title.contains("_") || ($0.originalTitle?.contains("_") ?? false) },
    "Search should not treat underscore as a wildcard"
)
let offlineSubscription = try videoOfflineSubscriptionRepository.save(
    VideoOfflineSubscription(
        seriesID: show.id,
        seriesTitle: show.title,
        mode: .nextUnwatched,
        episodeLimit: 10,
        qualityID: "height-1080"
    )
)
let fetchedOfflineSubscription = try videoOfflineSubscriptionRepository.fetch(seriesID: show.id)
check(fetchedOfflineSubscription?.id == offlineSubscription.id, "Video offline subscription should persist")
check(fetchedOfflineSubscription?.mode == .nextUnwatched, "Video offline subscription mode should round-trip")
check(fetchedOfflineSubscription?.episodeLimit == 10, "Video offline subscription episode limit should round-trip")
check(fetchedOfflineSubscription?.displayName == "自动缓存未看 10 集", "Video offline subscription display name should reflect episode limit")
check(fetchedOfflineSubscription?.qualityID == "height-1080", "Video offline subscription quality should round-trip")
let pausedUntil = Date(timeIntervalSince1970: 1_800_000_000)
let expiresAt = Date(timeIntervalSince1970: 1_900_000_000)
_ = try videoOfflineSubscriptionRepository.save(
    VideoOfflineSubscription(
        id: offlineSubscription.id,
        seriesID: show.id,
        seriesTitle: show.title,
        mode: .season,
        episodeLimit: 1,
        seasonNumber: 2,
        qualityID: nil,
        pausedUntil: pausedUntil,
        expiresAt: expiresAt,
        networkPolicy: .localNetworkOnly,
        createdAt: offlineSubscription.createdAt
    )
)
let fetchedSeasonOfflineSubscription = try videoOfflineSubscriptionRepository.fetch(seriesID: show.id)
check(fetchedSeasonOfflineSubscription?.mode == .season, "Video offline subscription season mode should round-trip")
check(fetchedSeasonOfflineSubscription?.seasonNumber == 2, "Video offline subscription season target should round-trip")
check(fetchedSeasonOfflineSubscription?.compactDisplayName == "第 2 季", "Video offline subscription compact name should reflect season")
check(fetchedSeasonOfflineSubscription?.networkPolicy == .localNetworkOnly, "Video offline subscription network policy should round-trip")
check(fetchedSeasonOfflineSubscription?.isRunnable == false, "Paused video offline subscription should not be runnable")
check(
    abs((fetchedSeasonOfflineSubscription?.pausedUntil?.timeIntervalSince1970 ?? 0) - pausedUntil.timeIntervalSince1970) < 0.001,
    "Video offline subscription pause date should round-trip"
)
check(
    abs((fetchedSeasonOfflineSubscription?.expiresAt?.timeIntervalSince1970 ?? 0) - expiresAt.timeIntervalSince1970) < 0.001,
    "Video offline subscription expiry date should round-trip"
)
try videoOfflineSubscriptionRepository.delete(seriesID: show.id)
let deletedOfflineSubscription = try videoOfflineSubscriptionRepository.fetch(seriesID: show.id)
check(deletedOfflineSubscription == nil, "Video offline subscription should be deletable")
let expiredOfflineSubscription = try videoOfflineSubscriptionRepository.save(
    VideoOfflineSubscription(
        seriesID: show.id,
        seriesTitle: show.title,
        mode: .nextEpisode,
        expiresAt: Date(timeIntervalSince1970: 1_500)
    )
)
let expiredOfflineSubscriptions = try videoOfflineSubscriptionRepository.fetchExpired(now: Date(timeIntervalSince1970: 2_000))
check(expiredOfflineSubscriptions.contains { $0.id == expiredOfflineSubscription.id }, "Expired video offline subscriptions should be fetchable")
let expiredOfflineSubscriptionDeleteCount = try videoOfflineSubscriptionRepository.deleteExpired(now: Date(timeIntervalSince1970: 2_000))
check(expiredOfflineSubscriptionDeleteCount == 1, "Expired video offline subscriptions should be deleted in bulk")
let prunedOfflineSubscription = try videoOfflineSubscriptionRepository.fetch(seriesID: show.id)
check(prunedOfflineSubscription == nil, "Expired video offline subscription cleanup should remove the rule")
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
let metadataChanges = try mediaRepository.updateMetadata(
    id: show.id,
    metadata: MediaMetadataUpdate(
        title: "Breaking Bad 修正版",
        overview: "一次可撤销的元数据修正",
        rating: 9.1,
        metadataProvider: "TMDB zh-CN"
    )
)
check(metadataChanges.contains { $0.field == .title }, "Metadata update should report changed title")
check(metadataChanges.contains { $0.field == .overview }, "Metadata update should report changed overview")
let correctionRecords = try metadataCorrectionRepository.record(
    mediaID: show.id,
    changes: metadataChanges,
    source: "check"
)
check(!correctionRecords.isEmpty, "Metadata correction history should record changed fields")
let correctionCountsByMediaID = try metadataCorrectionRepository.activeCountsByMediaID()
check(
    correctionCountsByMediaID[show.id] == correctionRecords.count,
    "Metadata correction counts should group by media"
)
let correctionBatches = try metadataCorrectionRepository.fetchActiveBatches()
check(
    correctionBatches.contains { $0.mediaID == show.id && $0.batchID == correctionRecords[0].batchID && $0.fieldCount == correctionRecords.count },
    "Metadata correction batches should summarize active history"
)
let undoBatch = try metadataCorrectionRepository.latestUndoableBatch(mediaID: show.id)
check(undoBatch.count == correctionRecords.count, "Latest metadata correction batch should be fetchable")
let undoValues = Dictionary(uniqueKeysWithValues: undoBatch.map { ($0.field, $0.oldValue) })
try database.transaction {
    try mediaRepository.restoreMetadataValues(id: show.id, values: undoValues)
    try metadataCorrectionRepository.markBatchUndone(batchID: undoBatch[0].batchID)
}
let restoredShow = try mediaRepository.fetch(id: show.id)
check(restoredShow?.title == "Breaking Bad", "Metadata undo should restore title")
check(restoredShow?.overview == nil, "Metadata undo should restore nil overview")
check(restoredShow?.rating == 9.2, "Metadata undo should restore provider score")
let activeCorrectionRecordCount = try metadataCorrectionRepository.activeRecordCount()
check(activeCorrectionRecordCount == 0, "Metadata correction undo should mark records as inactive")
let persistedLoudnessTrack = try mediaRepository.fetchTopLevel(type: .music).first
check(persistedLoudnessTrack?.loudnessTrackGainDB == -7.25, "Track loudness gain should persist")
check(persistedLoudnessTrack?.loudnessAlbumPeak == 0.99, "Album loudness peak should persist")

let jellyfinAccount = try remoteConnectorAccountRepository.save(
    RemoteConnectorAccount(
        provider: .jellyfin,
        accountLabel: "Jellyfin 测试",
        serverURL: "https://jellyfin.example",
        username: "demo",
        sourceID: source.id,
        connectionMode: .library,
        syncEnabled: true,
        capabilitiesJSON: #"{"playback":true,"progress":true}"#
    )
)
let plexAccount = try remoteConnectorAccountRepository.save(
    RemoteConnectorAccount(
        provider: .plex,
        accountLabel: "Plex 测试",
        serverURL: "https://plex.example",
        username: "demo",
        connectionMode: .direct
    )
)
let traktAccount = try remoteConnectorAccountRepository.save(
    RemoteConnectorAccount(
        provider: .trakt,
        accountLabel: "Trakt 测试",
        serverURL: "https://trakt.tv",
        connectionMode: .syncOnly,
        syncEnabled: true,
        capabilitiesJSON: #"{"historySync":true,"watchlistSync":true,"bidirectionalImport":true}"#
    )
)
let connectorAccounts = try remoteConnectorAccountRepository.fetchAll()
check(connectorAccounts.contains { $0.id == jellyfinAccount.id && $0.provider == .jellyfin }, "Jellyfin connector account should round-trip")
check(connectorAccounts.contains { $0.id == plexAccount.id && $0.provider == .plex && $0.connectionMode == .direct }, "Plex connector account should round-trip")
check(connectorAccounts.contains { $0.id == traktAccount.id && $0.provider == .trakt && $0.connectionMode == .syncOnly }, "Trakt connector account should round-trip")
let sourceScopedConnectorSource = MediaSource(
    name: "待删除 Jellyfin 来源",
    path: "jellyfin://jellyfin.example/delete-source"
)
try sourceRepository.save(sourceScopedConnectorSource)
let sourceScopedAccount = try remoteConnectorAccountRepository.save(
    RemoteConnectorAccount(
        provider: .jellyfin,
        accountLabel: "待删除 Jellyfin",
        sourceID: sourceScopedConnectorSource.id,
        syncEnabled: true
    )
)
try remoteConnectorAccountRepository.delete(sourceID: sourceScopedConnectorSource.id)
let connectorAccountsAfterSourceDelete = try remoteConnectorAccountRepository.fetchAll()
check(!connectorAccountsAfterSourceDelete.contains { $0.id == sourceScopedAccount.id }, "Connector accounts should be removable by source id")
let conflict = try syncConflictRepository.save(
    SyncConflict(
        mediaID: show.id,
        provider: .jellyfin,
        accountID: jellyfinAccount.id,
        fieldName: "watched",
        localValue: "false",
        remoteValue: "true",
        localUpdatedAt: Date(timeIntervalSince1970: 1_800_000_000),
        remoteUpdatedAt: Date(timeIntervalSince1970: 1_800_000_100)
    )
)
let pendingConflictCount = try syncConflictRepository.pendingCount()
check(pendingConflictCount == 1, "Sync conflict table should count pending conflicts")
try syncConflictRepository.resolve(id: conflict.id, resolution: .useRemote)
let resolvedPendingConflictCount = try syncConflictRepository.pendingCount()
check(resolvedPendingConflictCount == 0, "Resolved sync conflict should leave pending queue")
try mediaRepository.setWatchlist(id: show.id, watchlist: false)
let remoteApplyConflict = try syncConflictRepository.save(
    SyncConflict(
        mediaID: show.id,
        provider: .trakt,
        accountID: traktAccount.id,
        fieldName: "watchlist",
        localValue: "false",
        remoteValue: "true"
    )
)
try database.transaction {
    try mediaRepository.setWatchlist(id: show.id, watchlist: true)
    try syncConflictRepository.resolve(id: remoteApplyConflict.id, resolution: .useRemote)
}
let remoteAppliedShow = try mediaRepository.fetch(id: show.id)
check(remoteAppliedShow?.watchlist == true, "Adopting a remote watchlist conflict should update the internal media index")
let pendingConflictCountAfterRemoteApply = try syncConflictRepository.pendingCount()
check(pendingConflictCountAfterRemoteApply == 0, "Applied remote conflict should leave pending queue")
let ignoredConflict = try syncConflictRepository.save(
    SyncConflict(
        mediaID: show.id,
        provider: .plex,
        accountID: plexAccount.id,
        fieldName: "watchlist",
        localValue: "true",
        remoteValue: "false"
    )
)
let pendingConflictCountAfterInsert = try syncConflictRepository.pendingCount()
check(pendingConflictCountAfterInsert == 1, "New sync conflict should re-enter pending queue")
try syncConflictRepository.ignore(id: ignoredConflict.id)
let pendingConflictCountAfterIgnore = try syncConflictRepository.pendingCount()
check(pendingConflictCountAfterIgnore == 0, "Ignored sync conflict should leave pending queue")
let traktImportConflictID = StableID.make(prefix: "sync-conflict", value: "trakt-\(show.id)-watchlist")
let traktImportConflict = try syncConflictRepository.save(
    SyncConflict(
        id: traktImportConflictID,
        mediaID: show.id,
        provider: .trakt,
        accountID: traktAccount.id,
        fieldName: "watchlist",
        localValue: "false",
        remoteValue: "true"
    )
)
let traktImportConflictUpdate = try syncConflictRepository.save(
    SyncConflict(
        id: traktImportConflictID,
        mediaID: show.id,
        provider: .trakt,
        accountID: traktAccount.id,
        fieldName: "watchlist",
        localValue: "true",
        remoteValue: "false"
    )
)
check(traktImportConflict.id == traktImportConflictUpdate.id, "Trakt import conflict should use a stable conflict id")
let traktImportPendingCount = try syncConflictRepository.pendingCount()
check(traktImportPendingCount == 1, "Stable Trakt import conflict should update instead of duplicating")
try syncConflictRepository.resolve(id: traktImportConflictID, resolution: .useLocal)
let resolvedTraktImportPendingCount = try syncConflictRepository.pendingCount()
check(resolvedTraktImportPendingCount == 0, "Resolved Trakt import conflict should leave pending queue")

try mediaRepository.setWatchlist(id: show.id, watchlist: true)
let watchlistedShows = try mediaRepository.fetchTopLevel(type: .tvShow)
check(watchlistedShows.first?.watchlist == true, "Video watchlist state should persist")
try mediaRepository.upsert(show)
let rescannedShows = try mediaRepository.fetchTopLevel(type: .tvShow)
check(rescannedShows.first?.watchlist == true, "Video rescans should preserve local watchlist state")
try mediaRepository.markWatched(id: show.id, watched: true)
let defaultWatchedShow = try mediaRepository.fetch(id: show.id)
check(defaultWatchedShow?.watchlist == true, "Default mark watched should preserve watchlist state")
check(defaultWatchedShow?.playProgress == 1, "Marking watched should move progress to complete")
try mediaRepository.markWatched(id: show.id, watched: false, clearWatchlistWhenWatched: true)
let unwatchedWatchlistShow = try mediaRepository.fetch(id: show.id)
check(unwatchedWatchlistShow?.watchlist == true, "Unmarking watched should not clear watchlist state")
check(unwatchedWatchlistShow?.watched == false, "Unmarking watched should clear watched state")
check(unwatchedWatchlistShow?.playProgress == 0, "Unmarking watched should clear completed progress")
check(unwatchedWatchlistShow?.playPosition == 0, "Unmarking watched should clear playback position")
check(unwatchedWatchlistShow?.lastPlayedAt == nil, "Unmarking watched should clear playback recency")
try mediaRepository.markWatched(id: show.id, watched: true, clearWatchlistWhenWatched: true)
let watchedCleanedShow = try mediaRepository.fetch(id: show.id)
check(watchedCleanedShow?.watchlist == false, "Marking watched with cleanup should remove video watchlist state")
try mediaRepository.setWatchlist(id: show.id, watchlist: true)

let smartCollection = try videoSmartCollectionRepository.save(
    VideoSmartCollection(
        name: "最近想看电影",
        mediaScope: .movies,
        stateFilter: .watchlist,
        recency: .thirtyDays,
        rules: VideoSmartCollectionRules(
            matchMode: .all,
            year: .since2020,
            providerRating: .atLeastEight,
            userRating: .atLeastFour,
            genreKeyword: "科幻",
            source: .local
        ),
        showOnHome: true
    )
)
let fetchedSmartCollection = try videoSmartCollectionRepository.fetchAll().first
check(fetchedSmartCollection?.id == smartCollection.id, "Video smart collection should persist")
check(fetchedSmartCollection?.mediaScope == .movies, "Video smart collection media scope should round-trip")
check(fetchedSmartCollection?.stateFilter == .watchlist, "Video smart collection state filter should round-trip")
check(fetchedSmartCollection?.showOnHome == true, "Video smart collection home publishing should round-trip")
check(fetchedSmartCollection?.rules.year == .since2020, "Video smart collection year rule should round-trip")
check(fetchedSmartCollection?.rules.providerRating == .atLeastEight, "Video smart collection provider score rule should round-trip")
check(fetchedSmartCollection?.rules.userRating == .atLeastFour, "Video smart collection user rating rule should round-trip")
check(fetchedSmartCollection?.rules.genreKeyword == "科幻", "Video smart collection genre rule should be normalized and persist")
check(fetchedSmartCollection?.rules.source == .local, "Video smart collection source rule should round-trip")
let smartCollectionMatchMovie = MediaItem(
    id: "smart-match-movie",
    type: .movie,
    title: "Smart Match",
    year: 2023,
    rating: 8.7,
    userRating: 4,
    sourcePath: source.path,
    watchlist: true,
    genre: "科幻, 冒险"
)
check(
    fetchedSmartCollection?.matches(smartCollectionMatchMovie, watchedThreshold: 0.9) == true,
    "Video smart collection should match extended rules"
)
let smartCollectionRemoteMovie = MediaItem(
    id: "smart-remote-movie",
    type: .movie,
    title: "Smart Remote",
    year: 2023,
    rating: 8.7,
    userRating: 4,
    sourcePath: "emby://server/source/library/movies",
    watchlist: true,
    metadataProvider: "Emby",
    genre: "科幻, 冒险"
)
check(
    fetchedSmartCollection?.matches(smartCollectionRemoteMovie, watchedThreshold: 0.9) == false,
    "Video smart collection local source rule should reject remote media server items"
)
let smartCollectionMismatchMovie = MediaItem(
    id: "smart-mismatch-movie",
    type: .movie,
    title: "Smart Mismatch",
    year: 2018,
    rating: 8.7,
    userRating: 4,
    sourcePath: source.path,
    watchlist: true,
    genre: "科幻"
)
check(
    fetchedSmartCollection?.matches(smartCollectionMismatchMovie, watchedThreshold: 0.9) == false,
    "Video smart collection should reject items that miss an all-mode extended rule"
)
let smartAnyCollection = VideoSmartCollection(
    name: "任一高分",
    mediaScope: .movies,
    rules: VideoSmartCollectionRules(matchMode: .any, providerRating: .atLeastEight)
)
check(
    smartAnyCollection.matches(smartCollectionMatchMovie, watchedThreshold: 0.9),
    "Video smart collection should allow any-mode matches inside the selected media scope"
)
check(
    !smartAnyCollection.matches(
        MediaItem(id: "smart-any-music", type: .music, title: "High Score Song", rating: 9.5),
        watchedThreshold: 0.9
    ),
    "Video smart collection any-mode should still keep media scope as the base boundary"
)
let smartRemoteCollection = VideoSmartCollection(
    name: "远程高分",
    mediaScope: .movies,
    rules: VideoSmartCollectionRules(source: .emby)
)
check(
    smartRemoteCollection.matches(smartCollectionRemoteMovie, watchedThreshold: 0.9),
    "Video smart collection remote source rule should match media server items"
)
check(
    !smartRemoteCollection.matches(smartCollectionMatchMovie, watchedThreshold: 0.9),
    "Video smart collection remote source rule should reject local media"
)
check(
    !smartAnyCollection.matches(
        MediaItem(id: "smart-any-private", type: .privateCollection, title: "Private High Score", rating: 9.5),
        watchedThreshold: 0.9
    ),
    "Video smart collection should keep private collection items outside the media scope"
)

var manualCollection = try videoManualCollectionRepository.create(
    name: "周末片单",
    itemIDs: [show.id, episode.id, show.id, ""]
)
manualCollection.showOnHome = true
manualCollection = try videoManualCollectionRepository.save(manualCollection)
check(manualCollection.itemIDs == [show.id, episode.id], "Video manual collection should preserve unique item order")
check(manualCollection.showOnHome == true, "Video manual collection home publishing should round-trip")
manualCollection = try videoManualCollectionRepository.add(
    itemIDs: [collectionOnlyMovie.id, show.id],
    toCollectionID: manualCollection.id
) ?? manualCollection
check(
    manualCollection.itemIDs == [show.id, episode.id, collectionOnlyMovie.id],
    "Video manual collection should append new items without duplicating existing ones"
)
manualCollection = try videoManualCollectionRepository.remove(
    itemIDs: [episode.id],
    fromCollectionID: manualCollection.id
) ?? manualCollection
check(
    manualCollection.itemIDs == [show.id, collectionOnlyMovie.id],
    "Video manual collection should remove selected items"
)
var manualReorderCollection = try videoManualCollectionRepository.create(
    name: "排序片单",
    itemIDs: [show.id, episode.id, collectionOnlyMovie.id]
)
manualReorderCollection.itemIDs = VideoManualCollection.reorderedItemIDs(
    manualReorderCollection.itemIDs,
    movingItemIDs: [collectionOnlyMovie.id],
    operation: .moveUp
)
manualReorderCollection = try videoManualCollectionRepository.save(manualReorderCollection)
check(
    manualReorderCollection.itemIDs == [show.id, collectionOnlyMovie.id, episode.id],
    "Video manual collection should move an item up by one slot"
)
manualReorderCollection.itemIDs = VideoManualCollection.reorderedItemIDs(
    manualReorderCollection.itemIDs,
    movingItemIDs: [show.id, collectionOnlyMovie.id],
    operation: .moveDown
)
manualReorderCollection = try videoManualCollectionRepository.save(manualReorderCollection)
check(
    manualReorderCollection.itemIDs == [episode.id, show.id, collectionOnlyMovie.id],
    "Video manual collection should move selected items down while preserving relative order"
)
manualReorderCollection.itemIDs = VideoManualCollection.reorderedItemIDs(
    manualReorderCollection.itemIDs,
    movingItemIDs: [show.id],
    operation: .moveToBottom
)
manualReorderCollection = try videoManualCollectionRepository.save(manualReorderCollection)
check(
    manualReorderCollection.itemIDs == [episode.id, collectionOnlyMovie.id, show.id],
    "Video manual collection should move an item to the bottom"
)
manualReorderCollection.itemIDs = VideoManualCollection.reorderedItemIDs(
    manualReorderCollection.itemIDs,
    movingItemIDs: [show.id, episode.id],
    operation: .moveToTop
)
manualReorderCollection = try videoManualCollectionRepository.save(manualReorderCollection)
check(
    manualReorderCollection.itemIDs == [episode.id, show.id, collectionOnlyMovie.id],
    "Video manual collection should move selected items to the top in collection order"
)

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
check(introMarker.reviewStatus == .accepted, "Manual playback markers should default to accepted review status")
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
let automaticPendingMarker = try playbackMarkerRepository.save(
    PlaybackMarker(
        id: "automatic-intro-check",
        mediaID: episode.id,
        kind: .intro,
        title: "片头",
        startTime: 14,
        endTime: 88,
        origin: .automatic,
        reviewStatus: .pending,
        detectorIdentifier: "embedded-chapter-keyword",
        confidence: 0.88
    )
)
check(automaticPendingMarker.isPendingReview, "Automatic playback markers should preserve pending review status")
try playbackMarkerRepository.updateReviewStatus(id: automaticPendingMarker.id, status: .rejected)
let visibleAfterReject = try playbackMarkerRepository.fetch(mediaID: episode.id)
check(!visibleAfterReject.contains { $0.id == automaticPendingMarker.id }, "Rejected automatic playback markers should be hidden from normal fetch")
let allAfterReject = try playbackMarkerRepository.fetchIncludingRejected(mediaID: episode.id)
check(
    allAfterReject.contains { $0.id == automaticPendingMarker.id && $0.reviewStatus == .rejected },
    "Rejected automatic playback markers should remain available for duplicate suppression"
)
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
let recursiveDeleteParent = MediaItem(
    id: "recursive-delete-parent",
    type: .tvShow,
    title: "Recursive Delete",
    sourcePath: source.path
)
let recursiveDeleteChild = MediaItem(
    id: "recursive-delete-child",
    type: .episode,
    title: "Recursive Delete Episode",
    sourcePath: source.path,
    parentID: recursiveDeleteParent.id,
    filePath: "/Volumes/Media/Recursive Delete/S01E01.mkv"
)
let recursiveDeleteGrandchild = MediaItem(
    id: "recursive-delete-grandchild",
    type: .episode,
    title: "Recursive Delete Nested Clip",
    sourcePath: source.path,
    parentID: recursiveDeleteChild.id,
    filePath: "/Volumes/Media/Recursive Delete/S01E01-extra.mkv"
)
try mediaRepository.upsert(recursiveDeleteParent)
try mediaRepository.upsert(recursiveDeleteChild)
try mediaRepository.upsert(recursiveDeleteGrandchild)
_ = try playbackMarkerRepository.save(
    PlaybackMarker(mediaID: recursiveDeleteChild.id, kind: .bookmark, title: "子集书签", startTime: 20)
)
let recursiveDeleteCollection = try videoManualCollectionRepository.create(
    name: "递归删除检查",
    itemIDs: [recursiveDeleteParent.id, recursiveDeleteChild.id]
)
try mediaRepository.deleteItems(ids: [recursiveDeleteParent.id])
let recursiveDeleteItemsAfterDelete = try mediaRepository.fetchAll()
check(
    recursiveDeleteItemsAfterDelete.allSatisfy {
        $0.id != recursiveDeleteParent.id &&
            $0.id != recursiveDeleteChild.id &&
            $0.id != recursiveDeleteGrandchild.id
    },
    "Deleting a parent media index should also delete descendant media rows"
)
let recursiveDeleteMarkerCount = try database.query(
    "SELECT COUNT(*) FROM playback_markers WHERE media_id = ?",
    bindings: [.text(recursiveDeleteChild.id)]
) { $0.int(0) ?? 0 }.first ?? 0
check(
    recursiveDeleteMarkerCount == 0,
    "Deleting descendant media rows should cascade-delete their playback markers"
)
let recursiveCollectionAfterDelete = try videoManualCollectionRepository.fetch(id: recursiveDeleteCollection.id)
check(
    recursiveCollectionAfterDelete?.itemIDs.isEmpty == true,
    "Deleting a parent media index should cascade-remove descendants from manual collections"
)

let wildcardLocalSourcePath = "/Volumes/Media/Wildcard"
let wildcardLocalItem = MediaItem(
    id: "wildcard-local-item",
    type: .movie,
    title: "Wildcard Local",
    sourcePath: wildcardLocalSourcePath,
    filePath: "/Volumes/Media/Wildcard/Season_1/movie.mkv"
)
let wildcardLocalSibling = MediaItem(
    id: "wildcard-local-sibling",
    type: .movie,
    title: "Wildcard Local Sibling",
    sourcePath: wildcardLocalSourcePath,
    filePath: "/Volumes/Media/Wildcard/SeasonX1/movie.mkv"
)
try mediaRepository.upsert(wildcardLocalItem)
try mediaRepository.upsert(wildcardLocalSibling)
try mediaRepository.deleteItems(filePathPrefix: "/Volumes/Media/Wildcard/Season_1", sourcePath: wildcardLocalSourcePath)
let wildcardLocalItemsAfterDelete = try mediaRepository.fetchAll()
check(
    !wildcardLocalItemsAfterDelete.contains { $0.id == wildcardLocalItem.id },
    "Directory prefix cleanup should remove the requested underscore directory"
)
check(
    wildcardLocalItemsAfterDelete.contains { $0.id == wildcardLocalSibling.id },
    "Directory prefix cleanup should treat underscore as a literal path character"
)
let localSourceDeleteRoot = "/Volumes/Media/Delete_Source"
let localSourceRootItem = MediaItem(
    id: "local-source-root-delete",
    type: .movie,
    title: "Local Source Root Delete",
    sourcePath: localSourceDeleteRoot,
    filePath: "\(localSourceDeleteRoot)/movie.mkv"
)
let localSourceChildItem = MediaItem(
    id: "local-source-child-delete",
    type: .movie,
    title: "Local Source Child Delete",
    sourcePath: "\(localSourceDeleteRoot)/Nested",
    filePath: "\(localSourceDeleteRoot)/Nested/movie.mkv"
)
let localSourceSiblingItem = MediaItem(
    id: "local-source-sibling-keep",
    type: .movie,
    title: "Local Source Sibling Keep",
    sourcePath: "/Volumes/Media/DeleteXSource",
    filePath: "/Volumes/Media/DeleteXSource/movie.mkv"
)
try mediaRepository.upsert(localSourceRootItem)
try mediaRepository.upsert(localSourceChildItem)
try mediaRepository.upsert(localSourceSiblingItem)
try mediaRepository.deleteItems(sourcePathPrefix: localSourceDeleteRoot)
let localSourceItemsAfterDelete = try mediaRepository.fetchAll()
check(
    !localSourceItemsAfterDelete.contains { $0.id == localSourceRootItem.id || $0.id == localSourceChildItem.id },
    "Source prefix cleanup should remove root and child source path indexes"
)
check(
    localSourceItemsAfterDelete.contains { $0.id == localSourceSiblingItem.id },
    "Source prefix cleanup should keep sibling source paths outside the slash boundary"
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
let siblingRemoteItem = MediaItem(
    id: "remote-item-sibling",
    type: .movie,
    title: "Sibling Remote",
    sourcePath: "\(remoteSourcePath)2",
    filePath: "https://emby.example/Videos/sibling/stream",
    externalID: "sibling",
    metadataProvider: "Emby"
)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [remoteItemA, remoteItemB])
try mediaRepository.upsert(siblingRemoteItem)
var refreshedRemoteA = remoteItemA
refreshedRemoteA.playPosition = 100
refreshedRemoteA.playProgress = 1
refreshedRemoteA.watched = true
refreshedRemoteA.favorite = false
try mediaRepository.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [refreshedRemoteA])
let remoteItemsAfterScopedRefresh = try mediaRepository.fetchAll()
let refreshedRemoteItems = remoteItemsAfterScopedRefresh.filter { $0.sourcePath == remoteSourcePath }
check(refreshedRemoteItems.count == 1, "Remote replacement should remove server items no longer returned")
check(refreshedRemoteItems.first?.watched == true, "Remote replacement should refresh watched state from server")
check(refreshedRemoteItems.first?.favorite == false, "Remote replacement should refresh favorite state from server")
check(refreshedRemoteItems.first?.playPosition == 100, "Remote replacement should refresh playback position from server")
check(
    remoteItemsAfterScopedRefresh.contains(where: { $0.id == siblingRemoteItem.id && $0.sourcePath == siblingRemoteItem.sourcePath }),
    "Remote replacement should not delete sibling source paths that merely share a text prefix"
)
try mediaRepository.setWatchlist(id: refreshedRemoteA.id, watchlist: true)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: "\(remoteSourcePath)/", with: [refreshedRemoteA])
let remoteItemsAfterWatchlistRefresh = try mediaRepository.fetchAll()
check(
    remoteItemsAfterWatchlistRefresh.first(where: { $0.id == refreshedRemoteA.id })?.watchlist == true,
    "Remote refresh should preserve local watchlist state"
)
check(
    remoteItemsAfterWatchlistRefresh.contains(where: { $0.id == siblingRemoteItem.id && $0.sourcePath == siblingRemoteItem.sourcePath }),
    "Remote replacement should tolerate a trailing slash without widening to sibling sources"
)
let wildcardRemoteSourcePath = "emby://example/remote_source"
let wildcardRemoteItem = MediaItem(
    id: "wildcard-remote-item",
    type: .movie,
    title: "Wildcard Remote",
    sourcePath: "\(wildcardRemoteSourcePath)/library",
    filePath: "https://emby.example/Videos/wildcard/stream",
    externalID: "wildcard",
    metadataProvider: "Emby"
)
let wildcardRemoteSibling = MediaItem(
    id: "wildcard-remote-sibling",
    type: .movie,
    title: "Wildcard Remote Sibling",
    sourcePath: "emby://example/remoteXsource/library",
    filePath: "https://emby.example/Videos/wildcard-sibling/stream",
    externalID: "wildcard-sibling",
    metadataProvider: "Emby"
)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: wildcardRemoteSourcePath, with: [wildcardRemoteItem])
try mediaRepository.upsert(wildcardRemoteSibling)
try mediaRepository.replaceRemoteItems(sourcePathPrefix: wildcardRemoteSourcePath, with: [wildcardRemoteItem])
let wildcardRemoteItemsAfterRefresh = try mediaRepository.fetchAll()
check(
    wildcardRemoteItemsAfterRefresh.contains { $0.id == wildcardRemoteItem.id },
    "Remote replacement should keep items under the underscore source"
)
check(
    wildcardRemoteItemsAfterRefresh.contains { $0.id == wildcardRemoteSibling.id },
    "Remote replacement should treat underscore as a literal source path character"
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
let manualCollectionsAfterDatabaseRestore = try videoManualCollectionRepository.fetchAll()
check(
    manualCollectionsAfterDatabaseRestore.first(where: { $0.id == manualCollection.id })?.itemIDs == [show.id, collectionOnlyMovie.id],
    "Database restore should recover video manual collections and item order"
)
let markersAfterDatabaseRestore = try playbackMarkerRepository.fetch(mediaID: episode.id)
check(markersAfterDatabaseRestore.count == 2, "Database restore should recover playback markers")
try mediaRepository.deleteItems(ids: [collectionOnlyMovie.id])
let manualCollectionAfterMediaDelete = try videoManualCollectionRepository.fetch(id: manualCollection.id)
check(
    manualCollectionAfterMediaDelete?.itemIDs == [show.id],
    "Deleting a media index should cascade-remove it from video manual collections"
)
try videoSmartCollectionRepository.delete(id: smartCollection.id)
let smartCollectionsAfterDelete = try videoSmartCollectionRepository.fetchAll()
check(smartCollectionsAfterDelete.allSatisfy { $0.id != smartCollection.id }, "Video smart collection should be deletable")
try videoManualCollectionRepository.delete(id: manualCollection.id)
let manualCollectionsAfterDelete = try videoManualCollectionRepository.fetchAll()
check(manualCollectionsAfterDelete.allSatisfy { $0.id != manualCollection.id }, "Video manual collection should be deletable")

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

let subtitleURL = seasonDirectory.appendingPathComponent("S01E03 - Long Long Time.zh-Hans.srt")
try Data("1\n00:00:01,000 --> 00:00:02,000\nHello".utf8).write(to: subtitleURL)
let sidecarChangeSummary = await scanner.scanChanges(
    source: scanSource,
    changedPaths: [subtitleURL.path],
    settings: AppSettings(enableThumbnailFallback: false)
) { _ in }
check(sidecarChangeSummary.importedItems > 0, "Incremental sidecar changes should refresh nearby media files")
let episodesAfterSidecarChange = try scanRepository.fetchChildren(parentID: scannedShows.first?.id ?? "")
check(episodesAfterSidecarChange.count == 3, "Incremental sidecar changes should not import subtitle files as episodes")

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

let dottedDirectory = scanRoot
    .appendingPathComponent("TV Shows", isDirectory: true)
    .appendingPathComponent("Arcane.S01", isDirectory: true)
try FileManager.default.createDirectory(at: dottedDirectory, withIntermediateDirectories: true)
try Data("fake-dotted-video".utf8).write(to: dottedDirectory.appendingPathComponent("Arcane.S01E01.mkv"))
let dottedScanSummary = await scanner.scan(source: scanSource, settings: AppSettings(enableThumbnailFallback: false)) { _ in }
check(dottedScanSummary.importedItems == 1, "Scanner should import an episode from a dotted directory")
let dottedShows = try scanRepository.fetchTopLevel(type: .tvShow)
check(dottedShows.count == 1, "Dotted directory scan should create one show")
try FileManager.default.removeItem(at: dottedDirectory)
_ = await scanner.scanChanges(
    source: scanSource,
    changedPaths: [dottedDirectory.path],
    settings: AppSettings(enableThumbnailFallback: false)
) { _ in }
let itemsAfterDottedDirectoryDelete = try scanRepository.fetchAll()
check(itemsAfterDottedDirectoryDelete.isEmpty, "Incremental directory delete should clean dotted folder paths")

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
