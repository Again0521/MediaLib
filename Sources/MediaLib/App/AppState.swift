import AppKit
import Foundation
import MediaLibCore
import SwiftUI

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 受限 Emby 服务器（白名单拒绝）提示载体：携带服务器地址、判定原因、本机客户端身份，
/// 供 UI 弹窗展示并让用户复制客户端信息交给管理员加入白名单。
struct EmbyRestrictionNotice: Identifiable {
    let id = UUID()
    let serverHost: String
    let reason: String?
    let identity: EmbyClientIdentity
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
    @Published private(set) var backgroundTasks: [BackgroundTaskSnapshot] = []
    /// 剧集 TMDB 一键匹配进行中（驱动设置页按钮的进度态）。
    @Published var isMatchingTMDB = false
    @Published var alert: AppAlert?
    /// 受限 Emby 服务器提示（白名单拒绝）；非 nil 时弹出专用面板。
    @Published var embyRestrictionNotice: EmbyRestrictionNotice?
    /// C2 批量操作：海报墙多选模式开关与已选条目 ID 集合。
    @Published var isSelectionModeActive = false
    @Published var selectedItemIDs: Set<String> = []
    /// 配色切换计数：每次切换预设 +1，驱动整窗"加载过场"覆盖层在下层刷新界面，避免逐控件慢慢变色。
    @Published var themeRevision = 0
    @Published var startupError: String?
    @Published var privacyUnlocked = false
    @Published var privacyPINConfigured = false
    @Published var musicQueue: [MediaItem] = []
    @Published var musicRepeatMode: MusicRepeatMode = .sequential
    @Published var musicShuffleEnabled = false
    @Published var musicPlaylists: [MusicPlaylist] = []
    @Published var videoSmartCollections: [VideoSmartCollection] = []
    @Published var musicSmartPlaylists: [MusicSmartPlaylist] = []
    @Published var playbackCommandRequest: PlaybackCommandRequest?
    @Published var isFetchingMusicMetadata = false
    @Published private(set) var isConnectingEmby = false
    @Published var musicMetadataFetchProgress = ""
    @Published private(set) var libraryRevision = 0
    /// 仅在 reload() 完成（元数据/封面路径真实变化）时递增；文件存在性检查不会触发它。
    /// LocalPosterImage 的 cacheKey 改用此值，避免文件健康检查后触发全量图片重载。
    @Published private(set) var posterRevision = 0
    @Published private(set) var favoriteRevision = 0
    @Published private(set) var watchlistRevision = 0
    // #14 樱花彩蛋：播放歌名含「アゲイン」的歌曲时触发，每次启动软件只在首次播放时出现。
    @Published var sakuraEasterEggActive = false
    private var sakuraEasterEggShownThisLaunch = false
    private var sakuraEasterEggTask: Task<Void, Never>?
    // 只在本次进程内记住队列弹层上次停留位置，避免跨启动恢复到旧队列偏移。
    var musicQueueScrollAnchorID: String?
    let directories: AppDirectories?
    private let database: DatabaseManager?
    private let sourceRepository: SourceRepository?
    private let mediaRepository: MediaRepository?
    private let musicPlaylistRepository: MusicPlaylistRepository?
    private let musicQueueRepository: MusicQueueRepository?
    private let videoSmartCollectionRepository: VideoSmartCollectionRepository?
    private let musicSmartPlaylistRepository: MusicSmartPlaylistRepository?
    private let playbackMarkerRepository: PlaybackMarkerRepository?
    private let settingsStore = AppSettingsStore()
    private let logger: LoggingService?
    private let externalPlayerService = ExternalPlayerService()
    private let privacyLockService = PrivacyLockService()
    private let remoteCredentialStore = RemoteCredentialStore()
    private let embyService = EmbyService()
    private var scanTask: Task<Void, Never>?
    private var automaticScanTask: Task<Void, Never>?
    private var configuredAutomaticScanInterval: AutomaticScanInterval?
    private var automaticTMDBMatchTask: Task<Void, Never>?
    private var configuredAutomaticTMDBMatchInterval: AutomaticScanInterval?
    private var tmdbMatchTask: Task<Void, Never>?
    private var pendingScanSources: [MediaSource] = []
    private var pendingIncrementalChanges: [String: Set<String>] = [:]
    private var activeScanSourceID: String?
    private var scanRunID = UUID()
    private var fileEventDebounceTask: Task<Void, Never>?
    private var pendingFileEventPaths: [String: Set<String>] = [:]
    private var pendingFullScanSourceIDs: Set<String> = []
    private var remountingNetworkSourceIDs: Set<String> = []
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
    private var cachedWatchingItems: [MediaItem] = []
    private var cachedPrivateWatchingItems: [MediaItem] = []
    private var cachedMissingFileItems: [MediaItem] = []
    private var cachedSafeMissingFileItemIDs: Set<String> = []
    private var cachedMissingMetadataItems: [MediaItem] = []
    private var cachedDuplicateTitleGroups: [[MediaItem]] = []
    private var cachedVisibleVideoSections: [VideoLibrarySection] = []
    private var cachedAvailableHomeTabs: Set<HomeTab> = [.overview]
    private var cachedOfflineSources: [MediaSource] = []
    private var cachedOfflineSourceIDs: Set<String> = []
    private var cachedHomeStats = HomeStatsSnapshot()
    private var fileHealthTask: Task<Void, Never>?
    private var fileHealthRefreshID = UUID()
    private lazy var localFileEventMonitor = LocalFileEventMonitor { [weak self] changes in
        Task { @MainActor in
            self?.receiveLocalFileSystemChanges(changes)
        }
    }
    private var musicQueuePersistenceTask: Task<Void, Never>?
    private var didRestoreMusicQueue = false
    private var embyPlaybackSyncTasks: [String: Task<Void, Never>] = [:]
    private var embyPlaySessionIDs: [String: String] = [:]
    /// B2 Scrobbling：当前待结算的听歌候选（开始播放即记录，达到时长门槛后 track.scrobble）。
    private var pendingScrobble: (item: MediaItem, startedAt: Date, duration: Double)?
    /// Last.fm 授权流程中临时持有的 request token（用户在浏览器授权后用它换 session）。
    private var lastfmPendingAuthToken: String?
    /// 配色等高频设置变更的防抖落盘任务。
    private var settingsPersistTask: Task<Void, Never>?
    /// 正在进行 Last.fm 授权/连接操作。
    @Published var isLastfmAuthorizing = false

    init() {
        let loadedSettings = settingsStore.load()
        self.settings = loadedSettings
        self.privacyPINConfigured = loadedSettings.privacyPINEnabled && privacyLockService.hasPIN()
        // 首帧前就把用户配色写入全局色板，避免启动闪一帧默认配色。
        AppColors.activeTheme = AppThemeResolver.resolve(for: loadedSettings)

        do {
            let directories = try FileAccessService.appDirectories()
            let logger = LoggingService(logDirectory: directories.logs)
            let database = try DatabaseManager(url: directories.database, backupDirectory: directories.databaseBackups)
            self.directories = directories
            self.logger = logger
            self.database = database
            self.sourceRepository = SourceRepository(database: database)
            self.mediaRepository = MediaRepository(database: database)
            self.musicPlaylistRepository = MusicPlaylistRepository(database: database)
            self.musicQueueRepository = MusicQueueRepository(database: database)
            self.videoSmartCollectionRepository = VideoSmartCollectionRepository(database: database)
            self.musicSmartPlaylistRepository = MusicSmartPlaylistRepository(database: database)
            self.playbackMarkerRepository = PlaybackMarkerRepository(database: database)
            reload()
            restoreMusicQueueState()
            configureAutomaticScan()
            configureLocalFileEventMonitoring()
            configureAutomaticTMDBMatch()
        } catch {
            self.directories = nil
            self.logger = nil
            self.database = nil
            self.sourceRepository = nil
            self.mediaRepository = nil
            self.musicPlaylistRepository = nil
            self.musicQueueRepository = nil
            self.videoSmartCollectionRepository = nil
            self.musicSmartPlaylistRepository = nil
            self.playbackMarkerRepository = nil
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
        cachedMissingFileItems.filter(healthCheckEnabled(for:))
    }

    var missingMetadataItems: [MediaItem] {
        cachedMissingMetadataItems.filter(healthCheckEnabled(for:))
    }

    var offlineSources: [MediaSource] {
        cachedOfflineSources.filter(\.includeInHealthCheck)
    }

    var duplicateTitleGroups: [[MediaItem]] {
        cachedDuplicateTitleGroups
            .map { $0.filter(healthCheckEnabled(for:)) }
            .filter { $0.count > 1 }
    }

    /// 仅仍存在且明确开启健康检查的来源参与统计。
    /// 来源被删除后，旧异步结果可能短暂保留在缓存中；这里必须立即把它们过滤掉。
    /// 该条目所属来源是否参与健康检查。无法定位来源时默认参与——
    /// 与 metadataFetchEnabled 及构建期过滤一致，避免把"来源已被删但条目残留"的孤儿项从健康页隐藏，
    /// 否则这类真正需要清理的条目反而看不到。
    private func healthCheckEnabled(for item: MediaItem) -> Bool {
        source(for: item)?.includeInHealthCheck ?? true
    }

    /// 该条目所属来源是否参与一键元数据拉取（无法定位来源时默认参与）。
    func metadataFetchEnabled(for item: MediaItem) -> Bool {
        source(for: item)?.includeInMetadataFetch ?? true
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
        case .home, .health, .tasks, .sources, .settings:
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
            base = privacyPINConfigured && privacyUnlocked
                ? (cachedWatchingItems + cachedPrivateWatchingItems).sorted(by: Self.playbackRecencySort)
                : cachedWatchingItems
        case .video(.watchlist):
            base = allVisibleVideoCollectionItems.filter(\.watchlist)
        case .video(.favorites):
            base = topLevelItems.filter { $0.type != .music && $0.favorite }
        case .video(.unwatched):
            base = topLevelItems.filter { $0.type != .music && !$0.watched && $0.playProgress < 0.9 }
        case .video(.watched):
            let visibleItems = topLevelItems + ((privacyPINConfigured && privacyUnlocked) ? privateTopLevelItems : [])
            base = visibleItems.filter { $0.type != .music && ($0.watched || $0.playProgress >= 0.9) }
        case .music(let section):
            base = musicItems(for: section)
        case .embySection(let sourceID, let section):
            base = embyItems(for: section, sourceID: sourceID)
        case .embyLibrary(let libraryID):
            base = embyItems(forLibraryID: libraryID)
        case .smartCollection(let collectionID):
            guard let collection = videoSmartCollections.first(where: { $0.id == collectionID }) else {
                base = []
                break
            }
            base = allVisibleVideoCollectionItems.filter { matches($0, collection: collection) }
        case .musicSmartPlaylist(let playlistID):
            guard let playlist = musicSmartPlaylists.first(where: { $0.id == playlistID }) else {
                base = []
                break
            }
            base = musicTracks(inSmart: playlist)
        }

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        // 拼音/首字母/模糊搜索：支持"贝加尔"用 beijiaer / bje 命中。
        return base.filter {
            PinyinSearchMatcher.matches(query: searchText, in: [$0.title, $0.originalTitle, $0.artist, $0.album])
        }
    }

    func videoSmartCollection(id: String) -> VideoSmartCollection? {
        videoSmartCollections.first { $0.id == id }
    }

    func saveVideoSmartCollection(_ collection: VideoSmartCollection) {
        guard let videoSmartCollectionRepository else { return }
        do {
            let saved = try videoSmartCollectionRepository.save(collection)
            if let index = videoSmartCollections.firstIndex(where: { $0.id == saved.id }) {
                videoSmartCollections[index] = saved
            } else {
                videoSmartCollections.insert(saved, at: 0)
            }
            videoSmartCollections.sort { $0.updatedAt > $1.updatedAt }
            libraryRevision += 1
        } catch {
            showError("智能集合保存失败", error)
        }
    }

    func deleteVideoSmartCollection(_ collection: VideoSmartCollection) {
        guard let videoSmartCollectionRepository else { return }
        do {
            try videoSmartCollectionRepository.delete(id: collection.id)
            videoSmartCollections.removeAll { $0.id == collection.id }
            libraryRevision += 1
        } catch {
            showError("智能集合删除失败", error)
        }
    }

    // MARK: - 音乐智能歌单

    func musicSmartPlaylist(id: String) -> MusicSmartPlaylist? {
        musicSmartPlaylists.first { $0.id == id }
    }

    func saveMusicSmartPlaylist(_ playlist: MusicSmartPlaylist) {
        guard let musicSmartPlaylistRepository else { return }
        do {
            let saved = try musicSmartPlaylistRepository.save(playlist)
            if let index = musicSmartPlaylists.firstIndex(where: { $0.id == saved.id }) {
                musicSmartPlaylists[index] = saved
            } else {
                musicSmartPlaylists.insert(saved, at: 0)
            }
            musicSmartPlaylists.sort { $0.updatedAt > $1.updatedAt }
            libraryRevision += 1
        } catch {
            showError("智能歌单保存失败", error)
        }
    }

    func deleteMusicSmartPlaylist(_ playlist: MusicSmartPlaylist) {
        guard let musicSmartPlaylistRepository else { return }
        do {
            try musicSmartPlaylistRepository.delete(id: playlist.id)
            musicSmartPlaylists.removeAll { $0.id == playlist.id }
            libraryRevision += 1
        } catch {
            showError("智能歌单删除失败", error)
        }
    }

    /// 按规则实时求值：从全部音乐里筛选 → 排序 → 截断数量。曲目随库状态自动更新。
    func musicTracks(inSmart playlist: MusicSmartPlaylist) -> [MediaItem] {
        var tracks = musicTracks

        switch playlist.filter {
        case .any:
            break
        case .favorites:
            tracks = tracks.filter(\.favorite)
        case .recentlyPlayed:
            tracks = tracks.filter { $0.lastPlayedAt != nil }
        case .neverPlayed:
            tracks = tracks.filter { ($0.playCount ?? 0) == 0 }
        }

        if playlist.recency != .anytime {
            let cutoff = Date().addingTimeInterval(-Double(playlist.recency.rawValue) * 86_400)
            tracks = tracks.filter { $0.createdAt >= cutoff }
        }

        switch playlist.sort {
        case .dateAddedDesc:
            tracks.sort { $0.createdAt > $1.createdAt }
        case .playCountDesc:
            tracks.sort { ($0.playCount ?? 0) > ($1.playCount ?? 0) }
        case .lastPlayedDesc:
            tracks.sort { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .titleAsc:
            tracks.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .artistAsc:
            tracks.sort { ($0.artist ?? "").localizedCaseInsensitiveCompare($1.artist ?? "") == .orderedAscending }
        case .yearDesc:
            tracks.sort { ($0.year ?? 0) > ($1.year ?? 0) }
        }

        if playlist.limit != .unlimited {
            tracks = Array(tracks.prefix(playlist.limit.rawValue))
        }
        return tracks
    }

    private var allVisibleVideoCollectionItems: [MediaItem] {
        cachedTopLevelItems + cachedEmbyTopLevelItems
    }

    private func matches(_ item: MediaItem, collection: VideoSmartCollection) -> Bool {
        guard collection.mediaScope.includes(item.type) else { return false }
        switch collection.stateFilter {
        case .any:
            break
        case .watchlist:
            guard item.watchlist else { return false }
        case .favorites:
            guard item.favorite else { return false }
        case .watching:
            guard item.hasPlaybackTrace && !(item.watched || item.playProgress >= settings.watchedThreshold) else { return false }
        case .unwatched:
            guard !item.watched && item.playProgress < settings.watchedThreshold else { return false }
        case .watched:
            guard item.watched || item.playProgress >= settings.watchedThreshold else { return false }
        }
        guard collection.recency != .anytime else { return true }
        let cutoff = Calendar.current.date(byAdding: .day, value: -collection.recency.rawValue, to: Date()) ?? .distantPast
        return item.createdAt >= cutoff
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

    // MARK: - 歌单 M3U 导入 / 导出

    /// 生成 M3U 文本（含 #EXTINF 时长与"艺人 - 标题"）。
    func musicPlaylistM3UContent(_ playlist: MusicPlaylist) -> String {
        var lines = ["#EXTM3U"]
        for track in musicTracks(in: playlist) {
            guard let path = track.filePath, !path.isEmpty else { continue }
            let seconds = Int((track.duration ?? 0).rounded())
            let artist = track.artist?.trimmingCharacters(in: .whitespaces) ?? ""
            let info = artist.isEmpty ? track.title : "\(artist) - \(track.title)"
            lines.append("#EXTINF:\(seconds),\(info)")
            lines.append(path)
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// 从 M3U 文件导入：按文件路径（绝对/相对）匹配库内曲目，匹配不到再按文件名兜底，创建新歌单。返回匹配数量。
    @discardableResult
    func importMusicPlaylist(fromM3U url: URL, name: String) -> Int {
        let content: String
        if let utf8 = try? String(contentsOf: url, encoding: .utf8) {
            content = utf8
        } else if let latin = try? String(contentsOf: url, encoding: .isoLatin1) {
            content = latin
        } else {
            alert = AppAlert(title: "导入失败", message: "无法读取该 M3U 文件。")
            return 0
        }

        let baseDir = url.deletingLastPathComponent()
        let rawPaths: [String] = content
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { line in
                if line.hasPrefix("/") || line.contains("://") { return line }
                return baseDir.appendingPathComponent(line).standardizedFileURL.path
            }

        let byPath = Dictionary(cachedMusicTracks.compactMap { track in
            track.filePath.map { ($0, track) }
        }, uniquingKeysWith: { first, _ in first })
        let byFilename = Dictionary(cachedMusicTracks.compactMap { track -> (String, MediaItem)? in
            guard let path = track.filePath else { return nil }
            return (URL(fileURLWithPath: path).lastPathComponent, track)
        }, uniquingKeysWith: { first, _ in first })

        var matched: [MediaItem] = []
        var seenIDs = Set<String>()
        for path in rawPaths {
            let track = byPath[path] ?? byFilename[URL(fileURLWithPath: path).lastPathComponent]
            if let track, seenIDs.insert(track.id).inserted {
                matched.append(track)
            }
        }

        guard !matched.isEmpty else {
            alert = AppAlert(title: "未匹配到歌曲", message: "M3U 里的文件都不在当前音乐库中。请先扫描包含这些文件的音乐媒体源。")
            return 0
        }
        _ = createMusicPlaylist(name: name, tracks: matched)
        return matched.count
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

    /// 某个 Emby 来源的内部分区（视频/音乐/最近/收藏），按来源过滤。
    func embyItems(for section: EmbyLibrarySection, sourceID: String) -> [MediaItem] {
        let scoped = cachedEmbyTopLevelItems.filter { embySourceID(for: $0) == sourceID }
        switch section {
        case .videos:
            return scoped.filter { $0.type != .music }
        case .music:
            return scoped.filter { $0.type == .music }
        case .recent:
            return scoped
                .filter { $0.lastPlayedAt != nil }
                .sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        case .favorites:
            return scoped.filter(\.favorite)
        }
    }

    func hasEmbyItems(for section: EmbyLibrarySection, sourceID: String) -> Bool {
        !embyItems(for: section, sourceID: sourceID).isEmpty
    }

    /// 解析某个 Emby 条目所属来源的 id（按 sourcePath 根路径匹配）。
    private func embySourceID(for item: MediaItem) -> String? {
        guard let sourcePath = item.sourcePath else { return nil }
        let rootPath = EmbyService.sourceRootPath(from: sourcePath) ?? sourcePath
        return embySources.first { $0.path == rootPath || sourcePath.hasPrefix($0.path) }?.id
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

    /// 从 Emby 媒体源推断可展示的服务器地址（emby://host/... → host），回落到源名称。
    static func embyServerHost(for source: MediaSource) -> String {
        if let host = URLComponents(string: source.path)?.host, !host.isEmpty {
            return host
        }
        return source.name
    }

    func reload() {
        do {
            let reloadStart = Date()
            ArtworkImageCache.invalidateMissingPaths()
            let fetchStart = Date()
            sources = try sourceRepository?.fetchAll() ?? []
            items = try mediaRepository?.fetchAll() ?? []
            musicPlaylists = try musicPlaylistRepository?.fetchAll() ?? []
            videoSmartCollections = try videoSmartCollectionRepository?.fetchAll() ?? []
            musicSmartPlaylists = try musicSmartPlaylistRepository?.fetchAll() ?? []
            logPerformance("reload.fetch repositories: \(Self.milliseconds(since: fetchStart))ms items=\(items.count) sources=\(sources.count) playlists=\(musicPlaylists.count)")
            let cacheStart = Date()
            rebuildDerivedItemCaches()
            if didRestoreMusicQueue {
                reconcileMusicQueueWithLibrary()
            }
            logPerformance("reload.rebuildDerivedItemCaches: \(Self.milliseconds(since: cacheStart))ms")
            if let selectedItem, let refreshed = items.first(where: { $0.id == selectedItem.id }) {
                self.selectedItem = refreshed
            }
            let healthStart = Date()
            scheduleFileHealthRefresh()
            configureLocalFileEventMonitoring()
            logPerformance("reload.scheduleFileHealthRefresh: \(Self.milliseconds(since: healthStart))ms")
            libraryRevision += 1
            posterRevision += 1
            logPerformance("reload.total: \(Self.milliseconds(since: reloadStart))ms revision=\(libraryRevision) posterRevision=\(posterRevision)")
        } catch {
            showError("加载媒体库失败", error)
        }
    }

    private func rebuildDerivedItemCaches() {
        // Pass 1：识别私密集合 ID — 后续所有过滤依赖此集合。
        let privateCollectionIDs = Set(items.lazy.filter { $0.type == .privateCollection }.map(\.id))

        // Pass 2：单次遍历分拣所有 item，同时收集统计数据。
        // 避免原来 12+ 次独立 filter/reduce 各自遍历全量数组。
        var childrenByParentID: [String: [MediaItem]] = [:]
        var privateItemIDs: Set<String> = []
        var topLevelRaw: [MediaItem] = []
        var privateTopLevelRaw: [MediaItem] = []
        var musicTracksRaw: [MediaItem] = []
        var embyTopLevelRaw: [MediaItem] = []
        var continueWatchingRaw: [MediaItem] = []
        var watchingRaw: [MediaItem] = []
        var privateWatchingRaw: [MediaItem] = []
        var missingMetadataRaw: [MediaItem] = []

        var movieCount = 0
        var seriesCount = 0
        var episodeCount = 0
        var unwatchedCount = 0
        var favoriteCount = 0
        var watchedMovieCount = 0
        var watchedEpisodeCount = 0
        var totalWatchedMinutes = 0

        var availableVideoTypes: Set<MediaType> = []
        var hasVideoFavorite = false
        var hasVideoWatchlist = false
        var hasVideoUnwatched = false
        var hasVideoWatched = false
        var hasWatchingTrace = false

        let watchedThreshold = settings.watchedThreshold
        // 不参与健康检查的来源路径：其条目不计入元数据缺口/重复等健康统计（重新检测时即生效）。
        let healthExcludedSourcePaths = sources.filter { !$0.includeInHealthCheck }.map(\.path)

        for item in items {
            let isEmby = Self.isEmbyItem(item)
            let isPrivate: Bool
            if item.type == .privateCollection {
                privateItemIDs.insert(item.id)
                isPrivate = true
            } else if let parentID = item.parentID, privateCollectionIDs.contains(parentID) {
                privateItemIDs.insert(item.id)
                isPrivate = true
            } else {
                isPrivate = false
            }

            if !isEmby,
               item.type != .music,
               item.hasPlaybackTrace,
               !(item.watched || item.playProgress >= 0.9) {
                if isPrivate {
                    privateWatchingRaw.append(item)
                } else {
                    watchingRaw.append(item)
                }
            }

            if let parentID = item.parentID {
                childrenByParentID[parentID, default: []].append(item)
                // 剧集统计
                if !isPrivate, !isEmby {
                    episodeCount += 1
                    let isWatched = item.watched || item.playProgress >= 0.9
                    if isWatched { watchedEpisodeCount += 1 }
                    if item.type != .music, !isWatched, item.hasPlaybackTrace {
                        hasWatchingTrace = true
                    }
                }
                continue
            }

            // 以下均为顶层 item（parentID == nil）
            if item.type == .privateCollection {
                privateTopLevelRaw.append(item)
                continue
            }

            if !isPrivate, Self.isMissingCoreMetadata(item),
               !Self.sourcePathExcluded(item.sourcePath, in: healthExcludedSourcePaths) {
                missingMetadataRaw.append(item)
            }

            if isEmby {
                if !isPrivate { embyTopLevelRaw.append(item) }
                continue
            }

            if isPrivate { continue }

            if item.type == .music {
                musicTracksRaw.append(item)
                continue
            }

            // 视频顶层
            topLevelRaw.append(item)
            availableVideoTypes.insert(item.type)

            let isWatched = item.watched || item.playProgress >= 0.9
            let isUnwatched = !item.watched && item.playProgress < 0.9

            switch item.type {
            case .movie:
                movieCount += 1
                if isWatched {
                    watchedMovieCount += 1
                    totalWatchedMinutes += item.runtime ?? Int((item.duration ?? 0) / 60)
                }
            default:
                seriesCount += 1
            }
            if isUnwatched { unwatchedCount += 1 }
            if item.favorite { favoriteCount += 1; hasVideoFavorite = true }
            if item.watchlist { hasVideoWatchlist = true }
            if isUnwatched { hasVideoUnwatched = true }
            if isWatched { hasVideoWatched = true }
            if item.type != .music, item.hasPlaybackTrace { hasWatchingTrace = true }

            if item.filePath != nil, item.playProgress > 0, item.playProgress < 0.95 {
                continueWatchingRaw.append(item)
            }
        }

        // 存储 Pass 2 结果
        cachedPrivateItemIDs = privateItemIDs

        // 排序 children（季×集×标题）
        cachedChildrenByParentID = childrenByParentID.mapValues { children in
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

        cachedTopLevelItems = topLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedPrivateTopLevelItems = privateTopLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedMusicTracks = musicTracksRaw.sorted { lhs, rhs in
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
        cachedEmbyTopLevelItems = embyTopLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedContinueWatchingItems = continueWatchingRaw.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        cachedWatchingItems = watchingRaw.sorted(by: Self.playbackRecencySort)
        cachedPrivateWatchingItems = privateWatchingRaw.sorted(by: Self.playbackRecencySort)
        cachedMissingMetadataItems = missingMetadataRaw.sorted { $0.updatedAt > $1.updatedAt }

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

        // #9 下一集：仅针对”用户已经看完过至少一集”的系列，展示其最后一个看完的集之后的那一具体集。
        // 完全没看过任何一集的系列不进入这里（它们属于”未观看”），看到最后一集的系列也不再出现。
        cachedNextUpItems = Array(cachedTopLevelItems.compactMap { series -> MediaItem? in
            guard let episodes = cachedChildrenByParentID[series.id], !episodes.isEmpty else { return nil }
            func isFinished(_ ep: MediaItem) -> Bool { ep.watched || ep.playProgress >= watchedThreshold }
            guard let lastFinishedIndex = episodes.lastIndex(where: isFinished) else { return nil }
            let nextIndex = lastFinishedIndex + 1
            guard episodes.indices.contains(nextIndex) else { return nil }
            let next = episodes[nextIndex]
            guard !isFinished(next) else { return nil }
            return next
        }.prefix(12))

        let duplicateGroups = Dictionary(
            grouping: cachedTopLevelItems.filter { !Self.sourcePathExcluded($0.sourcePath, in: healthExcludedSourcePaths) }
        ) { duplicateKey(for: $0) }
        cachedDuplicateTitleGroups = duplicateGroups.values
            .filter { $0.count > 1 }
            .sorted { $0[0].title.localizedStandardCompare($1[0].title) == .orderedAscending }

        cachedHomeStats = HomeStatsSnapshot(
            movieCount: movieCount,
            seriesCount: seriesCount,
            episodeCount: episodeCount,
            unwatchedCount: unwatchedCount,
            favoriteCount: favoriteCount,
            watchedMovieCount: watchedMovieCount,
            watchedEpisodeCount: watchedEpisodeCount,
            totalWatchedMinutes: totalWatchedMinutes
        )

        // Tab/Section 可见性：用预先建立的 Set<MediaType> 做 O(1) 成员查询，
        // 避免原来对 videoTopLevelItems 做 14 × O(n) 的 .contains { $0.type == .xxx }。
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
                return availableVideoTypes.contains(.movie)
            case .tvShows:
                return availableVideoTypes.contains(.tvShow)
            case .anime:
                return availableVideoTypes.contains(.anime)
            case .documentaries:
                return availableVideoTypes.contains(.documentary)
            case .variety:
                return availableVideoTypes.contains(.variety)
            case .music:
                return !cachedMusicTracks.isEmpty
            case .other:
                return availableVideoTypes.contains(.other)
            case .favorites:
                return hasVideoFavorite
            case .unwatched:
                return hasVideoUnwatched
            case .privacy:
                return !cachedPrivateTopLevelItems.isEmpty
            }
        })

        cachedVisibleVideoSections = VideoLibrarySection.allCases.filter { section in
            switch section {
            case .movies:
                return availableVideoTypes.contains(.movie)
            case .tvShows:
                return availableVideoTypes.contains(.tvShow)
            case .anime:
                return availableVideoTypes.contains(.anime)
            case .documentaries:
                return availableVideoTypes.contains(.documentary)
            case .variety:
                return availableVideoTypes.contains(.variety)
            case .other:
                return availableVideoTypes.contains(.other)
            case .privacy:
                return true
            case .watching:
                return hasWatchingTrace
            case .watchlist:
                return hasVideoWatchlist || cachedEmbyTopLevelItems.contains(where: \.watchlist)
            case .favorites:
                return hasVideoFavorite
            case .unwatched:
                return hasVideoUnwatched
            case .watched:
                return hasVideoWatched
            }
        }

    }

    private static func isMissingCoreMetadata(_ item: MediaItem) -> Bool {
        if item.type == .music {
            return item.posterPath == nil ||
                item.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false ||
                item.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
        }
        return item.posterPath == nil ||
            item.year == nil ||
            item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false
    }

    private nonisolated static func playbackRecencySort(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        (lhs.lastPlayedAt ?? lhs.updatedAt) > (rhs.lastPlayedAt ?? rhs.updatedAt)
    }

    /// 条目的来源路径是否落在"不参与健康检查"的来源里。
    nonisolated static func sourcePathExcluded(_ sourcePath: String?, in excludedPaths: [String]) -> Bool {
        guard let sourcePath, !excludedPaths.isEmpty else { return false }
        return excludedPaths.contains { sourcePath == $0 || sourcePath.hasPrefix("\($0)/") }
    }

    private func scheduleFileHealthRefresh() {
        fileHealthTask?.cancel()
        let refreshID = UUID()
        fileHealthRefreshID = refreshID
        cachedMissingFileItems = []
        cachedSafeMissingFileItemIDs = []
        cachedOfflineSources = []
        cachedOfflineSourceIDs = []

        let itemSnapshots = items
        let sourceSnapshots = sources
        let privateItemIDs = cachedPrivateItemIDs
        // 不参与健康检查的来源：其失效文件与离线状态都不计入。
        let healthExcludedPaths = sourceSnapshots.filter { !$0.includeInHealthCheck }.map(\.path)

        fileHealthTask = Task { [itemSnapshots, sourceSnapshots, privateItemIDs, healthExcludedPaths, refreshID] in
            let healthStart = Date()
            let health = await Task.detached(priority: .utility) {
                let missingItemIDs = Set(itemSnapshots.compactMap { item -> String? in
                    guard !privateItemIDs.contains(item.id),
                          let sourcePath = item.sourcePath,
                          sourceSnapshots.contains(where: {
                              $0.includeInHealthCheck &&
                              (sourcePath == $0.path || sourcePath.hasPrefix("\($0.path)/"))
                          }),
                          !Self.sourcePathExcluded(sourcePath, in: healthExcludedPaths),
                          let filePath = item.filePath,
                          !item.isRemoteResource,
                          !FileManager.default.fileExists(atPath: filePath) else {
                        return nil
                    }
                    return item.id
                })

                let offlineSourceIDs = Set(sourceSnapshots.compactMap { source -> String? in
                    guard source.sourceKind != .emby,
                          source.includeInHealthCheck,
                          !FileManager.default.fileExists(atPath: source.path) else {
                        return nil
                    }
                    return source.id
                })

                let safeMissingItemIDs = Set(itemSnapshots.compactMap { item -> String? in
                    guard missingItemIDs.contains(item.id) else { return nil }
                    guard let sourcePath = item.sourcePath else { return item.id }
                    let source = sourceSnapshots
                        .filter { sourcePath == $0.path || sourcePath.hasPrefix("\($0.path)/") }
                        .max { $0.path.count < $1.path.count }
                    guard let source else { return item.id }
                    return offlineSourceIDs.contains(source.id) ? nil : item.id
                })

                return (
                    missingItemIDs: missingItemIDs,
                    safeMissingItemIDs: safeMissingItemIDs,
                    offlineSourceIDs: offlineSourceIDs
                )
            }.value

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.fileHealthRefreshID == refreshID else { return }
                self.cachedMissingFileItems = itemSnapshots.filter { health.missingItemIDs.contains($0.id) }
                self.cachedSafeMissingFileItemIDs = health.safeMissingItemIDs
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

    func source(for item: MediaItem) -> MediaSource? {
        guard let sourcePath = item.sourcePath else { return nil }
        return sources
            .filter { sourcePath == $0.path || sourcePath.hasPrefix("\($0.path)/") }
            .max { $0.path.count < $1.path.count }
    }

    func canRemoveMissingItemFromIndex(_ item: MediaItem) -> Bool {
        cachedSafeMissingFileItemIDs.contains(item.id)
    }

    func removeMissingItemsFromIndex(_ requestedItems: [MediaItem]) {
        let ids = requestedItems.filter(canRemoveMissingItemFromIndex).map(\.id)
        guard !ids.isEmpty else {
            alert = AppAlert(title: "没有可清理条目", message: "离线媒体源中的条目不会被清理。请先重新挂载或确认媒体源状态。")
            return
        }
        do {
            try mediaRepository?.deleteItems(ids: ids)
            reload()
            alert = AppAlert(title: "索引已清理", message: "已从 MediaLIB 内部索引移除 \(ids.count) 个失效条目，用户媒体文件没有被修改。")
        } catch {
            showError("失效索引清理失败", error)
        }
    }

    /// 合并重复组：保留 keptItem，把同组其余条目（及其子集）从内部索引移除（不动用户文件）。
    func resolveDuplicateGroup(keeping keptItem: MediaItem, in group: [MediaItem]) {
        let removeItems = group.filter { $0.id != keptItem.id }
        guard !removeItems.isEmpty else { return }
        var ids = removeItems.map(\.id)
        for item in removeItems {
            ids.append(contentsOf: children(for: item).map(\.id))
        }
        do {
            try mediaRepository?.deleteItems(ids: Array(Set(ids)))
            reload()
            alert = AppAlert(
                title: "已合并重复项",
                message: "已保留「\(keptItem.title)」，从索引移除其余 \(removeItems.count) 项（用户媒体文件未改动；若重新扫描仍存在的文件可能再次出现）。"
            )
        } catch {
            showError("合并重复项失败", error)
        }
    }

    func refreshLibraryHealth() {
        scheduleFileHealthRefresh()
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
            presentVaultAddedEasterEggIfNeeded(mediaType: mediaType)
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    /// #15 彩蛋：把媒体源添加进保险库后，弹出“注意身体”温馨提示。
    private func presentVaultAddedEasterEggIfNeeded(mediaType: MediaType) {
        guard mediaType == .privateCollection else { return }
        alert = AppAlert(title: "注意身体", message: "")
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
            presentVaultAddedEasterEggIfNeeded(mediaType: mediaType)
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    func connectEmbyServer(server: String, username: String, password: String) async {
        guard !isConnectingEmby else {
            alert = AppAlert(title: "Emby 正在连接", message: "当前连接完成后会自动显示结果。")
            return
        }
        isConnectingEmby = true
        defer { isConnectingEmby = false }

        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else {
            alert = AppAlert(title: "Emby 地址无效", message: "请输入服务器地址，例如 http://192.168.1.20:8096。")
            return
        }
        let normalizedServer = trimmedServer.contains("://") ? trimmedServer : "http://\(trimmedServer)"
        guard let components = URLComponents(string: normalizedServer),
              components.host != nil,
              let serverURL = components.url else {
            alert = AppAlert(title: "Emby 地址无效", message: "无法识别该服务器地址，请检查后重试。")
            return
        }

        let sourceID = UUID().uuidString
        let hostName = serverURL.host ?? "Emby"
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
        let taskID = beginBackgroundTask(
            kind: .embySync,
            source: source,
            detail: "正在登录并同步媒体库",
            isCancellable: false
        )
        var sourceSaved = false
        do {
            let session = try await embyService.authenticate(serverURL: serverURL, username: trimmedUsername, password: password)
            try sourceRepository?.save(source)
            sourceSaved = true
            try remoteCredentialStore.save(
                RemoteSourceCredential(
                    kind: "emby",
                    serverURL: session.serverURL.absoluteString,
                    username: session.username,
                    password: password,
                    accessToken: session.accessToken,
                    userID: session.userID
                ),
                sourceID: sourceID
            )
            try await importEmbyItems(source: source, session: session)
            reload()
            finishBackgroundTask(id: taskID, errors: [])
            alert = AppAlert(title: "Emby 已连接", message: "\(hostName) 的媒体库已同步到 EMBY 目录。")
        } catch {
            if sourceSaved {
                try? sourceRepository?.delete(id: sourceID)
                remoteCredentialStore.delete(sourceID: sourceID)
            }
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            if !presentEmbyRestrictionIfNeeded(error, serverHost: hostName) {
                showError("Emby 连接失败", error)
            }
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
            presentVaultAddedEasterEggIfNeeded(mediaType: mediaType)
        } catch {
            showError("添加网络媒体源失败", error)
        }
    }

    private func refreshEmbySource(_ source: MediaSource) async {
        let taskID = beginBackgroundTask(
            kind: .embySync,
            source: source,
            detail: "正在同步服务端媒体库",
            isCancellable: false
        )
        do {
            try await withValidEmbySession(for: source) { session in
                try await importEmbyItems(source: source, session: session)
            }
            finishBackgroundTask(id: taskID, errors: [])
            reload()
        } catch {
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            if !presentEmbyRestrictionIfNeeded(error, serverHost: Self.embyServerHost(for: source)) {
                showError("Emby 同步失败", error)
            }
        }
    }

    private func importEmbyItems(source: MediaSource, session: EmbySession) async throws {
        guard let mediaRepository else { return }
        let embyItems = try await embyService.fetchItems(session: session, sourceID: source.id, sourcePath: source.path)
        try mediaRepository.replaceRemoteItems(sourcePathPrefix: source.path, with: embyItems)
    }

    private func withValidEmbySession<T>(
        for source: MediaSource,
        operation: (EmbySession) async throws -> T
    ) async throws -> T {
        guard var credential = try remoteCredentialStore.load(sourceID: source.id),
              credential.kind == "emby",
              let serverURL = URL(string: credential.serverURL),
              let accessToken = credential.accessToken,
              let userID = credential.userID else {
            throw NSError(
                domain: "MediaLib.Emby",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的登录信息不存在，请重新连接 Emby。"]
            )
        }
        let session = EmbySession(
            serverURL: serverURL,
            username: credential.username ?? source.name,
            userID: userID,
            accessToken: accessToken
        )
        do {
            return try await operation(session)
        } catch {
            guard embyService.isAuthenticationFailure(error) else { throw error }
            guard let username = credential.username, !username.isEmpty,
                  let password = credential.password else {
                throw NSError(
                    domain: "MediaLib.Emby",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的旧登录凭据无法自动恢复，请删除该媒体源并重新连接一次。"]
                )
            }
            let refreshed = try await embyService.authenticate(
                serverURL: serverURL,
                username: username,
                password: password
            )
            credential.serverURL = refreshed.serverURL.absoluteString
            credential.username = refreshed.username
            credential.accessToken = refreshed.accessToken
            credential.userID = refreshed.userID
            try remoteCredentialStore.save(credential, sourceID: source.id)
            logger?.log("Emby token 已自动恢复：\(source.name)")
            return try await operation(refreshed)
        }
    }

    private func embySource(for item: MediaItem) -> MediaSource? {
        guard Self.isEmbyItem(item) else { return nil }
        return sources.first { source in
            source.sourceKind == .emby &&
            (item.sourcePath == source.path || item.sourcePath?.hasPrefix("\(source.path)/") == true)
        }
    }

    func syncEmbyPlayback(_ report: PlayerPlaybackReport) {
        guard let source = embySource(for: report.item),
              let externalID = report.item.externalID else { return }

        let playSessionID: String
        switch report.phase {
        case .started:
            playSessionID = UUID().uuidString
            embyPlaySessionIDs[report.item.id] = playSessionID
        case .progress:
            playSessionID = embyPlaySessionIDs[report.item.id] ?? UUID().uuidString
            embyPlaySessionIDs[report.item.id] = playSessionID
        case .stopped:
            playSessionID = embyPlaySessionIDs[report.item.id] ?? UUID().uuidString
            embyPlaySessionIDs.removeValue(forKey: report.item.id)
        }

        embyPlaybackSyncTasks[report.item.id]?.cancel()
        embyPlaybackSyncTasks[report.item.id] = Task { [weak self] in
            guard let self else { return }
            do {
                let phase: EmbyPlaybackPhase
                switch report.phase {
                case .started: phase = .started
                case .progress: phase = .progress
                case .stopped: phase = .stopped
                }
                try await self.withValidEmbySession(for: source) { session in
                    try await self.embyService.reportPlayback(
                        session: session,
                        itemID: externalID,
                        playSessionID: playSessionID,
                        phase: phase,
                        position: report.position,
                        duration: report.duration,
                        isPaused: report.isPaused,
                        filePath: report.item.filePath
                    )
                }
            } catch is CancellationError {
                return
            } catch {
                self.logger?.log("Emby 播放状态同步失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    private func syncEmbyFavorite(_ item: MediaItem, favorite: Bool) async throws {
        guard let source = embySource(for: item),
              let externalID = item.externalID else { return }
        try await withValidEmbySession(for: source) { session in
            try await embyService.setFavorite(session: session, itemID: externalID, favorite: favorite)
        }
    }

    private func syncEmbyPlayed(_ item: MediaItem, played: Bool) async throws {
        guard let source = embySource(for: item),
              let externalID = item.externalID else { return }
        try await withValidEmbySession(for: source) { session in
            try await embyService.setPlayed(session: session, itemID: externalID, played: played)
        }
    }

    private func scheduleEmbyPlayedSync(_ items: [MediaItem], played: Bool) {
        let remoteItems = items.filter(Self.isEmbyItem)
        guard !remoteItems.isEmpty else { return }
        Task { [weak self] in
            guard let self else { return }
            var failedCount = 0
            for item in remoteItems {
                do {
                    try await self.syncEmbyPlayed(item, played: played)
                } catch {
                    failedCount += 1
                    self.logger?.log("Emby 已观看状态同步失败：\(error.localizedDescription)", level: .warning)
                }
            }
            if failedCount > 0 {
                self.alert = AppAlert(
                    title: "Emby 状态同步失败",
                    message: "有 \(failedCount) 个条目未能写回 Emby，请检查连接后重新操作。"
                )
            }
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
            invalidateHealthCaches(forSourcePath: source.path, sourceID: source.id)
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
            if !updated.includeInHealthCheck {
                invalidateHealthCaches(forSourcePath: updated.path, sourceID: updated.id)
            }
            reload()
            restartScanIfNeeded(for: updated)
        } catch {
            showError("媒体源更新失败", error)
        }
    }

    private func invalidateHealthCaches(forSourcePath sourcePath: String, sourceID: String) {
        fileHealthTask?.cancel()
        fileHealthRefreshID = UUID()
        cachedMissingFileItems.removeAll { item in
            guard let itemSourcePath = item.sourcePath else { return false }
            return itemSourcePath == sourcePath || itemSourcePath.hasPrefix("\(sourcePath)/")
        }
        cachedSafeMissingFileItemIDs = Set(cachedMissingFileItems.map(\.id)).intersection(cachedSafeMissingFileItemIDs)
        cachedOfflineSourceIDs.remove(sourceID)
        cachedOfflineSources.removeAll { $0.id == sourceID }
    }

    func scanAllSources() {
        let emby = sources.filter { $0.sourceKind == .emby }
        let local = sources.filter { $0.sourceKind != .emby }
        refreshEmbySources(emby)
        startScanQueue(local)
    }

    func scanSources(for destination: SidebarDestination) {
        switch destination {
        case .home, .health, .tasks, .sources, .settings:
            scanAllSources()
        case .embySection, .embyLibrary:
            let emby = sources.filter { $0.sourceKind == .emby }
            guard !emby.isEmpty else {
                alert = AppAlert(title: "无法扫描", message: "当前 EMBY 分类没有可同步的媒体源。")
                return
            }
            refreshEmbySources(emby)
        case .music(.playlists):
            alert = AppAlert(title: "歌单无需扫描", message: "可从歌曲菜单或播放队列中添加歌曲。")
        case .music:
            scanLocalSources(mediaTypes: [.music], emptyMessage: "当前音乐分类没有可扫描的音乐媒体源。")
        case .smartCollection:
            scanLocalSources(mediaTypes: Self.videoScanTypes, emptyMessage: "当前智能集合没有可扫描的本地视频媒体源。")
        case .musicSmartPlaylist:
            scanLocalSources(mediaTypes: [.music], emptyMessage: "当前智能歌单没有可扫描的音乐媒体源。")
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
        case .watching, .watchlist, .favorites, .unwatched, .watched:
            return Self.videoScanTypes
        }
    }

    private func scanLocalSources(mediaTypes: Set<MediaType>, emptyMessage: String) {
        let matchingSources = sources.filter { source in
            source.sourceKind != .emby && mediaTypes.contains(source.mediaType)
        }
        guard !matchingSources.isEmpty else {
            alert = AppAlert(title: "无法扫描", message: "\(emptyMessage) 自动识别来源可在媒体源页面使用“扫描全部”。")
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
        let unreachableSources = sources.filter { !isSourceCurrentlyReachable($0) }
        let remountCandidates = unreachableSources.filter(canAttemptNetworkRemount)

        if !remountCandidates.isEmpty {
            Task { @MainActor in
                var recoveredSources: [MediaSource] = []
                for source in remountCandidates {
                    if await attemptNetworkRemountIfNeeded(for: source) {
                        recoveredSources.append(source)
                    }
                }
                if !recoveredSources.isEmpty {
                    enqueueScanSources(recoveredSources)
                } else if reachableSources.isEmpty && !sources.isEmpty && !silent {
                    alert = AppAlert(title: "无法扫描", message: "已尝试重新挂载网络媒体源，但 macOS 仍无法访问该目录。请确认 NAS 已开机、网络可达且账号密码未变化。")
                }
            }
        }

        guard !reachableSources.isEmpty else {
            if remountCandidates.isEmpty && !sources.isEmpty && !silent {
                alert = AppAlert(title: "无法扫描", message: "所选媒体源不可访问，请确认磁盘或 NAS 已挂载。")
            }
            return
        }
        enqueueScanSources(reachableSources)
    }

    private func enqueueScanSources(_ sources: [MediaSource]) {
        guard !sources.isEmpty else { return }
        if isScanning {
            for source in sources where !pendingScanSources.contains(where: { $0.id == source.id }) {
                pendingScanSources.append(source)
                scanQueueCount += 1
            }
            return
        }
        runScanQueue(sources)
    }

    private func enqueueIncrementalChanges(source: MediaSource, paths: Set<String>) {
        guard !paths.isEmpty, source.sourceKind == .local else { return }
        pendingIncrementalChanges[source.id, default: []].formUnion(paths)
        guard !isScanning else { return }
        runIncrementalScanQueue()
    }

    private func isSourceCurrentlyReachable(_ source: MediaSource) -> Bool {
        source.sourceKind == .emby || FileAccessService.isReachableDirectory(source.path)
    }

    private func canAttemptNetworkRemount(_ source: MediaSource) -> Bool {
        guard source.sourceKind == .smb || source.sourceKind == .ftp else { return false }
        return (try? remoteCredentialStore.load(sourceID: source.id)) != nil
    }

    func canRemountNetworkSource(_ source: MediaSource) -> Bool {
        canAttemptNetworkRemount(source)
    }

    func remountNetworkSource(_ source: MediaSource) {
        guard canAttemptNetworkRemount(source) else {
            alert = AppAlert(title: "无法重新挂载", message: "这个媒体源没有可用于重新挂载的网络地址或凭据。")
            return
        }
        Task { @MainActor in
            let recovered = await attemptNetworkRemountIfNeeded(for: source)
            if recovered {
                cachedOfflineSourceIDs.remove(source.id)
                cachedOfflineSources.removeAll { $0.id == source.id }
                libraryRevision += 1
                configureLocalFileEventMonitoring()
                alert = AppAlert(title: "已重新挂载", message: "\(source.name) 已恢复访问，可以继续扫描或播放。")
            } else {
                alert = AppAlert(title: "重新挂载失败", message: "macOS 仍无法访问 \(source.name)。请确认远程设备已开机、网络可达且账号密码没有变化。")
            }
        }
    }

    private func attemptNetworkRemountIfNeeded(for source: MediaSource) async -> Bool {
        if isSourceCurrentlyReachable(source) { return true }
        guard !remountingNetworkSourceIDs.contains(source.id) else { return false }
        remountingNetworkSourceIDs.insert(source.id)
        defer { remountingNetworkSourceIDs.remove(source.id) }

        guard let credential = try? remoteCredentialStore.load(sourceID: source.id),
              let mountURL = networkMountURL(for: credential) else {
            return false
        }

        logger?.log("尝试重新挂载网络媒体源：\(source.name) \(source.path)")
        guard NSWorkspace.shared.open(mountURL) else {
            logger?.log("触发网络媒体源挂载失败：\(source.name) \(credential.serverURL)", level: .warning)
            return false
        }

        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if isSourceCurrentlyReachable(source) {
                logger?.log("网络媒体源已重新挂载：\(source.name) \(source.path)")
                return true
            }
        }
        logger?.log("网络媒体源重新挂载超时：\(source.name) \(source.path)", level: .warning)
        return false
    }

    private func networkMountURL(for credential: RemoteSourceCredential) -> URL? {
        guard var components = URLComponents(string: credential.serverURL),
              let scheme = components.scheme?.lowercased(),
              ["smb", "ftp", "ftps"].contains(scheme),
              components.host != nil else {
            return nil
        }
        if let username = credential.username, !username.isEmpty {
            components.user = username
            if let password = credential.password, !password.isEmpty {
                components.password = password
            }
        }
        return components.url
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
                let taskID = await MainActor.run { () -> UUID in
                    self.activeScanSourceID = source.id
                    self.scanQueueCount = queue.count + self.pendingScanSources.count + 1
                    return self.beginBackgroundTask(
                        kind: .fullScan,
                        source: source,
                        detail: source.displayPath
                    )
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
                        self?.updateBackgroundTask(id: taskID, with: progress)
                    }
                }
                allErrors.append(contentsOf: summary.errors)
                await MainActor.run {
                    guard self.scanRunID == runID else { return }
                    self.finishBackgroundTask(id: taskID, errors: summary.errors)
                }
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
                let incrementalChanges = self.pendingIncrementalChanges
                self.pendingIncrementalChanges.removeAll()
                self.activeScanSourceID = nil
                self.isScanning = false
                self.scanQueueCount = 0
                self.scanProgress = nil
                self.reload()
                if let firstError = allErrors.first {
                    self.alert = AppAlert(title: "扫描完成但有错误", message: firstError)
                }
                for (sourceID, paths) in incrementalChanges {
                    self.pendingIncrementalChanges[sourceID, default: []].formUnion(paths)
                }
                if !self.pendingIncrementalChanges.isEmpty {
                    self.runIncrementalScanQueue()
                }
            }
        }
    }

    private func runIncrementalScanQueue() {
        guard let mediaRepository, let directories, !pendingIncrementalChanges.isEmpty else { return }
        scanTask?.cancel()
        let runID = UUID()
        scanRunID = runID
        let queuedChanges = pendingIncrementalChanges
        pendingIncrementalChanges.removeAll()
        isScanning = true
        scanQueueCount = queuedChanges.count

        scanTask = Task { [settings, logger] in
            var allErrors: [String] = []
            let progressThrottler = ScanProgressThrottler()
            for (sourceID, paths) in queuedChanges {
                if Task.isCancelled { return }
                guard let source = await MainActor.run(body: {
                    self.sources.first { $0.id == sourceID && $0.sourceKind == .local }
                }) else {
                    continue
                }
                guard FileAccessService.isReachableDirectory(source.path) else {
                    logger?.log("增量扫描跳过不可访问来源：\(source.name)", level: .warning)
                    continue
                }
                progressThrottler.reset()
                let taskID = await MainActor.run { () -> UUID in
                    self.activeScanSourceID = source.id
                    self.scanQueueCount = max(1, self.scanQueueCount)
                    return self.beginBackgroundTask(
                        kind: .incrementalScan,
                        source: source,
                        detail: "\(paths.count) 个文件变化"
                    )
                }
                let scanner = MediaScanner(
                    thumbnailGenerator: ThumbnailGenerator(outputDirectory: directories.thumbnails, logger: logger),
                    mediaRepository: mediaRepository,
                    logger: logger
                )
                let summary = await scanner.scanChanges(
                    source: source,
                    changedPaths: Array(paths),
                    settings: settings
                ) { [weak self] progress in
                    guard progressThrottler.shouldPublish(progress) else { return }
                    Task { @MainActor in
                        guard self?.scanRunID == runID else { return }
                        self?.scanProgress = progress
                        self?.updateBackgroundTask(id: taskID, with: progress)
                    }
                }
                allErrors.append(contentsOf: summary.errors)
                await MainActor.run {
                    guard self.scanRunID == runID else { return }
                    self.scanQueueCount = max(0, self.scanQueueCount - 1)
                    self.finishBackgroundTask(id: taskID, errors: summary.errors)
                }
            }
            await MainActor.run {
                guard self.scanRunID == runID else { return }
                let fullScans = self.pendingScanSources
                self.pendingScanSources.removeAll()
                self.activeScanSourceID = nil
                self.isScanning = false
                self.scanQueueCount = 0
                self.scanProgress = nil
                self.reload()
                if let firstError = allErrors.first {
                    self.alert = AppAlert(title: "增量扫描完成但有错误", message: firstError)
                }
                if !fullScans.isEmpty {
                    self.startScanQueue(fullScans, silent: true)
                } else if !self.pendingIncrementalChanges.isEmpty {
                    self.runIncrementalScanQueue()
                }
            }
        }
    }

    func cancelScanning() {
        guard isScanning else { return }
        scanTask?.cancel()
        scanRunID = UUID()
        pendingScanSources.removeAll()
        pendingIncrementalChanges.removeAll()
        activeScanSourceID = nil
        scanProgress = nil
        isScanning = false
        scanQueueCount = 0
        markCancellableBackgroundTasksCancelled()
        reload()
    }

    func clearCompletedBackgroundTasks() {
        backgroundTasks.removeAll { !$0.state.isActive }
    }

    private func beginBackgroundTask(
        kind: BackgroundTaskKind,
        source: MediaSource,
        detail: String?,
        isCancellable: Bool = true
    ) -> UUID {
        let task = BackgroundTaskSnapshot(
            kind: kind,
            state: .running,
            title: "\(kind.title) · \(source.name)",
            detail: detail,
            progress: kind == .embySync ? nil : 0,
            isCancellable: isCancellable,
            hidesDetail: source.mediaType == .privateCollection
        )
        backgroundTasks.insert(task, at: 0)
        if backgroundTasks.count > 40 {
            backgroundTasks.removeLast(backgroundTasks.count - 40)
        }
        return task.id
    }

    private func updateBackgroundTask(id: UUID, with progress: ScanProgress) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = backgroundTasks[index].progress ?? 0
        let next = progress.fraction
        guard next >= 1 || abs(next - previous) >= 0.025 else { return }
        backgroundTasks[index].progress = next
    }

    private func finishBackgroundTask(id: UUID, errors: [String]) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = errors.isEmpty ? .completed : .failed
        backgroundTasks[index].detail = backgroundTasks[index].hidesDetail ? nil : (errors.first ?? backgroundTasks[index].detail)
        backgroundTasks[index].progress = 1
        backgroundTasks[index].finishedAt = Date()
        backgroundTasks[index].isCancellable = false
        notifyTaskCompletionIfNeeded(backgroundTasks[index], errors: errors)
    }

    /// 后台任务完成后按需发系统通知：仅在开关开启、App 非前台、且为完整扫描 / Emby 同步 / 失败时提醒，
    /// 避免频繁的增量扫描刷屏。
    private func notifyTaskCompletionIfNeeded(_ task: BackgroundTaskSnapshot, errors: [String]) {
        guard settings.notifyOnTaskCompletion else { return }
        guard !NSApplication.shared.isActive else { return }
        let failed = !errors.isEmpty
        guard failed || task.kind == .fullScan || task.kind == .embySync else { return }
        let title = task.title + (failed ? " · 有错误" : " · 已完成")
        let body: String
        if failed {
            body = errors.first ?? "任务执行过程中出现错误。"
        } else {
            body = "\(task.title)已完成。"
        }
        SystemNotificationCenter.post(title: title, body: body)
    }

    /// 首次启动引导完成 / 跳过后调用：标记完成，不再弹出。
    func completeOnboarding() {
        guard !settings.hasCompletedOnboarding else { return }
        settings.hasCompletedOnboarding = true
        saveSettings()
    }

    /// 设置页「重新查看引导」：驱动 ContentView 再次弹出引导。
    @Published var onboardingReplayRequested = false
    func replayOnboarding() {
        onboardingReplayRequested = true
    }

    /// 设置页开关：开启时立即向系统申请通知授权；被拒则回退关闭并提示。
    func setTaskCompletionNotifications(_ enabled: Bool) {
        settings.notifyOnTaskCompletion = enabled
        saveSettings()
        guard enabled else { return }
        SystemNotificationCenter.requestAuthorization { [weak self] granted in
            guard let self, !granted else { return }
            self.settings.notifyOnTaskCompletion = false
            self.saveSettings()
            self.alert = AppAlert(
                title: "未获得通知权限",
                message: "请在「系统设置 → 通知 → MediaLIB」中允许通知后再开启此功能。"
            )
        }
    }

    private func markCancellableBackgroundTasksCancelled() {
        for index in backgroundTasks.indices where backgroundTasks[index].state.isActive && backgroundTasks[index].isCancellable {
            backgroundTasks[index].state = .cancelled
            backgroundTasks[index].finishedAt = Date()
            backgroundTasks[index].isCancellable = false
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
        markCancellableBackgroundTasksCancelled()
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
        if Self.isEmbyItem(item) {
            Task { [weak self] in
                guard let self else { return }
                do {
                    let preparedItem = try await self.prepareEmbyItemForPlayback(item)
                    self.playPreparedItem(preparedItem, preserveSelection: preserveSelection)
                } catch {
                    let host = self.embySource(for: item).map(AppState.embyServerHost(for:)) ?? (item.sourcePath ?? "Emby")
                    if !self.presentEmbyRestrictionIfNeeded(error, serverHost: host) {
                        self.showError("Emby 播放准备失败", error)
                    }
                }
            }
            return
        }
        playPreparedItem(item, preserveSelection: preserveSelection)
    }

    private func prepareEmbyItemForPlayback(_ item: MediaItem) async throws -> MediaItem {
        guard let source = embySource(for: item) else { return item }
        return try await withValidEmbySession(for: source) { session in
            try await embyService.validateSession(session)
            var prepared = item
            prepared.filePath = embyService.refreshedResourceURLString(item.filePath, session: session)
            return prepared
        }
    }

    private func playPreparedItem(_ item: MediaItem, preserveSelection: Bool) {
        if item.type == .music {
            incrementMusicPlayCount(item)
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

    func nextMusicItemForPreloading(after item: MediaItem) -> MediaItem? {
        guard item.type == .music,
              let nextID = MusicQueuePreloadPolicy.nextItemID(
                queueIDs: musicQueue.map(\.id),
                currentItemID: item.id,
                repeatModeRawValue: musicRepeatMode.rawValue,
                shuffleEnabled: musicShuffleEnabled
              ) else {
            return nil
        }
        return musicQueue.first { $0.id == nextID }
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
        scheduleMusicQueuePersistence()
    }

    func addToMusicQueue(_ item: MediaItem) {
        guard item.type == .music else { return }
        if musicQueue.isEmpty, let active = activePlayerItem, active.type == .music {
            prepareMusicQueue(for: active)
        }
        guard !musicQueue.contains(where: { $0.id == item.id }) else { return }
        musicQueue.append(item)
        scheduleMusicQueuePersistence()
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
        scheduleMusicQueuePersistence()
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
        scheduleMusicQueuePersistence()

        // 专辑/歌单/电台播放走的是 presentBuiltInPlayer 直连，不经过 playPreparedItem，
        // 因此这里需要补记首曲的播放次数并启动 Last.fm 打卡——否则整组的第一首永远不计数、不打卡。
        incrementMusicPlayCount(startItem)

        if settings.musicDefaultPlayer == .external {
            openExternally(startItem)
        } else {
            presentBuiltInPlayer(startItem)
        }
    }

    // MARK: - 电台（B5）

    /// 以某首歌为种子开始电台：从本地曲库按「同艺人 > 同风格 > 其它」加权采样，生成一条连续播放队列。
    /// 同艺人=艺人电台，配合风格权重即得相似度电台。
    func startRadio(seed: MediaItem) {
        guard seed.type == .music else { return }
        let pool = musicTracks
        let radio = buildRadioQueue(seed: seed, pool: pool, limit: 60)
        guard radio.count > 1 else {
            alert = AppAlert(title: "曲库太小", message: "可播放的本地歌曲不足，无法生成电台。")
            return
        }
        replaceMusicQueueAndPlay(radio, startingAt: seed)
    }

    /// 以某个风格为主题开始电台：随机选一首该风格歌曲作种子。
    func startGenreRadio(_ genre: String) {
        let target = genre.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return }
        let matches = musicTracks.filter { Self.genreSet($0).contains(target) }
        guard let seed = matches.randomElement() else {
            alert = AppAlert(title: "暂无该风格歌曲", message: "本地曲库中没有标记为「\(genre)」的歌曲。")
            return
        }
        startRadio(seed: seed)
    }

    /// 以某位艺人为主题开始电台：随机选一首该艺人歌曲作种子。
    func startArtistRadio(artistName: String) {
        let target = artistName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return }
        let matches = musicTracks.filter {
            ($0.artist?.trimmingCharacters(in: .whitespaces).lowercased() == target) && $0.filePath != nil
        }
        guard let seed = matches.randomElement() else {
            alert = AppAlert(title: "暂无该艺人歌曲", message: "本地曲库中没有「\(artistName)」的可播放歌曲。")
            return
        }
        startRadio(seed: seed)
    }

    /// 本地曲库中是否有该艺人的可播放歌曲（用于决定是否展示艺人电台入口）。
    func hasPlayableTracks(forArtist artistName: String) -> Bool {
        let target = artistName.trimmingCharacters(in: .whitespaces).lowercased()
        guard !target.isEmpty else { return false }
        return musicTracks.contains {
            ($0.artist?.trimmingCharacters(in: .whitespaces).lowercased() == target) && $0.filePath != nil
        }
    }

    private static func genreSet(_ item: MediaItem) -> Set<String> {
        guard let genre = item.genre else { return [] }
        return Set(
            genre.components(separatedBy: ", ")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
                .filter { !$0.isEmpty }
        )
    }

    /// 加权无放回采样：同艺人 +6、同风格 +3、基础 1，从种子相关度高到低自然铺开，同权重内随机。
    private func buildRadioQueue(seed: MediaItem, pool: [MediaItem], limit: Int) -> [MediaItem] {
        let seedGenres = Self.genreSet(seed)
        let seedArtist = seed.artist?.trimmingCharacters(in: .whitespaces).lowercased()
        var weighted: [(item: MediaItem, weight: Double)] = pool.compactMap { track in
            guard track.id != seed.id, track.filePath != nil else { return nil }
            var weight = 1.0
            if let seedArtist, !seedArtist.isEmpty,
               let artist = track.artist?.trimmingCharacters(in: .whitespaces).lowercased(),
               artist == seedArtist {
                weight += 6
            }
            if !seedGenres.isEmpty, !seedGenres.isDisjoint(with: Self.genreSet(track)) {
                weight += 3
            }
            return (track, weight)
        }

        var result: [MediaItem] = [seed]
        var generator = SystemRandomNumberGenerator()
        while result.count < limit, !weighted.isEmpty {
            let total = weighted.reduce(0.0) { $0 + $1.weight }
            var threshold = Double.random(in: 0..<total, using: &generator)
            var pickIndex = weighted.count - 1
            for (index, entry) in weighted.enumerated() {
                threshold -= entry.weight
                if threshold < 0 {
                    pickIndex = index
                    break
                }
            }
            result.append(weighted[pickIndex].item)
            weighted.remove(at: pickIndex)
        }
        return result
    }

    func clearMusicQueue(keepingCurrent: Bool = true) {
        if keepingCurrent, let active = activePlayerItem, active.type == .music {
            musicQueue = [active]
        } else {
            musicQueue.removeAll()
        }
        scheduleMusicQueuePersistence()
    }

    func moveMusicQueueItems(fromOffsets: IndexSet, toOffset: Int) {
        musicQueue.move(fromOffsets: fromOffsets, toOffset: toOffset)
        scheduleMusicQueuePersistence()
    }

    func sendPlaybackCommand(_ command: PlaybackCommand) {
        playbackCommandRequest = PlaybackCommandRequest(command: command)
    }

    func toggleMusicShuffle() {
        musicShuffleEnabled.toggle()
        scheduleMusicQueuePersistence()
    }

    func cycleMusicRepeatMode() {
        musicRepeatMode = musicRepeatMode.next
        scheduleMusicQueuePersistence()
    }

    func presentBuiltInPlayer(_ item: MediaItem, preserveSelection: Bool = false) {
        if !preserveSelection {
            selectedItem = nil
        }
        quickPreviewItem = nil
        guard item.type != .music else {
            activePlayerItem = item
            triggerSakuraEasterEggIfNeeded(for: item)
            return
        }
        activePlayerItem = item
    }

    /// #14 当播放的歌曲歌名包含「アゲイン」时，触发樱花纷飞特效（持续 5 秒），
    /// 每次启动软件只在首次播放该类歌曲时出现一次。
    private func triggerSakuraEasterEggIfNeeded(for item: MediaItem) {
        guard !sakuraEasterEggShownThisLaunch else { return }
        guard item.type == .music else { return }
        let matches = item.title.contains("アゲイン") || (item.originalTitle?.contains("アゲイン") ?? false)
        guard matches else { return }
        sakuraEasterEggShownThisLaunch = true
        sakuraEasterEggActive = true
        sakuraEasterEggTask?.cancel()
        sakuraEasterEggTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            self.sakuraEasterEggActive = false
        }
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
        scheduleMusicQueuePersistence()
    }

    private func restoreMusicQueueState() {
        guard let musicQueueRepository else {
            didRestoreMusicQueue = true
            return
        }
        do {
            let snapshot = try musicQueueRepository.fetch()
            let tracksByID = Dictionary(uniqueKeysWithValues: items.lazy.filter { $0.type == .music }.map { ($0.id, $0) })
            musicQueue = snapshot.itemIDs.compactMap { tracksByID[$0] }
            musicRepeatMode = MusicRepeatMode(rawValue: snapshot.repeatModeRawValue) ?? .sequential
            musicShuffleEnabled = snapshot.shuffleEnabled
            didRestoreMusicQueue = true
            if musicQueue.count != snapshot.itemIDs.count {
                scheduleMusicQueuePersistence()
            }
        } catch {
            didRestoreMusicQueue = true
            logger?.log("音乐播放队列恢复失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func reconcileMusicQueueWithLibrary() {
        guard !musicQueue.isEmpty else { return }
        let previousIDs = musicQueue.map(\.id)
        let tracksByID = Dictionary(uniqueKeysWithValues: items.lazy.filter { $0.type == .music }.map { ($0.id, $0) })
        musicQueue = previousIDs.compactMap { tracksByID[$0] }
        if musicQueue.map(\.id) != previousIDs {
            scheduleMusicQueuePersistence()
        }
    }

    private func scheduleMusicQueuePersistence() {
        guard didRestoreMusicQueue, let musicQueueRepository else { return }
        let snapshot = MusicQueueSnapshot(
            itemIDs: musicQueue.map(\.id),
            repeatModeRawValue: musicRepeatMode.rawValue,
            shuffleEnabled: musicShuffleEnabled
        )
        musicQueuePersistenceTask?.cancel()
        musicQueuePersistenceTask = Task { [weak self, musicQueueRepository] in
            do {
                try await Task.sleep(nanoseconds: 220_000_000)
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try musicQueueRepository.save(snapshot)
                }.value
            } catch is CancellationError {
                return
            } catch {
                self?.logger?.log("音乐播放队列保存失败：\(error.localizedDescription)", level: .warning)
            }
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

    func playbackMarkers(for item: MediaItem) -> [PlaybackMarker] {
        do {
            return try playbackMarkerRepository?.fetch(mediaID: item.id) ?? []
        } catch {
            logger?.log("读取播放标记失败：\(error.localizedDescription)", level: .warning)
            return []
        }
    }

    @discardableResult
    func savePlaybackMarker(_ marker: PlaybackMarker) -> PlaybackMarker? {
        do {
            return try playbackMarkerRepository?.save(marker)
        } catch {
            showError("保存播放标记失败", error)
            return nil
        }
    }

    func deletePlaybackMarker(_ marker: PlaybackMarker) {
        do {
            try playbackMarkerRepository?.delete(id: marker.id)
        } catch {
            showError("删除播放标记失败", error)
        }
    }

    func replaceEmbeddedPlaybackChapters(for item: MediaItem, chapters: [PlaybackMarker]) {
        do {
            try playbackMarkerRepository?.replaceEmbeddedChapters(mediaID: item.id, with: chapters)
        } catch {
            logger?.log("同步内嵌章节失败：\(error.localizedDescription)", level: .warning)
        }
    }

    func clearPlaybackHistory(_ item: MediaItem) {
        do {
            try mediaRepository?.clearPlaybackHistory(id: item.id)
            clearPlaybackHistoryInMemory(ids: [item.id])
            scheduleEmbyPlayedSync([item], played: false)
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
            scheduleEmbyPlayedSync(items, played: false)
        } catch {
            showError("播放记录删除失败", error)
        }
    }

    func resetMusicPlayCount(_ item: MediaItem) {
        guard item.type == .music else { return }
        do {
            try mediaRepository?.resetPlayCount(id: item.id)
            updateMusicPlayCountsInMemory(ids: [item.id], reset: true)
        } catch {
            showError("播放次数重置失败", error)
        }
    }

    func resetMusicPlayCounts(_ tracks: [MediaItem]) {
        let ids = tracks.filter { $0.type == .music }.map(\.id)
        guard !ids.isEmpty else { return }
        do {
            try mediaRepository?.resetPlayCounts(ids: ids)
            updateMusicPlayCountsInMemory(ids: ids, reset: true)
        } catch {
            showError("播放次数重置失败", error)
        }
    }

    func resetAllMusicPlayCounts() {
        resetMusicPlayCounts(musicTracks)
    }

    private func incrementMusicPlayCount(_ item: MediaItem) {
        guard item.type == .music else { return }
        scrobbleMusicStart(item)
        do {
            try mediaRepository?.incrementPlayCount(id: item.id)
            updateMusicPlayCountsInMemory(ids: [item.id], reset: false, bumpRevision: false)
        } catch {
            logger?.log("播放次数更新失败：\(error.localizedDescription)", level: .warning)
        }
    }

    // MARK: - Last.fm 听歌打卡（B2）

    private var lastfmService: LastfmScrobbleService? {
        let key = settings.lastfmAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = settings.lastfmSharedSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !key.isEmpty, !secret.isEmpty else { return nil }
        return LastfmScrobbleService(apiKey: key, sharedSecret: secret)
    }

    var isLastfmConnected: Bool {
        !(settings.lastfmSessionKey?.isEmpty ?? true)
    }

    /// 新曲目开始：先结算上一首，再对当前曲目发送 updateNowPlaying 并登记候选。
    private func scrobbleMusicStart(_ item: MediaItem) {
        finalizeScrobble()
        guard settings.lastfmScrobblingEnabled,
              let sessionKey = settings.lastfmSessionKey, !sessionKey.isEmpty,
              let service = lastfmService,
              let artist = item.artist, !artist.isEmpty else {
            pendingScrobble = nil
            return
        }
        let duration = item.duration ?? Double((item.runtime ?? 0) * 60)
        pendingScrobble = (item: item, startedAt: Date(), duration: duration)

        let track = item.title
        let album = item.album
        let durationSeconds = duration > 0 ? Int(duration) : nil
        Task { [weak self] in
            do {
                try await service.updateNowPlaying(
                    artist: artist, track: track, album: album,
                    durationSeconds: durationSeconds, sessionKey: sessionKey
                )
            } catch {
                self?.logger?.log("Last.fm updateNowPlaying 失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// 结算待打卡曲目：满足时长门槛（>30s 且播放过半或满 4 分钟）才提交 track.scrobble。
    func finalizeScrobble() {
        guard let candidate = pendingScrobble else { return }
        pendingScrobble = nil
        guard settings.lastfmScrobblingEnabled,
              let sessionKey = settings.lastfmSessionKey, !sessionKey.isEmpty,
              let service = lastfmService,
              let artist = candidate.item.artist, !artist.isEmpty else { return }

        let duration = candidate.duration
        // 时长未知时按播放满 30s 估计；已知时按官方门槛：过半或满 4 分钟。
        let elapsed = min(Date().timeIntervalSince(candidate.startedAt), duration > 0 ? duration : .greatestFiniteMagnitude)
        let threshold: Double = duration > 0 ? min(duration / 2, 240) : 30
        guard duration <= 0 || duration > 30, elapsed >= threshold else { return }

        let timestamp = Int(candidate.startedAt.timeIntervalSince1970)
        let track = candidate.item.title
        let album = candidate.item.album
        let durationSeconds = duration > 0 ? Int(duration) : nil
        Task { [weak self] in
            do {
                try await service.scrobble(
                    artist: artist, track: track, album: album,
                    timestamp: timestamp, durationSeconds: durationSeconds, sessionKey: sessionKey
                )
                self?.logger?.log("Last.fm 已打卡：\(artist) - \(track)")
            } catch {
                self?.logger?.log("Last.fm scrobble 失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    /// 设置页：第一步——获取 token 并打开浏览器授权页。
    func beginLastfmAuthorization() {
        guard let service = lastfmService else {
            alert = AppAlert(title: "缺少凭据", message: "请先填写 Last.fm API Key 与 Shared Secret。")
            return
        }
        guard !isLastfmAuthorizing else { return }
        isLastfmAuthorizing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLastfmAuthorizing = false }
            do {
                let token = try await service.fetchToken()
                self.lastfmPendingAuthToken = token
                if let url = service.authorizationURL(token: token) {
                    NSWorkspace.shared.open(url)
                }
                self.alert = AppAlert(
                    title: "请在浏览器中授权",
                    message: "已打开 Last.fm 授权页。点击“允许访问”后，回到这里点击「完成连接」。"
                )
            } catch {
                self.showError("Last.fm 授权失败", error)
            }
        }
    }

    /// 设置页：第二步——用户授权后用 token 换 session key 并保存。
    func completeLastfmAuthorization() {
        guard let service = lastfmService else { return }
        guard let token = lastfmPendingAuthToken else {
            alert = AppAlert(title: "尚未开始授权", message: "请先点击「授权」并在浏览器中确认。")
            return
        }
        guard !isLastfmAuthorizing else { return }
        isLastfmAuthorizing = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isLastfmAuthorizing = false }
            do {
                let session = try await service.fetchSession(token: token)
                self.settings.lastfmSessionKey = session.sessionKey
                self.settings.lastfmUsername = session.username
                self.lastfmPendingAuthToken = nil
                self.saveSettings()
                self.alert = AppAlert(title: "Last.fm 已连接", message: "已连接账号 \(session.username)，开始播放音乐即可自动打卡。")
            } catch {
                self.showError("Last.fm 连接失败", error)
            }
        }
    }

    func disconnectLastfm() {
        settings.lastfmSessionKey = nil
        settings.lastfmUsername = nil
        lastfmPendingAuthToken = nil
        saveSettings()
    }

    // MARK: - Trakt 同步（Phase 4）

    @Published var isTraktConnecting = false
    private var traktPollTask: Task<Void, Never>?

    private var traktService: TraktService? {
        let id = settings.traktClientID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let secret = settings.traktClientSecret?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !id.isEmpty, !secret.isEmpty else { return nil }
        return TraktService(clientID: id, clientSecret: secret)
    }

    var isTraktConnected: Bool {
        !(settings.traktAccessToken?.isEmpty ?? true)
    }

    /// 设备码授权：请求 code → 打开浏览器 → 提示验证码 → 轮询直至授权或超时。
    func beginTraktConnect() {
        guard let service = traktService else {
            alert = AppAlert(title: "缺少凭据", message: "请先填写 Trakt Client ID 与 Client Secret。")
            return
        }
        guard !isTraktConnecting else { return }
        isTraktConnecting = true
        traktPollTask?.cancel()
        traktPollTask = Task { [weak self] in
            guard let self else { return }
            defer { self.isTraktConnecting = false }
            do {
                let device = try await service.requestDeviceCode()
                if let url = URL(string: device.verificationURL) { NSWorkspace.shared.open(url) }
                self.alert = AppAlert(
                    title: "在 Trakt 输入验证码",
                    message: "已打开 \(device.verificationURL)\n请输入验证码：\(device.userCode)\n授权后将自动完成连接。"
                )
                let deadline = Date().addingTimeInterval(Double(device.expiresIn))
                let interval = UInt64(max(device.interval, 1)) * 1_000_000_000
                while Date() < deadline {
                    try? await Task.sleep(nanoseconds: interval)
                    if Task.isCancelled { return }
                    do {
                        let tokens = try await service.pollOnce(deviceCode: device.deviceCode)
                        self.settings.traktAccessToken = tokens.accessToken
                        self.settings.traktRefreshToken = tokens.refreshToken
                        self.settings.traktSyncEnabled = true
                        self.saveSettings()
                        self.alert = AppAlert(title: "Trakt 已连接", message: "之后标记已看 / 想看会自动同步到 Trakt。")
                        return
                    } catch TraktError.authorizationPending {
                        continue
                    } catch TraktError.authorizationExpired {
                        self.alert = AppAlert(title: "授权超时", message: "验证码已过期，请重新连接。")
                        return
                    } catch TraktError.authorizationDenied {
                        self.alert = AppAlert(title: "已取消", message: "你拒绝了 Trakt 授权。")
                        return
                    } catch {
                        self.alert = AppAlert(title: "连接失败", message: error.localizedDescription)
                        return
                    }
                }
                self.alert = AppAlert(title: "授权超时", message: "未在有效期内完成授权，请重新连接。")
            } catch {
                self.showError("Trakt 连接失败", error)
            }
        }
    }

    func disconnectTrakt() {
        traktPollTask?.cancel()
        settings.traktAccessToken = nil
        settings.traktRefreshToken = nil
        settings.traktSyncEnabled = false
        saveSettings()
    }

    func setTraktSyncEnabled(_ enabled: Bool) {
        settings.traktSyncEnabled = enabled
        saveSettings()
    }

    /// 带令牌的 Trakt 操作；遇 401 自动刷新令牌后重试一次。
    private func runTrakt(_ operation: (TraktService, String) async throws -> Void) async {
        guard let service = traktService, let token = settings.traktAccessToken, !token.isEmpty else { return }
        do {
            try await operation(service, token)
        } catch TraktError.requestFailed(401) {
            guard let refresh = settings.traktRefreshToken, !refresh.isEmpty else { return }
            do {
                let tokens = try await service.refreshTokens(refresh)
                settings.traktAccessToken = tokens.accessToken
                settings.traktRefreshToken = tokens.refreshToken
                saveSettings()
                try await operation(service, tokens.accessToken)
            } catch {
                logger?.log("Trakt 刷新令牌失败：\(error.localizedDescription)", level: .warning)
            }
        } catch {
            logger?.log("Trakt 同步失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private static func tmdbNumericID(_ externalID: String?, kind: String) -> Int? {
        let prefix = "tmdb:\(kind):"
        guard let externalID, externalID.hasPrefix(prefix) else { return nil }
        return Int(externalID.dropFirst(prefix.count))
    }

    private func traktHistoryRef(for item: MediaItem) -> TraktMediaRef? {
        switch item.type {
        case .movie:
            return Self.tmdbNumericID(item.externalID, kind: "movie").map { .movie(tmdbID: $0) }
        case .episode:
            guard let season = item.seasonNumber, let episode = item.episodeNumber,
                  let parentID = item.parentID,
                  let parent = items.first(where: { $0.id == parentID }),
                  let showID = Self.tmdbNumericID(parent.externalID, kind: "tv") else { return nil }
            return .episode(showTmdbID: showID, season: season, episode: episode)
        default:
            return nil
        }
    }

    private func traktWatchlistRef(for item: MediaItem) -> TraktMediaRef? {
        switch item.type {
        case .movie:
            return Self.tmdbNumericID(item.externalID, kind: "movie").map { .movie(tmdbID: $0) }
        case .tvShow:
            return Self.tmdbNumericID(item.externalID, kind: "tv").map { .show(tmdbID: $0) }
        default:
            return nil
        }
    }

    /// 标记已看 / 取消已看后推送到 Trakt 历史。
    func syncTraktHistory(_ items: [MediaItem], watched: Bool) {
        guard settings.traktSyncEnabled, isTraktConnected else { return }
        let refs = items.compactMap { traktHistoryRef(for: $0) }
        guard !refs.isEmpty else { return }
        Task { [weak self] in
            await self?.runTrakt { service, token in
                if watched {
                    try await service.addToHistory(refs, accessToken: token)
                } else {
                    try await service.removeFromHistory(refs, accessToken: token)
                }
            }
        }
    }

    /// 加入 / 移出想看后推送到 Trakt 想看清单。
    func syncTraktWatchlist(_ item: MediaItem, add: Bool) {
        guard settings.traktSyncEnabled, isTraktConnected,
              let ref = traktWatchlistRef(for: item) else { return }
        Task { [weak self] in
            await self?.runTrakt { service, token in
                if add {
                    try await service.addToWatchlist([ref], accessToken: token)
                } else {
                    try await service.removeFromWatchlist([ref], accessToken: token)
                }
            }
        }
    }

    private func updateMusicPlayCountsInMemory(ids: [String], reset: Bool, bumpRevision: Bool = true) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }

        func updated(_ item: MediaItem) -> MediaItem {
            guard targetIDs.contains(item.id), item.type == .music else { return item }
            var copy = item
            copy.playCount = reset ? 0 : ((copy.playCount ?? 0) + 1)
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
        if bumpRevision {
            libraryRevision += 1
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
                try await self?.syncEmbyFavorite(item, favorite: nextFavorite)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    try? mediaRepository.setFavorite(id: item.id, favorite: currentFavorite)
                    self.updateFavoriteInMemory(id: item.id, favorite: currentFavorite)
                    self.showError(Self.isEmbyItem(item) ? "Emby 收藏同步失败" : "喜欢状态更新失败", error)
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
        if let parentID = items.first(where: { $0.id == id })?.parentID,
           let children = cachedChildrenByParentID[parentID] {
            cachedChildrenByParentID[parentID] = children.map(updated)
        }
        cachedTopLevelItems = cachedTopLevelItems.map(updated)
        cachedPrivateTopLevelItems = cachedPrivateTopLevelItems.map(updated)
        cachedMusicTracks = cachedMusicTracks.map(updated)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        cachedEmbyTopLevelItems = cachedEmbyTopLevelItems.map(updated)
        cachedContinueWatchingItems = cachedContinueWatchingItems.map(updated)
        cachedWatchingItems = cachedWatchingItems.map(updated)
        cachedPrivateWatchingItems = cachedPrivateWatchingItems.map(updated)
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

    func toggleWatchlist(_ item: MediaItem) {
        guard item.type != .music else { return }
        let currentWatchlist =
        items.first(where: { $0.id == item.id })?.watchlist ??
        activePlayerItem.flatMap { $0.id == item.id ? $0.watchlist : nil } ??
        selectedItem.flatMap { $0.id == item.id ? $0.watchlist : nil } ??
        item.watchlist
        let nextWatchlist = !currentWatchlist
        updateWatchlistInMemory(id: item.id, watchlist: nextWatchlist)
        syncTraktWatchlist(item, add: nextWatchlist)

        guard let mediaRepository else { return }
        Task(priority: .utility) { [weak self, mediaRepository] in
            do {
                try mediaRepository.setWatchlist(id: item.id, watchlist: nextWatchlist)
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    try? mediaRepository.setWatchlist(id: item.id, watchlist: currentWatchlist)
                    self.updateWatchlistInMemory(id: item.id, watchlist: currentWatchlist)
                    self.showError("想看状态更新失败", error)
                }
            }
        }
    }

    private func updateWatchlistInMemory(id: String, watchlist: Bool) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.watchlist = watchlist
            return copy
        }

        items = items.map(updated)
        if let parentID = items.first(where: { $0.id == id })?.parentID,
           let children = cachedChildrenByParentID[parentID] {
            cachedChildrenByParentID[parentID] = children.map(updated)
        }
        cachedTopLevelItems = cachedTopLevelItems.map(updated)
        cachedEmbyTopLevelItems = cachedEmbyTopLevelItems.map(updated)
        cachedContinueWatchingItems = cachedContinueWatchingItems.map(updated)
        cachedWatchingItems = cachedWatchingItems.map(updated)
        cachedPrivateWatchingItems = cachedPrivateWatchingItems.map(updated)
        cachedNextUpItems = cachedNextUpItems.map(updated)
        cachedDuplicateTitleGroups = cachedDuplicateTitleGroups.map { $0.map(updated) }
        if let activePlayerItem {
            self.activePlayerItem = updated(activePlayerItem)
        }
        if let selectedItem {
            self.selectedItem = updated(selectedItem)
        }
        if let quickPreviewItem {
            self.quickPreviewItem = updated(quickPreviewItem)
        }
        if watchlist {
            if !cachedVisibleVideoSections.contains(.watchlist) {
                cachedVisibleVideoSections = VideoLibrarySection.allCases.filter {
                    $0 == .watchlist || cachedVisibleVideoSections.contains($0)
                }
            }
        } else if !(cachedTopLevelItems + cachedEmbyTopLevelItems).contains(where: \.watchlist) {
            cachedVisibleVideoSections.removeAll { $0 == .watchlist }
        }
        watchlistRevision += 1
    }

    func markWatched(_ item: MediaItem, watched: Bool) {
        do {
            try mediaRepository?.markWatched(id: item.id, watched: watched)
            reload()
            scheduleEmbyPlayedSync([item], played: watched)
            syncTraktHistory([item], watched: watched)
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
        scheduleEmbyPlayedSync(items, played: watched)
        syncTraktHistory(items, watched: watched)
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的观看状态未能更新，请检查数据库状态。")
        }
    }

    // MARK: - 批量选择操作（C2）

    /// 进入/退出多选模式；退出时清空已选。
    func toggleSelectionMode() {
        isSelectionModeActive.toggle()
        if !isSelectionModeActive {
            selectedItemIDs.removeAll()
        }
    }

    func exitSelectionMode() {
        guard isSelectionModeActive || !selectedItemIDs.isEmpty else { return }
        isSelectionModeActive = false
        selectedItemIDs.removeAll()
    }

    func toggleItemSelection(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    /// 在当前可见集合范围内全选 / 取消全选。
    func setSelection(_ ids: [String], selected: Bool) {
        if selected {
            selectedItemIDs.formUnion(ids)
        } else {
            selectedItemIDs.subtract(ids)
        }
    }

    /// 由 ID 集合还原为有序条目（按传入顺序），仅取库内存在的条目。
    func resolveSelectedItems(orderedBy ordered: [MediaItem]) -> [MediaItem] {
        ordered.filter { selectedItemIDs.contains($0.id) }
    }

    private var currentSelectionItems: [MediaItem] {
        items.filter { selectedItemIDs.contains($0.id) }
    }

    func batchMarkWatched(watched: Bool) {
        let targets = currentSelectionItems.filter { $0.type != .music }
        guard !targets.isEmpty else { return }
        markAllWatched(targets, watched: watched)
    }

    func batchSetWatchlist(_ watchlist: Bool) {
        let targets = currentSelectionItems.filter { $0.type != .music }
        guard !targets.isEmpty, let mediaRepository else { return }
        var hadError = false
        for item in targets {
            updateWatchlistInMemory(id: item.id, watchlist: watchlist)
            do {
                try mediaRepository.setWatchlist(id: item.id, watchlist: watchlist)
            } catch {
                hadError = true
                logger?.log("批量更新想看状态失败：\(error.localizedDescription)", level: .warning)
            }
            // 与单条 toggleWatchlist 保持一致：批量改动也推送到 Trakt 想看清单。
            syncTraktWatchlist(item, add: watchlist)
        }
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的想看状态未能更新。")
        }
    }

    func batchUpdateRating(_ rating: Double?) {
        let targets = currentSelectionItems
        guard !targets.isEmpty, let mediaRepository else { return }
        var hadError = false
        for item in targets {
            do {
                try mediaRepository.updateRating(id: item.id, rating: rating)
            } catch {
                hadError = true
                logger?.log("批量更新评分失败：\(error.localizedDescription)", level: .warning)
            }
        }
        reload()
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的评分未能更新。")
        }
    }

    func batchClearPlaybackHistory() {
        let targets = currentSelectionItems.filter { $0.hasPlaybackTrace }
        guard !targets.isEmpty else { return }
        clearPlaybackHistory(targets)
    }

    /// 将已选条目从内部索引移除（不删除磁盘文件）。本地来源在下次扫描时可能重新入库。
    func batchRemoveFromLibrary() {
        let ids = Array(selectedItemIDs)
        guard !ids.isEmpty, let mediaRepository else { return }
        do {
            try mediaRepository.deleteItems(ids: ids)
            reload()
            exitSelectionMode()
        } catch {
            showError("批量移除失败", error)
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
        // 仅处理"参与元数据拉取"来源里的曲目（设置中可逐源勾选）。
        let tracks = musicTracks.filter(metadataFetchEnabled(for:))
        guard !tracks.isEmpty else {
            alert = AppAlert(title: "没有可匹配的音乐", message: "请先扫描音乐媒体源，并确认来源已开启“参与元数据拉取”。")
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
        var lowConfidence = 0
        for (index, track) in tracks.enumerated() {
            if Task.isCancelled { break }
            musicMetadataFetchProgress = "\(index + 1)/\(tracks.count) \(track.title)"
            let query = [track.artist, track.title]
                .compactMap { $0?.isEmpty == false ? $0 : nil }
                .joined(separator: " ")
            if let results = try? await service.searchMusic(
                query: query.isEmpty ? track.title : query,
                provider: settings.musicMetadataProvider,
                lastfmAPIKey: settings.lastfmAPIKey
            ),
               let best = MetadataMatchScorer.bestMusicMatch(for: track, in: results) {
                // 置信度复核：标题+艺人相似度低于阈值（按用户选择的宽容度档位）则跳过，留待手动复核，不盲取首条。
                if best.confidence >= settings.metadataMatchTolerance.musicThreshold {
                    // 一键获取只补充缺失数据，绝不覆盖已有：先判断各字段是否缺失。
                    let needsArtist = (track.artist?.isEmpty ?? true)
                    let needsAlbum = (track.album?.isEmpty ?? true)
                    let needsYear = (track.year == nil)
                    let needsOverview = (track.overview?.isEmpty ?? true)
                    let needsTrackNumber = (track.trackNumber == nil)
                    let needsCover = (track.posterPath?.isEmpty ?? true)

                    if needsArtist || needsAlbum || needsYear || needsOverview || needsTrackNumber || needsCover {
                        var update: MediaMetadataUpdate
                        if needsCover {
                            // 仅缺封面时才下载封面，避免浪费与覆盖现有封面。
                            update = await service.materializedMetadataUpdate(
                                for: best.result,
                                itemID: track.id,
                                artworkDirectory: directories?.thumbnails,
                                preserveEmbeddedPoster: track.hasEmbeddedArtwork
                            )
                        } else {
                            update = best.result.metadataUpdate
                            update.posterPath = nil
                            update.backdropPath = nil
                        }
                        // 已有字段一律置 nil（DB 端 COALESCE 保留原值），只补缺失项；标题永不覆盖。
                        update.title = nil
                        update.originalTitle = nil
                        if !needsArtist { update.artist = nil }
                        if !needsAlbum { update.album = nil }
                        if !needsYear { update.year = nil }
                        if !needsOverview { update.overview = nil }
                        if !needsTrackNumber { update.trackNumber = nil }
                        do {
                            try mediaRepository?.updateMetadata(id: track.id, metadata: update)
                            updatedCount += 1
                        } catch {
                            showError("音乐信息写入失败", error)
                        }
                    }
                } else {
                    lowConfidence += 1
                }
            }
            await fetchLyricsIfPossible(for: track)
        }

        reload()
        musicMetadataFetchProgress = lowConfidence > 0
            ? "完成 \(updatedCount)/\(tracks.count) 首（\(lowConfidence) 首置信度偏低已跳过）"
            : "完成 \(updatedCount)/\(tracks.count) 首"
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
        configureAutomaticTMDBMatch()
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

    var databaseSchemaVersion: Int {
        guard let database else { return 0 }
        return (try? database.schemaVersion()) ?? 0
    }

    func createDatabaseBackup() {
        guard let database, let directories else { return }
        do {
            let backupURL = try database.createBackup(in: directories.databaseBackups)
            alert = AppAlert(
                title: "数据库备份完成",
                message: "已创建一致性备份：\(backupURL.lastPathComponent)"
            )
        } catch {
            showError("数据库备份失败", error)
        }
    }

    func restoreDatabase(from backupURL: URL) {
        guard let database, let directories else { return }
        scanTask?.cancel()
        fileEventDebounceTask?.cancel()
        fileEventDebounceTask = nil
        musicQueuePersistenceTask?.cancel()
        musicQueuePersistenceTask = nil
        embyPlaybackSyncTasks.values.forEach { $0.cancel() }
        embyPlaybackSyncTasks.removeAll()
        embyPlaySessionIDs.removeAll()
        didRestoreMusicQueue = false
        scanRunID = UUID()
        pendingScanSources.removeAll()
        pendingIncrementalChanges.removeAll()
        pendingFileEventPaths.removeAll()
        pendingFullScanSourceIDs.removeAll()
        activeScanSourceID = nil
        scanProgress = nil
        isScanning = false
        scanQueueCount = 0
        markCancellableBackgroundTasksCancelled()
        activePlayerItem = nil
        quickPreviewItem = nil

        do {
            try database.restore(from: backupURL, safetyBackupDirectory: directories.databaseBackups)
            reload()
            restoreMusicQueueState()
            alert = AppAlert(
                title: "数据库恢复完成",
                message: "已从 \(backupURL.lastPathComponent) 恢复媒体索引、播放记录、喜欢、想看、智能集合、歌单和队列。用户媒体文件没有被修改。"
            )
        } catch {
            showError("数据库恢复失败", error)
        }
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

    /// 若错误为受限服务器（白名单拒绝），弹出专用提示并返回 true；否则返回 false 由调用方走常规报错。
    /// 调用方据此避免对受限服务器反复重试/重新登录。
    @discardableResult
    private func presentEmbyRestrictionIfNeeded(_ error: Error, serverHost: String) -> Bool {
        guard embyService.isClientRestriction(error) else { return false }
        var reason: String?
        if case EmbyServiceError.clientRestricted(_, let detail) = error { reason = detail }
        logger?.log("Emby 受限服务器（白名单）：\(serverHost) — \(reason ?? "未知原因")", level: .error)
        embyRestrictionNotice = EmbyRestrictionNotice(
            serverHost: serverHost,
            reason: reason,
            identity: embyService.clientIdentity()
        )
        return true
    }

    private func configureAutomaticScan() {
        guard configuredAutomaticScanInterval != settings.automaticScanInterval else { return }
        configuredAutomaticScanInterval = settings.automaticScanInterval
        automaticScanTask?.cancel()
        configureLocalFileEventMonitoring()
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

    private func configureLocalFileEventMonitoring() {
        guard settings.automaticScanInterval != .disabled else {
            localFileEventMonitor.update(paths: [])
            return
        }
        let paths = sources.compactMap { source -> String? in
            guard source.autoScan,
                  source.sourceKind == .local,
                  FileAccessService.isReachableDirectory(source.path) else {
                return nil
            }
            return source.path
        }
        localFileEventMonitor.update(paths: paths)
    }

    private func receiveLocalFileSystemChanges(_ changes: [LocalFileSystemChange]) {
        guard settings.automaticScanInterval != .disabled, !changes.isEmpty else { return }
        let localSources = sources.filter { $0.autoScan && $0.sourceKind == .local }
        guard !localSources.isEmpty else { return }

        for change in changes {
            let path = URL(fileURLWithPath: change.path).standardizedFileURL.path
            guard let source = localSources
                .filter({ path == $0.path || path.hasPrefix("\($0.path)/") })
                .max(by: { $0.path.count < $1.path.count }) else {
                continue
            }
            if change.requiresFullScan || change.isRemovedOrRenamedDirectory || path == source.path {
                pendingFullScanSourceIDs.insert(source.id)
                pendingFileEventPaths[source.id] = nil
            } else if !pendingFullScanSourceIDs.contains(source.id) {
                pendingFileEventPaths[source.id, default: []].insert(path)
            }
        }

        fileEventDebounceTask?.cancel()
        fileEventDebounceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: 1_200_000_000)
            } catch {
                return
            }
            await MainActor.run {
                self?.flushLocalFileSystemChanges()
            }
        }
    }

    private func flushLocalFileSystemChanges() {
        let fullScanIDs = pendingFullScanSourceIDs
        let incremental = pendingFileEventPaths
        pendingFullScanSourceIDs.removeAll()
        pendingFileEventPaths.removeAll()

        let fullScanSources = sources.filter { fullScanIDs.contains($0.id) }
        if !fullScanSources.isEmpty {
            startScanQueue(fullScanSources, silent: true)
        }
        for (sourceID, paths) in incremental where !fullScanIDs.contains(sourceID) {
            guard let source = sources.first(where: { $0.id == sourceID }) else { continue }
            enqueueIncrementalChanges(source: source, paths: paths)
        }
    }

    // MARK: - 剧集 TMDB 一键匹配 / 自动拉取

    /// 尚未匹配 TMDB 的电视剧 / 动漫系列项（用作一键匹配与自动拉取的候选）。
    private var tmdbMatchCandidates: [MediaItem] {
        topLevelItems.filter { item in
            (item.type == .tvShow || item.type == .anime)
                && (item.externalID?.hasPrefix("tmdb:") != true)
                && metadataFetchEnabled(for: item)
        }
    }

    /// 一键为所有未匹配的电视剧/动漫从 TMDB 拉取信息（标题、简介、海报、评分等）。
    func startTMDBMatchForTVSeries() {
        guard !isMatchingTMDB else { return }
        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else {
            alert = AppAlert(title: "需要 TMDB API Key", message: "请先在设置中填写 TMDB API Key 或 Read Access Token。")
            return
        }
        let candidates = tmdbMatchCandidates
        guard !candidates.isEmpty else {
            alert = AppAlert(title: "无需匹配", message: "所有电视剧 / 动漫都已匹配过 TMDB 信息。")
            return
        }
        tmdbMatchTask?.cancel()
        tmdbMatchTask = Task { [weak self] in
            await self?.performTMDBMatch(candidates: candidates, silent: false)
        }
    }

    /// 实际执行匹配：逐部搜索 TMDB、取最佳结果、下载封面并写回元数据。单部失败不影响整体。
    private func performTMDBMatch(candidates: [MediaItem], silent: Bool) async {
        guard !isMatchingTMDB, !candidates.isEmpty else { return }
        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return }

        isMatchingTMDB = true
        let service = MetadataSearchService()
        let language = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        let videoThreshold = settings.metadataMatchTolerance.videoThreshold
        let artworkDirectory = directories?.thumbnails
        var matched = 0
        var lowConfidence = 0

        for item in candidates {
            if Task.isCancelled { break }
            let query = item.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !query.isEmpty else { continue }
            do {
                let results = try await service.searchTMDB(
                    query: query,
                    itemType: item.type,
                    apiKey: apiKey,
                    language: language
                )
                // 置信度复核：按标题相似度+年份挑最佳，低于阈值则跳过、留待手动复核（片库健康→补充），不盲取首条。
                guard let best = MetadataMatchScorer.bestVideoMatch(for: item, in: results) else { continue }
                guard best.confidence >= videoThreshold else {
                    lowConfidence += 1
                    logger?.log("TMDB 低置信跳过（\(query) → \(best.result.title) · \(String(format: "%.2f", best.confidence))）")
                    continue
                }
                let update = await service.materializedMetadataUpdate(
                    for: best.result,
                    itemID: item.id,
                    artworkDirectory: artworkDirectory
                )
                guard !Task.isCancelled else { break }
                applyMetadata(update, to: item)
                matched += 1
            } catch {
                logger?.log("TMDB 匹配失败（\(query)）：\(error.localizedDescription)", level: .error)
                continue
            }
        }

        isMatchingTMDB = false
        if !silent {
            let reviewNote = lowConfidence > 0
                ? "；另有 \(lowConfidence) 部置信度偏低已跳过，可在「片库健康 → 补充」手动复核。"
                : "。"
            alert = AppAlert(
                title: "匹配完成",
                message: "已为 \(matched)/\(candidates.count) 部电视剧 / 动漫高置信匹配 TMDB 信息\(reviewNote)"
            )
        }
    }

    private func configureAutomaticTMDBMatch() {
        guard configuredAutomaticTMDBMatchInterval != settings.automaticTMDBMatchInterval else { return }
        configuredAutomaticTMDBMatchInterval = settings.automaticTMDBMatchInterval
        automaticTMDBMatchTask?.cancel()
        guard let seconds = settings.automaticTMDBMatchInterval.seconds else {
            automaticTMDBMatchTask = nil
            return
        }

        automaticTMDBMatchTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                } catch {
                    return
                }
                await MainActor.run {
                    self?.runAutomaticTMDBMatchIfNeeded()
                }
            }
        }
    }

    private func runAutomaticTMDBMatchIfNeeded() {
        guard !isMatchingTMDB, !isScanning else { return }
        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return }
        let candidates = tmdbMatchCandidates
        guard !candidates.isEmpty else { return }
        tmdbMatchTask?.cancel()
        tmdbMatchTask = Task { [weak self] in
            await self?.performTMDBMatch(candidates: candidates, silent: true)
        }
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
        applyThemePalette()
        let appearance = settings.theme.nsAppearance
        NSApp.appearance = appearance
        for window in NSApp.windows {
            window.appearance = appearance
            window.toolbar?.validateVisibleItems()
            window.contentView?.needsDisplay = true
        }
    }

    /// 把当前配色写入 AppColors.activeTheme（除音乐展开页外的全局色板据此派生）。
    /// 在 init / 设置变更时调用；配合 @Published settings 触发的级联刷新即时生效。
    func applyThemePalette() {
        AppColors.activeTheme = AppThemeResolver.resolve(for: settings)
    }

    private func publishThemePaletteChange() {
        applyThemePalette()
        themeRevision &+= 1
        for window in NSApp.windows {
            window.contentView?.needsDisplay = true
            window.toolbar?.validateVisibleItems()
        }
    }

    /// 设置页：切换配色预设。
    func setThemePreset(_ preset: AppThemePreset) {
        settings.themePreset = preset
        if preset.isCustom {
            // 进入自定义时，用所选/默认种子填充空缺，避免一打开就空白。
            let seed = preset.seedHex
            if settings.themeBaseHex == nil { settings.themeBaseHex = seed.base }
            if settings.themeHighlightHex == nil { settings.themeHighlightHex = seed.highlight }
            if settings.themeLightHex == nil { settings.themeLightHex = seed.light }
        }
        publishThemePaletteChange()
        persistSettingsDebounced()
    }

    /// 设置页：更新自定义配色的某个锚点颜色（十六进制，不含 #）。
    /// ColorPicker 拖动时会高频触发，因此这里只做轻量的内存换色 + 防抖落盘，
    /// 不走 `saveSettings`（其会同步写盘、遍历所有窗口刷新外观并重配扫描/TMDB 定时器，高频调用会卡顿）。
    func setCustomThemeColor(base: String? = nil, highlight: String? = nil, light: String? = nil) {
        if let base { settings.themeBaseHex = base }
        if let highlight { settings.themeHighlightHex = highlight }
        if let light { settings.themeLightHex = light }
        settings.themePreset = .custom
        publishThemePaletteChange()
        persistSettingsDebounced()
    }

    /// 防抖落盘：高频设置变更（如配色拖动）只在停止操作约 0.4s 后写一次磁盘。
    /// 触发时落盘「当前最新」的 settings（而非排程时的快照），避免期间其它设置变更被旧快照覆盖丢失。
    private func persistSettingsDebounced() {
        settingsPersistTask?.cancel()
        settingsPersistTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled, let self else { return }
            self.settingsStore.save(self.settings)
        }
    }
}
