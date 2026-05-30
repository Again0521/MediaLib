import AppKit
import Foundation
import MediaLibCore
import SwiftUI

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

struct HomeStatsSnapshot {
    var movieCount: Int = 0
    var seriesCount: Int = 0
    var episodeCount: Int = 0
    var unwatchedCount: Int = 0
    var favoriteCount: Int = 0
    var watchedMovieCount: Int = 0
    var watchedEpisodeCount: Int = 0
    var totalWatchedMinutes: Int = 0
}

private final class ScanProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublishDate = Date.distantPast
    private var lastProcessedFiles = -1

    func reset() {
        lock.lock()
        lastPublishDate = .distantPast
        lastProcessedFiles = -1
        lock.unlock()
    }

    func shouldPublish(_ progress: ScanProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let isTerminal = progress.status != "running" ||
            progress.errorMessage != nil ||
            progress.processedFiles >= progress.totalFiles
        let isFirst = lastProcessedFiles < 0 || progress.processedFiles == 0
        let step = max(8, max(progress.totalFiles, 1) / 220)
        let advancedEnough = progress.processedFiles - lastProcessedFiles >= step
        let now = Date()
        let waitedEnough = now.timeIntervalSince(lastPublishDate) >= 0.18

        guard isTerminal || isFirst || advancedEnough || waitedEnough else {
            return false
        }

        lastPublishDate = now
        lastProcessedFiles = progress.processedFiles
        return true
    }
}

enum MusicRepeatMode: String, CaseIterable, Identifiable {
    case sequential
    case repeatAll
    case repeatOne

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sequential: return "顺序播放"
        case .repeatAll: return "队列循环"
        case .repeatOne: return "单曲循环"
        }
    }

    var systemImage: String {
        switch self {
        case .sequential: return "arrow.right"
        case .repeatAll: return "repeat"
        case .repeatOne: return "repeat.1"
        }
    }

    var next: MusicRepeatMode {
        switch self {
        case .sequential: return .repeatAll
        case .repeatAll: return .repeatOne
        case .repeatOne: return .sequential
        }
    }
}

enum PlaybackCommand {
    case play
    case pause
    case togglePlay
    case previous
    case next
    case seekBackward
    case seekForward
    case toggleShuffle
    case cycleRepeat
}

struct PlaybackCommandRequest: Identifiable, Equatable {
    let id = UUID()
    let command: PlaybackCommand
}

struct MusicTagApplyReport: Sendable, Hashable {
    var itemID: String
    var didUpdateLibrary: Bool
    var didWriteFile: Bool
    var warning: String?
}

private struct LRCLibLyricsSearchResult: Decodable {
    var plainLyrics: String?
    var syncedLyrics: String?
}

@MainActor
final class AppState: ObservableObject {
    @Published var sources: [MediaSource] = []
    @Published var items: [MediaItem] = []
    @Published var settings: AppSettings
    @Published var selectedItem: MediaItem?
    @Published var activePlayerItem: MediaItem?
    @Published var quickPreviewItem: MediaItem?
    @Published var scanProgress: ScanProgress?
    @Published var isScanning = false
    @Published var scanQueueCount = 0
    @Published var alert: AppAlert?
    @Published var startupError: String?
    @Published var privacyUnlocked = false
    @Published var privacyPINConfigured = false
    @Published var musicQueue: [MediaItem] = []
    @Published var musicRepeatMode: MusicRepeatMode = .sequential
    @Published var musicShuffleEnabled = false
    @Published var musicPlaylists: [MusicPlaylist] = []
    @Published var playbackCommandRequest: PlaybackCommandRequest?
    @Published var isFetchingMusicMetadata = false
    @Published var musicMetadataFetchProgress = ""
    @Published private(set) var libraryRevision = 0
    @Published private(set) var favoriteRevision = 0

    let directories: AppDirectories?
    private let database: DatabaseManager?
    private let sourceRepository: SourceRepository?
    private let mediaRepository: MediaRepository?
    private let musicPlaylistRepository: MusicPlaylistRepository?
    private let settingsStore = AppSettingsStore()
    private let logger: LoggingService?
    private let externalPlayerService = ExternalPlayerService()
    private let privacyLockService = PrivacyLockService()
    private let remoteCredentialStore = RemoteCredentialStore()
    private let embyService = EmbyService()
    private var scanTask: Task<Void, Never>?
    private var automaticScanTask: Task<Void, Never>?
    private var configuredAutomaticScanInterval: AutomaticScanInterval?
    private var pendingScanSources: [MediaSource] = []
    private var activeScanSourceID: String?
    private var scanRunID = UUID()
    private var cachedTopLevelItems: [MediaItem] = []
    private var cachedPrivateTopLevelItems: [MediaItem] = []
    private var cachedMusicTracks: [MediaItem] = []
    private var cachedMusicTracksByID: [String: MediaItem] = [:]
    private var cachedEmbyTopLevelItems: [MediaItem] = []
    private var cachedEmbyLibrarySummaries: [EmbyLibrarySummary] = []
    private var cachedChildrenByParentID: [String: [MediaItem]] = [:]
    private var cachedPrivateItemIDs: Set<String> = []
    private var cachedNextUpItems: [MediaItem] = []
    private var cachedContinueWatchingItems: [MediaItem] = []
    private var cachedMissingFileItems: [MediaItem] = []
    private var cachedDuplicateTitleGroups: [[MediaItem]] = []
    private var cachedVisibleVideoSections: [VideoLibrarySection] = []
    private var cachedAvailableHomeTabs: Set<HomeTab> = [.overview]
    private var cachedOfflineSources: [MediaSource] = []
    private var cachedOfflineSourceIDs: Set<String> = []
    private var cachedHomeStats = HomeStatsSnapshot()
    private var fileHealthTask: Task<Void, Never>?
    private var fileHealthRefreshID = UUID()

    init() {
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.privacyPINConfigured = loadedSettings.privacyPINEnabled && privacyLockService.hasPIN()

        do {
            let directories = try FileAccessService.appDirectories()
            let logger = LoggingService(logDirectory: directories.logs)
            let database = try DatabaseManager(url: directories.database)
            self.directories = directories
            self.logger = logger
            self.database = database
            self.sourceRepository = SourceRepository(database: database)
            self.mediaRepository = MediaRepository(database: database)
            self.musicPlaylistRepository = MusicPlaylistRepository(database: database)
            reload()
            configureAutomaticScan()
        } catch {
            self.directories = nil
            self.logger = nil
            self.database = nil
            self.sourceRepository = nil
            self.mediaRepository = nil
            self.musicPlaylistRepository = nil
            self.startupError = error.localizedDescription
        }
    }

    var topLevelItems: [MediaItem] {
        cachedTopLevelItems
    }

    var privateTopLevelItems: [MediaItem] {
        cachedPrivateTopLevelItems
    }

    var continueWatchingItems: [MediaItem] {
        cachedContinueWatchingItems
    }

    var visibleVideoSections: [VideoLibrarySection] {
        cachedVisibleVideoSections
    }

    var availableHomeTabs: Set<HomeTab> {
        cachedAvailableHomeTabs
    }

    var homeStats: HomeStatsSnapshot {
        cachedHomeStats
    }

    var nextUpItems: [MediaItem] {
        cachedNextUpItems
    }

    var missingFileItems: [MediaItem] {
        cachedMissingFileItems
    }

    var offlineSources: [MediaSource] {
        cachedOfflineSources
    }

    var duplicateTitleGroups: [[MediaItem]] {
        cachedDuplicateTitleGroups
    }

    var availableExternalPlayers: [ExternalPlayer] {
        externalPlayerService.availablePlayers(customPath: settings.videoExternalPlayerPath ?? settings.musicExternalPlayerPath)
    }

    var musicTracks: [MediaItem] {
        cachedMusicTracks
    }

    var embySources: [MediaSource] {
        sources.filter { $0.sourceKind == .emby }
    }

    var embyLibraries: [EmbyLibrarySummary] {
        cachedEmbyLibrarySummaries
    }

    var hasEmbyItems: Bool {
        !cachedEmbyTopLevelItems.isEmpty
    }

    func hasEmbyItems(for section: EmbyLibrarySection) -> Bool {
        !embyItems(for: section).isEmpty
    }

    func items(for destination: SidebarDestination, searchText: String = "") -> [MediaItem] {
        let base: [MediaItem]
        switch destination {
        case .home, .sources, .settings:
            base = topLevelItems
        case .video(.movies):
            base = topLevelItems.filter { $0.type == .movie }
        case .video(.tvShows):
            base = topLevelItems.filter { $0.type == .tvShow }
        case .video(.anime):
            base = topLevelItems.filter { $0.type == .anime }
        case .video(.documentaries):
            base = topLevelItems.filter { $0.type == .documentary }
        case .video(.variety):
            base = topLevelItems.filter { $0.type == .variety }
        case .video(.other):
            base = topLevelItems.filter { $0.type == .other }
        case .video(.privacy):
            base = privacyPINConfigured && privacyUnlocked ? privateTopLevelItems : []
        case .video(.watching):
            base = items
                .filter { $0.type != .music && $0.hasPlaybackTrace && !isPrivateItem($0) && !Self.isEmbyItem($0) }
                .sorted { ($0.lastPlayedAt ?? $0.updatedAt) > ($1.lastPlayedAt ?? $1.updatedAt) }
        case .video(.favorites):
            base = topLevelItems.filter { $0.type != .music && $0.favorite }
        case .video(.unwatched):
            base = topLevelItems.filter { $0.type != .music && !$0.watched && $0.playProgress < 0.9 }
        case .video(.watched):
            base = topLevelItems.filter { $0.type != .music && ($0.watched || $0.playProgress >= 0.9) }
        case .music(let section):
            base = musicItems(for: section)
        case .emby(let section):
            base = embyItems(for: section)
        case .embyLibrary(let libraryID):
            base = embyItems(forLibraryID: libraryID)
        }

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base.filter {
            $0.title.localizedCaseInsensitiveContains(searchText) ||
            ($0.originalTitle?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.artist?.localizedCaseInsensitiveContains(searchText) ?? false) ||
            ($0.album?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    func musicItems(for section: MusicLibrarySection) -> [MediaItem] {
        switch section {
        case .songs, .albums, .artists:
            return musicTracks
        case .playlists:
            return []
        case .recent:
            return musicTracks.filter { $0.lastPlayedAt != nil }.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .favorites:
            return musicTracks.filter(\.favorite)
        case .unmatched:
            return musicTracks.filter { ($0.artist?.isEmpty ?? true) || ($0.album?.isEmpty ?? true) || $0.metadataProvider == nil }
        }
    }

    func musicTracks(in playlist: MusicPlaylist) -> [MediaItem] {
        playlist.itemIDs.compactMap { cachedMusicTracksByID[$0] }
    }

    @discardableResult
    func createMusicPlaylist(name: String, tracks: [MediaItem] = []) -> MusicPlaylist? {
        guard let musicPlaylistRepository else { return nil }
        do {
            let playlist = try musicPlaylistRepository.create(
                name: name,
                itemIDs: uniqueMusicTracks(tracks).map(\.id)
            )
            upsertMusicPlaylistInMemory(playlist)
            return playlist
        } catch {
            showError("创建歌单失败", error)
            return nil
        }
    }

    func addMusicTracks(_ tracks: [MediaItem], to playlist: MusicPlaylist) {
        guard let musicPlaylistRepository else { return }
        do {
            guard let updated = try musicPlaylistRepository.add(
                itemIDs: uniqueMusicTracks(tracks).map(\.id),
                toPlaylistID: playlist.id
            ) else { return }
            upsertMusicPlaylistInMemory(updated)
        } catch {
            showError("添加到歌单失败", error)
        }
    }

    func renameMusicPlaylist(_ playlist: MusicPlaylist, name: String) {
        guard let musicPlaylistRepository else { return }
        do {
            guard let updated = try musicPlaylistRepository.rename(id: playlist.id, name: name) else { return }
            upsertMusicPlaylistInMemory(updated)
        } catch {
            showError("重命名歌单失败", error)
        }
    }

    func deleteMusicPlaylist(_ playlist: MusicPlaylist) {
        guard let musicPlaylistRepository else { return }
        do {
            try musicPlaylistRepository.delete(id: playlist.id)
            musicPlaylists.removeAll { $0.id == playlist.id }
        } catch {
            showError("删除歌单失败", error)
        }
    }

    func removeMusicTracks(_ tracks: [MediaItem], from playlist: MusicPlaylist) {
        guard let musicPlaylistRepository else { return }
        do {
            guard let updated = try musicPlaylistRepository.remove(
                itemIDs: uniqueMusicTracks(tracks).map(\.id),
                fromPlaylistID: playlist.id
            ) else { return }
            upsertMusicPlaylistInMemory(updated)
        } catch {
            showError("移出歌单失败", error)
        }
    }

    func moveMusicPlaylistItems(in playlist: MusicPlaylist, fromOffsets: IndexSet, toOffset: Int) {
        guard let musicPlaylistRepository,
              let current = musicPlaylists.first(where: { $0.id == playlist.id }) else { return }
        var itemIDs = current.itemIDs
        itemIDs.move(fromOffsets: fromOffsets, toOffset: toOffset)
        do {
            guard let updated = try musicPlaylistRepository.replaceItems(itemIDs, inPlaylistID: playlist.id) else { return }
            upsertMusicPlaylistInMemory(updated)
        } catch {
            showError("调整歌单顺序失败", error)
        }
    }

    func replaceMusicPlaylistItems(in playlist: MusicPlaylist, with tracks: [MediaItem]) {
        guard let musicPlaylistRepository else { return }
        do {
            guard let updated = try musicPlaylistRepository.replaceItems(
                uniqueMusicTracks(tracks).map(\.id),
                inPlaylistID: playlist.id
            ) else { return }
            upsertMusicPlaylistInMemory(updated)
        } catch {
            showError("保存歌单顺序失败", error)
        }
    }

    private func upsertMusicPlaylistInMemory(_ playlist: MusicPlaylist) {
        if let index = musicPlaylists.firstIndex(where: { $0.id == playlist.id }) {
            musicPlaylists[index] = playlist
        } else {
            musicPlaylists.insert(playlist, at: 0)
        }
        musicPlaylists.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    func embyItems(for section: EmbyLibrarySection) -> [MediaItem] {
        switch section {
        case .videos:
            return cachedEmbyTopLevelItems.filter { $0.type != .music }
        case .music:
            return cachedEmbyTopLevelItems.filter { $0.type == .music }
        case .recent:
            return cachedEmbyTopLevelItems
                .filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .favorites:
            return cachedEmbyTopLevelItems.filter(\.favorite)
        }
    }

    func embyItems(forLibraryID libraryID: String) -> [MediaItem] {
        cachedEmbyTopLevelItems.filter { item in
            guard let sourcePath = item.sourcePath,
                  let library = EmbyService.libraryInfo(from: sourcePath) else { return false }
            return library.id == libraryID
        }
    }

    func embyLibraryTitle(_ libraryID: String) -> String {
        cachedEmbyLibrarySummaries.first { $0.id == libraryID }?.displayName ?? "EMBY 分类"
    }

    func children(for item: MediaItem) -> [MediaItem] {
        cachedChildrenByParentID[item.id] ?? []
    }

    private func duplicateKey(for item: MediaItem) -> String {
        let normalizedTitle = item.title
            .lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
        return "\(item.type.rawValue)-\(normalizedTitle)-\(item.year.map(String.init) ?? "unknown")"
    }

    func isPrivateItem(_ item: MediaItem) -> Bool {
        cachedPrivateItemIDs.contains(item.id)
    }

    private static func isEmbyItem(_ item: MediaItem) -> Bool {
        item.sourcePath?.hasPrefix("emby://") == true
    }

    func reload() {
        do {
            let reloadStart = Date()
            ArtworkImageCache.invalidateMissingPaths()
            let fetchStart = Date()
            sources = try sourceRepository?.fetchAll() ?? []
            items = try mediaRepository?.fetchAll() ?? []
            musicPlaylists = try musicPlaylistRepository?.fetchAll() ?? []
            logPerformance("reload.fetch repositories: \(Self.milliseconds(since: fetchStart))ms items=\(items.count) sources=\(sources.count) playlists=\(musicPlaylists.count)")
            let cacheStart = Date()
            rebuildDerivedItemCaches()
            logPerformance("reload.rebuildDerivedItemCaches: \(Self.milliseconds(since: cacheStart))ms")
            if let selectedItem, let refreshed = items.first(where: { $0.id == selectedItem.id }) {
                self.selectedItem = refreshed
            }
            let healthStart = Date()
            scheduleFileHealthRefresh()
            logPerformance("reload.scheduleFileHealthRefresh: \(Self.milliseconds(since: healthStart))ms")
            libraryRevision += 1
            logPerformance("reload.total: \(Self.milliseconds(since: reloadStart))ms revision=\(libraryRevision)")
        } catch {
            showError("加载媒体库失败", error)
        }
    }

    private func rebuildDerivedItemCaches() {
        cachedChildrenByParentID = Dictionary(grouping: items.filter { $0.parentID != nil }) { $0.parentID ?? "" }
            .mapValues { children in
                children.sorted {
                    if ($0.seasonNumber ?? 0) != ($1.seasonNumber ?? 0) {
                        return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
                    }
                    if ($0.episodeNumber ?? 0) != ($1.episodeNumber ?? 0) {
                        return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
                    }
                    return $0.title.localizedStandardCompare($1.title) == .orderedAscending
                }
            }

        let privateCollectionIDs = Set(items.filter { $0.type == .privateCollection }.map(\.id))
        cachedPrivateItemIDs = Set(items.compactMap { item in
            if item.type == .privateCollection {
                return item.id
            }
            if let parentID = item.parentID, privateCollectionIDs.contains(parentID) {
                return item.id
            }
            return nil
        })

        cachedTopLevelItems = items
            .filter {
                $0.parentID == nil &&
                $0.sourcePath?.hasPrefix("emby://") != true &&
                !cachedPrivateItemIDs.contains($0.id)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        cachedPrivateTopLevelItems = items
            .filter { $0.parentID == nil && $0.type == .privateCollection }
            .sorted { $0.updatedAt > $1.updatedAt }

        cachedMusicTracks = items
            .filter {
                $0.type == .music &&
                $0.parentID == nil &&
                $0.sourcePath?.hasPrefix("emby://") != true &&
                !cachedPrivateItemIDs.contains($0.id)
            }
            .sorted { lhs, rhs in
                let leftAlbum = lhs.album ?? ""
                let rightAlbum = rhs.album ?? ""
                if leftAlbum != rightAlbum {
                    return leftAlbum.localizedStandardCompare(rightAlbum) == .orderedAscending
                }
                if (lhs.trackNumber ?? 0) != (rhs.trackNumber ?? 0) {
                    return (lhs.trackNumber ?? 0) < (rhs.trackNumber ?? 0)
                }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })

        cachedEmbyTopLevelItems = items
            .filter {
                $0.parentID == nil &&
                $0.sourcePath?.hasPrefix("emby://") == true &&
                !cachedPrivateItemIDs.contains($0.id)
            }
            .sorted { $0.updatedAt > $1.updatedAt }

        var embyLibraryByID: [String: EmbyLibrarySummary] = [:]
        for item in cachedEmbyTopLevelItems {
            guard let sourcePath = item.sourcePath,
                  let info = EmbyService.libraryInfo(from: sourcePath) else { continue }
            let rootPath = EmbyService.sourceRootPath(from: sourcePath) ?? sourcePath
            let source = sources.first { $0.path == rootPath || sourcePath.hasPrefix($0.path) }
            embyLibraryByID[info.id] = EmbyLibrarySummary(
                id: info.id,
                sourceID: source?.id ?? "",
                viewID: info.id,
                name: info.name ?? "EMBY 分类",
                collectionType: info.collectionType,
                sourceName: source?.name ?? "EMBY"
            )
        }
        cachedEmbyLibrarySummaries = embyLibraryByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        cachedContinueWatchingItems = items
            .filter {
                $0.filePath != nil &&
                $0.playProgress > 0 &&
                $0.playProgress < 0.95 &&
                !cachedPrivateItemIDs.contains($0.id) &&
                !Self.isEmbyItem($0)
            }
            .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }

        cachedNextUpItems = Array(cachedTopLevelItems.compactMap { item -> MediaItem? in
            guard let episodes = cachedChildrenByParentID[item.id], !episodes.isEmpty else { return nil }
            return episodes.first { !$0.watched && $0.playProgress < settings.watchedThreshold }
        }.prefix(12))

        let duplicateGroups = Dictionary(grouping: cachedTopLevelItems) { duplicateKey(for: $0) }
        cachedDuplicateTitleGroups = duplicateGroups.values
            .filter { $0.count > 1 }
            .sorted { $0[0].title.localizedStandardCompare($1[0].title) == .orderedAscending }

        let videoTopLevelItems = cachedTopLevelItems.filter { $0.type != .music }
        let watchedVideoTopLevel = videoTopLevelItems.filter { $0.watched || $0.playProgress >= 0.9 }
        let watchedEpisodeCount = items.reduce(0) { count, item in
            count + (item.parentID != nil && !cachedPrivateItemIDs.contains(item.id) && !Self.isEmbyItem(item) && (item.watched || item.playProgress >= 0.9) ? 1 : 0)
        }
        let totalWatchedMinutes = watchedVideoTopLevel.reduce(0) { total, item in
            total + (item.runtime ?? Int((item.duration ?? 0) / 60))
        }
        cachedHomeStats = HomeStatsSnapshot(
            movieCount: cachedTopLevelItems.filter { $0.type == .movie }.count,
            seriesCount: cachedTopLevelItems.filter { $0.type != .movie && $0.type != .music }.count,
            episodeCount: items.reduce(0) { count, item in
                count + ((item.parentID != nil && !cachedPrivateItemIDs.contains(item.id) && !Self.isEmbyItem(item)) ? 1 : 0)
            },
            unwatchedCount: cachedTopLevelItems.filter { !$0.watched && $0.playProgress < 0.9 }.count,
            favoriteCount: cachedTopLevelItems.filter(\.favorite).count,
            watchedMovieCount: watchedVideoTopLevel.filter { $0.type == .movie }.count,
            watchedEpisodeCount: watchedEpisodeCount,
            totalWatchedMinutes: totalWatchedMinutes
        )

        cachedAvailableHomeTabs = Set(HomeTab.allCases.filter { tab in
            switch tab {
            case .overview:
                return true
            case .nextUp:
                return !cachedNextUpItems.isEmpty
            case .continueWatching:
                return !cachedContinueWatchingItems.isEmpty
            case .recent:
                return !cachedTopLevelItems.isEmpty
            case .movies:
                return videoTopLevelItems.contains { $0.type == .movie }
            case .tvShows:
                return videoTopLevelItems.contains { $0.type == .tvShow }
            case .anime:
                return videoTopLevelItems.contains { $0.type == .anime }
            case .documentaries:
                return videoTopLevelItems.contains { $0.type == .documentary }
            case .variety:
                return videoTopLevelItems.contains { $0.type == .variety }
            case .music:
                return !cachedMusicTracks.isEmpty
            case .other:
                return videoTopLevelItems.contains { $0.type == .other }
            case .favorites:
                return videoTopLevelItems.contains { $0.favorite }
            case .unwatched:
                return videoTopLevelItems.contains { !$0.watched && $0.playProgress < 0.9 }
            case .privacy:
                return !cachedPrivateTopLevelItems.isEmpty
            }
        })

        cachedVisibleVideoSections = VideoLibrarySection.allCases.filter { section in
            switch section {
            case .movies:
                return videoTopLevelItems.contains { $0.type == .movie }
            case .tvShows:
                return videoTopLevelItems.contains { $0.type == .tvShow }
            case .anime:
                return videoTopLevelItems.contains { $0.type == .anime }
            case .documentaries:
                return videoTopLevelItems.contains { $0.type == .documentary }
            case .variety:
                return videoTopLevelItems.contains { $0.type == .variety }
            case .other:
                return videoTopLevelItems.contains { $0.type == .other }
            case .privacy:
                return true
            case .watching:
                return items.contains { $0.type != .music && $0.hasPlaybackTrace && !isPrivateItem($0) && !Self.isEmbyItem($0) }
            case .favorites:
                return videoTopLevelItems.contains { $0.favorite }
            case .unwatched:
                return videoTopLevelItems.contains { !$0.watched && $0.playProgress < 0.9 }
            case .watched:
                return videoTopLevelItems.contains { $0.watched || $0.playProgress >= 0.9 }
            }
        }

    }

    private func scheduleFileHealthRefresh() {
        fileHealthTask?.cancel()
        let refreshID = UUID()
        fileHealthRefreshID = refreshID
        cachedMissingFileItems = []
        cachedOfflineSources = []
        cachedOfflineSourceIDs = []

        let itemSnapshots = items
        let sourceSnapshots = sources
        let privateItemIDs = cachedPrivateItemIDs

        fileHealthTask = Task { [itemSnapshots, sourceSnapshots, privateItemIDs, refreshID] in
            let healthStart = Date()
            let health = await Task.detached(priority: .utility) {
                let missingItemIDs = Set(itemSnapshots.compactMap { item -> String? in
                    guard !privateItemIDs.contains(item.id),
                          let filePath = item.filePath,
                          !item.isRemoteResource,
                          !FileManager.default.fileExists(atPath: filePath) else {
                        return nil
                    }
                    return item.id
                })

                let offlineSourceIDs = Set(sourceSnapshots.compactMap { source -> String? in
                    guard source.sourceKind != .emby,
                          !FileManager.default.fileExists(atPath: source.path) else {
                        return nil
                    }
                    return source.id
                })

                return (missingItemIDs: missingItemIDs, offlineSourceIDs: offlineSourceIDs)
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.fileHealthRefreshID == refreshID else { return }
                self.cachedMissingFileItems = itemSnapshots.filter { health.missingItemIDs.contains($0.id) }
                self.cachedOfflineSourceIDs = health.offlineSourceIDs
                self.cachedOfflineSources = sourceSnapshots.filter { health.offlineSourceIDs.contains($0.id) }
                self.libraryRevision += 1
                self.logPerformance("fileHealth.refresh: \(Self.milliseconds(since: healthStart))ms missing=\(health.missingItemIDs.count) offlineSources=\(health.offlineSourceIDs.count) revision=\(self.libraryRevision)")
            }
        }
    }

    func sourceIsReachable(_ source: MediaSource) -> Bool {
        if source.sourceKind == .emby {
            return true
        }
        guard cachedOfflineSourceIDs.contains(source.id) else {
            return true
        }
        return FileAccessService.isReachableDirectory(source.path)
    }

    func addSource(url: URL, mediaType: MediaType = .auto) {
        guard let sourceRepository else { return }
        guard !sources.contains(where: { $0.path == url.path }) else {
            alert = AppAlert(title: "媒体源已存在", message: "目录「\(url.lastPathComponent)」已添加为媒体源。")
            return
        }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let source = MediaSource(
            name: name,
            path: url.path,
            mediaType: mediaType,
            minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024
        )
        do {
            try sourceRepository.save(source)
            reload()
            scan(source)
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    func addSources(urls: [URL], mediaType: MediaType = .auto) {
        guard let sourceRepository else { return }
        let existingPaths = Set(sources.map(\.path))
        let newURLs = urls.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else {
            if urls.count == 1 {
                alert = AppAlert(title: "媒体源已存在", message: "目录「\(urls[0].lastPathComponent)」已添加为媒体源。")
            } else {
                alert = AppAlert(title: "媒体源已存在", message: "所选目录均已添加为媒体源。")
            }
            return
        }
        var savedSources: [MediaSource] = []
        do {
            for url in newURLs {
                let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
                let source = MediaSource(
                    name: name,
                    path: url.path,
                    mediaType: mediaType,
                    minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024
                )
                try sourceRepository.save(source)
                savedSources.append(source)
            }
            reload()
            startScanQueue(savedSources)
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    func connectEmbyServer(server: String, username: String, password: String) async {
        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else {
            alert = AppAlert(title: "Emby 地址无效", message: "请输入 Emby 服务器地址，例如 http://192.168.1.20:8096。")
            return
        }
        let normalizedServer = trimmedServer.contains("://") ? trimmedServer : "http://\(trimmedServer)"
        guard let components = URLComponents(string: normalizedServer),
              components.host != nil,
              let serverURL = components.url else {
            alert = AppAlert(title: "Emby 地址无效", message: "无法识别这个 Emby 服务器地址。")
            return
        }

        do {
            let session = try await embyService.authenticate(serverURL: serverURL, username: trimmedUsername, password: password)
            let sourceID = UUID().uuidString
            let hostName = session.serverURL.host ?? "Emby"
            let sourcePath = "emby://\(hostName)/\(sourceID)"
            let source = MediaSource(
                id: sourceID,
                name: "EMBY",
                path: sourcePath,
                mediaType: .auto,
                autoScan: false,
                minimumFileSize: 0,
                preferLocalArtwork: false,
                networkScrapingEnabled: false,
                screenshotFallbackEnabled: false
            )
            try sourceRepository?.save(source)
            try remoteCredentialStore.save(
                RemoteSourceCredential(
                    kind: "emby",
                    serverURL: session.serverURL.absoluteString,
                    username: session.username,
                    password: nil,
                    accessToken: session.accessToken,
                    userID: session.userID
                ),
                sourceID: sourceID
            )
            try await importEmbyItems(source: source, session: session)
            reload()
            alert = AppAlert(title: "Emby 已连接", message: "已获取 \(hostName) 的媒体资源，并按 Emby 分类同步到 EMBY 目录。")
        } catch {
            showError("Emby 登录或同步失败", error)
        }
    }

    func addNetworkMountedSource(networkURL: String, mountedDirectory: URL, username: String?, password: String?, mediaType: MediaType) {
        guard let sourceRepository else { return }
        let trimmed = networkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["smb", "ftp", "ftps"].contains(scheme) else {
            alert = AppAlert(title: "网络地址无效", message: "请输入 smb://、ftp:// 或 ftps:// 开头的地址。")
            return
        }

        let sourceID = UUID().uuidString
        let name = "\(scheme.uppercased()) \(url.host ?? mountedDirectory.lastPathComponent)"
        let source = MediaSource(
            id: sourceID,
            name: name,
            path: mountedDirectory.path,
            mediaType: mediaType,
            minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024
        )
        do {
            try sourceRepository.save(source)
            try remoteCredentialStore.save(
                RemoteSourceCredential(
                    kind: scheme,
                    serverURL: sanitizedNetworkURL(trimmed),
                    username: username?.isEmpty == false ? username : nil,
                    password: password?.isEmpty == false ? password : nil,
                    accessToken: nil,
                    userID: nil
                ),
                sourceID: sourceID
            )
            reload()
            scan(source)
        } catch {
            showError("添加网络媒体源失败", error)
        }
    }

    private func refreshEmbySource(_ source: MediaSource) async {
        do {
            guard let credential = try remoteCredentialStore.load(sourceID: source.id),
                  let serverURL = URL(string: credential.serverURL),
                  let accessToken = credential.accessToken,
                  let userID = credential.userID else {
                alert = AppAlert(title: "Emby 需要重新登录", message: "\(source.name) 的登录信息不存在或已失效，请在媒体源中重新添加。")
                return
            }
            let session = EmbySession(
                serverURL: serverURL,
                username: credential.username ?? source.name,
                userID: userID,
                accessToken: accessToken
            )
            try await importEmbyItems(source: source, session: session)
            reload()
        } catch {
            showError("Emby 同步失败", error)
        }
    }

    private func importEmbyItems(source: MediaSource, session: EmbySession) async throws {
        guard let mediaRepository else { return }
        let embyItems = try await embyService.fetchItems(session: session, sourceID: source.id, sourcePath: source.path)
        try mediaRepository.deleteItems(sourcePathPrefix: source.path)
        for item in embyItems {
            try mediaRepository.upsert(item)
        }
    }

    private func sanitizedNetworkURL(_ value: String) -> String {
        guard var components = URLComponents(string: value) else { return value }
        components.user = nil
        components.password = nil
        return components.string ?? value
    }

    func deleteSource(_ source: MediaSource) {
        do {
            if source.sourceKind == .emby {
                try mediaRepository?.deleteItems(sourcePathPrefix: source.path)
            } else {
                try mediaRepository?.deleteItems(sourcePath: source.path)
            }
            try sourceRepository?.delete(id: source.id)
            remoteCredentialStore.delete(sourceID: source.id)
            reload()
        } catch {
            showError("删除媒体源失败", error)
        }
    }

    func updateSource(_ source: MediaSource) {
        do {
            var updated = source
            if updated.mediaType == .music, updated.minimumFileSize > 5 * 1024 * 1024 {
                updated.minimumFileSize = 512 * 1024
            }
            updated.updatedAt = Date()
            try sourceRepository?.save(updated)
            reload()
            restartScanIfNeeded(for: updated)
        } catch {
            showError("媒体源更新失败", error)
        }
    }

    func scanAllSources() {
        let emby = sources.filter { $0.sourceKind == .emby }
        let local = sources.filter { $0.sourceKind != .emby }
        refreshEmbySources(emby)
        startScanQueue(local)
    }

    func scanSources(for destination: SidebarDestination) {
        switch destination {
        case .home, .sources, .settings:
            scanAllSources()
        case .emby, .embyLibrary:
            let emby = sources.filter { $0.sourceKind == .emby }
            guard !emby.isEmpty else {
                alert = AppAlert(title: "无法扫描", message: "当前 EMBY 分类没有可同步的媒体源。")
                return
            }
            refreshEmbySources(emby)
        case .music(.playlists):
            alert = AppAlert(title: "歌单不需要扫描", message: "歌单只记录 MediaLIB 内部索引，可从歌曲右键菜单或播放队列添加歌曲。")
        case .music:
            scanLocalSources(mediaTypes: [.music], emptyMessage: "当前音乐分类没有可扫描的音乐媒体源。")
        case .video(let section):
            scanLocalSources(mediaTypes: mediaTypes(for: section), emptyMessage: "当前分类没有可扫描的媒体源。")
        }
    }

    func scanSources(for homeTab: HomeTab) {
        switch homeTab {
        case .overview:
            scanAllSources()
        case .music:
            scanLocalSources(mediaTypes: [.music], emptyMessage: "当前音乐分类没有可扫描的音乐媒体源。")
        case .movies:
            scanLocalSources(mediaTypes: [.movie], emptyMessage: "当前电影分类没有可扫描的媒体源。")
        case .tvShows, .nextUp:
            scanLocalSources(mediaTypes: [.tvShow], emptyMessage: "当前电视剧分类没有可扫描的媒体源。")
        case .anime:
            scanLocalSources(mediaTypes: [.anime], emptyMessage: "当前动漫分类没有可扫描的媒体源。")
        case .documentaries:
            scanLocalSources(mediaTypes: [.documentary], emptyMessage: "当前纪录片分类没有可扫描的媒体源。")
        case .variety:
            scanLocalSources(mediaTypes: [.variety], emptyMessage: "当前综艺分类没有可扫描的媒体源。")
        case .other:
            scanLocalSources(mediaTypes: [.other], emptyMessage: "当前其他分类没有可扫描的媒体源。")
        case .privacy:
            scanLocalSources(mediaTypes: [.privateCollection], emptyMessage: "当前保险库分类没有可扫描的媒体源。")
        case .continueWatching, .recent, .favorites, .unwatched:
            scanLocalSources(mediaTypes: Self.videoScanTypes, emptyMessage: "当前视频分类没有可扫描的媒体源。")
        }
    }

    func scan(_ source: MediaSource) {
        if source.sourceKind == .emby {
            Task { @MainActor in
                await refreshEmbySource(source)
            }
            return
        }
        startScanQueue([source])
    }

    private static let videoScanTypes: Set<MediaType> = [.movie, .tvShow, .anime, .documentary, .variety, .other]

    private func mediaTypes(for section: VideoLibrarySection) -> Set<MediaType> {
        switch section {
        case .movies:
            return [.movie]
        case .tvShows:
            return [.tvShow]
        case .anime:
            return [.anime]
        case .documentaries:
            return [.documentary]
        case .variety:
            return [.variety]
        case .other:
            return [.other]
        case .privacy:
            return [.privateCollection]
        case .watching, .favorites, .unwatched, .watched:
            return Self.videoScanTypes
        }
    }

    private func scanLocalSources(mediaTypes: Set<MediaType>, emptyMessage: String) {
        let matchingSources = sources.filter { source in
            source.sourceKind != .emby && mediaTypes.contains(source.mediaType)
        }
        guard !matchingSources.isEmpty else {
            alert = AppAlert(title: "无法扫描", message: "\(emptyMessage) 自动识别媒体源请在媒体源页使用“扫描全部”。")
            return
        }
        startScanQueue(matchingSources)
    }

    private func refreshEmbySources(_ embySources: [MediaSource]) {
        guard !embySources.isEmpty else { return }
        Task { @MainActor in
            for source in embySources {
                await refreshEmbySource(source)
            }
        }
    }

    private func startScanQueue(_ sources: [MediaSource], silent: Bool = false) {
        let reachableSources = sources.filter(isSourceCurrentlyReachable)
        guard !reachableSources.isEmpty else {
            if !sources.isEmpty && !silent {
                alert = AppAlert(title: "无法扫描", message: "所选媒体源不可访问，请确认磁盘或 NAS 已挂载。")
            }
            return
        }
        if isScanning {
            pendingScanSources.append(contentsOf: reachableSources)
            scanQueueCount += reachableSources.count
            return
        }
        runScanQueue(reachableSources)
    }

    private func isSourceCurrentlyReachable(_ source: MediaSource) -> Bool {
        source.sourceKind == .emby || FileAccessService.isReachableDirectory(source.path)
    }

    private func runScanQueue(_ sources: [MediaSource]) {
        guard let mediaRepository, let directories else { return }
        scanTask?.cancel()
        let runID = UUID()
        scanRunID = runID
        isScanning = true
        scanQueueCount = sources.count

        scanTask = Task { [settings, logger] in
            var queue = sources
            var allErrors: [String] = []
            let progressThrottler = ScanProgressThrottler()
            while !queue.isEmpty {
                if Task.isCancelled { return }
                let source = queue.removeFirst()
                progressThrottler.reset()
                await MainActor.run {
                    guard self.scanRunID == runID else { return }
                    self.activeScanSourceID = source.id
                    self.scanQueueCount = queue.count + self.pendingScanSources.count + 1
                }
                let scanner = MediaScanner(
                    thumbnailGenerator: ThumbnailGenerator(outputDirectory: directories.thumbnails, logger: logger),
                    mediaRepository: mediaRepository,
                    logger: logger
                )
                let summary = await scanner.scan(source: source, settings: settings) { [weak self] progress in
                    guard progressThrottler.shouldPublish(progress) else { return }
                    Task { @MainActor in
                        guard self?.scanRunID == runID else { return }
                        self?.scanProgress = progress
                    }
                }
                allErrors.append(contentsOf: summary.errors)
                if Task.isCancelled { return }
                let pending = await MainActor.run { () -> [MediaSource] in
                    guard self.scanRunID == runID else { return [] }
                    let pending = self.pendingScanSources
                    self.pendingScanSources.removeAll()
                    return pending
                }
                queue.append(contentsOf: pending)
            }
            await MainActor.run {
                guard self.scanRunID == runID else { return }
                self.activeScanSourceID = nil
                self.isScanning = false
                self.scanQueueCount = 0
                self.reload()
                if let firstError = allErrors.first {
                    self.alert = AppAlert(title: "扫描完成但有错误", message: firstError)
                }
            }
        }
    }

    private func restartScanIfNeeded(for source: MediaSource) {
        guard isScanning else { return }

        scanTask?.cancel()
        scanRunID = UUID()
        pendingScanSources.removeAll { $0.id == source.id }
        activeScanSourceID = nil
        scanProgress = nil
        isScanning = false
        scanQueueCount = 0
        startScanQueue([source])
    }

    func play(_ item: MediaItem, preserveSelection: Bool = false) {
        if item.filePath == nil, let firstEpisode = children(for: item).first {
            play(firstEpisode, preserveSelection: preserveSelection)
            return
        }
        guard item.filePath != nil else {
            alert = AppAlert(title: "无法播放", message: "此媒体没有可播放文件。")
            return
        }
        let playerMode = item.type == .music ? settings.musicDefaultPlayer : settings.videoDefaultPlayer
        if playerMode == .external {
            openExternally(item)
        } else {
            if item.type == .music {
                prepareMusicQueue(for: item)
            }
            presentBuiltInPlayer(item, preserveSelection: preserveSelection)
        }
    }

    func playAdjacent(to item: MediaItem, direction: Int) {
        guard let adjacent = adjacentItem(to: item, direction: direction) else { return }
        play(adjacent, preserveSelection: item.parentID != nil)
    }

    func queueItems(after item: MediaItem, limit: Int = 18) -> [MediaItem] {
        guard item.type == .music else { return [] }
        prepareMusicQueue(for: item)
        guard let index = musicQueue.firstIndex(where: { $0.id == item.id }) else {
            return Array(musicQueue.prefix(limit))
        }
        let suffix = musicQueue.dropFirst(index + 1)
        return Array(suffix.prefix(limit))
    }

    func removeFromMusicQueue(_ item: MediaItem) {
        musicQueue.removeAll { $0.id == item.id }
    }

    func addToMusicQueue(_ item: MediaItem) {
        guard item.type == .music else { return }
        if musicQueue.isEmpty, let active = activePlayerItem, active.type == .music {
            prepareMusicQueue(for: active)
        }
        guard !musicQueue.contains(where: { $0.id == item.id }) else { return }
        musicQueue.append(item)
    }

    func playNextInMusicQueue(_ item: MediaItem) {
        guard item.type == .music else { return }
        let activeMusic = activePlayerItem?.type == .music ? activePlayerItem : nil
        if musicQueue.isEmpty {
            prepareMusicQueue(for: activeMusic ?? item)
        }
        musicQueue.removeAll { $0.id == item.id }
        let insertIndex: Int
        if let activeMusic,
           let activeIndex = musicQueue.firstIndex(where: { $0.id == activeMusic.id }) {
            insertIndex = min(activeIndex + 1, musicQueue.count)
        } else {
            insertIndex = min(1, musicQueue.count)
        }
        musicQueue.insert(item, at: insertIndex)
    }

    func replaceMusicQueueAndPlay(_ tracks: [MediaItem], startingAt requestedStart: MediaItem? = nil) {
        let playableTracks = uniqueMusicTracks(tracks)
        guard !playableTracks.isEmpty else {
            alert = AppAlert(title: "无法播放", message: "这个分组里没有可播放的歌曲。")
            return
        }

        let startItem = requestedStart.flatMap { requested in
            playableTracks.first { $0.id == requested.id }
        } ?? playableTracks.first!

        if let startIndex = playableTracks.firstIndex(where: { $0.id == startItem.id }) {
            musicQueue = Array(playableTracks[startIndex...]) + Array(playableTracks[..<startIndex])
        } else {
            musicQueue = playableTracks
        }

        if settings.musicDefaultPlayer == .external {
            openExternally(startItem)
        } else {
            presentBuiltInPlayer(startItem)
        }
    }

    func clearMusicQueue(keepingCurrent: Bool = true) {
        if keepingCurrent, let active = activePlayerItem, active.type == .music {
            musicQueue = [active]
        } else {
            musicQueue.removeAll()
        }
    }

    func moveMusicQueueItems(fromOffsets: IndexSet, toOffset: Int) {
        musicQueue.move(fromOffsets: fromOffsets, toOffset: toOffset)
    }

    func sendPlaybackCommand(_ command: PlaybackCommand) {
        playbackCommandRequest = PlaybackCommandRequest(command: command)
    }

    func toggleMusicShuffle() {
        musicShuffleEnabled.toggle()
    }

    func cycleMusicRepeatMode() {
        musicRepeatMode = musicRepeatMode.next
    }

    func presentBuiltInPlayer(_ item: MediaItem, preserveSelection: Bool = false) {
        if !preserveSelection {
            selectedItem = nil
        }
        quickPreviewItem = nil
        guard item.type != .music else {
            activePlayerItem = item
            return
        }
        activePlayerItem = item
    }

    private func prepareMusicQueue(for item: MediaItem) {
        guard item.type == .music else { return }
        if musicQueue.contains(where: { $0.id == item.id }) {
            return
        }
        let sourceQueue = musicTracks.isEmpty ? [item] : musicTracks
        if sourceQueue.contains(where: { $0.id == item.id }) {
            musicQueue = sourceQueue
        } else {
            musicQueue = [item] + sourceQueue
        }
    }

    private func uniqueMusicTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        var seen = Set<String>()
        var result: [MediaItem] = []
        for track in tracks where track.type == .music && track.filePath != nil {
            guard seen.insert(track.id).inserted else { continue }
            result.append(track)
        }
        return result
    }

    private func adjacentItem(to item: MediaItem, direction: Int) -> MediaItem? {
        let normalizedDirection = direction < 0 ? -1 : 1
        let sequence: [MediaItem]
        if item.type == .music {
            prepareMusicQueue(for: item)
            sequence = musicQueue
            if musicRepeatMode == .repeatOne {
                return item
            }
            if normalizedDirection > 0, musicShuffleEnabled {
                let candidates = sequence.filter { $0.id != item.id }
                return candidates.randomElement() ?? item
            }
        } else if let parentID = item.parentID,
                  let parent = items.first(where: { $0.id == parentID }) {
            sequence = children(for: parent)
        } else {
            sequence = topLevelItems.filter { $0.type != .music && $0.filePath != nil }
        }
        guard let index = sequence.firstIndex(where: { $0.id == item.id }) else { return nil }
        let targetIndex = index + normalizedDirection
        if item.type == .music,
           musicRepeatMode == .repeatAll,
           !sequence.isEmpty {
            if targetIndex < sequence.startIndex {
                return sequence.last
            }
            if targetIndex >= sequence.endIndex {
                return sequence.first
            }
        }
        guard sequence.indices.contains(targetIndex) else { return nil }
        return sequence[targetIndex]
    }

    func openExternally(_ item: MediaItem) {
        guard let filePath = item.filePath else {
            alert = AppAlert(title: "无法打开外部播放器", message: "此媒体没有文件路径。")
            return
        }
        do {
            let path = item.type == .music ? settings.musicExternalPlayerPath : settings.videoExternalPlayerPath
            try externalPlayerService.open(filePath: filePath, preferredPlayerPath: path)
        } catch {
            showError("外部播放器不可用", error)
        }
    }

    func updatePlayback(item: MediaItem, position: Double, duration: Double?, reloadLibrary: Bool = true) {
        guard settings.rememberPlaybackPosition else { return }
        do {
            try mediaRepository?.updatePlayback(
                id: item.id,
                position: position,
                duration: duration,
                watchedThreshold: settings.watchedThreshold
            )
            if reloadLibrary {
                reload()
            }
        } catch {
            logger?.log("播放进度保存失败：\(error.localizedDescription)", level: .warning)
        }
    }

    func clearPlaybackHistory(_ item: MediaItem) {
        do {
            try mediaRepository?.clearPlaybackHistory(id: item.id)
            clearPlaybackHistoryInMemory(ids: [item.id])
        } catch {
            showError("播放记录删除失败", error)
        }
    }

    func clearPlaybackHistory(_ items: [MediaItem]) {
        let ids = items.filter(\.hasPlaybackTrace).map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try mediaRepository?.clearPlaybackHistory(ids: ids)
            clearPlaybackHistoryInMemory(ids: ids)
        } catch {
            showError("播放记录删除失败", error)
        }
    }

    private func clearPlaybackHistoryInMemory(ids: [String]) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        let now = Date()

        func cleared(_ item: MediaItem) -> MediaItem {
            guard targetIDs.contains(item.id) else { return item }
            var copy = item
            copy.playPosition = 0
            copy.playProgress = 0
            copy.watched = false
            copy.lastPlayedAt = nil
            copy.updatedAt = now
            return copy
        }

        items = items.map(cleared)
        musicQueue = musicQueue.map(cleared)
        if let activePlayerItem {
            self.activePlayerItem = cleared(activePlayerItem)
        }
        if let selectedItem {
            self.selectedItem = cleared(selectedItem)
        }
        if let quickPreviewItem {
            self.quickPreviewItem = cleared(quickPreviewItem)
        }
        rebuildDerivedItemCaches()
        libraryRevision += 1
    }

    func toggleFavorite(_ item: MediaItem) {
        let currentFavorite =
        items.first(where: { $0.id == item.id })?.favorite ??
        activePlayerItem.flatMap { $0.id == item.id ? $0.favorite : nil } ??
        selectedItem.flatMap { $0.id == item.id ? $0.favorite : nil } ??
        item.favorite
        let nextFavorite = !currentFavorite

        updateFavoriteInMemory(id: item.id, favorite: nextFavorite)

        guard let mediaRepository else { return }
        Task(priority: .utility) { [weak self, mediaRepository] in
            do {
                try mediaRepository.setFavorite(id: item.id, favorite: nextFavorite)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    self.updateFavoriteInMemory(id: item.id, favorite: currentFavorite)
                    self.showError("收藏状态更新失败", error)
                }
            }
        }
    }

    private func updateFavoriteInMemory(id: String, favorite: Bool) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.favorite = favorite
            return copy
        }

        items = items.map(updated)
        musicQueue = musicQueue.map(updated)
        cachedChildrenByParentID = cachedChildrenByParentID.mapValues { children in
            children.map(updated)
        }
        cachedTopLevelItems = cachedTopLevelItems.map(updated)
        cachedPrivateTopLevelItems = cachedPrivateTopLevelItems.map(updated)
        cachedMusicTracks = cachedMusicTracks.map(updated)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        cachedEmbyTopLevelItems = cachedEmbyTopLevelItems.map(updated)
        cachedContinueWatchingItems = cachedContinueWatchingItems.map(updated)
        cachedNextUpItems = cachedNextUpItems.map(updated)
        cachedDuplicateTitleGroups = cachedDuplicateTitleGroups.map { group in
            group.map(updated)
        }
        if let activePlayerItem {
            self.activePlayerItem = updated(activePlayerItem)
        }
        if let selectedItem {
            self.selectedItem = updated(selectedItem)
        }
        if let quickPreviewItem {
            self.quickPreviewItem = updated(quickPreviewItem)
        }
        cachedHomeStats.favoriteCount = cachedTopLevelItems.filter(\.favorite).count
        if cachedHomeStats.favoriteCount > 0 {
            cachedAvailableHomeTabs.insert(.favorites)
        } else {
            cachedAvailableHomeTabs.remove(.favorites)
        }
        favoriteRevision += 1
    }

    func markWatched(_ item: MediaItem, watched: Bool) {
        do {
            try mediaRepository?.markWatched(id: item.id, watched: watched)
            reload()
        } catch {
            showError("观看状态更新失败", error)
        }
    }

    func markAllWatched(_ items: [MediaItem], watched: Bool) {
        guard !items.isEmpty, let mediaRepository else { return }
        var hadError = false
        for item in items {
            do {
                try mediaRepository.markWatched(id: item.id, watched: watched)
            } catch {
                hadError = true
                logger?.log("批量更新观看状态失败：\(error.localizedDescription)", level: .warning)
            }
        }
        reload()
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的观看状态未能更新，请检查数据库状态。")
        }
    }

    func reclassify(_ item: MediaItem, as type: MediaType) {
        do {
            try mediaRepository?.updateType(id: item.id, type: type)
            reload()
        } catch {
            showError("分类更新失败", error)
        }
    }

    func updateRating(_ item: MediaItem, rating: Double?) {
        do {
            try mediaRepository?.updateRating(id: item.id, rating: rating)
            reload()
        } catch {
            showError("评分更新失败", error)
        }
    }

    func applyMetadata(_ metadata: MediaMetadataUpdate, to item: MediaItem) {
        do {
            try mediaRepository?.updateMetadata(id: item.id, metadata: metadata)
            updateMetadataInMemory(id: item.id, metadata: metadata)
        } catch {
            showError("元数据更新失败", error)
        }
    }

    func applyMusicTagDraft(
        _ draft: MusicTagDraft,
        to item: MediaItem,
        writeFileTags: Bool
    ) async throws -> MusicTagApplyReport {
        var writeWarning: String?
        if writeFileTags {
            let service = MusicTagEditingService(logger: logger)
            let report = try await service.write(draft, to: item)
            writeWarning = report.warning
        }

        let update = draft.metadataUpdate
        try mediaRepository?.updateMetadata(id: item.id, metadata: update)
        updateMetadataInMemory(id: item.id, metadata: update)
        return MusicTagApplyReport(
            itemID: item.id,
            didUpdateLibrary: true,
            didWriteFile: writeFileTags,
            warning: writeWarning
        )
    }

    func fetchTMDBCollection(for item: MediaItem) async {
        guard item.type == .movie,
              let tmdbIDStr = item.externalID,
              tmdbIDStr.hasPrefix("tmdb:movie:") else { return }
        let numericID = String(tmdbIDStr.dropFirst("tmdb:movie:".count))
        guard !numericID.isEmpty else { return }

        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            alert = AppAlert(title: "需要 TMDB API Key", message: "请先在设置中填写 TMDB API Key 或 Read Access Token。")
            return
        }

        let lang = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        var components = URLComponents(string: "https://api.themoviedb.org/3/movie/\(numericID)")
        components?.queryItems = [URLQueryItem(name: "language", value: lang)]

        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        if apiKey.contains(".") || apiKey.count > 80 {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        } else {
            components?.queryItems?.append(URLQueryItem(name: "api_key", value: apiKey))
            request.url = components?.url
        }

        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let collection = json["belongs_to_collection"] as? [String: Any],
              let name = collection["name"] as? String,
              !name.isEmpty else {
            alert = AppAlert(title: "未找到合集信息", message: "该影片在 TMDB 上没有关联的合集，或 API 请求失败。")
            return
        }

        applyMetadata(MediaMetadataUpdate(collectionTitle: name), to: item)
    }

    func canWriteMusicFileTags(for item: MediaItem) -> Bool {
        MusicTagEditingService(logger: logger).canWriteFileTags(for: item)
    }

    func fetchAllMusicMetadata() async {
        guard !isFetchingMusicMetadata else { return }
        let tracks = musicTracks
        guard !tracks.isEmpty else {
            alert = AppAlert(title: "没有音乐", message: "添加音乐媒体源并扫描后，才能获取封面和歌词。")
            return
        }
        guard settings.musicMetadataProvider != .disabled else {
            alert = AppAlert(title: "音乐数据源未启用", message: "请先在设置中选择 MusicBrainz 或 iTunes Search。")
            return
        }

        let service = MetadataSearchService()
        isFetchingMusicMetadata = true
        musicMetadataFetchProgress = "准备匹配 \(tracks.count) 首"
        defer { isFetchingMusicMetadata = false }

        var updatedCount = 0
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled { break }
            musicMetadataFetchProgress = "\(index + 1)/\(tracks.count) \(track.title)"
            let query = [track.artist, track.title]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
            if let result = try? await service.searchMusic(
                query: query.isEmpty ? track.title : query,
                provider: settings.musicMetadataProvider
            ).first {
                let update = await service.materializedMetadataUpdate(
                    for: result,
                    itemID: track.id,
                    artworkDirectory: directories?.thumbnails,
                    preserveEmbeddedPoster: track.hasEmbeddedArtwork
                )
                do {
                    try mediaRepository?.updateMetadata(id: track.id, metadata: update)
                    updatedCount += 1
                } catch {
                    showError("音乐信息写入失败", error)
                }
            }
            await fetchLyricsIfPossible(for: track)
        }

        reload()
        musicMetadataFetchProgress = "完成 \(updatedCount)/\(tracks.count) 首"
    }

    private func updateMetadataInMemory(id: String, metadata: MediaMetadataUpdate) {
        let now = Date()

        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.title = metadata.title ?? copy.title
            copy.originalTitle = metadata.originalTitle ?? copy.originalTitle
            copy.artist = metadata.artist ?? copy.artist
            copy.album = metadata.album ?? copy.album
            copy.trackNumber = metadata.trackNumber ?? copy.trackNumber
            copy.year = metadata.year ?? copy.year
            copy.overview = metadata.overview ?? copy.overview
            copy.posterPath = metadata.posterPath ?? copy.posterPath
            copy.backdropPath = metadata.backdropPath ?? copy.backdropPath
            copy.rating = metadata.rating ?? copy.rating
            copy.runtime = metadata.runtime ?? copy.runtime
            copy.externalID = metadata.externalID ?? copy.externalID
            copy.metadataProvider = metadata.metadataProvider ?? copy.metadataProvider
            copy.collectionTitle = metadata.collectionTitle ?? copy.collectionTitle
            copy.updatedAt = now
            return copy
        }

        items = items.map(updated)
        musicQueue = musicQueue.map(updated)
        if let activePlayerItem {
            self.activePlayerItem = updated(activePlayerItem)
        }
        if let selectedItem {
            self.selectedItem = updated(selectedItem)
        }
        if let quickPreviewItem {
            self.quickPreviewItem = updated(quickPreviewItem)
        }
        rebuildDerivedItemCaches()
        libraryRevision += 1
    }

    private func fetchLyricsIfPossible(for track: MediaItem) async {
        guard let filePath = track.filePath else { return }
        var components = URLComponents(string: "https://lrclib.net/api/search")
        components?.queryItems = [
            URLQueryItem(name: "track_name", value: track.title),
            URLQueryItem(name: "artist_name", value: track.artist),
            URLQueryItem(name: "album_name", value: track.album)
        ].filter { $0.value?.isEmpty == false }
        guard let url = components?.url else { return }
        var request = URLRequest(url: url)
        request.timeoutInterval = 10
        request.setValue("MediaLIB/1.0 local macOS media library", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let results = try? JSONDecoder().decode([LRCLibLyricsSearchResult].self, from: data),
              let text = results.first.flatMap({ $0.syncedLyrics ?? $0.plainLyrics }),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        let mediaURL = URL(fileURLWithPath: filePath)
        let outputURL = mediaURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(mediaURL.deletingPathExtension().lastPathComponent).lrc")
        try? text.write(to: outputURL, atomically: true, encoding: .utf8)
    }

    func saveSettings() {
        settingsStore.save(settings)
        applyAppearance()
        configureAutomaticScan()
    }

    func rememberPlayerVolume(_ volume: Float, for mediaType: MediaType) {
        let nextVolume = min(max(Double(volume), 0), 1)
        let currentVolume = settings.rememberedVolume(for: mediaType)
        guard abs(currentVolume - nextVolume) > 0.001 else { return }
        settings.setRememberedVolume(nextVolume, for: mediaType)
        saveSettings()
    }

    func chooseExternalPlayer(url: URL) {
        settings.videoExternalPlayerPath = url.path
        saveSettings()
    }

    func chooseExternalPlayer(url: URL, forMusic: Bool) {
        if forMusic {
            settings.musicExternalPlayerPath = url.path
        } else {
            settings.videoExternalPlayerPath = url.path
        }
        saveSettings()
    }

    var privacyBiometricsAvailable: Bool {
        privacyLockService.canUseBiometrics()
    }

    func setPrivacyPIN(_ pin: String) -> Bool {
        do {
            try privacyLockService.setPIN(pin)
            settings.privacyPINEnabled = true
            settingsStore.save(settings)
            privacyPINConfigured = true
            privacyUnlocked = true
            return true
        } catch {
            showError("隐私密码设置失败", error)
            return false
        }
    }

    func verifyPrivacyPIN(_ pin: String) -> Bool {
        guard privacyLockService.verify(pin: pin) else {
            alert = AppAlert(title: "无法解锁", message: "密码不正确，请输入 4 到 8 位数字密码。")
            return false
        }
        settings.privacyPINEnabled = true
        settingsStore.save(settings)
        privacyPINConfigured = true
        privacyUnlocked = true
        return true
    }

    func unlockPrivacyWithBiometrics() {
        Task { @MainActor in
            do {
                let unlocked = try await privacyLockService.unlockWithBiometrics()
                privacyUnlocked = unlocked
                if unlocked {
                    privacyPINConfigured = true
                }
                if !unlocked {
                    alert = AppAlert(title: "无法解锁", message: "Touch ID 未完成验证。")
                }
            } catch {
                showError("Touch ID 解锁失败", error)
            }
        }
    }

    func lockPrivacy() {
        privacyUnlocked = false
        selectedItem = nil
        stopPlaybackIfPrivate()
    }

    func removePrivacyPIN() {
        guard privacyUnlocked else {
            alert = AppAlert(title: "需要先解锁", message: "请先解锁\(settings.privacyVaultName)，再移除保险库密码。")
            return
        }
        privacyLockService.removePIN()
        settings.privacyPINEnabled = false
        settingsStore.save(settings)
        privacyPINConfigured = false
        privacyUnlocked = false
        selectedItem = nil
        stopPlaybackIfPrivate()
    }

    private func stopPlaybackIfPrivate() {
        if let active = activePlayerItem, cachedPrivateItemIDs.contains(active.id) {
            activePlayerItem = nil
        }
        if let preview = quickPreviewItem, cachedPrivateItemIDs.contains(preview.id) {
            quickPreviewItem = nil
        }
    }

    func showError(_ title: String, _ error: Error) {
        logger?.log("\(title)：\(error.localizedDescription)", level: .error)
        alert = AppAlert(title: title, message: error.localizedDescription)
    }

    private func configureAutomaticScan() {
        guard configuredAutomaticScanInterval != settings.automaticScanInterval else { return }
        configuredAutomaticScanInterval = settings.automaticScanInterval
        automaticScanTask?.cancel()
        guard let seconds = settings.automaticScanInterval.seconds else {
            automaticScanTask = nil
            return
        }

        automaticScanTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                await MainActor.run {
                    self?.runAutomaticScanIfNeeded()
                }
            }
        }
    }

    private func runAutomaticScanIfNeeded() {
        guard !isScanning else { return }
        let candidates = sources.filter { source in
            source.autoScan && source.sourceKind != .emby
        }
        guard !candidates.isEmpty else { return }
        startScanQueue(candidates, silent: true)
    }

    private func logPerformance(_ message: String) {
        guard settings.debugLoggingEnabled else { return }
        logger?.log("[Performance] \(message)")
    }

    private static func milliseconds(since startDate: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(startDate) * 1000)
    }
}

extension AppTheme {
    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .dark: return .dark
        case .light: return .light
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system:
            return nil
        case .dark:
            return NSAppearance(named: .darkAqua)
        case .light:
            return NSAppearance(named: .aqua)
        }
    }
}

extension AppState {
    func applyAppearance() {
        let appearance = settings.theme.nsAppearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            window.toolbar?.validateVisibleItems()
            window.contentView?.needsDisplay = true
        }
    }
}
