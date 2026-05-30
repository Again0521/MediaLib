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

let source = MediaSource(name: "测试媒体源", path: "/Volumes/Media", mediaType: .auto)
try sourceRepository.save(source)
let sources = try sourceRepository.fetchAll()
check(sources.count == 1, "Source should be saved")
check(sources.first?.path == "/Volumes/Media", "Source path should round-trip")

let showID = StableID.make(prefix: "show", value: "Breaking Bad")
let show = MediaItem(id: showID, type: .tvShow, title: "Breaking Bad", sourcePath: source.path)
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
try mediaRepository.upsert(show)
try mediaRepository.upsert(episode)
let shows = try mediaRepository.fetchTopLevel(type: .tvShow)
let episodes = try mediaRepository.fetchChildren(parentID: showID)
check(shows.count == 1, "Show should be fetched")
check(episodes.first?.episodeNumber == 1, "Episode should be linked")

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
