import AppKit
import Foundation
import MediaLibCore
import Network
import SwiftUI

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

enum AppFloatingNoticeKind: Equatable, Sendable {
    case info
    case success
    case warning
    case error
    case tip

    var systemImage: String {
        switch self {
        case .info: return "info.circle"
        case .success: return "checkmark.circle"
        case .warning: return "exclamationmark.triangle"
        case .error: return "xmark.circle"
        case .tip: return "sparkles"
        }
    }
}

struct AppFloatingNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    var title: String
    var message: String?
    var kind: AppFloatingNoticeKind

    init(id: UUID = UUID(), title: String, message: String? = nil, kind: AppFloatingNoticeKind = .info) {
        self.id = id
        self.title = title
        self.message = message
        self.kind = kind
    }
}

private struct PendingFloatingNotice: Sendable {
    var notice: AppFloatingNotice
    var duration: TimeInterval
}

struct VideoManualCollectionCreationRequest: Identifiable, Equatable {
    let id = UUID()
    let itemIDs: [String]
}

struct VideoOfflineSubscriptionLimitRequest: Identifiable, Equatable {
    let id = UUID()
    let itemID: String
    let seriesTitle: String
    let qualityID: String?
    let initialEpisodeLimit: Int
    let hidesDetail: Bool

    var displayTitle: String {
        hidesDetail ? "这个系列" : seriesTitle
    }
}

/// 受限远程媒体服务器（白名单拒绝）提示载体：携带服务器地址、判定原因、本机客户端身份，
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

/// 视频缓存的 URLSession 回调可能非常密集；这里统一把任务中心进度压到约 5fps/1% 步进，
/// 避免远程缓存任务把主线程和浮动任务列表拖进高频刷新路径。
private final class VideoCacheProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPublishDate = Date.distantPast
    private var lastProgress: Double = -1

    func shouldPublish(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }

        let clamped = min(max(progress, 0), 1)
        let isTerminal = clamped >= 1
        let advancedEnough = clamped - lastProgress >= 0.01
        let waitedEnough = Date().timeIntervalSince(lastPublishDate) >= 0.18
        guard isTerminal || advancedEnough || waitedEnough else { return false }
        lastProgress = clamped
        lastPublishDate = Date()
        return true
    }
}

private struct OneClickCleanupResult: Sendable {
    var missingCacheManifestEntries = 0
    var orphanCacheEntries = 0
    var untrackedCacheFiles = 0
    var overLimitCacheEntries = 0
    var reclaimedVideoCacheBytes: Int64 = 0
    var trimmedTaskHistory = 0
    var removedEmptyArtworkDirectories = 0

    var total: Int {
        missingCacheManifestEntries +
        orphanCacheEntries +
        untrackedCacheFiles +
        overLimitCacheEntries +
        trimmedTaskHistory +
        removedEmptyArtworkDirectories
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

private struct LibraryClassificationHint: Sendable {
    var libraryName: String?
    var collectionType: String?
}

private struct VideoCacheJob {
    var item: MediaItem
    var qualityID: String?
    var candidates: [MediaItem]
    var currentIndex: Int
    var cleanedItemIDs: Set<String> = []
    var hidesDetail: Bool
    var errors: [String]
    var isPausing: Bool = false
    var controller: VideoCacheDownloadController?
    var worker: Task<Void, Never>?
}

private struct TraktImportReport {
    var conflictCount: Int
}

private struct SyncConflictRemoteMutation {
    enum Value {
        case boolean(Bool)
        case userRating(Double?)
    }

    var item: MediaItem
    var fieldName: String
    var value: Value
}

private enum SyncConflictApplyError: LocalizedError {
    case missingMediaID
    case missingRemoteValue
    case missingLocalValue
    case invalidBooleanValue(String)
    case invalidRatingValue(String)
    case unsupportedField(String)
    case unsupportedProvider(RemoteConnectorProvider)
    case privateItemLocked
    case privateItemNotSyncable
    case mediaItemNotFound(String)
    case repositoryUnavailable

    var errorDescription: String? {
        switch self {
        case .missingMediaID:
            return "同步冲突缺少媒体条目 ID。"
        case .missingRemoteValue:
            return "同步冲突缺少远端值。"
        case .missingLocalValue:
            return "同步冲突缺少本地值。"
        case .invalidBooleanValue(let value):
            return "无法识别远端布尔值：\(value)"
        case .invalidRatingValue(let value):
            return "无法识别远端用户评级：\(value)"
        case .unsupportedField(let field):
            return "暂不支持自动采用该字段：\(field)"
        case .unsupportedProvider(let provider):
            return "暂不支持向 \(provider.displayName) 写回该冲突。"
        case .privateItemLocked:
            return "保险库锁定时不能处理该条同步冲突。"
        case .privateItemNotSyncable:
            return "保险库内容不会同步到远端服务。"
        case .mediaItemNotFound(let id):
            return "媒体条目不存在：\(id)"
        case .repositoryUnavailable:
            return "媒体索引仓库不可用。"
        }
    }
}

private extension RemoteConnectorProvider {
    var mediaSourceScheme: String {
        switch self {
        case .plex:
            return "plex"
        case .jellyfin:
            return "jellyfin"
        default:
            return "emby"
        }
    }

    var credentialKind: String {
        mediaSourceScheme
    }

    var mediaSourceDisplayName: String {
        switch self {
        case .emby:
            return "EMBY"
        case .jellyfin:
            return "Jellyfin"
        case .plex:
            return "Plex"
        default:
            return displayName
        }
    }

    var mediaServerCapabilitiesJSON: String {
        if self == .plex {
            return """
            {"mediaSync":true,"librarySelection":true,"playbackReporting":true,"favoriteSync":false,"watchedSync":true,"tokenLogin":true,"transcodeQualitySelection":false}
            """
        }
        return """
        {"mediaSync":true,"librarySelection":true,"playbackReporting":true,"favoriteSync":true,"watchedSync":true}
        """
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var sources: [MediaSource] = []
    @Published var items: [MediaItem] = []
    @Published var settings: AppSettings
    @Published var selectedItem: MediaItem?
    @Published var selectedItemReturnAnchorID: String?
    @Published var activePlayerItem: MediaItem?
    /// 视频播放队列（播放器内剧集列表）：播放系列中的某一集时，
    /// 自动装入「当前集 + 之后的同系列剧集」；独立影片只含自身。
    @Published var videoQueue: [MediaItem] = []
    /// 「打开网络串流」输入弹窗。
    @Published var showingNetworkStreamPrompt = false
    /// 可用的新版本（驱动更新提示弹窗）。
    @Published var availableUpdate: AppUpdateInfo?
    @Published var isCheckingForUpdates = false
    /// 第三次启动时弹出的赞赏邀请。
    @Published var showingSponsorPrompt = false
    @Published var quickPreviewItem: MediaItem?
    @Published var scanProgress: ScanProgress?
    @Published var isScanning = false
    @Published var scanQueueCount = 0
    @Published private(set) var backgroundTasks: [BackgroundTaskSnapshot] = [] {
        didSet { persistBackgroundTasksIfPossible() }
    }
    /// 剧集 TMDB 一键匹配进行中（驱动设置页按钮的进度态）。
    @Published var isMatchingTMDB = false
    @Published var alert: AppAlert? {
        didSet {
            if let alert {
                showFloatingNotice(title: alert.title, message: alert.message.isEmpty ? nil : alert.message)
            }
        }
    }
    @Published private(set) var floatingNotices: [AppFloatingNotice] = []
    /// 受限远程媒体服务器提示（白名单拒绝）；非 nil 时弹出专用面板。
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
    @Published var videoManualCollections: [VideoManualCollection] = []
    @Published var videoOfflineSubscriptions: [VideoOfflineSubscription] = []
    @Published private(set) var metadataCorrectionCountsByMediaID: [String: Int] = [:]
    @Published private(set) var metadataCorrectionRecordCount = 0
    @Published private(set) var metadataCorrectionBatches: [MetadataCorrectionBatchSummary] = []
    @Published private(set) var pendingSyncConflictCount = 0
    @Published private(set) var pendingSyncConflicts: [SyncConflict] = []
    @Published private(set) var remoteConnectorAccounts: [RemoteConnectorAccount] = []
    @Published var videoManualCollectionCreationRequest: VideoManualCollectionCreationRequest?
    @Published var videoOfflineSubscriptionLimitRequest: VideoOfflineSubscriptionLimitRequest?
    @Published var musicSmartPlaylists: [MusicSmartPlaylist] = []
    @Published var playbackCommandRequest: PlaybackCommandRequest?
    @Published var isFetchingMusicMetadata = false
    @Published var isSupplementingMetadata = false
    @Published private(set) var isConnectingEmby = false
    @Published private(set) var isConnectingJellyfin = false
    @Published private(set) var isConnectingPlex = false
    @Published var musicMetadataFetchProgress = ""
    @Published private(set) var libraryRevision = 0
    /// 仅在 reload() 完成（元数据/封面路径真实变化）时递增；文件存在性检查不会触发它。
    /// LocalPosterImage 的 cacheKey 改用此值，避免文件健康检查后触发全量图片重载。
    @Published private(set) var posterRevision = 0
    @Published private(set) var favoriteRevision = 0
    @Published private(set) var watchlistRevision = 0
    @Published private(set) var ratingRevision = 0
    @Published private(set) var videoCacheRevision = 0
    @Published private(set) var videoCacheStorageSummary = VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
    @Published private(set) var videoOfflineSubscriptionWiFiAvailable = false
    // 播放歌名含「アゲイン」的歌曲时触发一次轻量樱花动效，仅限本次启动首次播放。
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
    private let videoManualCollectionRepository: VideoManualCollectionRepository?
    private let videoOfflineSubscriptionRepository: VideoOfflineSubscriptionRepository?
    private let musicSmartPlaylistRepository: MusicSmartPlaylistRepository?
    private let playbackMarkerRepository: PlaybackMarkerRepository?
    private let metadataCorrectionRepository: MetadataCorrectionRepository?
    private let syncConflictRepository: SyncConflictRepository?
    private let remoteConnectorAccountRepository: RemoteConnectorAccountRepository?
    private let videoOfflineCacheStore: VideoOfflineCacheStore?
    private let settingsStore = AppSettingsStore()
    private let logger: LoggingService?
    private let externalPlayerService = ExternalPlayerService()
    private let privacyLockService = PrivacyLockService()
    private let remoteCredentialStore = RemoteCredentialStore()
    private let embyService = EmbyService()
    private let plexService = PlexService()
    private var scanTask: Task<Void, Never>?
    private var automaticScanTask: Task<Void, Never>?
    private var configuredAutomaticScanInterval: AutomaticScanInterval?
    private var configuredWatchedThreshold: Double
    private var automaticTMDBMatchTask: Task<Void, Never>?
    private var configuredAutomaticTMDBMatchInterval: AutomaticScanInterval?
    private var tmdbMatchTask: Task<Void, Never>?
    private var videoCacheJobs: [UUID: VideoCacheJob] = [:]
    private var videoOfflineSubscriptionMaintenanceTask: Task<Void, Never>?
    private var videoOfflineSubscriptionExpirationTask: Task<Void, Never>?
    private var networkPathMonitor: NWPathMonitor?
    private let networkPathMonitorQueue = DispatchQueue(label: "MediaLIB.NetworkPathMonitor")
    private var keyframeStoryboardTasks: [UUID: Task<Void, Never>] = [:]
    private var playbackMarkerAnalysisTasks: [UUID: Task<Void, Never>] = [:]
    private var floatingNoticeDismissTasks: [UUID: Task<Void, Never>] = [:]
    private var floatingNoticeQueue: [PendingFloatingNotice] = []
    private var foregroundFallbackNotices: [PendingFloatingNotice] = []
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var isRestoringBackgroundTasks = false
    private var embyArtworkWarmupTasks: [String: Task<Void, Never>] = [:]
    private static let shownInterfaceTipDefaultsKey = "MediaLib.shownInterfaceTipKeys"
    private var shownInterfaceTipKeys: Set<String> = []
    private var didLoadShownInterfaceTipKeys = false
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
    private var cachedHomeVideoItems: [MediaItem] = []
    private var cachedHomeOfflineVideoItems: [MediaItem] = []
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
    private var cachedVideoEntriesByItemID: [String: VideoCacheEntry] = [:]
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
    private var playbackClearRevisionByItemID: [String: Date] = [:]
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
        self.configuredWatchedThreshold = loadedSettings.watchedThreshold
        self.privacyPINConfigured = loadedSettings.privacyPINEnabled && privacyLockService.hasPIN()
        // 首帧前就把用户配色写入全局色板，避免启动闪一帧默认配色。
        AppColors.activeTheme = AppThemeResolver.resolve(for: loadedSettings)

        do {
            let directories = try FileAccessService.appDirectories()
            VideoFramePreviewGenerator.configure(diskCacheDirectory: directories.previewFrames)
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
            self.videoManualCollectionRepository = VideoManualCollectionRepository(database: database)
            self.videoOfflineSubscriptionRepository = VideoOfflineSubscriptionRepository(database: database)
            self.musicSmartPlaylistRepository = MusicSmartPlaylistRepository(database: database)
            self.playbackMarkerRepository = PlaybackMarkerRepository(database: database)
            self.metadataCorrectionRepository = MetadataCorrectionRepository(database: database)
            self.syncConflictRepository = SyncConflictRepository(database: database)
            self.remoteConnectorAccountRepository = RemoteConnectorAccountRepository(database: database)
            do {
                self.videoOfflineCacheStore = try VideoOfflineCacheStore(
                    applicationSupportDirectory: directories.applicationSupport,
                    defaultCacheDirectory: directories.cache,
                    customCacheDirectoryPath: loadedSettings.videoCacheDirectoryPath
                )
                self.cachedVideoEntriesByItemID = self.videoOfflineCacheStore?.allEntries() ?? [:]
                self.videoCacheStorageSummary = self.videoOfflineCacheStore?.storageSummary(
                    byteLimit: Self.videoCacheByteLimit(from: loadedSettings.videoCacheSizeLimitGB)
                ) ?? VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
            } catch {
                self.videoOfflineCacheStore = nil
                logger.log("视频缓存清单初始化失败：\(error.localizedDescription)", level: .warning)
            }
            restoreBackgroundTasksIfPossible()
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
            self.videoManualCollectionRepository = nil
            self.videoOfflineSubscriptionRepository = nil
            self.musicSmartPlaylistRepository = nil
            self.playbackMarkerRepository = nil
            self.metadataCorrectionRepository = nil
            self.syncConflictRepository = nil
            self.remoteConnectorAccountRepository = nil
            self.videoOfflineCacheStore = nil
            self.startupError = error.localizedDescription
        }
        configureNetworkPathMonitoring()
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.flushForegroundFallbackNotices()
            }
        }
    }

    deinit {
        networkPathMonitor?.cancel()
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }
    }

    var topLevelItems: [MediaItem] {
        cachedTopLevelItems
    }

    /// 首页视频看板使用的公开集合：本地公开视频 + 远程服务器顶层视频。
    /// 与左侧“视频”目录分开，避免远程 / 保险库状态串入本地分类。
    var homeVideoItems: [MediaItem] {
        cachedHomeVideoItems
    }

    var homeOfflineVideoItems: [MediaItem] {
        cachedHomeOfflineVideoItems
    }

    var embyTopLevelItems: [MediaItem] {
        cachedEmbyTopLevelItems
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

    var canDisplayPrivateItems: Bool {
        privacyPINConfigured && privacyUnlocked
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
        sources.filter { $0.sourceKind.isRemoteMediaServer }
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
            base = canDisplayPrivateItems ? privateTopLevelItems : []
        case .video(.watching):
            base = canDisplayPrivateItems
                ? (cachedWatchingItems + cachedPrivateWatchingItems).sorted(by: Self.playbackRecencySort)
                : cachedWatchingItems
        case .video(.watchlist):
            base = topLevelItems.filter { $0.type != .music && $0.watchlist }
        case .video(.favorites):
            base = topLevelItems.filter { $0.type != .music && $0.favorite }
        case .video(.unwatched):
            base = topLevelItems.filter { $0.type != .music && !$0.watched && $0.playProgress < settings.watchedThreshold }
        case .video(.watched):
            let visibleItems = topLevelItems + (canDisplayPrivateItems ? privateTopLevelItems : [])
            base = visibleItems.filter { $0.type != .music && ($0.watched || $0.playProgress >= settings.watchedThreshold) }
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
            base = visibleVideoSmartCollectionItems.filter { matches($0, collection: collection) }
        case .manualCollection(let collectionID):
            guard let collection = videoManualCollections.first(where: { $0.id == collectionID }) else {
                base = []
                break
            }
            base = manualVideoCollectionItems(collection)
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

    @discardableResult
    func saveVideoSmartCollection(_ collection: VideoSmartCollection, notify: Bool = true) -> VideoSmartCollection? {
        guard let videoSmartCollectionRepository else { return nil }
        let isNew = !videoSmartCollections.contains { $0.id == collection.id }
        do {
            let saved = try videoSmartCollectionRepository.save(collection)
            if let index = videoSmartCollections.firstIndex(where: { $0.id == saved.id }) {
                videoSmartCollections[index] = saved
            } else {
                videoSmartCollections.insert(saved, at: 0)
            }
            videoSmartCollections.sort { $0.updatedAt > $1.updatedAt }
            libraryRevision += 1
            if notify {
                let title = isNew ? "智能集合已创建" : "智能集合已保存"
                deliverTaskNotice(
                    title: title,
                    message: saved.name,
                    kind: .success,
                    systemTitle: title,
                    systemBody: "\(saved.name) 已保存。"
                )
            }
            return saved
        } catch {
            deliverTaskNotice(
                title: "智能集合保存失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "智能集合保存失败",
                systemBody: error.localizedDescription
            )
            return nil
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

    func setVideoSmartCollectionHomeVisibility(_ collection: VideoSmartCollection, showOnHome: Bool) {
        guard collection.showOnHome != showOnHome else { return }
        var updated = collection
        updated.showOnHome = showOnHome
        saveVideoSmartCollection(updated, notify: false)
        showFloatingNotice(
            title: showOnHome ? "已发布到首页" : "已从首页移除",
            message: updated.name,
            kind: showOnHome ? .success : .info
        )
    }

    // MARK: - 手动视频集合

    func videoManualCollection(id: String) -> VideoManualCollection? {
        videoManualCollections.first { $0.id == id }
    }

    @discardableResult
    func saveVideoManualCollection(_ collection: VideoManualCollection, notify: Bool = true) -> VideoManualCollection? {
        guard let videoManualCollectionRepository else { return nil }
        let isNew = !videoManualCollections.contains { $0.id == collection.id }
        do {
            let saved = try videoManualCollectionRepository.save(collection)
            upsertVideoManualCollectionInMemory(saved)
            libraryRevision += 1
            if notify {
                let title = isNew ? "集合已创建" : "集合已保存"
                deliverTaskNotice(
                    title: title,
                    message: saved.name,
                    kind: .success,
                    systemTitle: title,
                    systemBody: "\(saved.name) 已保存。"
                )
            }
            return saved
        } catch {
            deliverTaskNotice(
                title: "集合保存失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "集合保存失败",
                systemBody: error.localizedDescription
            )
            return nil
        }
    }

    @discardableResult
    func createVideoManualCollection(name: String, items: [MediaItem] = []) -> VideoManualCollection? {
        createVideoManualCollection(name: name, itemIDs: uniqueVideoCollectionItemIDs(items))
    }

    func requestVideoManualCollectionCreation(items: [MediaItem]) {
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        videoManualCollectionCreationRequest = VideoManualCollectionCreationRequest(itemIDs: itemIDs)
    }

    func cancelVideoManualCollectionCreation(_ request: VideoManualCollectionCreationRequest) {
        guard videoManualCollectionCreationRequest?.id == request.id else { return }
        videoManualCollectionCreationRequest = nil
    }

    @discardableResult
    func finishVideoManualCollectionCreation(_ request: VideoManualCollectionCreationRequest, name: String) -> VideoManualCollection? {
        guard videoManualCollectionCreationRequest?.id == request.id else { return nil }
        let collection = createVideoManualCollectionAndNotify(
            name: name,
            itemIDs: request.itemIDs,
            successTitle: "已创建集合并加入"
        )
        videoManualCollectionCreationRequest = nil
        return collection
    }

    @discardableResult
    func createVideoManualCollectionAndNotify(
        name: String,
        itemIDs: [String],
        successTitle: String = "集合已创建"
    ) -> VideoManualCollection? {
        let collection = createVideoManualCollection(name: name, itemIDs: itemIDs)
        if let collection {
            deliverTaskNotice(
                title: successTitle,
                message: collection.name,
                kind: .success,
                systemTitle: successTitle,
                systemBody: "\(collection.name) 已保存。"
            )
        }
        return collection
    }

    @discardableResult
    func createVideoManualCollection(name: String, itemIDs: [String]) -> VideoManualCollection? {
        guard let videoManualCollectionRepository else { return nil }
        do {
            let collection = try videoManualCollectionRepository.create(
                name: name,
                itemIDs: itemIDs
            )
            upsertVideoManualCollectionInMemory(collection)
            libraryRevision += 1
            return collection
        } catch {
            deliverTaskNotice(
                title: "集合创建失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "集合创建失败",
                systemBody: error.localizedDescription
            )
            return nil
        }
    }

    func deleteVideoManualCollection(_ collection: VideoManualCollection) {
        guard let videoManualCollectionRepository else { return }
        do {
            try videoManualCollectionRepository.delete(id: collection.id)
            videoManualCollections.removeAll { $0.id == collection.id }
            libraryRevision += 1
        } catch {
            showError("集合删除失败", error)
        }
    }

    func setVideoManualCollectionHomeVisibility(_ collection: VideoManualCollection, showOnHome: Bool) {
        guard collection.showOnHome != showOnHome else { return }
        var updated = collection
        updated.showOnHome = showOnHome
        saveVideoManualCollection(updated, notify: false)
        showFloatingNotice(
            title: showOnHome ? "已发布到首页" : "已从首页移除",
            message: updated.name,
            kind: showOnHome ? .success : .info
        )
    }

    func addToVideoManualCollection(_ items: [MediaItem], collectionID: String) {
        guard let videoManualCollectionRepository else { return }
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            if let updated = try videoManualCollectionRepository.add(itemIDs: itemIDs, toCollectionID: collectionID) {
                upsertVideoManualCollectionInMemory(updated)
                libraryRevision += 1
                showFloatingNotice(title: "已加入集合", message: updated.name, kind: .success)
            }
        } catch {
            showError("加入集合失败", error)
        }
    }

    func removeFromVideoManualCollection(_ items: [MediaItem], collectionID: String) {
        guard let videoManualCollectionRepository else { return }
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            if let updated = try videoManualCollectionRepository.remove(itemIDs: itemIDs, fromCollectionID: collectionID) {
                upsertVideoManualCollectionInMemory(updated)
                libraryRevision += 1
                showFloatingNotice(title: "已从集合移除", message: updated.name, kind: .info)
            }
        } catch {
            showError("移出集合失败", error)
        }
    }

    func canReorderVideoManualCollection(_ items: [MediaItem], collectionID: String, operation: VideoManualCollectionReorderOperation) -> Bool {
        guard let collection = videoManualCollection(id: collectionID) else { return false }
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        return reorderedVideoManualCollectionItemIDs(collection.itemIDs, movingItemIDs: itemIDs, operation: operation) != collection.itemIDs
    }

    func reorderVideoManualCollection(_ items: [MediaItem], collectionID: String, operation: VideoManualCollectionReorderOperation) {
        guard let videoManualCollectionRepository else { return }
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            guard var collection = try videoManualCollectionRepository.fetch(id: collectionID) else { return }
            let reordered = reorderedVideoManualCollectionItemIDs(collection.itemIDs, movingItemIDs: itemIDs, operation: operation)
            guard reordered != collection.itemIDs else { return }
            collection.itemIDs = reordered
            let saved = try videoManualCollectionRepository.save(collection)
            upsertVideoManualCollectionInMemory(saved)
            libraryRevision += 1
            showFloatingNotice(title: "集合顺序已更新", message: saved.name, kind: .success)
        } catch {
            showError("调整集合顺序失败", error)
        }
    }

    func collections(containing item: MediaItem) -> [VideoManualCollection] {
        videoManualCollections.filter { $0.itemIDs.contains(item.id) }
    }

    func videoManualCollectionPreviewItems(_ collection: VideoManualCollection, limit: Int = 4) -> [MediaItem] {
        guard limit > 0 else { return [] }
        let visibleItemsByID = manualVideoCollectionVisibleItemsByID()
        return Array(manualVideoCollectionItems(collection, visibleItemsByID: visibleItemsByID).prefix(limit))
    }

    func videoManualCollectionPreviewItemsByCollectionID(limit: Int = 1) -> [String: [MediaItem]] {
        guard limit > 0 else { return [:] }
        let visibleItemsByID = manualVideoCollectionVisibleItemsByID()
        var result: [String: [MediaItem]] = [:]
        for collection in videoManualCollections {
            result[collection.id] = Array(manualVideoCollectionItems(collection, visibleItemsByID: visibleItemsByID).prefix(limit))
        }
        return result
    }

    func videoManualCollectionHomeItems(_ collection: VideoManualCollection, limit: Int = 12) -> [MediaItem] {
        guard limit > 0 else { return [] }
        let visibleItemsByID = publicVideoCollectionVisibleItemsByID()
        return Array(manualVideoCollectionItems(collection, visibleItemsByID: visibleItemsByID).prefix(limit))
    }

    func videoSmartCollectionHomeItems(_ collection: VideoSmartCollection, limit: Int = 12) -> [MediaItem] {
        guard limit > 0 else { return [] }
        return Array(cachedHomeVideoItems.filter { matches($0, collection: collection) }.prefix(limit))
    }

    func canUseInVideoManualCollection(_ item: MediaItem) -> Bool {
        item.type != .music && item.type != .privateCollection && !Self.isRemoteMediaServerItem(item)
    }

    private func upsertVideoManualCollectionInMemory(_ collection: VideoManualCollection) {
        if let index = videoManualCollections.firstIndex(where: { $0.id == collection.id }) {
            videoManualCollections[index] = collection
        } else {
            videoManualCollections.insert(collection, at: 0)
        }
        videoManualCollections.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func uniqueVideoCollectionItemIDs(_ items: [MediaItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where canUseInVideoManualCollection(item) {
            guard seen.insert(item.id).inserted else { continue }
            result.append(item.id)
        }
        return result
    }

    private func reorderedVideoManualCollectionItemIDs(
        _ currentIDs: [String],
        movingItemIDs: [String],
        operation: VideoManualCollectionReorderOperation
    ) -> [String] {
        VideoManualCollection.reorderedItemIDs(currentIDs, movingItemIDs: movingItemIDs, operation: operation)
    }

    // MARK: - 音乐智能歌单

    func musicSmartPlaylist(id: String) -> MusicSmartPlaylist? {
        musicSmartPlaylists.first { $0.id == id }
    }

    @discardableResult
    func saveMusicSmartPlaylist(_ playlist: MusicSmartPlaylist, notify: Bool = true) -> MusicSmartPlaylist? {
        guard let musicSmartPlaylistRepository else { return nil }
        let isNew = !musicSmartPlaylists.contains { $0.id == playlist.id }
        do {
            let saved = try musicSmartPlaylistRepository.save(playlist)
            if let index = musicSmartPlaylists.firstIndex(where: { $0.id == saved.id }) {
                musicSmartPlaylists[index] = saved
            } else {
                musicSmartPlaylists.insert(saved, at: 0)
            }
            musicSmartPlaylists.sort { $0.updatedAt > $1.updatedAt }
            libraryRevision += 1
            if notify {
                let title = isNew ? "智能歌单已创建" : "智能歌单已保存"
                deliverTaskNotice(
                    title: title,
                    message: saved.name,
                    kind: .success,
                    systemTitle: title,
                    systemBody: "\(saved.name) 已保存。"
                )
            }
            return saved
        } catch {
            deliverTaskNotice(
                title: "智能歌单保存失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "智能歌单保存失败",
                systemBody: error.localizedDescription
            )
            return nil
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

    private var visibleVideoSmartCollectionItems: [MediaItem] {
        cachedHomeVideoItems
    }

    private func manualVideoCollectionItems(_ collection: VideoManualCollection) -> [MediaItem] {
        let visibleItemsByID = manualVideoCollectionVisibleItemsByID()
        return manualVideoCollectionItems(collection, visibleItemsByID: visibleItemsByID)
    }

    private func manualVideoCollectionItems(
        _ collection: VideoManualCollection,
        visibleItemsByID: [String: MediaItem]
    ) -> [MediaItem] {
        collection.itemIDs.compactMap { visibleItemsByID[$0] }
    }

    private func manualVideoCollectionVisibleItemsByID() -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]

        func insert(_ item: MediaItem) {
            guard item.type != .music,
                  item.type != .privateCollection,
                  !Self.isRemoteMediaServerItem(item) else { return }
            if cachedPrivateItemIDs.contains(item.id), !canDisplayPrivateItems {
                return
            }
            result[item.id] = item
        }

        cachedTopLevelItems.forEach(insert)
        if canDisplayPrivateItems {
            cachedPrivateTopLevelItems.forEach(insert)
        }
        for children in cachedChildrenByParentID.values {
            children.forEach(insert)
        }
        return result
    }

    private func publicVideoCollectionVisibleItemsByID() -> [String: MediaItem] {
        var result: [String: MediaItem] = [:]

        func insert(_ item: MediaItem) {
            guard item.type != .music,
                  item.type != .privateCollection,
                  !cachedPrivateItemIDs.contains(item.id),
                  !Self.isRemoteMediaServerItem(item) else { return }
            result[item.id] = item
        }

        cachedTopLevelItems.forEach(insert)
        for children in cachedChildrenByParentID.values {
            children.forEach(insert)
        }
        return result
    }

    private func matches(_ item: MediaItem, collection: VideoSmartCollection) -> Bool {
        collection.matches(item, watchedThreshold: settings.watchedThreshold)
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
        case .watchlist:
            return cachedEmbyTopLevelItems.filter { $0.type != .music && $0.watchlist }
        case .favorites:
            return cachedEmbyTopLevelItems.filter(\.favorite)
        }
    }

    func embyItems(forLibraryID libraryID: String) -> [MediaItem] {
        if let summary = cachedEmbyLibrarySummaries.first(where: { $0.id == libraryID }) {
            return cachedEmbyTopLevelItems.filter { item in
                guard embySourceID(for: item) == summary.sourceID,
                      let sourcePath = item.sourcePath,
                      let library = EmbyService.libraryInfo(from: sourcePath) else { return false }
                return library.id == summary.viewID
            }
        }
        return cachedEmbyTopLevelItems.filter { item in
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
        case .watchlist:
            return scoped.filter { $0.type != .music && $0.watchlist }
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
        return embySources.first { Self.isSourcePath(rootPath, inside: $0.path) }?.id
    }

    func embyLibraryTitle(_ libraryID: String) -> String {
        cachedEmbyLibrarySummaries.first { $0.id == libraryID }?.displayName ?? "远程分类"
    }

    func children(for item: MediaItem) -> [MediaItem] {
        cachedChildrenByParentID[item.id] ?? []
    }

    func videoCacheEntry(for item: MediaItem) -> VideoCacheEntry? {
        cachedVideoEntriesByItemID[item.id]
    }

    func isVideoCached(_ item: MediaItem) -> Bool {
        videoCacheEntry(for: item) != nil
    }

    var videoCacheDirectoryDisplayPath: String {
        if let directory = videoOfflineCacheStore?.currentCacheDirectory {
            return directory.path
        }
        if let path = settings.videoCacheDirectoryPath?.trimmingCharacters(in: .whitespacesAndNewlines),
           !path.isEmpty {
            return URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent("VideoCache", isDirectory: true)
                .path
        }
        return directories?.cache.appendingPathComponent("VideoCache", isDirectory: true).path ?? "暂不可用"
    }

    var videoCacheSizeLimitDisplayText: String {
        guard let byteLimit = Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB) else {
            return "不限制"
        }
        return Self.shortByteCount(byteLimit)
    }

    var videoCacheStorageDisplayText: String {
        let used = Self.shortByteCount(videoCacheStorageSummary.totalBytes)
        if let byteLimit = videoCacheStorageSummary.byteLimit {
            return "\(used) / \(Self.shortByteCount(byteLimit))"
        }
        return "\(used) · \(videoCacheStorageSummary.entryCount) 个视频"
    }

    func videoCacheState(for item: MediaItem) -> VideoSeriesCacheState {
        let episodes = children(for: item).filter { cacheableVideoCandidate($0) || isVideoCached($0) }
        guard !episodes.isEmpty else {
            return isVideoCached(item) ? .complete : .none
        }
        let cachedCount = episodes.filter { isVideoCached($0) }.count
        if cachedCount == 0 { return .none }
        return cachedCount == episodes.count ? .complete : .partial
    }

    func includesCachedVideo(_ item: MediaItem) -> Bool {
        if isVideoCached(item) { return true }
        return children(for: item).contains { isVideoCached($0) }
    }

    func hasCachedVideos(in items: [MediaItem]) -> Bool {
        items.contains { includesCachedVideo($0) }
    }

    private func rebuildHomeOfflineVideoCache() {
        cachedHomeOfflineVideoItems = cachedHomeVideoItems.filter { includesCachedVideo($0) }
        if cachedHomeOfflineVideoItems.isEmpty {
            cachedAvailableHomeTabs.remove(.offline)
        } else {
            cachedAvailableHomeTabs.insert(.offline)
        }
    }

    func cachedVideoScopeIDs(in items: [MediaItem]) -> Set<String> {
        var ids = Set<String>()
        for item in items {
            if isVideoCached(item) {
                ids.insert(item.id)
            }
            if children(for: item).contains(where: { isVideoCached($0) }) {
                ids.insert(item.id)
            }
        }
        return ids
    }

    func videoCacheQualityChoices(for item: MediaItem) -> [VideoCacheQualityChoice] {
        guard let representative = cacheableVideoItems(for: item).first else { return [] }
        let options = RemoteVideoQualityPlanner.options(for: representative, knownMountedNetworkFile: false)
            .filter { !$0.appliesInPlace }
        let optionChoices = uniqueCacheQualityChoices(from: options)
        if !optionChoices.isEmpty {
            return optionChoices
        }
        return cacheableVideoCandidate(representative) ? [originalVideoCacheChoice(for: representative)] : []
    }

    func canUseVideoOfflineSubscription(_ item: MediaItem) -> Bool {
        guard videoOfflineCacheStore != nil,
              let series = videoOfflineSubscriptionSeries(for: item) else {
            return false
        }
        return children(for: series).contains(where: cacheableVideoCandidate)
    }

    func videoOfflineSubscription(for item: MediaItem) -> VideoOfflineSubscription? {
        guard let series = videoOfflineSubscriptionSeries(for: item) else { return nil }
        return videoOfflineSubscriptions.first { $0.seriesID == series.id }
    }

    func requestCustomVideoOfflineSubscriptionLimit(for item: MediaItem, qualityID: String? = nil) {
        guard let series = videoOfflineSubscriptionSeries(for: item),
              children(for: series).contains(where: cacheableVideoCandidate) else {
            alert = AppAlert(title: "无法开启自动缓存", message: "这个系列没有可缓存的远程剧集。")
            return
        }
        let existing = videoOfflineSubscription(for: series)
        videoOfflineSubscriptionLimitRequest = VideoOfflineSubscriptionLimitRequest(
            itemID: item.id,
            seriesTitle: series.title,
            qualityID: qualityID,
            initialEpisodeLimit: existing?.mode == .nextUnwatched ? existing?.episodeLimit ?? 3 : 3,
            hidesDetail: isPrivateItem(series)
        )
    }

    func saveCustomVideoOfflineSubscriptionLimit(
        _ request: VideoOfflineSubscriptionLimitRequest,
        episodeLimit: Int
    ) {
        guard let item = items.first(where: { $0.id == request.itemID }) else {
            videoOfflineSubscriptionLimitRequest = nil
            alert = AppAlert(title: "无法开启自动缓存", message: "这个系列已不在当前媒体库中。")
            return
        }
        saveVideoOfflineSubscription(
            for: item,
            mode: .nextUnwatched,
            episodeLimit: episodeLimit,
            qualityID: request.qualityID
        )
        videoOfflineSubscriptionLimitRequest = nil
    }

    func saveVideoOfflineSubscription(
        for item: MediaItem,
        mode: VideoOfflineSubscriptionMode,
        episodeLimit: Int? = nil,
        seasonNumber: Int? = nil,
        qualityID: String? = nil,
        networkPolicy: VideoOfflineSubscriptionNetworkPolicy? = nil
    ) {
        guard let repository = videoOfflineSubscriptionRepository else {
            alert = AppAlert(title: "无法开启自动缓存", message: "离线订阅规则暂不可用，请重启 MediaLIB 后重试。")
            return
        }
        guard let series = videoOfflineSubscriptionSeries(for: item),
              children(for: series).contains(where: cacheableVideoCandidate) else {
            alert = AppAlert(title: "无法开启自动缓存", message: "这个系列没有可缓存的远程剧集。")
            return
        }
        let existing = videoOfflineSubscription(for: series)
        let resolvedSeasonNumber = mode == .season
            ? (seasonNumber ?? videoOfflineSubscriptionSeasonNumber(from: item, in: series))
            : nil
        let resolvedEpisodeLimit = mode == .nextUnwatched ? (episodeLimit ?? existing?.episodeLimit ?? 3) : 1
        let resolvedExpiresAt = existing?.expiresAt.flatMap { $0 > Date() ? $0 : nil }
        let subscription = VideoOfflineSubscription(
            id: existing?.id ?? UUID().uuidString,
            seriesID: series.id,
            seriesTitle: series.title,
            mode: mode,
            episodeLimit: resolvedEpisodeLimit,
            seasonNumber: resolvedSeasonNumber,
            qualityID: qualityID,
            enabled: true,
            pausedUntil: nil,
            expiresAt: resolvedExpiresAt,
            networkPolicy: networkPolicy ?? existing?.networkPolicy ?? .allowRemote,
            createdAt: existing?.createdAt ?? Date()
        )
        do {
            _ = try repository.save(subscription)
            videoOfflineSubscriptions = try repository.fetchAll()
            showFloatingNotice(
                title: "已开启自动缓存",
                message: isPrivateItem(series) ? nil : series.title,
                kind: .success
            )
            scheduleVideoOfflineSubscriptionExpirationCheck(reason: "subscription saved")
            scheduleVideoOfflineSubscriptionMaintenance(reason: "subscription saved", delay: 80_000_000)
        } catch {
            showError("自动缓存设置失败", error)
        }
    }

    func pauseVideoOfflineSubscription(for item: MediaItem, days: Int = 7) {
        updateVideoOfflineSubscription(for: item, successTitle: "已暂停自动缓存") { subscription in
            var updated = subscription
            updated.pausedUntil = Date().addingTimeInterval(Double(max(days, 1)) * 24 * 60 * 60)
            return updated
        }
    }

    func resumeVideoOfflineSubscription(for item: MediaItem) {
        updateVideoOfflineSubscription(for: item, successTitle: "已继续自动缓存") { subscription in
            var updated = subscription
            updated.pausedUntil = nil
            updated.enabled = true
            return updated
        }
        scheduleVideoOfflineSubscriptionMaintenance(reason: "subscription resumed", delay: 80_000_000)
    }

    func setVideoOfflineSubscriptionNetworkPolicy(
        for item: MediaItem,
        policy: VideoOfflineSubscriptionNetworkPolicy
    ) {
        updateVideoOfflineSubscription(for: item, successTitle: "自动缓存网络策略已更新") { subscription in
            var updated = subscription
            updated.networkPolicy = policy
            return updated
        }
        scheduleVideoOfflineSubscriptionMaintenance(reason: "subscription network policy updated", delay: 80_000_000)
    }

    func setVideoOfflineSubscriptionExpiration(for item: MediaItem, days: Int?) {
        let successTitle = days == nil ? "已取消自动缓存到期" : "自动缓存到期已更新"
        updateVideoOfflineSubscription(for: item, successTitle: successTitle) { subscription in
            var updated = subscription
            if let days {
                updated.expiresAt = Date().addingTimeInterval(Double(max(days, 1)) * 24 * 60 * 60)
            } else {
                updated.expiresAt = nil
            }
            return updated
        }
        scheduleVideoOfflineSubscriptionExpirationCheck(reason: "subscription expiration updated")
    }

    func deleteVideoOfflineSubscription(for item: MediaItem) {
        guard let repository = videoOfflineSubscriptionRepository,
              let series = videoOfflineSubscriptionSeries(for: item) else {
            return
        }
        do {
            try repository.delete(seriesID: series.id)
            videoOfflineSubscriptions = try repository.fetchAll()
            scheduleVideoOfflineSubscriptionExpirationCheck(reason: "subscription deleted")
            showFloatingNotice(
                title: "已关闭自动缓存",
                message: isPrivateItem(series) ? nil : series.title,
                kind: .info
            )
        } catch {
            showError("自动缓存设置失败", error)
        }
    }

    private func updateVideoOfflineSubscription(
        for item: MediaItem,
        successTitle: String,
        transform: (VideoOfflineSubscription) -> VideoOfflineSubscription
    ) {
        guard let repository = videoOfflineSubscriptionRepository,
              let series = videoOfflineSubscriptionSeries(for: item),
              let existing = videoOfflineSubscription(for: series) else {
            return
        }
        do {
            _ = try repository.save(transform(existing))
            videoOfflineSubscriptions = try repository.fetchAll()
            scheduleVideoOfflineSubscriptionExpirationCheck(reason: "subscription updated")
            showFloatingNotice(
                title: successTitle,
                message: isPrivateItem(series) ? nil : series.title,
                kind: .success
            )
        } catch {
            showError("自动缓存设置失败", error)
        }
    }

    func chooseVideoCacheDirectory(url: URL?) {
        guard let store = videoOfflineCacheStore else {
            alert = AppAlert(title: "缓存位置不可用", message: "视频缓存清单暂不可用，请重启 MediaLIB 后重试。")
            return
        }
        do {
            try store.setCustomCacheDirectoryPath(url?.path)
            settings.videoCacheDirectoryPath = url?.path
            saveSettings()
            updateVideoCacheStorageSummary()
            showFloatingNotice(
                title: url == nil ? "已恢复默认缓存位置" : "视频缓存位置已更新",
                message: videoCacheDirectoryDisplayPath,
                kind: .success
            )
        } catch {
            showError("缓存位置更新失败", error)
        }
    }

    func deleteVideoCache(_ item: MediaItem) {
        guard let store = videoOfflineCacheStore else {
            alert = AppAlert(title: "无法删除缓存", message: "视频缓存清单暂不可用，请重启 MediaLIB 后重试。")
            return
        }
        let itemIDs = cachedVideoItemIDs(for: item)
        let hidesDetail = isPrivateItem(item) || children(for: item).contains { isPrivateItem($0) }
        guard !itemIDs.isEmpty else {
            showFloatingNotice(
                title: "没有可删除的缓存",
                message: hidesDetail ? nil : item.title,
                kind: .info
            )
            return
        }
        do {
            let removed = try store.remove(itemIDs: itemIDs)
            refreshVideoCacheEntries()
            showFloatingNotice(
                title: removed.count > 1 ? "系列缓存已删除" : "缓存文件已删除",
                message: hidesDetail ? nil : item.title,
                kind: .success
            )
        } catch {
            showError("缓存删除失败", error)
        }
    }

    func updateVideoCacheSizeLimit(_ gigabytes: Double) {
        settings.videoCacheSizeLimitGB = min(max(0, gigabytes), 4096)
        saveSettings()
        updateVideoCacheStorageSummary()
    }

    func cacheVideo(_ item: MediaItem, qualityID: String? = nil) {
        let candidates = cacheableVideoItems(for: item)
        guard !candidates.isEmpty else {
            alert = AppAlert(title: "无法缓存", message: "这个条目没有可缓存的远程视频。")
            return
        }
        guard videoOfflineCacheStore != nil else {
            alert = AppAlert(title: "无法缓存", message: "视频缓存目录暂不可用，请重启 MediaLIB 后重试。")
            return
        }

        let hidesDetail = isPrivateItem(item) || candidates.contains { isPrivateItem($0) }
        let detail = candidates.count > 1 ? "准备缓存 \(candidates.count) 集" : "准备缓存视频"
        startVideoCacheJob(
            item: item,
            title: videoCacheTaskTitle(for: item, hidesDetail: hidesDetail),
            detail: detail,
            candidates: candidates,
            qualityID: qualityID,
            hidesDetail: hidesDetail
        )
    }

    func canGenerateVideoFrameStoryboard(for item: MediaItem) -> Bool {
        !videoFrameStoryboardCandidates(for: item).isEmpty
    }

    func generateVideoFrameStoryboard(for item: MediaItem) {
        let candidates = videoFrameStoryboardCandidates(for: item)
        guard !candidates.isEmpty else {
            alert = AppAlert(title: "无法生成预览图", message: "这个条目没有带时长的可播放视频。")
            return
        }

        let hidesDetail = isPrivateItem(item) || candidates.contains { isPrivateItem($0) }
        let totalFrames = candidates.reduce(0) { partial, candidate in
            partial + VideoFramePreviewGenerator.storyboardBuckets(
                duration: candidate.duration ?? 0,
                preferCoarse: videoFrameStoryboardPrefersFFmpeg(candidate)
            ).count
        }
        guard totalFrames > 0 else {
            alert = AppAlert(title: "无法生成预览图", message: "这个条目的时长信息不足，请播放或重新扫描后再试。")
            return
        }

        let detail = candidates.count > 1 ? "准备生成 \(candidates.count) 个视频的预览图" : "准备生成预览图"
        let taskID = beginBackgroundTask(
            kind: .keyframeStoryboard,
            title: videoFrameStoryboardTaskTitle(for: item, hidesDetail: hidesDetail),
            detail: hidesDetail ? nil : detail,
            progress: 0,
            isCancellable: true,
            hidesDetail: hidesDetail,
            retrySourceID: nil,
            retryItemID: item.id
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runVideoFrameStoryboardTask(
                taskID: taskID,
                item: item,
                candidates: candidates,
                totalFrames: totalFrames,
                hidesDetail: hidesDetail
            )
        }
        keyframeStoryboardTasks[taskID] = task
    }

    func canAnalyzeIntroOutroMarkers(for item: MediaItem) -> Bool {
        !playbackMarkerAnalysisItems(for: item).isEmpty
    }

    func analyzeIntroOutroMarkers(for item: MediaItem) {
        let candidates = playbackMarkerAnalysisItems(for: item)
        guard !candidates.isEmpty else {
            alert = AppAlert(title: "无法检测片头片尾", message: "这个条目没有可分析的视频。")
            return
        }

        let hidesDetail = isPrivateItem(item) || candidates.contains { isPrivateItem($0) }
        let taskID = beginBackgroundTask(
            kind: .markerAnalysis,
            title: hidesDetail ? BackgroundTaskKind.markerAnalysis.title : "片头片尾检测 · \(item.title)",
            detail: hidesDetail ? nil : "准备分析 \(candidates.count) 个视频的内嵌章节",
            progress: 0,
            isCancellable: true,
            hidesDetail: hidesDetail,
            retrySourceID: nil,
            retryItemID: item.id
        )
        let task = Task { [weak self] in
            guard let self else { return }
            await self.runIntroOutroMarkerAnalysisTask(
                taskID: taskID,
                rootItem: item,
                candidates: candidates,
                hidesDetail: hidesDetail
            )
        }
        playbackMarkerAnalysisTasks[taskID] = task
    }

    func runOneClickCleanup() {
        let taskID = beginBackgroundTask(
            kind: .cleanup,
            title: "一键清理",
            detail: "正在整理缓存和任务历史",
            progress: 0,
            isCancellable: false
        )
        let validItemIDs = Set(items.map(\.id))
        let cleanupHint = videoCacheCleanupHint()
        let byteLimit = Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB)
        let store = videoOfflineCacheStore
        let directories = directories
        let existingInactiveTaskCount = backgroundTasks.filter { !$0.state.isActive }.count

        Task { [weak self] in
            do {
                let cacheResult = try await Task.detached(priority: .utility) {
                    try store?.runMaintenance(
                        validItemIDs: validItemIDs,
                        byteLimit: byteLimit,
                        cleanupHint: cleanupHint
                    )
                }.value
                await MainActor.run {
                    guard let self else { return }
                    self.updateBackgroundTask(id: taskID, progress: 0.62, detail: "正在清理任务历史")
                    self.refreshVideoCacheEntries()
                }

                let removedArtworkDirectories = await Task.detached(priority: .utility) {
                    Self.removeEmptyArtworkCacheDirectories(in: directories?.cache)
                }.value
                await MainActor.run {
                    guard let self else { return }
                    let trimmedHistory = self.trimInactiveBackgroundTaskHistory(existingInactiveCount: existingInactiveTaskCount)
                    var result = OneClickCleanupResult()
                    result.missingCacheManifestEntries = cacheResult?.missingManifestEntries ?? 0
                    result.orphanCacheEntries = cacheResult?.orphanManifestEntries ?? 0
                    result.untrackedCacheFiles = cacheResult?.untrackedFiles ?? 0
                    result.overLimitCacheEntries = cacheResult?.overLimitEntries ?? 0
                    if let cacheResult {
                        result.reclaimedVideoCacheBytes = max(cacheResult.bytesBeforeCleanup - cacheResult.bytesAfterCleanup, 0)
                    }
                    result.trimmedTaskHistory = trimmedHistory
                    result.removedEmptyArtworkDirectories = removedArtworkDirectories
                    self.updateBackgroundTask(
                        id: taskID,
                        progress: 1,
                        detail: Self.cleanupResultDetail(result)
                    )
                    self.finishBackgroundTask(id: taskID, errors: [])
                }
            } catch {
                await MainActor.run {
                    self?.finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
                }
            }
        }
    }

    func pauseBackgroundTask(id: UUID) {
        guard var job = videoCacheJobs[id],
              let index = backgroundTasks.firstIndex(where: { $0.id == id }),
              backgroundTasks[index].kind == .videoCache,
              backgroundTasks[index].state == .running else {
            return
        }
        job.isPausing = true
        videoCacheJobs[id] = job
        backgroundTasks[index].state = .pausing
        if !backgroundTasks[index].hidesDetail {
            backgroundTasks[index].detail = "正在暂停缓存"
        }
        job.controller?.pause()
        showFloatingNotice(title: "视频缓存已暂停", message: backgroundTasks[index].title, kind: .info)
    }

    func resumeBackgroundTask(id: UUID) {
        guard var job = videoCacheJobs[id],
              let index = backgroundTasks.firstIndex(where: { $0.id == id }),
              backgroundTasks[index].kind == .videoCache,
              backgroundTasks[index].state == .paused else {
            return
        }
        job.isPausing = false
        backgroundTasks[index].state = .running
        if !backgroundTasks[index].hidesDetail {
            let currentTitle = job.candidates.indices.contains(job.currentIndex)
                ? job.candidates[job.currentIndex].cardTitle
                : job.item.title
            backgroundTasks[index].detail = "继续缓存 \(currentTitle)"
        }
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.runVideoCacheJob(taskID: id)
        }
        job.worker = worker
        videoCacheJobs[id] = job
        showFloatingNotice(title: "视频缓存继续进行", message: backgroundTasks[index].title, kind: .info)
    }

    func cancelBackgroundTask(id: UUID) {
        if let job = videoCacheJobs[id] {
            job.controller?.cancel()
            job.controller?.invalidate()
            job.worker?.cancel()
            videoCacheJobs[id] = nil
            markBackgroundTaskCancelled(id: id, detail: job.hidesDetail ? nil : "缓存任务已取消")
            showFloatingNotice(
                title: "视频缓存已取消",
                message: job.hidesDetail ? nil : job.item.title,
                kind: .warning
            )
            return
        }

        if let task = keyframeStoryboardTasks[id] {
            task.cancel()
            keyframeStoryboardTasks[id] = nil
            markBackgroundTaskCancelled(id: id, detail: "章节图任务已取消")
            showFloatingNotice(
                title: "章节图已取消",
                message: nil,
                kind: .warning
            )
            return
        }

        if let task = playbackMarkerAnalysisTasks[id] {
            task.cancel()
            playbackMarkerAnalysisTasks[id] = nil
            markBackgroundTaskCancelled(id: id, detail: "片头片尾检测已取消")
            showFloatingNotice(
                title: "片头片尾检测已取消",
                message: nil,
                kind: .warning
            )
            return
        }

        guard let task = backgroundTasks.first(where: { $0.id == id }) else { return }
        if task.kind == .fullScan || task.kind == .incrementalScan {
            cancelScanning()
        }
    }

    private func cachedVideoItemIDs(for item: MediaItem) -> Set<String> {
        var ids = Set<String>()
        if isVideoCached(item) {
            ids.insert(item.id)
        }
        for child in children(for: item) where isVideoCached(child) {
            ids.insert(child.id)
        }
        return ids
    }

    private func runVideoCacheJob(taskID: UUID) async {
        while true {
            guard let job = videoCacheJobs[taskID] else { return }
            if Task.isCancelled {
                job.controller?.cancel()
                job.controller?.invalidate()
                markBackgroundTaskCancelled(id: taskID, detail: job.hidesDetail ? nil : "缓存任务已取消")
                videoCacheJobs[taskID] = nil
                return
            }
            if job.isPausing {
                markBackgroundTaskPaused(id: taskID, detail: job.hidesDetail ? nil : "已暂停，可稍后继续")
                return
            }
            guard job.currentIndex < job.candidates.count else {
                job.controller?.invalidate()
                finishBackgroundTask(id: taskID, errors: job.errors)
                videoCacheJobs[taskID] = nil
                if let firstError = job.errors.first {
                    alert = AppAlert(
                        title: "视频缓存失败",
                        message: job.hidesDetail ? "保险库视频缓存时遇到问题，请在任务中心查看状态。" : firstError
                    )
                }
                return
            }

            let candidate = job.candidates[job.currentIndex]
            let total = max(job.candidates.count, 1)
            let controller = job.controller ?? VideoCacheDownloadController()
            videoCacheJobs[taskID]?.controller = controller
            if !job.hidesDetail {
                updateBackgroundTask(
                    id: taskID,
                    progress: Double(job.currentIndex) / Double(total),
                    detail: "正在缓存 \(candidate.cardTitle)"
                )
            }

            do {
                try await cacheSingleVideo(
                    candidate,
                    requestedQualityID: job.qualityID,
                    controller: controller,
                    taskID: taskID,
                    itemIndex: job.currentIndex,
                    totalItems: total,
                    hidesDetail: job.hidesDetail
                )
                guard videoCacheJobs[taskID] != nil else { return }
                controller.invalidate()
                videoCacheJobs[taskID]?.controller = nil
                videoCacheJobs[taskID]?.currentIndex += 1
                updateBackgroundTask(
                    id: taskID,
                    progress: Double(job.currentIndex + 1) / Double(total)
                )
            } catch VideoCacheDownloadControlError.paused {
                guard videoCacheJobs[taskID] != nil else { return }
                videoCacheJobs[taskID]?.controller = controller
                videoCacheJobs[taskID]?.isPausing = false
                videoCacheJobs[taskID]?.worker = nil
                markBackgroundTaskPaused(id: taskID, detail: job.hidesDetail ? nil : "已暂停，可稍后继续")
                return
            } catch VideoCacheDownloadControlError.cancelled {
                controller.invalidate()
                markBackgroundTaskCancelled(id: taskID, detail: job.hidesDetail ? nil : "缓存任务已取消")
                videoCacheJobs[taskID] = nil
                return
            } catch is CancellationError {
                controller.invalidate()
                markBackgroundTaskCancelled(id: taskID, detail: job.hidesDetail ? nil : "缓存任务已取消")
                videoCacheJobs[taskID] = nil
                return
            } catch {
                guard videoCacheJobs[taskID] != nil else { return }
                controller.invalidate()
                let errorTitle = videoCacheDisplayTitle(for: candidate, hidesDetail: job.hidesDetail)
                if job.hidesDetail {
                    logger?.log("视频缓存失败：\(errorTitle)", level: .warning)
                } else {
                    logger?.log("视频缓存失败：\(errorTitle) \(error.localizedDescription)", level: .warning)
                }
                videoCacheJobs[taskID]?.controller = nil
                videoCacheJobs[taskID]?.currentIndex += 1
                let errorDetail = job.hidesDetail ? "缓存失败" : error.localizedDescription
                videoCacheJobs[taskID]?.errors.append("\(errorTitle)：\(errorDetail)")
                updateBackgroundTask(
                    id: taskID,
                    progress: Double(job.currentIndex + 1) / Double(total)
                )
            }
        }
    }

    private func trimInactiveBackgroundTaskHistory(existingInactiveCount: Int) -> Int {
        let activeTasks = backgroundTasks.filter(\.state.isActive)
        let inactiveTasks = backgroundTasks
            .filter { !$0.state.isActive }
            .sorted { lhs, rhs in
                (lhs.finishedAt ?? lhs.startedAt) > (rhs.finishedAt ?? rhs.startedAt)
            }
        let keptInactive = Array(inactiveTasks.prefix(24))
        let nextTasks = (activeTasks + keptInactive).sorted { lhs, rhs in
            lhs.startedAt > rhs.startedAt
        }
        let removed = max(existingInactiveCount - keptInactive.count, 0)
        if removed > 0 {
            backgroundTasks = nextTasks
        }
        return removed
    }

    nonisolated private static func removeEmptyArtworkCacheDirectories(in cacheDirectory: URL?) -> Int {
        guard let cacheDirectory else { return 0 }
        let fileManager = FileManager.default
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var removed = 0
        for url in contents where url.lastPathComponent.localizedCaseInsensitiveContains("artwork") {
            guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true,
                  (try? fileManager.contentsOfDirectory(atPath: url.path).isEmpty) == true else { continue }
            do {
                try fileManager.removeItem(at: url)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    nonisolated private static func cleanupResultDetail(_ result: OneClickCleanupResult) -> String {
        guard result.total > 0 else {
            return "缓存和任务历史已经很干净"
        }
        var parts: [String] = []
        let removedCacheEntries = result.missingCacheManifestEntries + result.orphanCacheEntries
        if removedCacheEntries > 0 {
            parts.append("清理 \(removedCacheEntries) 条缓存记录")
        }
        if result.untrackedCacheFiles > 0 {
            parts.append("删除 \(result.untrackedCacheFiles) 个无用缓存文件")
        }
        if result.overLimitCacheEntries > 0 {
            let reclaimed = result.reclaimedVideoCacheBytes > 0 ? "，释放 \(Self.shortByteCount(result.reclaimedVideoCacheBytes))" : ""
            parts.append("回收 \(result.overLimitCacheEntries) 个超限缓存\(reclaimed)")
        }
        if result.trimmedTaskHistory > 0 {
            parts.append("整理 \(result.trimmedTaskHistory) 条任务历史")
        }
        if result.removedEmptyArtworkDirectories > 0 {
            parts.append("移除 \(result.removedEmptyArtworkDirectories) 个空缓存目录")
        }
        return parts.joined(separator: "，")
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

    private func userVisibleNoticeTitle(for item: MediaItem) -> String? {
        isPrivateItem(item) && !canDisplayPrivateItems ? nil : item.cardTitle
    }

    private func mediaStateNoticeMessage(for item: MediaItem, suffix: String? = nil) -> String? {
        let title = userVisibleNoticeTitle(for: item)
        switch (title, suffix) {
        case let (title?, suffix?) where !suffix.isEmpty:
            return "\(title) · \(suffix)"
        case let (title?, _):
            return title
        case let (nil, suffix?) where !suffix.isEmpty:
            return suffix
        default:
            return nil
        }
    }

    private func showMediaStateNotice(
        title: String,
        item: MediaItem,
        suffix: String? = nil,
        kind: AppFloatingNoticeKind = .info
    ) {
        showFloatingNotice(
            title: title,
            message: mediaStateNoticeMessage(for: item, suffix: suffix),
            kind: kind,
            duration: 3.2
        )
    }

    private func userRatingNoticeSuffix(_ rating: Double?) -> String {
        guard let rating, rating.isFinite, rating > 0 else { return "已清除星级" }
        let rounded = (rating * 10).rounded() / 10
        if rounded.rounded() == rounded {
            return "\(Int(rounded)) 星"
        }
        return String(format: "%.1f 星", rounded)
    }

    private func videoCacheTaskTitle(for item: MediaItem, hidesDetail: Bool) -> String {
        hidesDetail ? BackgroundTaskKind.videoCache.title : "视频缓存 · \(item.title)"
    }

    private func videoFrameStoryboardTaskTitle(for item: MediaItem, hidesDetail: Bool) -> String {
        hidesDetail ? BackgroundTaskKind.keyframeStoryboard.title : "章节图 · \(item.title)"
    }

    private func videoCacheDisplayTitle(for item: MediaItem, hidesDetail: Bool) -> String {
        hidesDetail ? "保险库视频" : item.cardTitle
    }

    private func videoFrameStoryboardCandidates(for item: MediaItem) -> [MediaItem] {
        let children = children(for: item)
        let rawCandidates = children.isEmpty ? [item] : children
        return rawCandidates.compactMap { rawItem in
            var prepared = videoFrameStoryboardPlayableItem(for: rawItem)
            if prepared.duration == nil {
                prepared.duration = rawItem.duration
            }
            guard prepared.type != .music,
                  let filePath = prepared.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !filePath.isEmpty,
                  let duration = prepared.duration,
                  duration.isFinite,
                  duration > 1 else {
                return nil
            }
            return prepared
        }
    }

    private func videoFrameStoryboardPlayableItem(for item: MediaItem) -> MediaItem {
        guard let store = videoOfflineCacheStore,
              let entry = store.entry(for: item.id) else {
            return item
        }
        return VideoOfflineCacheStore.itemWithCache(item, entry: entry)
    }

    private func videoFrameStoryboardPrefersFFmpeg(_ item: MediaItem) -> Bool {
        item.isRemoteResource || RemoteVideoQualityPlanner.isMountedNetworkFile(for: item)
    }

    private func playbackMarkerAnalysisItems(for item: MediaItem) -> [MediaItem] {
        let children = children(for: item)
        let rawCandidates = children.isEmpty ? [item] : children
        return rawCandidates.filter { candidate in
            guard candidate.type != .music,
                  let duration = candidate.duration,
                  duration.isFinite,
                  duration > 60 else {
                return false
            }
            return true
        }
    }

    private func automaticIntroOutroCandidates(
        for item: MediaItem,
        existingMarkers: [PlaybackMarker]
    ) -> [PlaybackMarker] {
        let existingIDs = Set(existingMarkers.map(\.id))
        let acceptedKinds = Set(existingMarkers.compactMap { marker -> PlaybackMarker.Kind? in
            guard (marker.kind == .intro || marker.kind == .credits),
                  marker.isCompleteRange,
                  marker.isAcceptedForPlayback else { return nil }
            return marker.kind
        })
        let duration = item.duration ?? 0
        let embeddedChapters = existingMarkers
            .filter { $0.kind == .chapter && $0.origin == .embedded && $0.isCompleteRange }
            .sorted { $0.startTime < $1.startTime }

        var candidates: [PlaybackMarker] = []
        for chapter in embeddedChapters {
            guard let kind = automaticMarkerKind(fromChapterTitle: chapter.title),
                  !acceptedKinds.contains(kind),
                  let endTime = chapter.endTime,
                  automaticMarkerRangeIsPlausible(kind: kind, start: chapter.startTime, end: endTime, duration: duration) else {
                continue
            }
            let id = "automatic-\(item.id)-\(kind.rawValue)-\(chapter.id)"
            guard !existingIDs.contains(id),
                  !candidates.contains(where: { $0.kind == kind }) else { continue }
            candidates.append(
                PlaybackMarker(
                    id: id,
                    mediaID: item.id,
                    kind: kind,
                    title: kind.title,
                    startTime: chapter.startTime,
                    endTime: endTime,
                    origin: .automatic,
                    reviewStatus: .pending,
                    detectorIdentifier: "embedded-chapter-keyword",
                    confidence: automaticMarkerConfidence(for: chapter.title)
                )
            )
        }
        return candidates
    }

    private func automaticMarkerKind(fromChapterTitle title: String) -> PlaybackMarker.Kind? {
        let normalized = title
            .folding(options: [.diacriticInsensitive, .widthInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return nil }

        let introKeywords = ["片头", "opening", "op", "intro", "オープニング", "開頭", "开场"]
        let creditsKeywords = ["片尾", "ending", "ed", "credits", "credit", "エンディング", "スタッフ", "staff roll"]
        if introKeywords.contains(where: { automaticMarkerTitle(normalized, matches: $0) }) {
            return .intro
        }
        if creditsKeywords.contains(where: { automaticMarkerTitle(normalized, matches: $0) }) {
            return .credits
        }
        return nil
    }

    private func automaticMarkerTitle(_ title: String, matches keyword: String) -> Bool {
        if keyword.count <= 2 {
            return title == keyword ||
                title.contains(" \(keyword) ") ||
                title.contains("[\(keyword)]") ||
                title.contains("(\(keyword))") ||
                title.contains("【\(keyword)】")
        }
        return title.contains(keyword)
    }

    private func automaticMarkerRangeIsPlausible(
        kind: PlaybackMarker.Kind,
        start: Double,
        end: Double,
        duration: Double
    ) -> Bool {
        guard duration.isFinite, duration > 60, end > start else { return false }
        let length = end - start
        switch kind {
        case .intro:
            return length >= 12 && length <= 180 && start <= max(duration * 0.35, 420)
        case .credits:
            return length >= 12 && length <= 720 && start >= duration * 0.45
        case .chapter, .bookmark:
            return false
        }
    }

    private func automaticMarkerConfidence(for title: String) -> Double {
        let normalized = title.lowercased()
        if normalized.contains("opening") ||
            normalized.contains("ending") ||
            normalized.contains("credits") ||
            normalized.contains("片头") ||
            normalized.contains("片尾") {
            return 0.88
        }
        return 0.76
    }

    private func safeSourceLogLabel(_ source: MediaSource) -> String {
        source.mediaType == .privateCollection ? "保险库媒体源" : "\(source.name) \(source.path)"
    }

    /// 用户可见提示只在保险库锁定时隐藏名称；日志始终通过 safeSourceLogLabel 泛化。
    private func safeSourceUserLabel(_ source: MediaSource) -> String {
        source.mediaType == .privateCollection && !canDisplayPrivateItems ? "保险库媒体源" : source.name
    }

    private static func isRemoteMediaServerItem(_ item: MediaItem) -> Bool {
        EmbyService.isMediaServerSourcePath(item.sourcePath)
    }

    private static func isEmbyItem(_ item: MediaItem) -> Bool {
        isRemoteMediaServerItem(item)
    }

    private static func remoteConnectorProvider(for source: MediaSource) -> RemoteConnectorProvider? {
        switch source.sourceKind {
        case .emby:
            return .emby
        case .jellyfin:
            return .jellyfin
        case .plex:
            return .plex
        default:
            return nil
        }
    }

    /// 从远程媒体源推断可展示的服务器地址（emby://host/... → host），回落到源名称。
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
            let fetchedItems = try mediaRepository?.fetchAll() ?? []
            musicPlaylists = try musicPlaylistRepository?.fetchAll() ?? []
            videoSmartCollections = try videoSmartCollectionRepository?.fetchAll() ?? []
            videoManualCollections = try videoManualCollectionRepository?.fetchAll() ?? []
            videoOfflineSubscriptions = try videoOfflineSubscriptionRepository?.fetchAll() ?? []
            musicSmartPlaylists = try musicSmartPlaylistRepository?.fetchAll() ?? []
            metadataCorrectionCountsByMediaID = try metadataCorrectionRepository?.activeCountsByMediaID() ?? [:]
            metadataCorrectionRecordCount = try metadataCorrectionRepository?.activeRecordCount() ?? 0
            metadataCorrectionBatches = try metadataCorrectionRepository?.fetchActiveBatches(limit: 120) ?? []
            pendingSyncConflictCount = try syncConflictRepository?.pendingCount() ?? 0
            pendingSyncConflicts = try syncConflictRepository?.fetchPending(limit: 120) ?? []
            remoteConnectorAccounts = try remoteConnectorAccountRepository?.fetchAll() ?? []
            items = fetchedItems
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
            pruneExpiredVideoOfflineSubscriptions(reason: "library reload", notify: false)
            scheduleVideoOfflineSubscriptionExpirationCheck(reason: "library reload")
            scheduleVideoOfflineSubscriptionMaintenance(reason: "library reload")
            logPerformance("reload.total: \(Self.milliseconds(since: reloadStart))ms revision=\(libraryRevision) posterRevision=\(posterRevision)")
        } catch {
            showError("加载媒体库失败", error)
        }
    }

    private func rebuildDerivedItemCaches() {
        // Pass 1：建立父子索引，并从保险库根节点向下传播私密标记。
        // 保险库可能是“集合 -> 剧集 -> 单集”的多层结构，只看直接 parent 会漏掉更深的后代。
        let privateCollectionIDs = Set(items.lazy.filter { $0.type == .privateCollection }.map(\.id))
        var childrenByParentID: [String: [MediaItem]] = [:]
        for item in items {
            if let parentID = item.parentID {
                childrenByParentID[parentID, default: []].append(item)
            }
        }

        var privateItemIDs = privateCollectionIDs
        var privateQueue = Array(privateCollectionIDs)
        var privateQueueIndex = 0
        while privateQueueIndex < privateQueue.count {
            let parentID = privateQueue[privateQueueIndex]
            privateQueueIndex += 1
            for child in childrenByParentID[parentID] ?? [] {
                if privateItemIDs.insert(child.id).inserted {
                    privateQueue.append(child.id)
                }
            }
        }

        // Pass 2：单次遍历分拣所有 item，同时收集统计数据。
        // 避免原来 12+ 次独立 filter/reduce 各自遍历全量数组。
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
            let isPrivate = privateItemIDs.contains(item.id)

            if !isEmby,
               item.type != .music,
               item.hasPlaybackTrace,
               !(item.watched || item.playProgress >= watchedThreshold) {
                if isPrivate {
                    privateWatchingRaw.append(item)
                } else {
                    watchingRaw.append(item)
                }
            }

            if item.parentID != nil {
                // 剧集统计
                if !isPrivate {
                    episodeCount += 1
                    let isWatched = item.watched || item.playProgress >= watchedThreshold
                    if isWatched { watchedEpisodeCount += 1 }
                    if !isEmby, item.type != .music, !isWatched, item.hasPlaybackTrace {
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
                if !isPrivate {
                    let displayItem = Self.classifiedEmbyTopLevelItem(item)
                    embyTopLevelRaw.append(displayItem)
                    if displayItem.type != .music {
                        let isWatched = displayItem.watched || displayItem.playProgress >= watchedThreshold
                        let isUnwatched = !displayItem.watched && displayItem.playProgress < watchedThreshold
                        switch displayItem.type {
                        case .movie:
                            movieCount += 1
                            if isWatched {
                                watchedMovieCount += 1
                                totalWatchedMinutes += displayItem.runtime ?? Int((displayItem.duration ?? 0) / 60)
                            }
                        default:
                            seriesCount += 1
                        }
                        if isUnwatched { unwatchedCount += 1 }
                        if displayItem.favorite { favoriteCount += 1 }
                    }
                    if displayItem.type != .music, displayItem.filePath != nil, displayItem.playProgress > 0, displayItem.playProgress < 0.95 {
                        continueWatchingRaw.append(displayItem)
                    }
                }
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

            let isWatched = item.watched || item.playProgress >= watchedThreshold
            let isUnwatched = !item.watched && item.playProgress < watchedThreshold

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
        cachedHomeVideoItems = (cachedTopLevelItems + cachedEmbyTopLevelItems.filter { $0.type != .music })
            .sorted { $0.updatedAt > $1.updatedAt }
        cachedHomeOfflineVideoItems = cachedHomeVideoItems.filter { includesCachedVideo($0) }
        cachedContinueWatchingItems = continueWatchingRaw.sorted { ($0.lastPlayedAt ?? .distantPast) > ($1.lastPlayedAt ?? .distantPast) }
        cachedWatchingItems = watchingRaw.sorted(by: Self.playbackRecencySort)
        cachedPrivateWatchingItems = privateWatchingRaw.sorted(by: Self.playbackRecencySort)
        cachedMissingMetadataItems = missingMetadataRaw.sorted { $0.updatedAt > $1.updatedAt }

        var embyLibraryByID: [String: EmbyLibrarySummary] = [:]
        for item in cachedEmbyTopLevelItems {
            guard let sourcePath = item.sourcePath,
                  let info = EmbyService.libraryInfo(from: sourcePath) else { continue }
            let rootPath = EmbyService.sourceRootPath(from: sourcePath) ?? sourcePath
            let source = sources.first { Self.isSourcePath(rootPath, inside: $0.path) }
            let sourceID = source?.id ?? rootPath
            let summaryID = "\(sourceID)::\(info.id)"
            embyLibraryByID[summaryID] = EmbyLibrarySummary(
                id: summaryID,
                sourceID: source?.id ?? "",
                viewID: info.id,
                name: info.name ?? "远程分类",
                collectionType: info.collectionType,
                sourceName: source?.name ?? "远程媒体库"
            )
        }
        cachedEmbyLibrarySummaries = embyLibraryByID.values.sorted {
            $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
        }

        // #9 下一集：仅针对”用户已经看完过至少一集”的系列，展示其最后一个看完的集之后的那一具体集。
        // 完全没看过任何一集的系列不进入这里（它们属于”未观看”），看到最后一集的系列也不再出现。
        cachedNextUpItems = Array(cachedHomeVideoItems.compactMap { series -> MediaItem? in
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
            case .offline:
                return !cachedHomeOfflineVideoItems.isEmpty
            case .recent:
                return !cachedHomeVideoItems.isEmpty
            case .movies:
                return cachedHomeVideoItems.contains { $0.type == .movie }
            case .tvShows:
                return cachedHomeVideoItems.contains { $0.type == .tvShow }
            case .anime:
                return cachedHomeVideoItems.contains { $0.type == .anime }
            case .documentaries:
                return cachedHomeVideoItems.contains { $0.type == .documentary }
            case .variety:
                return cachedHomeVideoItems.contains { $0.type == .variety }
            case .music:
                return !cachedMusicTracks.isEmpty
            case .other:
                return cachedHomeVideoItems.contains { $0.type == .other }
            case .favorites:
                return cachedHomeVideoItems.contains { $0.type != .music && $0.favorite }
            case .unwatched:
                return cachedHomeVideoItems.contains { $0.type != .music && !$0.watched && $0.playProgress < settings.watchedThreshold }
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
                return hasVideoWatchlist
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

    private static func classifiedEmbyTopLevelItem(_ item: MediaItem) -> MediaItem {
        guard isEmbyItem(item), item.parentID == nil, item.type != .music else { return item }
        let hint: LibraryClassificationHint?
        if let sourcePath = item.sourcePath,
           let info = EmbyService.libraryInfo(from: sourcePath) {
            hint = LibraryClassificationHint(libraryName: info.name, collectionType: info.collectionType)
        } else {
            hint = nil
        }
        guard let type = inferredEmbyMediaType(for: item, hint: hint) else { return item }
        var copy = item
        copy.type = type
        return copy
    }

    private static func inferredEmbyMediaType(for item: MediaItem, hint: LibraryClassificationHint?) -> MediaType? {
        if let fromName = inferMediaType(fromLibraryName: hint?.libraryName) {
            return fromName
        }
        if let fromGenre = inferMediaType(fromGenre: item.genre) {
            return fromGenre
        }
        if let fromCollection = inferMediaType(fromCollectionType: hint?.collectionType) {
            return fromCollection
        }
        return item.type == .episode ? .tvShow : item.type
    }

    private static func inferMediaType(fromLibraryName name: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(name), !normalized.isEmpty else { return nil }
        let rules: [(MediaType, [String])] = [
            (.anime, ["动漫", "动画", "番剧", "新番", "国漫", "日漫", "anime", "animation", "bangumi", "cartoon"]),
            (.documentary, ["纪录", "纪实", "documentary", "docu"]),
            (.variety, ["综艺", "真人秀", "脱口秀", "variety", "reality", "talk show", "talkshow"]),
            (.movie, ["电影", "影片", "影院", "movie", "movies", "film", "cinema"]),
            (.tvShow, ["电视剧", "剧集", "连续剧", "美剧", "日剧", "韩剧", "英剧", "华语剧", "tv", "series", "drama", "shows"])
        ]
        return rules.first { _, keywords in keywords.contains { normalized.contains($0) } }?.0
    }

    private static func inferMediaType(fromCollectionType collectionType: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(collectionType), !normalized.isEmpty else { return nil }
        if normalized.contains("movies") || normalized == "movie" { return .movie }
        if normalized.contains("music") { return .music }
        if normalized.contains("tvshows") || normalized.contains("series") { return .tvShow }
        return nil
    }

    private static func inferMediaType(fromGenre genre: String?) -> MediaType? {
        guard let normalized = normalizedClassifierText(genre), !normalized.isEmpty else { return nil }
        let rules: [(MediaType, [String])] = [
            (.anime, ["动画", "动漫", "animation", "anime"]),
            (.documentary, ["纪录", "documentary"]),
            (.variety, ["综艺", "真人秀", "脱口秀", "reality", "talk", "variety"])
        ]
        return rules.first { _, keywords in keywords.contains { normalized.contains($0) } }?.0
    }

    private static func normalizedClassifierText(_ text: String?) -> String? {
        guard let text else { return nil }
        return (text.removingPercentEncoding ?? text)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    private nonisolated static func playbackRecencySort(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        (lhs.lastPlayedAt ?? lhs.updatedAt) > (rhs.lastPlayedAt ?? rhs.updatedAt)
    }

    /// 条目的来源路径是否落在"不参与健康检查"的来源里。
    nonisolated static func sourcePathExcluded(_ sourcePath: String?, in excludedPaths: [String]) -> Bool {
        guard let sourcePath, !excludedPaths.isEmpty else { return false }
        return excludedPaths.contains { isSourcePath(sourcePath, inside: $0) }
    }

    /// 来源归属判断必须有路径边界：`/Media/A` 不能匹配 `/Media/Anime`，
    /// `emby://server/source` 也不能匹配 `emby://server/source2`。所有来源过滤统一走这里。
    nonisolated static func isSourcePath(_ candidate: String?, inside sourceRoot: String) -> Bool {
        guard let candidate, !sourceRoot.isEmpty else { return false }
        let sourceRoot = normalizedSourceRoot(sourceRoot)
        guard !sourceRoot.isEmpty else { return false }
        if sourceRoot == "/" {
            return candidate.hasPrefix("/")
        }
        return candidate == sourceRoot || candidate.hasPrefix("\(sourceRoot)/")
    }

    private nonisolated static func normalizedSourceRoot(_ sourceRoot: String) -> String {
        var normalized = sourceRoot
        while normalized.count > 1,
              normalized.hasSuffix("/"),
              !normalized.hasSuffix("://") {
            normalized.removeLast()
        }
        return normalized
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
                          item.type != .music,
                          let sourcePath = item.sourcePath,
                          let source = sourceSnapshots
                              .filter({
                                  $0.includeInHealthCheck &&
                                  Self.isSourcePath(sourcePath, inside: $0.path)
                              })
                              .max(by: { $0.path.count < $1.path.count }),
                          !Self.sourcePathExcluded(sourcePath, in: healthExcludedPaths) else {
                        return nil
                    }

                    let trimmedFilePath = item.filePath?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                    if source.sourceKind.isRemoteMediaServer {
                        return trimmedFilePath.isEmpty ? item.id : nil
                    }

                    guard !trimmedFilePath.isEmpty,
                          !item.isRemoteResource,
                          !FileManager.default.fileExists(atPath: trimmedFilePath) else {
                        return nil
                    }
                    return item.id
                })

                let offlineSourceIDs = Set(sourceSnapshots.compactMap { source -> String? in
                    guard !source.sourceKind.isRemoteMediaServer,
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
                        .filter { Self.isSourcePath(sourcePath, inside: $0.path) }
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
        if source.sourceKind.isRemoteMediaServer {
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
            .filter { Self.isSourcePath(sourcePath, inside: $0.path) }
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

    func addSource(
        url: URL,
        mediaType: MediaType = .auto,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        preferMetadataWriteToSource: Bool = false
    ) {
        guard let sourceRepository else { return }
        guard !sources.contains(where: { $0.path == url.path }) else {
            alert = duplicateMediaSourceAlert(for: [url], mediaType: mediaType)
            return
        }
        let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
        let source = MediaSource(
            name: name,
            path: url.path,
            mediaType: mediaType,
            minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024,
            includeInMetadataFetch: includeInMetadataFetch,
            preferMetadataWriteToSource: includeInMetadataFetch && preferMetadataWriteToSource,
            includeInHealthCheck: includeInHealthCheck
        )
        do {
            try sourceRepository.save(source)
            reload()
            scan(source)
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    func addSources(
        urls: [URL],
        mediaType: MediaType = .auto,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        preferMetadataWriteToSource: Bool = false
    ) {
        guard let sourceRepository else { return }
        let existingPaths = Set(sources.map(\.path))
        let newURLs = urls.filter { !existingPaths.contains($0.path) }
        guard !newURLs.isEmpty else {
            alert = duplicateMediaSourceAlert(for: urls, mediaType: mediaType)
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
                    minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024,
                    includeInMetadataFetch: includeInMetadataFetch,
                    preferMetadataWriteToSource: includeInMetadataFetch && preferMetadataWriteToSource,
                    includeInHealthCheck: includeInHealthCheck
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

    func connectEmbyServer(
        server: String,
        username: String,
        password: String,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional
    ) async {
        await connectRemoteMediaServer(
            provider: .emby,
            server: server,
            username: username,
            password: password,
            includeInMetadataFetch: includeInMetadataFetch,
            includeInHealthCheck: includeInHealthCheck,
            remoteTraceSyncMode: remoteTraceSyncMode
        )
    }

    func connectJellyfinServer(
        server: String,
        username: String,
        password: String,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional
    ) async {
        await connectRemoteMediaServer(
            provider: .jellyfin,
            server: server,
            username: username,
            password: password,
            includeInMetadataFetch: includeInMetadataFetch,
            includeInHealthCheck: includeInHealthCheck,
            remoteTraceSyncMode: remoteTraceSyncMode
        )
    }

    func connectPlexServer(
        server: String,
        token: String,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional
    ) async {
        let provider: RemoteConnectorProvider = .plex
        if isConnectingRemoteMediaServer(provider) {
            alert = AppAlert(title: "Plex 正在连接", message: "当前连接完成后会自动显示结果。")
            return
        }
        setConnectingRemoteMediaServer(provider, connecting: true)
        defer { setConnectingRemoteMediaServer(provider, connecting: false) }

        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedToken = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else {
            alert = AppAlert(title: "Plex 地址无效", message: "请输入服务器地址，例如 http://192.168.1.20:32400。")
            return
        }
        guard !trimmedToken.isEmpty else {
            alert = AppAlert(title: "Plex Token 为空", message: "请输入 Plex 服务器 Token 后再连接。")
            return
        }
        let normalizedServer = trimmedServer.contains("://") ? trimmedServer : "http://\(trimmedServer)"
        guard let components = URLComponents(string: normalizedServer),
              components.host != nil,
              let serverURL = components.url else {
            alert = AppAlert(title: "Plex 地址无效", message: "无法识别该服务器地址，请检查后重试。")
            return
        }

        let sourceID = UUID().uuidString
        let hostName = serverURL.host ?? "Plex"
        let sourcePath = "plex://\(hostName)/\(sourceID)"
        let source = MediaSource(
            id: sourceID,
            name: provider.mediaSourceDisplayName,
            path: sourcePath,
            mediaType: .auto,
            autoScan: false,
            minimumFileSize: 0,
            preferLocalArtwork: false,
            networkScrapingEnabled: false,
            screenshotFallbackEnabled: false,
            includeInMetadataFetch: includeInMetadataFetch,
            includeInHealthCheck: includeInHealthCheck,
            remoteTraceSyncMode: remoteTraceSyncMode
        )
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "Plex 同步",
            detail: "正在连接并同步媒体库",
            progress: nil,
            isCancellable: false,
            retrySourceID: sourceID
        )
        var sourceSaved = false
        do {
            let session = try await plexService.authenticate(serverURL: serverURL, token: trimmedToken)
            try sourceRepository?.save(source)
            sourceSaved = true
            try remoteCredentialStore.save(
                RemoteSourceCredential(
                    kind: provider.credentialKind,
                    serverURL: session.serverURL.absoluteString,
                    username: nil,
                    password: nil,
                    accessToken: session.accessToken,
                    userID: session.machineIdentifier
                ),
                sourceID: sourceID
            )
            try remoteConnectorAccountRepository?.save(
                RemoteConnectorAccount(
                    provider: provider,
                    accountLabel: "Plex · \(hostName)",
                    serverURL: session.serverURL.absoluteString,
                    username: nil,
                    sourceID: sourceID,
                    connectionMode: .library,
                    syncEnabled: true,
                    capabilitiesJSON: provider.mediaServerCapabilitiesJSON,
                    privacyNote: "Plex Token 仅保存在本机 MediaLIB 受限凭据文件中。",
                    lastSyncedAt: Date()
                )
            )
            try await importPlexItems(source: source, session: session)
            reload()
            finishBackgroundTask(id: taskID, errors: [])
            alert = AppAlert(title: "Plex 已连接", message: "\(hostName) 的媒体库已同步到 Plex 目录。")
        } catch {
            if sourceSaved {
                try? remoteConnectorAccountRepository?.delete(sourceID: sourceID)
                remoteCredentialStore.delete(sourceID: sourceID)
                try? sourceRepository?.delete(id: sourceID)
            }
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            showError("Plex 连接失败", error)
        }
    }

    private func connectRemoteMediaServer(
        provider: RemoteConnectorProvider,
        server: String,
        username: String,
        password: String,
        includeInMetadataFetch: Bool,
        includeInHealthCheck: Bool,
        remoteTraceSyncMode: RemoteTraceSyncMode
    ) async {
        guard provider == .emby || provider == .jellyfin else { return }
        if isConnectingRemoteMediaServer(provider) {
            alert = AppAlert(title: "\(provider.displayName) 正在连接", message: "当前连接完成后会自动显示结果。")
            return
        }
        setConnectingRemoteMediaServer(provider, connecting: true)
        defer { setConnectingRemoteMediaServer(provider, connecting: false) }

        let trimmedServer = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedServer.isEmpty else {
            alert = AppAlert(title: "\(provider.displayName) 地址无效", message: "请输入服务器地址，例如 http://192.168.1.20:8096。")
            return
        }
        let normalizedServer = trimmedServer.contains("://") ? trimmedServer : "http://\(trimmedServer)"
        guard let components = URLComponents(string: normalizedServer),
              components.host != nil,
              let serverURL = components.url else {
            alert = AppAlert(title: "\(provider.displayName) 地址无效", message: "无法识别该服务器地址，请检查后重试。")
            return
        }

        let sourceID = UUID().uuidString
        let hostName = serverURL.host ?? provider.displayName
        let sourcePath = "\(provider.mediaSourceScheme)://\(hostName)/\(sourceID)"
        let source = MediaSource(
            id: sourceID,
            name: provider.mediaSourceDisplayName,
            path: sourcePath,
            mediaType: .auto,
            autoScan: false,
            minimumFileSize: 0,
            preferLocalArtwork: false,
            networkScrapingEnabled: false,
            screenshotFallbackEnabled: false,
            includeInMetadataFetch: includeInMetadataFetch,
            includeInHealthCheck: includeInHealthCheck,
            remoteTraceSyncMode: remoteTraceSyncMode
        )
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "\(provider.displayName) 同步",
            detail: "正在登录并同步媒体库",
            progress: nil,
            isCancellable: false,
            retrySourceID: sourceID
        )
        var sourceSaved = false
        do {
            let session = try await embyService.authenticate(
                serverURL: serverURL,
                username: trimmedUsername,
                password: password,
                provider: provider
            )
            try sourceRepository?.save(source)
            sourceSaved = true
            try remoteCredentialStore.save(
                RemoteSourceCredential(
                    kind: provider.credentialKind,
                    serverURL: session.serverURL.absoluteString,
                    username: session.username,
                    password: password,
                    accessToken: session.accessToken,
                    userID: session.userID
                ),
                sourceID: sourceID
            )
            try remoteConnectorAccountRepository?.save(
                RemoteConnectorAccount(
                    provider: provider,
                    accountLabel: "\(provider.displayName) · \(hostName)",
                    serverURL: session.serverURL.absoluteString,
                    username: session.username,
                    sourceID: sourceID,
                    connectionMode: .library,
                    syncEnabled: true,
                    capabilitiesJSON: provider.mediaServerCapabilitiesJSON,
                    privacyNote: "凭据仅保存在本机 MediaLIB 受限凭据文件中。",
                    lastSyncedAt: Date()
                )
            )
            try await importEmbyItems(source: source, session: session)
            reload()
            finishBackgroundTask(id: taskID, errors: [])
            alert = AppAlert(title: "\(provider.displayName) 已连接", message: "\(hostName) 的媒体库已同步到 \(provider.mediaSourceDisplayName) 目录。")
        } catch {
            if sourceSaved {
                try? remoteConnectorAccountRepository?.delete(sourceID: sourceID)
                remoteCredentialStore.delete(sourceID: sourceID)
                try? sourceRepository?.delete(id: sourceID)
            }
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            if !presentEmbyRestrictionIfNeeded(error, serverHost: hostName) {
                showError("\(provider.displayName) 连接失败", error)
            }
        }
    }

    private func isConnectingRemoteMediaServer(_ provider: RemoteConnectorProvider) -> Bool {
        switch provider {
        case .emby:
            return isConnectingEmby
        case .jellyfin:
            return isConnectingJellyfin
        case .plex:
            return isConnectingPlex
        default:
            return false
        }
    }

    private func setConnectingRemoteMediaServer(_ provider: RemoteConnectorProvider, connecting: Bool) {
        switch provider {
        case .emby:
            isConnectingEmby = connecting
        case .jellyfin:
            isConnectingJellyfin = connecting
        case .plex:
            isConnectingPlex = connecting
        default:
            break
        }
    }

    func addNetworkMountedSource(
        networkURL: String,
        mountedDirectory: URL,
        username: String?,
        password: String?,
        mediaType: MediaType,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        preferMetadataWriteToSource: Bool = false
    ) {
        guard let sourceRepository else { return }
        let trimmed = networkURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["smb", "ftp", "ftps"].contains(scheme) else {
            alert = AppAlert(title: "网络地址无效", message: "请输入 smb://、ftp:// 或 ftps:// 开头的地址。")
            return
        }
        guard !sources.contains(where: { $0.path == mountedDirectory.path }) else {
            alert = duplicateMediaSourceAlert(for: [mountedDirectory], mediaType: mediaType)
            return
        }

        let sourceID = UUID().uuidString
        let name = "\(scheme.uppercased()) \(url.host ?? mountedDirectory.lastPathComponent)"
        let source = MediaSource(
            id: sourceID,
            name: name,
            path: mountedDirectory.path,
            mediaType: mediaType,
            minimumFileSize: mediaType == .music ? 512 * 1024 : 50 * 1024 * 1024,
            includeInMetadataFetch: includeInMetadataFetch,
            preferMetadataWriteToSource: includeInMetadataFetch && preferMetadataWriteToSource,
            includeInHealthCheck: includeInHealthCheck
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

    private func duplicateMediaSourceAlert(for urls: [URL], mediaType: MediaType) -> AppAlert {
        if mediaType == .privateCollection {
            let name = settings.privacyVaultName
            return AppAlert(
                title: "媒体源已存在",
                message: urls.count == 1 ? "该\(name)媒体源已添加。" : "所选\(name)媒体源均已添加。"
            )
        }
        if urls.count == 1, let url = urls.first {
            let displayName = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
            return AppAlert(title: "媒体源已存在", message: "目录「\(displayName)」已添加为媒体源。")
        }
        return AppAlert(title: "媒体源已存在", message: "所选目录均已添加为媒体源。")
    }

    private func refreshEmbySource(_ source: MediaSource) async {
        let provider = Self.remoteConnectorProvider(for: source) ?? .emby
        if provider == .plex {
            await refreshPlexSource(source)
            return
        }
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "\(provider.displayName) 同步 · \(source.name)",
            detail: "正在同步服务端媒体库",
            progress: nil,
            isCancellable: false,
            retrySourceID: source.id
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
                showError("\(provider.displayName) 同步失败", error)
            }
        }
    }

    private func refreshPlexSource(_ source: MediaSource) async {
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "Plex 同步 · \(source.name)",
            detail: "正在同步服务端媒体库",
            progress: nil,
            isCancellable: false,
            retrySourceID: source.id
        )
        do {
            try await withValidPlexSession(for: source) { session in
                try await importPlexItems(source: source, session: session)
            }
            finishBackgroundTask(id: taskID, errors: [])
            reload()
        } catch {
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            showError("Plex 同步失败", error)
        }
    }

    func loadEmbyLibraries(for source: MediaSource) async throws -> [EmbyLibrarySummary] {
        guard source.sourceKind.isRemoteMediaServer else { return [] }
        if source.sourceKind == .plex {
            return try await withValidPlexSession(for: source) { session in
                try await plexService.fetchLibraries(
                    session: session,
                    sourceID: source.id,
                    sourceName: source.name
                )
            }
        }
        return try await withValidEmbySession(for: source) { session in
            try await embyService.fetchLibraries(
                session: session,
                sourceID: source.id,
                sourceName: source.name
            )
        }
    }

    func updateEmbyLibrarySelection(source: MediaSource, selectedLibraryIDs: Set<String>) async {
        guard source.sourceKind.isRemoteMediaServer else { return }
        let provider = Self.remoteConnectorProvider(for: source) ?? .emby
        do {
            var updated = source
            updated.selectedEmbyLibraryIDs = Array(selectedLibraryIDs)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .sorted()
            updated.updatedAt = Date()
            try sourceRepository?.save(updated)
            let message = updated.selectedEmbyLibraryIDs.isEmpty ? "将同步全部服务器媒体库。" : "正在按选择刷新媒体库。"
            deliverTaskNotice(
                title: "\(provider.mediaSourceDisplayName) 同步范围已更新",
                message: message,
                kind: .success,
                systemTitle: "\(provider.mediaSourceDisplayName) 同步范围已更新",
                systemBody: message
            )
            reload()
            await refreshEmbySource(updated)
        } catch {
            deliverTaskNotice(
                title: "\(provider.displayName) 同步范围更新失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "\(provider.displayName) 同步范围更新失败",
                systemBody: error.localizedDescription
            )
        }
    }

    private func importEmbyItems(source: MediaSource, session: EmbySession) async throws {
        guard let mediaRepository else { return }
        var embyItems = try await embyService.fetchItems(
            session: session,
            sourceID: source.id,
            sourcePath: source.path,
            selectedLibraryIDs: Set(source.selectedEmbyLibraryIDs)
        )
        if source.remoteTraceSyncMode == .disabled {
            embyItems = embyItems.map(preservingLocalTraceForDisabledEmbySync)
        }
        try mediaRepository.replaceRemoteItems(sourcePathPrefix: source.path, with: embyItems)
        scheduleEmbyArtworkWarmup(source: source, items: embyItems)
    }

    private func importPlexItems(source: MediaSource, session: PlexSession) async throws {
        guard let mediaRepository else { return }
        var plexItems = try await plexService.fetchItems(
            session: session,
            sourceID: source.id,
            sourcePath: source.path,
            selectedLibraryIDs: Set(source.selectedEmbyLibraryIDs)
        )
        if source.remoteTraceSyncMode == .disabled {
            plexItems = plexItems.map(preservingLocalTraceForDisabledEmbySync)
        }
        try mediaRepository.replaceRemoteItems(sourcePathPrefix: source.path, with: plexItems)
        scheduleEmbyArtworkWarmup(source: source, items: plexItems)
    }

    private func preservingLocalTraceForDisabledEmbySync(_ incoming: MediaItem) -> MediaItem {
        guard let existing = items.first(where: { $0.id == incoming.id }) else { return incoming }
        var copy = incoming
        copy.playPosition = existing.playPosition
        copy.playProgress = existing.playProgress
        copy.watched = existing.watched
        copy.favorite = existing.favorite
        copy.watchlist = existing.watchlist
        copy.lastPlayedAt = existing.lastPlayedAt
        copy.userRating = existing.userRating ?? incoming.userRating
        return copy
    }

    private func scheduleEmbyArtworkWarmup(source: MediaSource, items: [MediaItem]) {
        let urls = Array(Set(items.compactMap { item -> URL? in
            guard let posterPath = item.posterPath,
                  let url = URL(string: posterPath),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url
        }))
        guard !urls.isEmpty else { return }

        embyArtworkWarmupTasks[source.id]?.cancel()
        let taskID = beginBackgroundTask(
            kind: .artworkWarmup,
            title: "封面预热 · \(source.name)",
            detail: "准备缓存 \(urls.count) 张封面",
            progress: 0,
            isCancellable: false,
            retrySourceID: source.id
        )
        let task = Task { [weak self] in
            guard let self else { return }
            var processed = 0
            for url in urls {
                guard !Task.isCancelled else { return }
                _ = await ArtworkImageCache.prewarmRemoteImage(url: url, targetSize: CGSize(width: 260, height: 390))
                processed += 1
                if processed == urls.count || processed % 6 == 0 {
                    self.updateBackgroundTask(
                        id: taskID,
                        progress: Double(processed) / Double(max(urls.count, 1)),
                        detail: "已缓存 \(processed)/\(urls.count) 张封面"
                    )
                }
            }
            self.embyArtworkWarmupTasks[source.id] = nil
            self.finishBackgroundTask(id: taskID, errors: [])
        }
        embyArtworkWarmupTasks[source.id] = task
    }

    private func withValidEmbySession<T>(
        for source: MediaSource,
        operation: (EmbySession) async throws -> T
    ) async throws -> T {
        let provider = Self.remoteConnectorProvider(for: source) ?? .emby
        guard var credential = try remoteCredentialStore.load(sourceID: source.id),
              credential.kind == provider.credentialKind,
              let serverURL = URL(string: credential.serverURL),
              let accessToken = credential.accessToken,
              let userID = credential.userID else {
            throw NSError(
                domain: "MediaLib.\(provider.displayName)",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的登录信息不存在，请重新连接 \(provider.displayName)。"]
            )
        }
        let session = EmbySession(
            serverURL: serverURL,
            username: credential.username ?? source.name,
            userID: userID,
            accessToken: accessToken,
            provider: provider
        )
        do {
            return try await operation(session)
        } catch {
            guard embyService.isAuthenticationFailure(error) else { throw error }
            guard let username = credential.username, !username.isEmpty,
                  let password = credential.password else {
                throw NSError(
                    domain: "MediaLib.\(provider.displayName)",
                    code: 401,
                    userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的旧登录凭据无法自动恢复，请删除该媒体源并重新连接一次。"]
                )
            }
            let refreshed = try await embyService.authenticate(
                serverURL: serverURL,
                username: username,
                password: password,
                provider: provider
            )
            credential.serverURL = refreshed.serverURL.absoluteString
            credential.username = refreshed.username
            credential.accessToken = refreshed.accessToken
            credential.userID = refreshed.userID
            try remoteCredentialStore.save(credential, sourceID: source.id)
            logger?.log("\(provider.displayName) token 已自动恢复：\(source.name)")
            return try await operation(refreshed)
        }
    }

    private func withValidPlexSession<T>(
        for source: MediaSource,
        operation: (PlexSession) async throws -> T
    ) async throws -> T {
        guard let credential = try remoteCredentialStore.load(sourceID: source.id),
              credential.kind == RemoteConnectorProvider.plex.credentialKind,
              let serverURL = URL(string: credential.serverURL),
              let accessToken = credential.accessToken,
              !accessToken.isEmpty else {
            throw NSError(
                domain: "MediaLib.Plex",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的 Plex Token 不存在，请重新连接 Plex。"]
            )
        }
        let session = PlexSession(
            serverURL: serverURL,
            accessToken: accessToken,
            machineIdentifier: credential.userID,
            serverName: source.name
        )
        do {
            return try await operation(session)
        } catch {
            guard plexService.isAuthenticationFailure(error) else { throw error }
            throw NSError(
                domain: "MediaLib.Plex",
                code: 401,
                userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的 Plex Token 已失效，请删除该媒体源并重新连接一次。"]
            )
        }
    }

    private func embySource(for item: MediaItem) -> MediaSource? {
        guard Self.isEmbyItem(item) else { return nil }
        return sources.first { source in
            source.sourceKind.isRemoteMediaServer &&
            Self.isSourcePath(item.sourcePath, inside: source.path)
        }
    }

    func syncEmbyPlayback(_ report: PlayerPlaybackReport) {
        guard let source = embySource(for: report.item),
              source.remoteTraceSyncMode == .bidirectional,
              let externalID = report.item.externalID else { return }

        if source.sourceKind == .plex {
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
                    try await self.withValidPlexSession(for: source) { session in
                        try await self.plexService.reportPlayback(
                            session: session,
                            itemID: externalID,
                            phase: phase,
                            position: report.position,
                            isPaused: report.isPaused
                        )
                    }
                } catch is CancellationError {
                    return
                } catch {
                    self.logger?.log("Plex 播放状态同步失败：\(error.localizedDescription)", level: .warning)
                }
            }
            return
        }

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
                self.logger?.log("远程播放状态同步失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    private func syncEmbyFavorite(_ item: MediaItem, favorite: Bool) async throws {
        guard let source = embySource(for: item),
              source.remoteTraceSyncMode == .bidirectional,
              let externalID = item.externalID else { return }
        if source.sourceKind == .plex {
            return
        }
        try await withValidEmbySession(for: source) { session in
            try await embyService.setFavorite(session: session, itemID: externalID, favorite: favorite)
        }
    }

    private func syncEmbyPlayed(_ item: MediaItem, played: Bool) async throws {
        guard let source = embySource(for: item),
              source.remoteTraceSyncMode == .bidirectional,
              let externalID = item.externalID else { return }
        if source.sourceKind == .plex {
            try await withValidPlexSession(for: source) { session in
                try await plexService.setPlayed(session: session, itemID: externalID, played: played)
            }
            return
        }
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
                    self.logger?.log("远程已观看状态同步失败：\(error.localizedDescription)", level: .warning)
                }
            }
            if failedCount > 0 {
                let message = "有 \(failedCount) 个条目未能写回远程服务器，请检查连接后重新操作。"
                self.deliverTaskNotice(
                    title: "远程状态同步失败",
                    message: message,
                    kind: .error,
                    systemTitle: "远程状态同步失败",
                    systemBody: message
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
            try mediaRepository?.deleteItems(sourcePathPrefix: source.path)
            try sourceRepository?.delete(id: source.id)
            try remoteConnectorAccountRepository?.delete(sourceID: source.id)
            remoteCredentialStore.delete(sourceID: source.id)
            reload()
        } catch {
            showError("删除媒体源失败", error)
        }
    }

    @discardableResult
    func updateSource(_ source: MediaSource, notify: Bool = true) -> Bool {
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
            if notify {
                let title = source.sourceKind.isRemoteMediaServer ? "\(source.sourceKind.displayName) 设置已保存" : "媒体源设置已保存"
                let message = source.sourceKind.isRemoteMediaServer ? source.name : safeSourceUserLabel(source)
                deliverTaskNotice(
                    title: title,
                    message: message,
                    kind: .success,
                    systemTitle: title,
                    systemBody: "\(message) 已保存。"
                )
            }
            return true
        } catch {
            deliverTaskNotice(
                title: "媒体源更新失败",
                message: error.localizedDescription,
                kind: .error,
                systemTitle: "媒体源更新失败",
                systemBody: error.localizedDescription
            )
            return false
        }
    }

    private func invalidateHealthCaches(forSourcePath sourcePath: String, sourceID: String) {
        fileHealthTask?.cancel()
        fileHealthRefreshID = UUID()
        cachedMissingFileItems.removeAll { item in
            Self.isSourcePath(item.sourcePath, inside: sourcePath)
        }
        cachedSafeMissingFileItemIDs = Set(cachedMissingFileItems.map(\.id)).intersection(cachedSafeMissingFileItemIDs)
        cachedOfflineSourceIDs.remove(sourceID)
        cachedOfflineSources.removeAll { $0.id == sourceID }
    }

    func scanAllSources() {
        let emby = sources.filter { $0.sourceKind.isRemoteMediaServer }
        let local = sources.filter { !$0.sourceKind.isRemoteMediaServer }
        refreshEmbySources(emby)
        startScanQueue(local)
    }

    func scanSources(for destination: SidebarDestination) {
        switch destination {
        case .home, .health, .tasks, .sources, .settings:
            scanAllSources()
        case .embySection(let sourceID, _):
            guard let source = sources.first(where: { $0.id == sourceID && $0.sourceKind.isRemoteMediaServer }) else {
                alert = AppAlert(title: "无法扫描", message: "当前远程媒体分类没有可同步的媒体源。")
                return
            }
            refreshEmbySources([source])
        case .embyLibrary(let libraryID):
            guard let summary = cachedEmbyLibrarySummaries.first(where: { $0.id == libraryID }),
                  let source = sources.first(where: { $0.id == summary.sourceID && $0.sourceKind.isRemoteMediaServer }) else {
                alert = AppAlert(title: "无法扫描", message: "当前远程媒体库没有可同步的媒体源。")
                return
            }
            refreshEmbySources([source])
        case .music(.playlists):
            alert = AppAlert(title: "歌单无需扫描", message: "可从歌曲菜单或播放队列中添加歌曲。")
        case .music:
            scanLocalSources(mediaTypes: [.music], emptyMessage: "当前音乐分类没有可扫描的音乐媒体源。")
        case .smartCollection:
            scanLocalSources(mediaTypes: Self.videoScanTypes, emptyMessage: "当前智能集合没有可扫描的本地视频媒体源。")
        case .manualCollection:
            scanLocalSources(mediaTypes: Self.videoScanTypes, emptyMessage: "当前集合没有可扫描的本地视频媒体源。")
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
        case .offline:
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
        if source.sourceKind.isRemoteMediaServer {
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
            !source.sourceKind.isRemoteMediaServer && (mediaTypes.contains(source.mediaType) || source.mediaType == .auto)
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
        source.sourceKind.isRemoteMediaServer || FileAccessService.isReachableDirectory(source.path)
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
                let sourceName = self.safeSourceUserLabel(source)
                alert = AppAlert(title: "已重新挂载", message: "\(sourceName) 已恢复访问，可以继续扫描或播放。")
            } else {
                let sourceName = self.safeSourceUserLabel(source)
                alert = AppAlert(title: "重新挂载失败", message: "macOS 仍无法访问 \(sourceName)。请确认远程设备已开机、网络可达且账号密码没有变化。")
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

        let sourceLabel = safeSourceLogLabel(source)
        logger?.log("尝试重新挂载网络媒体源：\(sourceLabel)")
        guard NSWorkspace.shared.open(mountURL) else {
            let serverLabel = source.mediaType == .privateCollection ? "保险库网络地址" : credential.serverURL
            logger?.log("触发网络媒体源挂载失败：\(sourceLabel) \(serverLabel)", level: .warning)
            return false
        }

        for _ in 0..<16 {
            try? await Task.sleep(nanoseconds: 700_000_000)
            if isSourceCurrentlyReachable(source) {
                logger?.log("网络媒体源已重新挂载：\(sourceLabel)")
                return true
            }
        }
        logger?.log("网络媒体源重新挂载超时：\(sourceLabel)", level: .warning)
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
                    let sourceLabel = self.safeSourceUserLabel(source)
                    logger?.log("增量扫描跳过不可访问来源：\(sourceLabel)", level: .warning)
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
        markCancellableScanTasksCancelled()
        reload()
    }

    func clearCompletedBackgroundTasks() {
        backgroundTasks.removeAll { !$0.state.isActive }
    }

    func canRetryBackgroundTask(_ task: BackgroundTaskSnapshot) -> Bool {
        guard task.state == .failed,
              !hasActiveRetryEquivalent(for: task) else {
            return false
        }
        switch task.kind {
        case .fullScan, .incrementalScan:
            guard let source = backgroundTaskRetrySource(for: task),
                  !source.sourceKind.isRemoteMediaServer else {
                return false
            }
            return true
        case .embySync:
            guard let source = backgroundTaskRetrySource(for: task) else { return false }
            return source.sourceKind.isRemoteMediaServer
        case .artworkWarmup:
            guard let source = backgroundTaskRetrySource(for: task),
                  source.sourceKind.isRemoteMediaServer else {
                return false
            }
            return items.contains { item in
                guard let sourcePath = item.sourcePath else { return false }
                return Self.isSourcePath(sourcePath, inside: source.path)
            }
        case .cleanup:
            return true
        case .metadataSupplement:
            return !isSupplementingMetadata
        case .videoCache:
            guard videoOfflineCacheStore != nil,
                  let item = backgroundTaskRetryItem(for: task) else {
                return false
            }
            return !videoCacheQualityChoices(for: item).isEmpty
        case .keyframeStoryboard:
            guard let item = backgroundTaskRetryItem(for: task) else { return false }
            return canGenerateVideoFrameStoryboard(for: item)
        case .markerAnalysis:
            guard let item = backgroundTaskRetryItem(for: task) else { return false }
            return canAnalyzeIntroOutroMarkers(for: item)
        }
    }

    func retryBackgroundTask(_ task: BackgroundTaskSnapshot) {
        guard canRetryBackgroundTask(task) else {
            alert = AppAlert(title: "无法重试任务", message: "这个任务缺少可重建的目标，或同一目标已经有任务在运行。")
            return
        }

        switch task.kind {
        case .fullScan, .incrementalScan:
            guard let source = backgroundTaskRetrySource(for: task) else { return }
            startScanQueue([source])
        case .embySync:
            guard let source = backgroundTaskRetrySource(for: task) else { return }
            refreshEmbySources([source])
        case .artworkWarmup:
            guard let source = backgroundTaskRetrySource(for: task) else { return }
            let sourceItems = items.filter { item in
                guard let sourcePath = item.sourcePath else { return false }
                return Self.isSourcePath(sourcePath, inside: source.path)
            }
            scheduleEmbyArtworkWarmup(source: source, items: sourceItems)
        case .cleanup:
            runOneClickCleanup()
        case .metadataSupplement:
            supplementMissingMetadataFromHealth()
        case .videoCache:
            guard let item = backgroundTaskRetryItem(for: task) else { return }
            cacheVideo(item, qualityID: task.retryQualityID)
        case .keyframeStoryboard:
            guard let item = backgroundTaskRetryItem(for: task) else { return }
            generateVideoFrameStoryboard(for: item)
        case .markerAnalysis:
            guard let item = backgroundTaskRetryItem(for: task) else { return }
            analyzeIntroOutroMarkers(for: item)
        }
    }

    private func backgroundTaskRetrySource(for task: BackgroundTaskSnapshot) -> MediaSource? {
        guard let sourceID = task.retrySourceID else { return nil }
        return sources.first { $0.id == sourceID }
    }

    private func backgroundTaskRetryItem(for task: BackgroundTaskSnapshot) -> MediaItem? {
        guard let itemID = task.retryItemID else { return nil }
        return items.first { $0.id == itemID }
    }

    private func hasActiveRetryEquivalent(for task: BackgroundTaskSnapshot) -> Bool {
        backgroundTasks.contains { candidate in
            guard candidate.id != task.id,
                  candidate.state.isActive,
                  candidate.kind == task.kind else {
                return false
            }
            if let sourceID = task.retrySourceID {
                return candidate.retrySourceID == sourceID
            }
            if let itemID = task.retryItemID {
                return candidate.retryItemID == itemID
            }
            return task.kind == .cleanup || task.kind == .metadataSupplement
        }
    }

    func showFloatingNotice(
        title: String,
        message: String? = nil,
        kind: AppFloatingNoticeKind = .info,
        duration: TimeInterval = 4.2
    ) {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else { return }
        let trimmedMessage = message?.trimmingCharacters(in: .whitespacesAndNewlines)
        let notice = AppFloatingNotice(
            title: trimmedTitle,
            message: trimmedMessage?.isEmpty == false ? trimmedMessage : nil,
            kind: kind
        )
        enqueueFloatingNotice(PendingFloatingNotice(notice: notice, duration: duration))
    }

    private func enqueueFloatingNotice(_ pending: PendingFloatingNotice) {
        if floatingNotices.isEmpty {
            presentFloatingNotice(pending)
            return
        }
        floatingNoticeQueue.append(pending)
        if floatingNoticeQueue.count > 12 {
            floatingNoticeQueue.removeFirst(floatingNoticeQueue.count - 12)
        }
    }

    private func presentFloatingNotice(_ pending: PendingFloatingNotice) {
        let notice = pending.notice
        floatingNotices = [notice]
        floatingNoticeDismissTasks[notice.id]?.cancel()
        floatingNoticeDismissTasks[notice.id] = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(max(pending.duration, 1.2) * 1_000_000_000))
            } catch {
                return
            }
            await MainActor.run {
                self?.dismissFloatingNotice(id: notice.id)
            }
        }
    }

    func dismissFloatingNotice(id: UUID) {
        floatingNoticeDismissTasks[id]?.cancel()
        floatingNoticeDismissTasks[id] = nil
        floatingNoticeQueue.removeAll { $0.notice.id == id }
        floatingNotices.removeAll { $0.id == id }
        presentNextFloatingNoticeIfNeeded()
    }

    private func presentNextFloatingNoticeIfNeeded() {
        guard floatingNotices.isEmpty, !floatingNoticeQueue.isEmpty else { return }
        let next = floatingNoticeQueue.removeFirst()
        presentFloatingNotice(next)
    }

    private func deliverTaskNotice(
        title: String,
        message: String?,
        kind: AppFloatingNoticeKind,
        duration: TimeInterval = 4.2,
        systemTitle: String? = nil,
        systemBody: String? = nil
    ) {
        guard !NSApplication.shared.isActive else {
            showFloatingNotice(title: title, message: message, kind: kind, duration: duration)
            return
        }

        let notice = AppFloatingNotice(title: title, message: message, kind: kind)
        let pending = PendingFloatingNotice(notice: notice, duration: duration)
        guard settings.notifyOnTaskCompletion else {
            enqueueForegroundFallbackNotice(pending)
            return
        }

        SystemNotificationCenter.post(
            title: systemTitle ?? title,
            body: systemBody ?? message ?? title
        ) { [weak self] delivered in
            guard let self, !delivered else { return }
            self.enqueueForegroundFallbackNotice(pending)
        }
    }

    private func enqueueForegroundFallbackNotice(_ pending: PendingFloatingNotice) {
        if NSApplication.shared.isActive {
            enqueueFloatingNotice(pending)
            return
        }
        foregroundFallbackNotices.append(pending)
        if foregroundFallbackNotices.count > 12 {
            foregroundFallbackNotices.removeFirst(foregroundFallbackNotices.count - 12)
        }
    }

    private func flushForegroundFallbackNotices() {
        guard !foregroundFallbackNotices.isEmpty else { return }
        let pending = foregroundFallbackNotices
        foregroundFallbackNotices.removeAll()
        pending.forEach(enqueueFloatingNotice)
    }

    func showInterfaceTipOnce(key: String, title: String = "提示", message: String) {
        loadShownInterfaceTipKeysIfNeeded()
        guard shownInterfaceTipKeys.insert(key).inserted else { return }
        UserDefaults.standard.set(Array(shownInterfaceTipKeys).sorted(), forKey: Self.shownInterfaceTipDefaultsKey)
        showFloatingNotice(title: title, message: message, kind: .tip, duration: 5.8)
    }

    private func loadShownInterfaceTipKeysIfNeeded() {
        guard !didLoadShownInterfaceTipKeys else { return }
        shownInterfaceTipKeys = Set(UserDefaults.standard.stringArray(forKey: Self.shownInterfaceTipDefaultsKey) ?? [])
        didLoadShownInterfaceTipKeys = true
    }

    private func beginBackgroundTask(
        kind: BackgroundTaskKind,
        source: MediaSource,
        detail: String?,
        isCancellable: Bool = true
    ) -> UUID {
        let hidesDetail = source.mediaType == .privateCollection
        let task = BackgroundTaskSnapshot(
            kind: kind,
            state: .running,
            title: hidesDetail ? kind.title : "\(kind.title) · \(source.name)",
            detail: hidesDetail ? nil : detail,
            progress: kind == .embySync ? nil : 0,
            isCancellable: isCancellable,
            hidesDetail: hidesDetail,
            retrySourceID: source.id
        )
        backgroundTasks.insert(task, at: 0)
        if backgroundTasks.count > 40 {
            backgroundTasks.removeLast(backgroundTasks.count - 40)
        }
        showBackgroundTaskQueuedNotice(task)
        return task.id
    }

    private var backgroundTasksURL: URL? {
        directories?.applicationSupport.appendingPathComponent("BackgroundTasks.json", isDirectory: false)
    }

    private func restoreBackgroundTasksIfPossible() {
        guard let url = backgroundTasksURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([BackgroundTaskSnapshot].self, from: data) else { return }
        isRestoringBackgroundTasks = true
        backgroundTasks = decoded.prefix(60).map { task in
            var restored = task
            if restored.hidesDetail {
                restored.title = restored.kind.title
                restored.detail = nil
            }
            guard task.state.isActive else { return restored }
            restored.state = .failed
            restored.finishedAt = restored.finishedAt ?? Date()
            restored.isCancellable = false
            if !restored.hidesDetail {
                restored.detail = "上次退出时任务尚未完成。"
            }
            return restored
        }
        isRestoringBackgroundTasks = false
        persistBackgroundTasksIfPossible()
    }

    private func persistBackgroundTasksIfPossible() {
        guard !isRestoringBackgroundTasks, let url = backgroundTasksURL else { return }
        let persisted = Array(backgroundTasks.prefix(60))
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(persisted)
            try data.write(to: url, options: [.atomic])
        } catch {
            logger?.log("任务中心历史保存失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func beginBackgroundTask(
        kind: BackgroundTaskKind,
        title: String? = nil,
        detail: String?,
        progress: Double? = 0,
        isCancellable: Bool = true,
        hidesDetail: Bool = false,
        retrySourceID: String? = nil,
        retryItemID: String? = nil,
        retryQualityID: String? = nil
    ) -> UUID {
        let safeTitle = hidesDetail ? kind.title : (title ?? kind.title)
        let task = BackgroundTaskSnapshot(
            kind: kind,
            state: .running,
            title: safeTitle,
            detail: hidesDetail ? nil : detail,
            progress: progress,
            isCancellable: isCancellable,
            hidesDetail: hidesDetail,
            retrySourceID: retrySourceID,
            retryItemID: retryItemID,
            retryQualityID: retryQualityID
        )
        backgroundTasks.insert(task, at: 0)
        if backgroundTasks.count > 40 {
            backgroundTasks.removeLast(backgroundTasks.count - 40)
        }
        showBackgroundTaskQueuedNotice(task)
        return task.id
    }

    private func updateBackgroundTask(id: UUID, with progress: ScanProgress) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = backgroundTasks[index].progress ?? 0
        let next = progress.fraction
        guard next >= 1 || abs(next - previous) >= 0.025 else { return }
        backgroundTasks[index].progress = next
    }

    private func updateBackgroundTask(id: UUID, progress: Double?, detail: String? = nil) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        if let progress {
            let previous = backgroundTasks[index].progress ?? 0
            let clamped = min(max(progress, 0), 1)
            guard clamped >= 1 || abs(clamped - previous) >= 0.025 || detail != nil else { return }
            backgroundTasks[index].progress = clamped
        }
        if let detail, !backgroundTasks[index].hidesDetail {
            backgroundTasks[index].detail = detail
        }
    }

    private func finishBackgroundTask(id: UUID, errors: [String]) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = errors.isEmpty ? .completed : .failed
        backgroundTasks[index].detail = backgroundTasks[index].hidesDetail ? nil : (errors.first ?? backgroundTasks[index].detail)
        backgroundTasks[index].progress = 1
        backgroundTasks[index].finishedAt = Date()
        backgroundTasks[index].isCancellable = false
        let task = backgroundTasks[index]
        let failed = !errors.isEmpty
        let noticeTitle = failed ? "\(task.kind.title)遇到问题" : "\(task.kind.title)已完成"
        let noticeMessage = task.hidesDetail ? nil : (errors.first ?? task.title)
        let safeTitle = task.hidesDetail ? task.kind.title : task.title
        let systemTitle = safeTitle + (failed ? " · 有错误" : " · 已完成")
        let systemBody: String
        if failed {
            systemBody = task.hidesDetail ? "\(task.kind.title)遇到问题，请回到 MediaLIB 查看任务中心。" : (errors.first ?? "任务执行过程中出现错误。")
        } else {
            systemBody = "\(safeTitle)已完成。"
        }
        deliverTaskNotice(
            title: noticeTitle,
            message: noticeMessage,
            kind: failed ? .error : .success,
            systemTitle: systemTitle,
            systemBody: systemBody
        )
    }

    private func showBackgroundTaskQueuedNotice(_ task: BackgroundTaskSnapshot) {
        showFloatingNotice(
            title: "\(task.kind.title)已加入任务",
            message: task.hidesDetail ? nil : queuedBackgroundTaskNoticeMessage(for: task),
            kind: .info
        )
    }

    private func queuedBackgroundTaskNoticeMessage(for task: BackgroundTaskSnapshot) -> String? {
        let detail = task.detail?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard task.title != task.kind.title else {
            return detail?.isEmpty == false ? detail : nil
        }
        if let detail, !detail.isEmpty {
            return "\(task.title) · \(detail)"
        }
        return task.title
    }

    private func markBackgroundTaskPaused(id: UUID, detail: String?) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = .paused
        if let detail, !backgroundTasks[index].hidesDetail {
            backgroundTasks[index].detail = detail
        }
    }

    private func markBackgroundTaskCancelled(id: UUID, detail: String?) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = .cancelled
        backgroundTasks[index].finishedAt = Date()
        backgroundTasks[index].isCancellable = false
        if let detail, !backgroundTasks[index].hidesDetail {
            backgroundTasks[index].detail = detail
        }
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

    private func markCancellableScanTasksCancelled() {
        for index in backgroundTasks.indices
            where backgroundTasks[index].state.isActive &&
            backgroundTasks[index].isCancellable &&
            (backgroundTasks[index].kind == .fullScan || backgroundTasks[index].kind == .incrementalScan) {
            backgroundTasks[index].state = .cancelled
            backgroundTasks[index].finishedAt = Date()
            backgroundTasks[index].isCancellable = false
        }
    }

    private func cancelAllCancellableBackgroundTasks() {
        videoCacheJobs.values.forEach { job in
            job.controller?.cancel()
            job.controller?.invalidate()
            job.worker?.cancel()
        }
        videoCacheJobs.removeAll()
        keyframeStoryboardTasks.values.forEach { $0.cancel() }
        keyframeStoryboardTasks.removeAll()
        playbackMarkerAnalysisTasks.values.forEach { $0.cancel() }
        playbackMarkerAnalysisTasks.removeAll()
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
        markCancellableScanTasksCancelled()
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
        if let cachedItem = cachedPlayableItem(for: item) {
            playPreparedItem(cachedItem, preserveSelection: preserveSelection)
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
                        self.showError("远程播放准备失败", error)
                    }
                }
            }
            return
        }
        playPreparedItem(item, preserveSelection: preserveSelection)
    }

    private func prepareEmbyItemForPlayback(_ item: MediaItem) async throws -> MediaItem {
        guard let source = embySource(for: item) else { return item }
        if source.sourceKind == .plex {
            return try await withValidPlexSession(for: source) { session in
                try await plexService.validateSession(session)
                var prepared = item
                prepared.filePath = plexService.refreshedResourceURLString(item.filePath, session: session)
                return prepared
            }
        }
        return try await withValidEmbySession(for: source) { session in
            try await embyService.validateSession(session)
            var prepared = item
            prepared.filePath = embyService.refreshedResourceURLString(item.filePath, session: session)
            return prepared
        }
    }

    private func cachedPlayableItem(for item: MediaItem) -> MediaItem? {
        guard let store = videoOfflineCacheStore else { return nil }
        if let entry = store.entry(for: item.id) {
            try? store.markAccessed(itemID: item.id)
            updateVideoCacheStorageSummary()
            return VideoOfflineCacheStore.itemWithCache(item, entry: entry)
        }
        refreshVideoCacheEntries(pruningMissingFiles: true)
        return nil
    }

    private func refreshVideoCacheEntries(pruningMissingFiles: Bool = false) {
        guard let store = videoOfflineCacheStore else {
            if !cachedVideoEntriesByItemID.isEmpty {
                cachedVideoEntriesByItemID = [:]
                rebuildHomeOfflineVideoCache()
                videoCacheRevision += 1
            }
            videoCacheStorageSummary = VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
            return
        }
        do {
            let next = pruningMissingFiles ? try store.refreshEntriesPruningMissingFiles() : store.allEntries()
            if next != cachedVideoEntriesByItemID {
                cachedVideoEntriesByItemID = next
                rebuildHomeOfflineVideoCache()
                videoCacheRevision += 1
            }
            updateVideoCacheStorageSummary()
        } catch {
            logger?.log("刷新视频缓存清单失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func cacheSingleVideo(
        _ item: MediaItem,
        requestedQualityID: String?,
        controller: VideoCacheDownloadController,
        taskID: UUID,
        itemIndex: Int,
        totalItems: Int,
        hidesDetail: Bool
    ) async throws {
        guard let store = videoOfflineCacheStore else { throw VideoOfflineCacheStoreError.unsupportedItem }
        let prepared = Self.isEmbyItem(item) ? try await prepareEmbyItemForPlayback(item) : item
        try ensureVideoCacheJobCanContinue(taskID: taskID)
        guard cacheableVideoCandidate(prepared),
              let remotePath = prepared.filePath,
              URL(string: remotePath) != nil else {
            throw VideoOfflineCacheStoreError.invalidRemoteURL
        }

        let options = RemoteVideoQualityPlanner.options(for: prepared, knownMountedNetworkFile: false)
            .filter { !$0.appliesInPlace }
        let selectedOption = selectedCacheOption(for: prepared, options: options, requestedQualityID: requestedQualityID)
        guard let selectedURL = URL(string: selectedOption.baseURLString) else {
            throw VideoOfflineCacheStoreError.invalidRemoteURL
        }
        try ensureVideoCacheJobCanContinue(taskID: taskID)
        let cacheQualityID = cacheQualityIdentifier(for: selectedOption)
        let destination = store.destinationURL(
            for: prepared,
            qualityID: cacheQualityID,
            remoteURL: selectedURL,
            isTranscode: !selectedOption.isOriginal
        )
        try removeExistingVideoCacheBeforeRedownload(itemID: item.id, taskID: taskID, store: store)
        let progressThrottler = VideoCacheProgressThrottler()
        let (temporaryURL, response) = try await controller.download(from: selectedURL) { [weak self] progress in
            let fileFraction = Self.videoCacheFileFraction(progress)
            let overall = (Double(itemIndex) + fileFraction) / Double(max(totalItems, 1))
            guard progressThrottler.shouldPublish(overall) else { return }
            Task { @MainActor in
                guard let self, self.videoCacheJobs[taskID] != nil else { return }
                let detail = self.videoCacheProgressDetail(
                    title: self.videoCacheDisplayTitle(for: item, hidesDetail: hidesDetail),
                    fileFraction: fileFraction,
                    receivedBytes: progress.receivedBytes,
                    expectedBytes: progress.expectedBytes
                )
                self.updateBackgroundTask(id: taskID, progress: overall, detail: detail)
            }
        }
        updateBackgroundTask(
            id: taskID,
            progress: (Double(itemIndex) + 0.96) / Double(max(totalItems, 1)),
            detail: hidesDetail ? nil : "正在保存 \(item.cardTitle)"
        )
        do {
            try ensureVideoCacheJobCanContinue(taskID: taskID)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw error
        }
        let fileSize = try await Self.moveVideoCacheDownload(
            temporaryURL: temporaryURL,
            response: response,
            destination: destination
        )
        if Task.isCancelled || videoCacheJobs[taskID] == nil {
            throw CancellationError()
        }
        await syncVideoCacheSidecarsIfNeeded(
            item: prepared,
            selectedOption: selectedOption,
            destination: destination,
            hidesDetail: hidesDetail
        )
        let entry = VideoCacheEntry(
            itemID: item.id,
            parentID: item.parentID,
            title: item.title,
            localPath: destination.path,
            qualityID: cacheQualityID,
            qualityLabel: selectedOption.label,
            resolution: selectedOption.width.flatMap { width in
                selectedOption.height.map { "\(width)x\($0)" }
            } ?? prepared.resolution,
            videoBitrate: selectedOption.videoBitrate ?? prepared.videoBitrate,
            fileSize: fileSize,
            createdAt: Date()
        )
        try store.upsert(entry)
        refreshVideoCacheEntries()
        enforceVideoCacheLimitIfNeeded()
        updateBackgroundTask(
            id: taskID,
            progress: Double(itemIndex + 1) / Double(max(totalItems, 1)),
            detail: hidesDetail ? nil : "已缓存 \(item.cardTitle)"
        )
    }

    private func syncVideoCacheSidecarsIfNeeded(
        item: MediaItem,
        selectedOption: VideoStreamQualityOption,
        destination: URL,
        hidesDetail: Bool
    ) async {
        guard Self.isEmbyItem(item),
              let store = videoOfflineCacheStore,
              let source = embySource(for: item),
              source.sourceKind != .plex,
              let externalID = item.externalID else {
            return
        }
        let mediaSourceID = Self.videoCacheMediaSourceID(from: selectedOption.baseURLString)
            ?? Self.videoCacheMediaSourceID(from: item.filePath)

        do {
            try await withValidEmbySession(for: source) { session in
                let streams = try await embyService.subtitleStreams(
                    session: session,
                    itemID: externalID,
                    mediaSourceID: mediaSourceID
                )
                guard !streams.isEmpty else { return }
                for stream in streams {
                    do {
                        let data = try await embyService.downloadSubtitle(session: session, stream: stream)
                        let sidecarURL = store.sidecarSubtitleURL(
                            forVideoAt: destination,
                            language: stream.language ?? stream.displayTitle,
                            streamIndex: stream.index,
                            fileExtension: stream.fileExtension
                        )
                        try await Self.writeVideoCacheSidecar(data, to: sidecarURL)
                    } catch {
                        let displayTitle = videoCacheDisplayTitle(for: item, hidesDetail: hidesDetail)
                        if hidesDetail {
                            logger?.log("视频缓存字幕同步失败：\(displayTitle)", level: .warning)
                        } else {
                            logger?.log("视频缓存字幕同步失败：\(displayTitle) \(stream.displayTitle ?? stream.language ?? "\(stream.index)") \(error.localizedDescription)", level: .warning)
                        }
                    }
                }
            }
        } catch {
            let displayTitle = videoCacheDisplayTitle(for: item, hidesDetail: hidesDetail)
            if hidesDetail {
                logger?.log("视频缓存字幕列表获取失败：\(displayTitle)", level: .warning)
            } else {
                logger?.log("视频缓存字幕列表获取失败：\(displayTitle) \(error.localizedDescription)", level: .warning)
            }
        }
    }

    private func removeExistingVideoCacheBeforeRedownload(
        itemID: String,
        taskID: UUID,
        store: VideoOfflineCacheStore
    ) throws {
        guard videoCacheJobs[taskID]?.cleanedItemIDs.contains(itemID) == false else { return }
        let removed = try store.remove(itemIDs: [itemID])
        videoCacheJobs[taskID]?.cleanedItemIDs.insert(itemID)
        if !removed.isEmpty {
            refreshVideoCacheEntries()
        }
    }

    private func ensureVideoCacheJobCanContinue(taskID: UUID) throws {
        try Task.checkCancellation()
        guard let job = videoCacheJobs[taskID] else {
            throw CancellationError()
        }
        if job.isPausing {
            throw VideoCacheDownloadControlError.paused
        }
    }

    @discardableResult
    private func startVideoCacheJob(
        item: MediaItem,
        title: String,
        detail: String?,
        candidates: [MediaItem],
        qualityID: String?,
        hidesDetail: Bool
    ) -> UUID? {
        guard videoOfflineCacheStore != nil, !candidates.isEmpty else { return nil }
        let taskID = beginBackgroundTask(
            kind: .videoCache,
            title: title,
            detail: hidesDetail ? nil : detail,
            progress: 0,
            isCancellable: true,
            hidesDetail: hidesDetail,
            retrySourceID: nil,
            retryItemID: item.id,
            retryQualityID: qualityID
        )
        videoCacheJobs[taskID] = VideoCacheJob(
            item: item,
            qualityID: qualityID,
            candidates: candidates,
            currentIndex: 0,
            hidesDetail: hidesDetail,
            errors: []
        )
        let worker = Task { [weak self] in
            guard let self else { return }
            await self.runVideoCacheJob(taskID: taskID)
        }
        videoCacheJobs[taskID]?.worker = worker
        return taskID
    }

    private func runVideoFrameStoryboardTask(
        taskID: UUID,
        item: MediaItem,
        candidates: [MediaItem],
        totalFrames: Int,
        hidesDetail: Bool
    ) async {
        var completedFrames = 0
        var readyFrames = 0
        var failedFrames = 0

        do {
            for (index, candidate) in candidates.enumerated() {
                try Task.checkCancellation()
                guard keyframeStoryboardTasks[taskID] != nil else { throw CancellationError() }
                let duration = candidate.duration ?? 0
                let preferFFmpeg = videoFrameStoryboardPrefersFFmpeg(candidate)
                let itemFrameBase = completedFrames
                let itemTitle = videoCacheDisplayTitle(for: candidate, hidesDetail: hidesDetail)
                let summary = try await VideoFramePreviewGenerator.prewarmStoryboard(
                    itemID: candidate.id,
                    filePath: candidate.filePath ?? "",
                    duration: duration,
                    preferFFmpeg: preferFFmpeg
                ) { [weak self] processed, itemTotal, itemReadyFrames in
                    await MainActor.run {
                        guard let self else { return }
                        let overallProgress = Double(itemFrameBase + processed) / Double(max(totalFrames, 1))
                        let detail: String?
                        if hidesDetail {
                            detail = nil
                        } else if candidates.count > 1 {
                            detail = "第 \(index + 1)/\(candidates.count) 个视频 · \(itemTitle) · \(itemReadyFrames)/\(itemTotal) 张"
                        } else {
                            detail = "已准备 \(itemReadyFrames)/\(itemTotal) 张预览图"
                        }
                        self.updateBackgroundTask(id: taskID, progress: overallProgress, detail: detail)
                    }
                }
                completedFrames += summary.requestedCount
                readyFrames += summary.generatedCount + summary.cachedCount
                failedFrames += summary.failedCount
                updateBackgroundTask(
                    id: taskID,
                    progress: Double(completedFrames) / Double(max(totalFrames, 1)),
                    detail: hidesDetail ? nil : "已完成 \(index + 1)/\(candidates.count) 个视频"
                )
            }

            keyframeStoryboardTasks[taskID] = nil
            if readyFrames == 0 && totalFrames > 0 {
                finishBackgroundTask(id: taskID, errors: ["未能生成预览图，请确认媒体文件可访问，或 ffmpeg 已随 App 分发。"])
            } else {
                let skippedText = failedFrames > 0 ? "，\(failedFrames) 张暂不可用" : ""
                updateBackgroundTask(
                    id: taskID,
                    progress: 1,
                    detail: hidesDetail ? nil : "已准备 \(readyFrames)/\(totalFrames) 张预览图\(skippedText)"
                )
                finishBackgroundTask(id: taskID, errors: [])
            }
        } catch is CancellationError {
            keyframeStoryboardTasks[taskID] = nil
            markBackgroundTaskCancelled(id: taskID, detail: hidesDetail ? nil : "章节图任务已取消")
        } catch {
            keyframeStoryboardTasks[taskID] = nil
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            logger?.log("章节图生成失败：\(hidesDetail ? "保险库视频" : item.title) \(error.localizedDescription)", level: .warning)
        }
    }

    private func runIntroOutroMarkerAnalysisTask(
        taskID: UUID,
        rootItem: MediaItem,
        candidates: [MediaItem],
        hidesDetail: Bool
    ) async {
        var createdCount = 0
        var skippedCount = 0

        do {
            for (index, item) in candidates.enumerated() {
                try Task.checkCancellation()
                guard playbackMarkerAnalysisTasks[taskID] != nil else { throw CancellationError() }
                let existing = try playbackMarkerRepository?.fetchIncludingRejected(mediaID: item.id) ?? []
                let markers = automaticIntroOutroCandidates(for: item, existingMarkers: existing)
                if markers.isEmpty {
                    skippedCount += 1
                } else {
                    for marker in markers {
                        try playbackMarkerRepository?.save(marker)
                        createdCount += 1
                    }
                }
                updateBackgroundTask(
                    id: taskID,
                    progress: Double(index + 1) / Double(max(candidates.count, 1)),
                    detail: hidesDetail ? nil : "已分析 \(index + 1)/\(candidates.count) 个视频"
                )
            }

            playbackMarkerAnalysisTasks[taskID] = nil
            let detail = createdCount > 0
                ? "新增 \(createdCount) 个待审核标记"
                : "没有发现可审核候选"
            updateBackgroundTask(id: taskID, progress: 1, detail: hidesDetail ? nil : detail)
            finishBackgroundTask(id: taskID, errors: [])
            if !hidesDetail {
                logger?.log("片头片尾检测完成：\(rootItem.title) created=\(createdCount) skipped=\(skippedCount)", level: .info)
            }
        } catch is CancellationError {
            playbackMarkerAnalysisTasks[taskID] = nil
            markBackgroundTaskCancelled(id: taskID, detail: hidesDetail ? nil : "片头片尾检测已取消")
        } catch {
            playbackMarkerAnalysisTasks[taskID] = nil
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            logger?.log("片头片尾检测失败：\(hidesDetail ? "保险库视频" : rootItem.title) \(error.localizedDescription)", level: .warning)
        }
    }

    private func scheduleVideoOfflineSubscriptionMaintenance(
        reason: String,
        delay: UInt64 = 700_000_000
    ) {
        guard videoOfflineSubscriptions.contains(where: { $0.isRunnable || $0.isExpired }) else { return }
        videoOfflineSubscriptionMaintenanceTask?.cancel()
        videoOfflineSubscriptionMaintenanceTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: delay)
                try Task.checkCancellation()
                await MainActor.run {
                    self?.maintainVideoOfflineSubscriptions(reason: reason)
                }
            } catch {
                return
            }
        }
    }

    private func configureNetworkPathMonitoring() {
        guard networkPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        networkPathMonitor = monitor
        monitor.pathUpdateHandler = { [weak self] path in
            let wiFiAvailable = path.status == .satisfied && path.usesInterfaceType(.wifi)
            Task { @MainActor [weak self] in
                guard let self else { return }
                let changed = self.videoOfflineSubscriptionWiFiAvailable != wiFiAvailable
                self.videoOfflineSubscriptionWiFiAvailable = wiFiAvailable
                guard changed else { return }
                self.scheduleVideoOfflineSubscriptionMaintenance(
                    reason: wiFiAvailable ? "wifi available" : "wifi unavailable",
                    delay: wiFiAvailable ? 80_000_000 : 700_000_000
                )
            }
        }
        monitor.start(queue: networkPathMonitorQueue)
    }

    private func scheduleVideoOfflineSubscriptionExpirationCheck(reason: String) {
        videoOfflineSubscriptionExpirationTask?.cancel()
        let now = Date()
        let nextExpiry = videoOfflineSubscriptions
            .compactMap(\.expiresAt)
            .filter { $0 > now }
            .min()
        guard let nextExpiry else { return }
        let secondsUntilExpiry = max(1, min(nextExpiry.timeIntervalSince(now) + 1, 24 * 60 * 60))
        videoOfflineSubscriptionExpirationTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: UInt64(secondsUntilExpiry * 1_000_000_000))
                try Task.checkCancellation()
                await MainActor.run {
                    self?.pruneExpiredVideoOfflineSubscriptions(reason: reason, notify: true)
                    self?.scheduleVideoOfflineSubscriptionExpirationCheck(reason: "expiration check")
                    self?.scheduleVideoOfflineSubscriptionMaintenance(reason: "expiration check", delay: 80_000_000)
                }
            } catch {
                return
            }
        }
    }

    private func maintainVideoOfflineSubscriptions(reason: String) {
        guard videoOfflineCacheStore != nil else { return }
        pruneExpiredVideoOfflineSubscriptions(reason: reason, notify: true)
        let activeSubscriptions = videoOfflineSubscriptions.filter(\.isRunnable)
        guard !activeSubscriptions.isEmpty else { return }
        var queuedIDs = queuedVideoCacheItemIDs()
        for subscription in activeSubscriptions {
            guard let series = items.first(where: { $0.id == subscription.seriesID }) else { continue }
            let candidates = videoOfflineSubscriptionCandidates(
                for: subscription,
                series: series,
                excluding: queuedIDs
            )
            guard !candidates.isEmpty else { continue }
            queuedIDs.formUnion(candidates.map(\.id))
            let hidesDetail = isPrivateItem(series) || candidates.contains { isPrivateItem($0) }
            let detail = candidates.count > 1 ? "准备缓存 \(candidates.count) 集" : "准备缓存下一集"
            startVideoCacheJob(
                item: series,
                title: videoCacheTaskTitle(for: series, hidesDetail: hidesDetail),
                detail: detail,
                candidates: candidates,
                qualityID: subscription.qualityID,
                hidesDetail: hidesDetail
            )
            logger?.log("自动缓存维护已加入 \(videoCacheDisplayTitle(for: series, hidesDetail: hidesDetail)) \(candidates.count) 集。reason=\(reason)", level: .info)
        }
    }

    private func pruneExpiredVideoOfflineSubscriptions(reason: String, notify: Bool) {
        guard let repository = videoOfflineSubscriptionRepository else { return }
        do {
            let removedCount = try repository.deleteExpired()
            guard removedCount > 0 else { return }
            videoOfflineSubscriptions = try repository.fetchAll()
            logger?.log("自动缓存到期清理：removed=\(removedCount) reason=\(reason)", level: .info)
            if notify {
                showFloatingNotice(
                    title: "已清理到期自动缓存",
                    message: "\(removedCount) 条订阅规则已关闭",
                    kind: .info
                )
            }
        } catch {
            logger?.log("自动缓存到期清理失败：\(error.localizedDescription)", level: .warning)
        }
    }


    private func videoOfflineSubscriptionCandidates(
        for subscription: VideoOfflineSubscription,
        series: MediaItem,
        excluding queuedIDs: Set<String>
    ) -> [MediaItem] {
        let episodes = children(for: series)
            .filter(cacheableVideoCandidate)
        guard !episodes.isEmpty else { return [] }

        let planned: [MediaItem] = switch subscription.mode {
        case .fullSeries:
            episodes
        case .nextEpisode:
            Array(nextUnwatchedEpisodes(in: episodes).prefix(1))
        case .nextUnwatched:
            Array(nextUnwatchedEpisodes(in: episodes).prefix(max(subscription.episodeLimit, 1)))
        case .season:
            episodes.filter { episode in
                guard let seasonNumber = subscription.seasonNumber else { return true }
                return episode.seasonNumber == seasonNumber
            }
        }
        return planned.filter {
            !isVideoCached($0) &&
            !queuedIDs.contains($0.id) &&
            videoOfflineSubscriptionNetworkPolicyAllows(subscription.networkPolicy, item: $0)
        }
    }

    private func videoOfflineSubscriptionSeasonNumber(from item: MediaItem, in series: MediaItem) -> Int? {
        if item.type == .episode, let seasonNumber = item.seasonNumber {
            return seasonNumber
        }
        let episodes = children(for: series)
            .filter(cacheableVideoCandidate)
        return nextUnwatchedEpisodes(in: episodes).first?.seasonNumber ?? episodes.first?.seasonNumber
    }

    private func videoOfflineSubscriptionNetworkPolicyAllows(
        _ policy: VideoOfflineSubscriptionNetworkPolicy,
        item: MediaItem
    ) -> Bool {
        switch policy {
        case .allowRemote:
            return true
        case .wifiOnly:
            return videoOfflineSubscriptionWiFiAvailable
        case .localNetworkOnly:
            guard let filePath = item.filePath,
                  let url = URL(string: filePath),
                  let host = url.host else {
                return false
            }
            return Self.isLocalNetworkHost(host)
        }
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        if normalized == "localhost" || normalized == "::1" || normalized.hasSuffix(".local") {
            return true
        }
        if normalized.hasPrefix("fe80:") || normalized.hasPrefix("fd") {
            return true
        }
        let octets = normalized.split(separator: ".").compactMap { Int(String($0)) }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _), (127, _), (192, 168):
            return true
        case (172, 16...31):
            return true
        default:
            return false
        }
    }

    private func nextUnwatchedEpisodes(in episodes: [MediaItem]) -> [MediaItem] {
        episodes.filter { !($0.watched || $0.playProgress >= settings.watchedThreshold) }
    }

    private func queuedVideoCacheItemIDs() -> Set<String> {
        var ids = Set<String>()
        for job in videoCacheJobs.values {
            ids.formUnion(job.candidates.map(\.id))
        }
        return ids
    }

    private func videoOfflineSubscriptionSeries(for item: MediaItem) -> MediaItem? {
        if item.type == .episode,
           let parentID = item.parentID {
            return items.first { $0.id == parentID }
        }
        if !children(for: item).isEmpty {
            return item
        }
        return nil
    }

    private func updateVideoCacheStorageSummary() {
        guard let store = videoOfflineCacheStore else {
            videoCacheStorageSummary = VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
            return
        }
        videoCacheStorageSummary = store.storageSummary(byteLimit: Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB))
    }

    private func enforceVideoCacheLimitIfNeeded() {
        guard let store = videoOfflineCacheStore,
              let byteLimit = Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB) else {
            updateVideoCacheStorageSummary()
            return
        }
        let validItemIDs = Set(items.map(\.id))
        let cleanupHint = videoCacheCleanupHint()
        do {
            let result = try store.runMaintenance(
                validItemIDs: validItemIDs,
                byteLimit: byteLimit,
                cleanupHint: cleanupHint
            )
            refreshVideoCacheEntries()
            if result.overLimitEntries > 0 {
                logger?.log("视频缓存超过容量上限，已自动回收 \(result.overLimitEntries) 个缓存。", level: .info)
            }
        } catch {
            updateVideoCacheStorageSummary()
            logger?.log("视频缓存容量维护失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func videoCacheCleanupHint() -> VideoCacheCleanupHint {
        let recentCutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        var watchedIDs = Set<String>()
        var recentlyPlayedIDs = Set<String>()
        for item in items {
            if item.watched || item.playProgress >= settings.watchedThreshold {
                watchedIDs.insert(item.id)
            }
            if let lastPlayedAt = item.lastPlayedAt, lastPlayedAt >= recentCutoff {
                recentlyPlayedIDs.insert(item.id)
            }
        }
        return VideoCacheCleanupHint(watchedItemIDs: watchedIDs, recentlyPlayedItemIDs: recentlyPlayedIDs)
    }

    private func videoCacheProgressDetail(
        title: String,
        fileFraction: Double,
        receivedBytes: Int64,
        expectedBytes: Int64
    ) -> String {
        guard expectedBytes > 0 else {
            return "正在缓存 \(title) · 已接收 \(Self.shortByteCount(receivedBytes))"
        }
        let percent = Int((min(max(fileFraction, 0), 1) * 100).rounded())
        return "正在缓存 \(title) · \(percent)% · \(Self.shortByteCount(receivedBytes))/\(Self.shortByteCount(expectedBytes))"
    }

    nonisolated private static func videoCacheFileFraction(_ progress: VideoCacheDownloadController.Progress) -> Double {
        if let fraction = progress.fraction, fraction.isFinite {
            return min(max(fraction, 0), 1)
        }
        guard progress.receivedBytes > 0 else { return 0 }
        let megabytes = Double(progress.receivedBytes) / 1_048_576
        let estimated = 0.04 + (log1p(megabytes) / log1p(2048)) * 0.88
        return min(max(estimated, 0.04), 0.92)
    }

    private func cacheableVideoItems(for item: MediaItem) -> [MediaItem] {
        let episodes = children(for: item)
        if !episodes.isEmpty {
            return episodes.filter(cacheableVideoCandidate)
        }
        return cacheableVideoCandidate(item) ? [item] : []
    }

    private func cacheableVideoCandidate(_ item: MediaItem) -> Bool {
        guard item.type != .music,
              let filePath = item.filePath,
              let scheme = URL(string: filePath)?.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            return false
        }
        return true
    }

    private func uniqueCacheQualityChoices(from options: [VideoStreamQualityOption]) -> [VideoCacheQualityChoice] {
        var choices: [VideoCacheQualityChoice] = []
        var seen = Set<String>()
        for option in options {
            let id = cacheQualityIdentifier(for: option)
            guard seen.insert(id).inserted else { continue }
            choices.append(VideoCacheQualityChoice(id: id, label: option.label, detail: option.detail))
        }
        return choices
    }

    private func originalVideoCacheChoice(for item: MediaItem) -> VideoCacheQualityChoice {
        let resolution = item.resolution.flatMap { $0.isEmpty ? nil : $0 } ?? "原始分辨率"
        return VideoCacheQualityChoice(id: "original", label: "原画", detail: "\(resolution) · 直连缓存")
    }

    private func selectedCacheOption(
        for item: MediaItem,
        options: [VideoStreamQualityOption],
        requestedQualityID: String?
    ) -> VideoStreamQualityOption {
        if let requestedQualityID {
            if let exact = options.first(where: { cacheQualityIdentifier(for: $0) == requestedQualityID }) {
                return exact
            }
            if requestedQualityID == "original", let original = options.first(where: \.isOriginal) {
                return original
            }
        }
        if let original = options.first(where: \.isOriginal) {
            return original
        }
        return fallbackOriginalCacheOption(for: item)
    }

    private func fallbackOriginalCacheOption(for item: MediaItem) -> VideoStreamQualityOption {
        let size = VideoAspectRatioResolver.sizeFromResolution(item.resolution)
        return VideoStreamQualityOption(
            id: "original",
            label: "原画",
            detail: originalVideoCacheChoice(for: item).detail,
            baseURLString: item.filePath ?? "",
            isOriginal: true,
            appliesInPlace: false,
            videoFilter: nil,
            width: size?.width,
            height: size?.height,
            videoBitrate: item.videoBitrate
        )
    }

    private func cacheQualityIdentifier(for option: VideoStreamQualityOption) -> String {
        if option.isOriginal {
            return "original"
        }
        if let height = option.height {
            return "height-\(height)"
        }
        return option.id
    }

    nonisolated private static func videoCacheMediaSourceID(from urlString: String?) -> String? {
        guard let urlString,
              let components = URLComponents(string: urlString) else { return nil }
        return components.queryItems?.first {
            $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame
        }?.value
    }

    nonisolated private static func writeVideoCacheSidecar(_ data: Data, to url: URL) async throws {
        try await Task.detached(priority: .utility) {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }.value
    }

    nonisolated private static func moveVideoCacheDownload(
        temporaryURL: URL,
        response: URLResponse,
        destination: URL
    ) async throws -> Int64 {
        try await Task.detached(priority: .utility) {
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            if let httpResponse = response as? HTTPURLResponse,
               !(200...299).contains(httpResponse.statusCode) {
                throw VideoCacheDownloadControlError.invalidHTTPStatus(httpResponse.statusCode)
            }
            let fileManager = FileManager.default
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fileManager.fileExists(atPath: destination.path) {
                try fileManager.removeItem(at: destination)
            }
            try fileManager.moveItem(at: temporaryURL, to: destination)
            guard fileManager.fileExists(atPath: destination.path) else {
                throw VideoOfflineCacheStoreError.missingDownloadedFile
            }
            let attributes = try? fileManager.attributesOfItem(atPath: destination.path)
            return attributes?[.size] as? Int64 ?? 0
        }.value
    }

    nonisolated private static func shortByteCount(_ bytes: Int64) -> String {
        let value = Double(max(bytes, 0))
        let units = ["B", "KB", "MB", "GB", "TB"]
        var current = value
        var unitIndex = 0
        while current >= 1024, unitIndex < units.count - 1 {
            current /= 1024
            unitIndex += 1
        }
        if unitIndex == 0 {
            return "\(Int(current)) \(units[unitIndex])"
        }
        return String(format: "%.1f %@", current, units[unitIndex])
    }

    nonisolated private static func videoCacheByteLimit(from gigabytes: Double) -> Int64? {
        guard gigabytes.isFinite, gigabytes > 0 else { return nil }
        return Int64((gigabytes * 1_073_741_824).rounded())
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

    /// 上一集/下一集是否存在：播放器在 teardown 当前播放前必须先确认，
    /// 否则越界切换会把当前播放拆掉却没有新内容顶上（窗口卡死在黑屏）。
    func hasAdjacentItem(to item: MediaItem, direction: Int) -> Bool {
        adjacentItem(to: item, direction: direction) != nil
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
        } ?? playableTracks[0]

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
        videoQueue = videoQueueItems(startingAt: item)
        activePlayerItem = item
    }

    /// 检查 GitHub Releases 是否有新版本。手动检查总是反馈结果；
    /// 静默检查（每日首启）尊重「跳过该版本 / 永不提醒」。
    func checkForUpdates(manual: Bool) {
        guard !isCheckingForUpdates else { return }
        isCheckingForUpdates = true
        Task { @MainActor in
            defer { isCheckingForUpdates = false }
            do {
                guard let info = try await AppUpdateChecker.fetchLatestRelease(),
                      AppVersion.isVersion(info.version, newerThan: AppVersion.current) else {
                    if manual {
                        alert = AppAlert(title: "已是最新版本", message: "当前版本 \(AppVersion.current)。")
                    }
                    return
                }
                if !manual {
                    guard !settings.updateRemindersDisabled,
                          settings.updateSkippedVersion != info.tagName else { return }
                }
                availableUpdate = info
            } catch {
                if manual {
                    alert = AppAlert(title: "检查更新失败", message: error.localizedDescription)
                }
            }
        }
    }

    /// 记录启动次数；恰好第三次启动时邀请用户赞赏（只弹一次）。
    func registerLaunchAndMaybeInvite() {
        let countKey = "MediaLib.launchCount"
        let invitedKey = "MediaLib.sponsorInvited"
        let count = UserDefaults.standard.integer(forKey: countKey) + 1
        UserDefaults.standard.set(count, forKey: countKey)
        guard count == 3, !UserDefaults.standard.bool(forKey: invitedKey) else { return }
        UserDefaults.standard.set(true, forKey: invitedKey)
        showingSponsorPrompt = true
    }

    /// 每天第一次启动时静默检查一次更新。
    func checkForUpdatesDailyIfNeeded() {
        let key = "MediaLib.update.lastCheckDay"
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let today = formatter.string(from: Date())
        guard UserDefaults.standard.string(forKey: key) != today else { return }
        UserDefaults.standard.set(today, forKey: key)
        checkForUpdates(manual: false)
    }

    /// 从访达双击/「打开方式」进入的本地媒体文件：在库内则播放库内条目
    /// （保留进度、剧集队列等），否则构造临时条目直接播放，不写入媒体库。
    func playExternalFiles(_ urls: [URL]) {
        guard let url = urls.first(where: \.isFileURL) else { return }
        let path = url.path
        if let existing = items.first(where: { $0.filePath == path }) {
            play(existing)
            return
        }
        let ext = url.pathExtension.lowercased()
        let isMusic = SystemDefaultPlayerRegistrar.musicExtensions.contains(ext)
        let item = MediaItem(
            id: "external-file:\(path)",
            type: isMusic ? .music : .other,
            title: url.deletingPathExtension().lastPathComponent,
            filePath: path
        )
        if isMusic {
            musicQueue = [item]
        }
        presentBuiltInPlayer(item)
    }

    /// 直接播放网络串流地址（不入库）：构造临时 MediaItem 交给内置播放器，
    /// mpv 原生支持 http(s)/rtsp/rtmp 等协议；进度按未知 id 落库为 no-op，不污染媒体库。
    func playNetworkStream(_ urlString: String) {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              ["http", "https", "rtsp", "rtmp", "rtp", "mms", "srt", "udp", "ftp"].contains(scheme) else {
            alert = AppAlert(title: "无法播放", message: "请输入合法的串流地址（http / https / rtsp / rtmp 等）。")
            return
        }
        let title: String = {
            let name = url.lastPathComponent
            if !name.isEmpty, name != "/" {
                return name.removingPercentEncoding ?? name
            }
            return url.host ?? trimmed
        }()
        let item = MediaItem(
            id: "url-stream:\(trimmed)",
            type: .other,
            title: title,
            filePath: trimmed
        )
        showingNetworkStreamPrompt = false
        presentBuiltInPlayer(item)
    }

    /// 构建剧集播放队列：当前集 + 同系列中排在它之后的剧集（沿用剧集页的排序）。
    private func videoQueueItems(startingAt item: MediaItem) -> [MediaItem] {
        guard let parentID = item.parentID,
              let parent = items.first(where: { $0.id == parentID }) else {
            return [item]
        }
        let siblings = children(for: parent).filter { $0.filePath != nil }
        guard let index = siblings.firstIndex(where: { $0.id == item.id }) else {
            return [item]
        }
        return Array(siblings[index...])
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
        let playableItem = cachedPlayableItem(for: item) ?? item
        guard let filePath = playableItem.filePath else {
            alert = AppAlert(title: "无法打开外部播放器", message: "此媒体没有文件路径。")
            return
        }
        do {
            let path = playableItem.type == .music ? settings.musicExternalPlayerPath : settings.videoExternalPlayerPath
            try externalPlayerService.open(filePath: filePath, preferredPlayerPath: path)
        } catch {
            showError("外部播放器不可用", error)
        }
    }

    func updatePlayback(item: MediaItem, position: Double, duration: Double?, reloadLibrary: Bool = true) {
        guard settings.rememberPlaybackPosition else { return }
        guard !shouldIgnoreStalePlaybackSave(from: item) else { return }
        do {
            // 「播放完成自动标记已看」关闭时传一个不可达阈值：仍记录进度，
            // 但永不自动置已看（此前该开关只有设置项、无任何行为）。
            try mediaRepository?.updatePlayback(
                id: item.id,
                position: position,
                duration: duration,
                watchedThreshold: settings.autoMarkWatched ? settings.watchedThreshold : 2.0
            )
            playbackClearRevisionByItemID.removeValue(forKey: item.id)
            if reloadLibrary {
                reload()
            } else if item.type != .music {
                updatePlaybackInMemory(id: item.id, position: position, duration: duration)
                scheduleVideoOfflineSubscriptionMaintenance(reason: "playback updated")
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

    func reviewAutomaticPlaybackMarker(_ marker: PlaybackMarker, accepted: Bool) {
        guard marker.origin == .automatic else { return }
        do {
            try playbackMarkerRepository?.updateReviewStatus(
                id: marker.id,
                status: accepted ? .accepted : .rejected
            )
            showFloatingNotice(
                title: accepted ? "已采用自动标记" : "已忽略自动标记",
                message: marker.kind.title,
                kind: accepted ? .success : .info
            )
        } catch {
            showError("更新自动标记失败", error)
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
        clearPlaybackHistory([item])
    }

    func clearPlaybackHistory(_ items: [MediaItem]) {
        let targetItems = playbackHistoryCascadeItems(for: items).filter(\.hasPlaybackTrace)
        let ids = targetItems.map(\.id)
        guard !ids.isEmpty else { return }
        let staleRevisions = targetItems.map { (id: $0.id, updatedAt: currentSnapshot(for: $0).updatedAt) }
        do {
            try mediaRepository?.clearPlaybackHistory(ids: ids)
            staleRevisions.forEach { recordPlaybackClearedRevision(id: $0.id, staleUntil: $0.updatedAt) }
            clearPlaybackHistoryInMemory(ids: ids)
            scheduleEmbyPlayedSync(targetItems, played: false)
            if targetItems.count == 1, let item = targetItems.first {
                showMediaStateNotice(title: "播放记录已删除", item: item, kind: .info)
            } else {
                showFloatingNotice(
                    title: "播放记录已删除",
                    message: "\(targetItems.count) 个内容",
                    kind: .info,
                    duration: 3.2
                )
            }
        } catch {
            showError("播放记录删除失败", error)
        }
    }

    private func recordPlaybackClearedRevision(id: String, staleUntil updatedAt: Date) {
        playbackClearRevisionByItemID[id] = updatedAt
    }

    private func shouldIgnoreStalePlaybackSave(from item: MediaItem) -> Bool {
        guard let clearedRevision = playbackClearRevisionByItemID[item.id] else { return false }
        return item.updatedAt <= clearedRevision
    }

    private func playbackHistoryCascadeItems(for roots: [MediaItem]) -> [MediaItem] {
        guard !roots.isEmpty else { return [] }
        let itemByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var ordered: [MediaItem] = []
        var visited = Set<String>()
        var stack = roots.map(\.id)
        while let id = stack.popLast() {
            guard visited.insert(id).inserted,
                  let item = itemByID[id] ?? roots.first(where: { $0.id == id }) else { continue }
            ordered.append(item)
            let childIDs = (cachedChildrenByParentID[id] ?? []).map(\.id)
            stack.append(contentsOf: childIDs.reversed())
        }
        return ordered
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
    @Published var isImportingTraktState = false
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
                        _ = self.traktAccountRecord(syncEnabled: true)
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
        deleteTraktAccountRecord()
    }

    func setTraktSyncEnabled(_ enabled: Bool) {
        settings.traktSyncEnabled = enabled
        saveSettings()
        if isTraktConnected {
            _ = traktAccountRecord(syncEnabled: enabled)
        }
    }

    @discardableResult
    private func traktAccountRecord(syncEnabled: Bool? = nil, lastSyncedAt: Date? = nil) -> RemoteConnectorAccount? {
        guard let remoteConnectorAccountRepository else { return nil }
        let existing = remoteConnectorAccounts.first { $0.provider == .trakt }
        let now = Date()
        var account = existing ?? RemoteConnectorAccount(
            provider: .trakt,
            accountLabel: "Trakt",
            serverURL: "https://trakt.tv",
            username: nil,
            sourceID: nil,
            connectionMode: .syncOnly,
            syncEnabled: settings.traktSyncEnabled,
            capabilitiesJSON: #"{"historySync":true,"watchlistSync":true,"bidirectionalImport":true}"#,
            privacyNote: "Trakt token 仅保存在本机设置中；同步只处理已匹配 TMDB 的公开视频。"
        )
        account.connectionMode = .syncOnly
        account.serverURL = "https://trakt.tv"
        account.syncEnabled = syncEnabled ?? settings.traktSyncEnabled
        account.capabilitiesJSON = #"{"historySync":true,"watchlistSync":true,"bidirectionalImport":true}"#
        account.privacyNote = "Trakt token 仅保存在本机设置中；同步只处理已匹配 TMDB 的公开视频。"
        if let lastSyncedAt {
            account.lastSyncedAt = lastSyncedAt
        }
        account.updatedAt = now
        do {
            let saved = try remoteConnectorAccountRepository.save(account)
            if let index = remoteConnectorAccounts.firstIndex(where: { $0.id == saved.id }) {
                remoteConnectorAccounts[index] = saved
            } else {
                remoteConnectorAccounts.append(saved)
            }
            return saved
        } catch {
            logger?.log("Trakt 连接器账号保存失败：\(error.localizedDescription)", level: .warning)
            return existing
        }
    }

    private func deleteTraktAccountRecord() {
        guard let remoteConnectorAccountRepository else { return }
        for account in remoteConnectorAccounts where account.provider == .trakt {
            try? remoteConnectorAccountRepository.delete(id: account.id)
        }
        remoteConnectorAccounts.removeAll { $0.provider == .trakt }
    }

    private func withValidTraktToken<T>(_ operation: (TraktService, String) async throws -> T) async throws -> T {
        guard let service = traktService, let token = settings.traktAccessToken, !token.isEmpty else {
            throw TraktError.notConnected
        }
        do {
            return try await operation(service, token)
        } catch TraktError.requestFailed(401) {
            guard let refresh = settings.traktRefreshToken, !refresh.isEmpty else { throw TraktError.notConnected }
            let tokens = try await service.refreshTokens(refresh)
            settings.traktAccessToken = tokens.accessToken
            settings.traktRefreshToken = tokens.refreshToken
            saveSettings()
            return try await operation(service, tokens.accessToken)
        }
    }

    /// 带令牌的 Trakt 操作；遇 401 自动刷新令牌后重试一次。
    private func runTrakt(_ operation: (TraktService, String) async throws -> Void) async {
        do {
            try await withValidTraktToken(operation)
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
        let refs = items
            .filter { $0.type != .privateCollection && !cachedPrivateItemIDs.contains($0.id) }
            .compactMap { traktHistoryRef(for: $0) }
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
        guard item.type != .privateCollection, !cachedPrivateItemIDs.contains(item.id) else { return }
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

    func importTraktState() {
        guard settings.traktSyncEnabled, isTraktConnected else {
            alert = AppAlert(title: "Trakt 未启用", message: "请先连接 Trakt 并开启同步。")
            return
        }
        guard !isImportingTraktState else { return }
        isImportingTraktState = true
        Task { [weak self] in
            guard let self else { return }
            defer { self.isImportingTraktState = false }
            do {
                let state = try await self.withValidTraktToken { service, token in
                    try await service.fetchRemoteState(accessToken: token)
                }
                let report = try self.recordTraktImportConflicts(remoteState: state)
                let now = Date()
                _ = self.traktAccountRecord(syncEnabled: self.settings.traktSyncEnabled, lastSyncedAt: now)
                self.remoteConnectorAccounts = try self.remoteConnectorAccountRepository?.fetchAll() ?? self.remoteConnectorAccounts
                self.pendingSyncConflictCount = try self.syncConflictRepository?.pendingCount() ?? self.pendingSyncConflictCount
                self.pendingSyncConflicts = try self.syncConflictRepository?.fetchPending(limit: 120) ?? self.pendingSyncConflicts
                let message = report.conflictCount == 0
                    ? "没有发现需要处理的本地/远端状态差异。"
                    : "已生成 \(report.conflictCount) 条待处理同步冲突，可在“连接器与同步 > 同步冲突”中处理。"
                self.deliverTaskNotice(
                    title: "Trakt 导入完成",
                    message: message,
                    kind: .success,
                    systemTitle: "Trakt 导入完成",
                    systemBody: message
                )
            } catch {
                self.deliverTaskNotice(
                    title: "Trakt 导入失败",
                    message: error.localizedDescription,
                    kind: .error,
                    systemTitle: "Trakt 导入失败",
                    systemBody: error.localizedDescription
                )
            }
        }
    }

    private func recordTraktImportConflicts(remoteState: TraktRemoteState) throws -> TraktImportReport {
        guard let syncConflictRepository else { return TraktImportReport(conflictCount: 0) }
        let accountID = traktAccountRecord(syncEnabled: settings.traktSyncEnabled)?.id
        let remoteUpdatedAt = Date()
        var conflictCount = 0

        func saveConflict(item: MediaItem, fieldName: String, local: Bool, remote: Bool) throws {
            guard local != remote else { return }
            let conflict = SyncConflict(
                id: StableID.make(prefix: "sync-conflict", value: "trakt-\(item.id)-\(fieldName)"),
                mediaID: item.id,
                provider: .trakt,
                accountID: accountID,
                fieldName: fieldName,
                localValue: local ? "true" : "false",
                remoteValue: remote ? "true" : "false",
                localUpdatedAt: item.updatedAt,
                remoteUpdatedAt: remoteUpdatedAt
            )
            _ = try syncConflictRepository.save(conflict)
            conflictCount += 1
        }

        for item in items {
            guard !cachedPrivateItemIDs.contains(item.id), item.type != .privateCollection else { continue }
            switch item.type {
            case .movie:
                guard let tmdbID = Self.tmdbNumericID(item.externalID, kind: "movie") else { continue }
                try saveConflict(
                    item: item,
                    fieldName: "watched",
                    local: item.watched,
                    remote: remoteState.watchedMovies.contains(tmdbID)
                )
                try saveConflict(
                    item: item,
                    fieldName: "watchlist",
                    local: item.watchlist,
                    remote: remoteState.watchlistMovies.contains(tmdbID)
                )
            case .tvShow:
                guard let tmdbID = Self.tmdbNumericID(item.externalID, kind: "tv") else { continue }
                try saveConflict(
                    item: item,
                    fieldName: "watchlist",
                    local: item.watchlist,
                    remote: remoteState.watchlistShows.contains(tmdbID)
                )
            case .episode:
                guard let ref = traktHistoryRef(for: item),
                      case let .episode(showTmdbID, season, episode) = ref else { continue }
                let remoteWatched = remoteState.watchedEpisodes.contains(
                    TraktEpisodeKey(showTmdbID: showTmdbID, season: season, episode: episode)
                )
                try saveConflict(
                    item: item,
                    fieldName: "watched",
                    local: item.watched,
                    remote: remoteWatched
                )
            default:
                continue
            }
        }

        return TraktImportReport(conflictCount: conflictCount)
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

    private func updatePlaybackInMemory(id: String, position: Double, duration: Double?) {
        let progress = duration.map { $0 > 0 ? min(max(position / $0, 0), 1) : 0 } ?? 0
        let watched = progress >= settings.watchedThreshold
        let now = Date()

        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.playPosition = position
            copy.playProgress = progress
            copy.watched = watched
            copy.lastPlayedAt = now
            copy.updatedAt = now
            return copy
        }

        items = items.map(updated)
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

    private func updateWatchedInMemory(ids: [String], watched: Bool) {
        let targetIDs = Set(ids)
        guard !targetIDs.isEmpty else { return }
        let now = Date()

        func updated(_ item: MediaItem) -> MediaItem {
            guard targetIDs.contains(item.id) else { return item }
            var copy = item
            copy.watched = watched
            if watched {
                copy.playProgress = 1
            } else {
                copy.playPosition = 0
                copy.playProgress = 0
                copy.lastPlayedAt = nil
            }
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

    func toggleFavorite(_ item: MediaItem) {
        let currentFavorite =
        items.first(where: { $0.id == item.id })?.favorite ??
        activePlayerItem.flatMap { $0.id == item.id ? $0.favorite : nil } ??
        selectedItem.flatMap { $0.id == item.id ? $0.favorite : nil } ??
        item.favorite
        let nextFavorite = !currentFavorite

        updateFavoriteInMemory(id: item.id, favorite: nextFavorite)
        showMediaStateNotice(
            title: nextFavorite ? "已加入喜欢" : "已取消喜欢",
            item: item,
            kind: nextFavorite ? .success : .info
        )

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
                    let title = Self.isEmbyItem(item) ? "远程收藏同步失败" : "喜欢状态更新失败"
                    let message = self.isPrivateItem(item) ? "状态已回滚，请解锁后重试。" : "\(item.cardTitle)：\(error.localizedDescription)"
                    self.deliverTaskNotice(
                        title: title,
                        message: message,
                        kind: .error,
                        systemTitle: title,
                        systemBody: message
                    )
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
        cachedHomeVideoItems = cachedHomeVideoItems.map(updated)
        cachedHomeOfflineVideoItems = cachedHomeOfflineVideoItems.map(updated)
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
        cachedHomeStats.favoriteCount = cachedHomeVideoItems.filter { $0.type != .music && $0.favorite }.count
        let localPublicHasFavorite = cachedTopLevelItems.contains { $0.type != .music && $0.favorite }
        if localPublicHasFavorite, !cachedVisibleVideoSections.contains(.favorites) {
            cachedVisibleVideoSections = VideoLibrarySection.allCases.filter {
                $0 == .favorites || cachedVisibleVideoSections.contains($0)
            }
        } else if !localPublicHasFavorite {
            cachedVisibleVideoSections.removeAll { $0 == .favorites }
        }
        if cachedHomeVideoItems.contains(where: { $0.type != .music && $0.favorite }) {
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
        showMediaStateNotice(
            title: nextWatchlist ? "已加入想看" : "已从想看移除",
            item: item,
            kind: nextWatchlist ? .success : .info
        )

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
                    let message = self.isPrivateItem(item) ? "状态已回滚，请解锁后重试。" : "\(item.cardTitle)：\(error.localizedDescription)"
                    self.deliverTaskNotice(
                        title: "想看状态更新失败",
                        message: message,
                        kind: .error,
                        systemTitle: "想看状态更新失败",
                        systemBody: message
                    )
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
        cachedPrivateTopLevelItems = cachedPrivateTopLevelItems.map(updated)
        cachedEmbyTopLevelItems = cachedEmbyTopLevelItems.map(updated)
        cachedHomeVideoItems = cachedHomeVideoItems.map(updated)
        cachedHomeOfflineVideoItems = cachedHomeOfflineVideoItems.map(updated)
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
        let localPublicHasWatchlist = cachedTopLevelItems.contains { $0.type != .music && $0.watchlist }
        if localPublicHasWatchlist {
            if !cachedVisibleVideoSections.contains(.watchlist) {
                cachedVisibleVideoSections = VideoLibrarySection.allCases.filter {
                    $0 == .watchlist || cachedVisibleVideoSections.contains($0)
                }
            }
        } else {
            cachedVisibleVideoSections.removeAll { $0 == .watchlist }
        }
        watchlistRevision += 1
    }

    private func currentSnapshot(for item: MediaItem) -> MediaItem {
        items.first(where: { $0.id == item.id }) ??
        activePlayerItem.flatMap { $0.id == item.id ? $0 : nil } ??
        selectedItem.flatMap { $0.id == item.id ? $0 : nil } ??
        quickPreviewItem.flatMap { $0.id == item.id ? $0 : nil } ??
        item
    }

    private func shouldClearWatchlistWhenMarkedWatched(_ item: MediaItem, watched: Bool) -> Bool {
        watched && item.type != .music && item.watchlist
    }

    func markWatched(_ item: MediaItem, watched: Bool) {
        do {
            let currentItem = currentSnapshot(for: item)
            let shouldClearWatchlist = shouldClearWatchlistWhenMarkedWatched(currentItem, watched: watched)
            let staleRevision = currentItem.updatedAt
            try mediaRepository?.markWatched(
                id: item.id,
                watched: watched,
                clearWatchlistWhenWatched: shouldClearWatchlist
            )
            if watched {
                playbackClearRevisionByItemID.removeValue(forKey: item.id)
            } else {
                recordPlaybackClearedRevision(id: item.id, staleUntil: staleRevision)
            }
            reload()
            scheduleEmbyPlayedSync([item], played: watched)
            syncTraktHistory([item], watched: watched)
            if shouldClearWatchlist {
                syncTraktWatchlist(currentItem, add: false)
            }
            showMediaStateNotice(
                title: watched ? "已标记为已观看" : "已标记为未观看",
                item: currentItem,
                kind: .success
            )
        } catch {
            showError("观看状态更新失败", error)
        }
    }

    func markAllWatched(_ items: [MediaItem], watched: Bool) {
        guard !items.isEmpty else { return }
        guard let mediaRepository else { return }
        var hadError = false
        var clearedWatchlistItems: [MediaItem] = []
        for item in items {
            do {
                let currentItem = currentSnapshot(for: item)
                let shouldClearWatchlist = shouldClearWatchlistWhenMarkedWatched(currentItem, watched: watched)
                let staleRevision = currentItem.updatedAt
                try mediaRepository.markWatched(
                    id: item.id,
                    watched: watched,
                    clearWatchlistWhenWatched: shouldClearWatchlist
                )
                if watched {
                    playbackClearRevisionByItemID.removeValue(forKey: item.id)
                } else {
                    recordPlaybackClearedRevision(id: item.id, staleUntil: staleRevision)
                }
                if shouldClearWatchlist {
                    clearedWatchlistItems.append(currentItem)
                }
            } catch {
                hadError = true
                logger?.log("批量更新观看状态失败：\(error.localizedDescription)", level: .warning)
            }
        }
        reload()
        scheduleEmbyPlayedSync(items, played: watched)
        syncTraktHistory(items, watched: watched)
        clearedWatchlistItems.forEach { syncTraktWatchlist($0, add: false) }
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的观看状态未能更新，请检查数据库状态。")
        } else {
            showFloatingNotice(
                title: watched ? "已标记为已观看" : "已标记为未观看",
                message: "\(items.count) 个内容",
                kind: .success,
                duration: 3.2
            )
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
        guard !targets.isEmpty else { return }
        guard let mediaRepository else { return }
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
        } else {
            showFloatingNotice(
                title: watchlist ? "已加入想看" : "已从想看移除",
                message: "\(targets.count) 个内容",
                kind: watchlist ? .success : .info,
                duration: 3.2
            )
        }
    }

    func batchUpdateRating(_ rating: Double?) {
        let targets = currentSelectionItems
        guard !targets.isEmpty else { return }
        guard let mediaRepository else { return }
        var hadError = false
        for item in targets {
            updateRatingInMemory(id: item.id, rating: rating)
            do {
                try mediaRepository.updateRating(id: item.id, rating: rating)
            } catch {
                hadError = true
                logger?.log("批量更新评级失败：\(error.localizedDescription)", level: .warning)
            }
        }
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的评级未能更新。")
        } else {
            showFloatingNotice(
                title: rating == nil ? "已清除评级" : "评级已更新",
                message: "\(targets.count) 个内容 · \(userRatingNoticeSuffix(rating))",
                kind: .success,
                duration: 3.2
            )
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
        let previousRating =
        items.first(where: { $0.id == item.id })?.userRating ??
        selectedItem.flatMap { $0.id == item.id ? $0.userRating : nil } ??
        item.userRating
        updateRatingInMemory(id: item.id, rating: rating)
        showMediaStateNotice(
            title: rating == nil ? "已清除评级" : "评级已更新",
            item: item,
            suffix: userRatingNoticeSuffix(rating),
            kind: .success
        )
        guard let mediaRepository else { return }
        Task(priority: .utility) { [weak self, mediaRepository] in
            do {
                try mediaRepository.updateRating(id: item.id, rating: rating)
            } catch {
                await MainActor.run {
                    self?.updateRatingInMemory(id: item.id, rating: previousRating)
                    self?.showError("评级更新失败", error)
                }
            }
        }
    }

    private func updateRatingInMemory(id: String, rating: Double?) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.userRating = rating
            copy.updatedAt = Date()
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
        cachedHomeVideoItems = cachedHomeVideoItems.map(updated)
        cachedHomeOfflineVideoItems = cachedHomeOfflineVideoItems.map(updated)
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
        ratingRevision += 1
    }

    func applyMetadata(_ metadata: MediaMetadataUpdate, to item: MediaItem, source: String = "manual") {
        do {
            try updateMetadata(id: item.id, metadata: metadata, source: source)
            updateMetadataInMemory(id: item.id, metadata: metadata)
        } catch {
            showError("元数据更新失败", error)
        }
    }

    func applyMetadataSearchResult(_ result: MetadataSearchResult, to item: MediaItem) {
        showFloatingNotice(title: "正在应用元数据", message: item.title, kind: .info)
        Task { [weak self] in
            guard let self else { return }
            let service = MetadataSearchService()
            let update = await service.materializedMetadataUpdate(
                for: result,
                itemID: item.id,
                artworkDirectory: self.directories?.thumbnails,
                preserveEmbeddedPoster: item.type == .music && item.hasEmbeddedArtwork
            )
            await MainActor.run {
                do {
                    try self.updateMetadata(id: item.id, metadata: update, source: "manual")
                    self.updateMetadataInMemory(id: item.id, metadata: update)
                    let displayTitle = update.title ?? item.title
                    self.deliverTaskNotice(
                        title: "元数据已应用",
                        message: displayTitle,
                        kind: .success,
                        systemTitle: "元数据已应用",
                        systemBody: "\(displayTitle) 已完成。"
                    )
                } catch {
                    self.deliverTaskNotice(
                        title: "元数据更新失败",
                        message: error.localizedDescription,
                        kind: .error,
                        systemTitle: "元数据更新失败",
                        systemBody: error.localizedDescription
                    )
                }
            }
        }
    }

    func canUndoLatestMetadataCorrection(for item: MediaItem) -> Bool {
        (metadataCorrectionCountsByMediaID[item.id] ?? 0) > 0
    }

    func displayTitleForMediaID(_ mediaID: String?) -> String {
        guard let mediaID, let item = items.first(where: { $0.id == mediaID }) else {
            return "未关联媒体"
        }
        if isPrivateItem(item) && !canDisplayPrivateItems {
            return "保险库条目"
        }
        return item.cardTitle
    }

    func hidesDetailForMediaID(_ mediaID: String?) -> Bool {
        guard let mediaID, let item = items.first(where: { $0.id == mediaID }) else {
            return false
        }
        return isPrivateItem(item) && !canDisplayPrivateItems
    }

    func undoLatestMetadataCorrection(for item: MediaItem) {
        guard let database, let mediaRepository, let metadataCorrectionRepository else { return }
        do {
            let records = try metadataCorrectionRepository.latestUndoableBatch(mediaID: item.id)
            guard let batchID = records.first?.batchID, !records.isEmpty else {
                showFloatingNotice(title: "没有可撤销的元数据修正", message: item.title, kind: .info)
                return
            }
            let values = Dictionary(uniqueKeysWithValues: records.map { ($0.field, $0.oldValue) })
            try database.transaction {
                try mediaRepository.restoreMetadataValues(id: item.id, values: values)
                try metadataCorrectionRepository.markBatchUndone(batchID: batchID)
            }
            reload()
            showFloatingNotice(title: "已撤销元数据修正", message: item.title, kind: .success)
        } catch {
            showError("撤销元数据失败", error)
        }
    }

    func undoMetadataCorrectionBatch(_ batch: MetadataCorrectionBatchSummary) {
        guard let database, let mediaRepository, let metadataCorrectionRepository else { return }
        do {
            let records = try metadataCorrectionRepository.records(batchID: batch.batchID, mediaID: batch.mediaID)
            guard !records.isEmpty else {
                showFloatingNotice(title: "没有可撤销的元数据修正", message: displayTitleForMediaID(batch.mediaID), kind: .info)
                return
            }
            let values = Dictionary(uniqueKeysWithValues: records.map { ($0.field, $0.oldValue) })
            try database.transaction {
                try mediaRepository.restoreMetadataValues(id: batch.mediaID, values: values)
                try metadataCorrectionRepository.markBatchUndone(batchID: batch.batchID)
            }
            reload()
            showFloatingNotice(title: "已撤销元数据修正", message: displayTitleForMediaID(batch.mediaID), kind: .success)
        } catch {
            showError("撤销元数据失败", error)
        }
    }

    func resolveSyncConflict(_ conflict: SyncConflict, resolution: SyncConflictResolution) {
        guard let syncConflictRepository else { return }
        if conflict.provider == .trakt, resolution == .useLocal {
            resolveTraktSyncConflictUsingLocal(conflict)
            return
        }
        do {
            if resolution == .useRemote,
               let database,
               let mediaRepository {
                let mutation = try remoteMutation(for: conflict)
                try database.transaction {
                    switch mutation.value {
                    case .boolean(let value):
                        switch mutation.fieldName {
                        case "watched":
                            try mediaRepository.markWatched(
                                id: mutation.item.id,
                                watched: value,
                                clearWatchlistWhenWatched: shouldClearWatchlistWhenMarkedWatched(mutation.item, watched: value)
                            )
                        case "watchlist":
                            try mediaRepository.setWatchlist(id: mutation.item.id, watchlist: value)
                        case "favorite":
                            try mediaRepository.setFavorite(id: mutation.item.id, favorite: value)
                        default:
                            throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
                        }
                    case .userRating(let rating):
                        try mediaRepository.updateRating(id: mutation.item.id, rating: rating)
                    }
                    try syncConflictRepository.resolve(id: conflict.id, resolution: resolution)
                }
                applyRemoteMutationInMemory(mutation)
            } else {
                try syncConflictRepository.resolve(id: conflict.id, resolution: resolution)
            }
            pendingSyncConflicts.removeAll { $0.id == conflict.id }
            pendingSyncConflictCount = max(0, pendingSyncConflictCount - 1)
            showFloatingNotice(
                title: resolution == .useRemote ? "已采用远端状态" : "已记录冲突处理",
                message: syncConflictResolutionNotice(conflict, resolution: resolution),
                kind: .success
            )
        } catch {
            showError("处理同步冲突失败", error)
        }
    }

    private func resolveTraktSyncConflictUsingLocal(_ conflict: SyncConflict) {
        guard let syncConflictRepository else { return }
        Task { [weak self] in
            guard let self else { return }
            do {
                let mutation = try self.localMutation(for: conflict)
                try await self.pushLocalMutationToTrakt(mutation)
                try syncConflictRepository.resolve(id: conflict.id, resolution: .useLocal)
                let now = Date()
                _ = self.traktAccountRecord(syncEnabled: self.settings.traktSyncEnabled, lastSyncedAt: now)
                self.remoteConnectorAccounts = try self.remoteConnectorAccountRepository?.fetchAll() ?? self.remoteConnectorAccounts
                self.pendingSyncConflicts.removeAll { $0.id == conflict.id }
                self.pendingSyncConflictCount = max(0, self.pendingSyncConflictCount - 1)
                let message = self.syncConflictResolutionNotice(conflict, resolution: .useLocal)
                self.deliverTaskNotice(
                    title: "已保留本地并同步 Trakt",
                    message: message,
                    kind: .success,
                    systemTitle: "已保留本地并同步 Trakt",
                    systemBody: message
                )
            } catch {
                self.deliverTaskNotice(
                    title: "Trakt 写回失败",
                    message: error.localizedDescription,
                    kind: .error,
                    systemTitle: "Trakt 写回失败",
                    systemBody: error.localizedDescription
                )
            }
        }
    }

    private func remoteMutation(for conflict: SyncConflict) throws -> SyncConflictRemoteMutation {
        guard let mediaID = conflict.mediaID, !mediaID.isEmpty else {
            throw SyncConflictApplyError.missingMediaID
        }
        if cachedPrivateItemIDs.contains(mediaID), !canDisplayPrivateItems {
            throw SyncConflictApplyError.privateItemLocked
        }
        guard let mediaRepository else {
            throw SyncConflictApplyError.repositoryUnavailable
        }
        guard let existing = try mediaRepository.fetch(id: mediaID) else {
            throw SyncConflictApplyError.mediaItemNotFound(mediaID)
        }
        let fieldName = normalizedSyncConflictField(conflict.fieldName)

        switch fieldName {
        case "watchlist":
            guard existing.type != .music else {
                throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
            }
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(try booleanSyncValue(conflict.remoteValue)))
        case "watched", "favorite":
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(try booleanSyncValue(conflict.remoteValue)))
        case "user_rating":
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .userRating(try userRatingSyncValue(conflict.remoteValue)))
        default:
            throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
        }
    }

    private func localMutation(for conflict: SyncConflict) throws -> SyncConflictRemoteMutation {
        guard conflict.provider == .trakt else {
            throw SyncConflictApplyError.unsupportedProvider(conflict.provider)
        }
        guard let mediaID = conflict.mediaID, !mediaID.isEmpty else {
            throw SyncConflictApplyError.missingMediaID
        }
        if cachedPrivateItemIDs.contains(mediaID) {
            throw SyncConflictApplyError.privateItemNotSyncable
        }
        guard let mediaRepository else {
            throw SyncConflictApplyError.repositoryUnavailable
        }
        guard let existing = try mediaRepository.fetch(id: mediaID) else {
            throw SyncConflictApplyError.mediaItemNotFound(mediaID)
        }
        guard existing.type != .privateCollection else {
            throw SyncConflictApplyError.privateItemNotSyncable
        }
        let fieldName = normalizedSyncConflictField(conflict.fieldName)
        switch fieldName {
        case "watched", "watchlist":
            let localValue = try booleanSyncValue(conflict.localValue, missing: .missingLocalValue)
            return SyncConflictRemoteMutation(item: existing, fieldName: fieldName, value: .boolean(localValue))
        default:
            throw SyncConflictApplyError.unsupportedField(conflict.fieldName)
        }
    }

    private func pushLocalMutationToTrakt(_ mutation: SyncConflictRemoteMutation) async throws {
        guard settings.traktSyncEnabled, isTraktConnected else { throw TraktError.notConnected }
        switch mutation.fieldName {
        case "watched":
            guard case .boolean(let value) = mutation.value else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            guard let ref = traktHistoryRef(for: mutation.item) else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            try await withValidTraktToken { service, token in
                if value {
                    try await service.addToHistory([ref], accessToken: token)
                } else {
                    try await service.removeFromHistory([ref], accessToken: token)
                }
            }
        case "watchlist":
            guard case .boolean(let value) = mutation.value else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            guard let ref = traktWatchlistRef(for: mutation.item) else {
                throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
            }
            try await withValidTraktToken { service, token in
                if value {
                    try await service.addToWatchlist([ref], accessToken: token)
                } else {
                    try await service.removeFromWatchlist([ref], accessToken: token)
                }
            }
        default:
            throw SyncConflictApplyError.unsupportedField(mutation.fieldName)
        }
    }

    private func applyRemoteMutationInMemory(_ mutation: SyncConflictRemoteMutation) {
        switch mutation.value {
        case .boolean(let value):
            switch mutation.fieldName {
            case "watched":
                updateWatchedInMemory(ids: [mutation.item.id], watched: value)
                if shouldClearWatchlistWhenMarkedWatched(mutation.item, watched: value) {
                    updateWatchlistInMemory(id: mutation.item.id, watchlist: false)
                }
            case "watchlist":
                updateWatchlistInMemory(id: mutation.item.id, watchlist: value)
            case "favorite":
                updateFavoriteInMemory(id: mutation.item.id, favorite: value)
            default:
                break
            }
        case .userRating(let rating):
            updateRatingInMemory(id: mutation.item.id, rating: rating)
        }
    }

    private func normalizedSyncConflictField(_ fieldName: String) -> String {
        SyncConflictValueParser.isUserRatingField(fieldName)
            ? "user_rating"
            : SyncConflictValueParser.normalizedFieldName(fieldName)
    }

    private func booleanSyncValue(_ rawValue: String?) throws -> Bool {
        try booleanSyncValue(rawValue, missing: .missingRemoteValue)
    }

    private func booleanSyncValue(_ rawValue: String?, missing: SyncConflictApplyError) throws -> Bool {
        do {
            return try SyncConflictValueParser.boolean(rawValue)
        } catch SyncConflictValueParseError.missingValue {
            throw missing
        } catch SyncConflictValueParseError.invalidBoolean(let value) {
            throw SyncConflictApplyError.invalidBooleanValue(value)
        } catch {
            throw error
        }
    }

    private func userRatingSyncValue(_ rawValue: String?) throws -> Double? {
        do {
            return try SyncConflictValueParser.userRating(rawValue)
        } catch SyncConflictValueParseError.missingValue {
            throw SyncConflictApplyError.missingRemoteValue
        } catch SyncConflictValueParseError.invalidUserRating(let value) {
            throw SyncConflictApplyError.invalidRatingValue(value)
        } catch {
            throw error
        }
    }

    func ignoreSyncConflict(_ conflict: SyncConflict) {
        guard let syncConflictRepository else { return }
        do {
            try syncConflictRepository.ignore(id: conflict.id)
            pendingSyncConflicts.removeAll { $0.id == conflict.id }
            pendingSyncConflictCount = max(0, pendingSyncConflictCount - 1)
            showFloatingNotice(title: "已忽略同步冲突", message: syncConflictDisplayTitle(conflict), kind: .info)
        } catch {
            showError("忽略同步冲突失败", error)
        }
    }

    private func displayedItem(id: String, fallback: MediaItem? = nil) -> MediaItem? {
        items.first { $0.id == id } ??
            activePlayerItem.flatMap { $0.id == id ? $0 : nil } ??
            selectedItem.flatMap { $0.id == id ? $0 : nil } ??
            quickPreviewItem.flatMap { $0.id == id ? $0 : nil } ??
            fallback
    }

    private func syncConflictDisplayTitle(_ conflict: SyncConflict) -> String {
        "\(conflict.provider.displayName) · \(displayTitleForMediaID(conflict.mediaID))"
    }

    private func resolutionDisplayName(_ resolution: SyncConflictResolution) -> String {
        switch resolution {
        case .useLocal: return "保留本地"
        case .useRemote: return "采用远端"
        case .merge: return "合并"
        case .keepBoth: return "都保留"
        }
    }

    private func syncConflictResolutionNotice(_ conflict: SyncConflict, resolution: SyncConflictResolution) -> String {
        switch resolution {
        case .useRemote:
            return "\(syncConflictDisplayTitle(conflict)) · 已写入 MediaLIB 内部索引"
        case .useLocal where conflict.provider == .trakt:
            return "\(syncConflictDisplayTitle(conflict)) · 已写回 Trakt"
        case .useLocal, .merge, .keepBoth:
            return resolutionDisplayName(resolution)
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
        try updateMetadata(id: item.id, metadata: update, source: writeFileTags ? "music-tag-file" : "music-tag-index")
        updateMetadataInMemory(id: item.id, metadata: update)
        return MusicTagApplyReport(
            itemID: item.id,
            didUpdateLibrary: true,
            didWriteFile: writeFileTags,
            warning: writeWarning
        )
    }

    @discardableResult
    private func updateMetadata(id: String, metadata: MediaMetadataUpdate, source: String) throws -> [MetadataCorrectionFieldChange] {
        guard let mediaRepository else { return [] }
        let changes = try mediaRepository.updateMetadata(id: id, metadata: metadata)
        if !changes.isEmpty {
            try metadataCorrectionRepository?.record(mediaID: id, changes: changes, source: source)
            metadataCorrectionCountsByMediaID[id] = (metadataCorrectionCountsByMediaID[id] ?? 0) + changes.count
            metadataCorrectionRecordCount += changes.count
        }
        return changes
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
        // 一键获取只做增量补充：已有完整标签/封面的曲目不再进入匹配队列。
        let tracks = musicTracks
            .filter(metadataFetchEnabled(for:))
            .filter(needsMusicMetadataSupplement)
        guard !tracks.isEmpty else {
            alert = AppAlert(title: "没有需要补充的音乐", message: "当前参与元数据拉取的音乐已具备主要标签和封面。")
            return
        }
        guard settings.musicMetadataProvider != .disabled else {
            alert = AppAlert(title: "音乐数据源未启用", message: "请先在设置中选择 MusicBrainz 或 iTunes Search。")
            return
        }

        let service = MetadataSearchService()
        isFetchingMusicMetadata = true
        musicMetadataFetchProgress = "准备补充 \(tracks.count) 首"
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
                if best.confidence >= settings.musicMetadataMatchTolerance.musicThreshold {
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
                            if source(for: track)?.preferMetadataWriteToSource == true {
                                await writeMusicTagsToSourceIfPossible(update: update, item: track)
                            }
                            try updateMetadata(id: track.id, metadata: update, source: "music-metadata-fetch")
                            updatedCount += 1
                        } catch {
                            showError("音乐信息写入失败", error)
                        }
                    }
                } else {
                    lowConfidence += 1
                }
            }
            if source(for: track)?.preferMetadataWriteToSource == true {
                await fetchLyricsIfPossible(for: track)
            }
        }

        reload()
        musicMetadataFetchProgress = lowConfidence > 0
            ? "完成 \(updatedCount)/\(tracks.count) 首（\(lowConfidence) 首置信度偏低已跳过）"
            : "完成 \(updatedCount)/\(tracks.count) 首"
    }

    private func needsMusicMetadataSupplement(_ track: MediaItem) -> Bool {
        (track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            (track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true) ||
            track.year == nil ||
            track.trackNumber == nil ||
            (track.posterPath?.isEmpty ?? true)
    }

    func supplementMissingMetadataFromHealth() {
        guard !isSupplementingMetadata else { return }
        let videoCandidates = missingMetadataItems
            .filter { $0.type != .music && metadataFetchEnabled(for: $0) }
        let musicCandidates = musicTracks
            .filter(metadataFetchEnabled(for:))
            .filter(needsMusicMetadataSupplement)
        guard !videoCandidates.isEmpty || !musicCandidates.isEmpty else {
            alert = AppAlert(title: "没有可补充项目", message: "当前参与元数据拉取的来源中没有发现需要补充的信息。")
            return
        }

        let taskID = beginBackgroundTask(
            kind: .metadataSupplement,
            title: "一键补充元数据",
            detail: "准备补充 \(videoCandidates.count) 个视频项目、\(musicCandidates.count) 首音乐",
            progress: 0,
            isCancellable: false
        )
        Task { [weak self] in
            await self?.performMetadataSupplement(
                videoCandidates: videoCandidates,
                musicCandidates: musicCandidates,
                taskID: taskID
            )
        }
    }

    private func performMetadataSupplement(
        videoCandidates: [MediaItem],
        musicCandidates: [MediaItem],
        taskID: UUID
    ) async {
        guard !isSupplementingMetadata else { return }
        isSupplementingMetadata = true
        defer { isSupplementingMetadata = false }

        let total = max(videoCandidates.count + musicCandidates.count, 1)
        let service = MetadataSearchService()
        var processed = 0
        var updated = 0
        var skipped = 0
        var errors: [String] = []

        for item in videoCandidates {
            if Task.isCancelled { break }
            updateBackgroundTask(id: taskID, progress: Double(processed) / Double(total), detail: "补充 \(item.title)")
            guard let update = await bestSupplementalVideoUpdate(for: item, service: service) else {
                skipped += 1
                processed += 1
                continue
            }
            do {
                if source(for: item)?.preferMetadataWriteToSource == true {
                    try? writeVideoMetadataSidecarIfPossible(item: item, update: update)
                }
                try updateMetadata(id: item.id, metadata: update, source: "metadata-supplement")
                updated += 1
            } catch {
                errors.append(error.localizedDescription)
            }
            processed += 1
        }

        if settings.musicMetadataProvider != .disabled {
            for track in musicCandidates {
                if Task.isCancelled { break }
                updateBackgroundTask(id: taskID, progress: Double(processed) / Double(total), detail: "补充 \(track.title)")
                guard let update = await bestSupplementalMusicUpdate(for: track, service: service) else {
                    skipped += 1
                    processed += 1
                    continue
                }
                do {
                    if source(for: track)?.preferMetadataWriteToSource == true {
                        await writeMusicTagsToSourceIfPossible(update: update, item: track)
                    }
                    try updateMetadata(id: track.id, metadata: update, source: "metadata-supplement")
                    updated += 1
                } catch {
                    errors.append(error.localizedDescription)
                }
                processed += 1
            }
        } else if !musicCandidates.isEmpty {
            skipped += musicCandidates.count
        }

        reload()
        let detail = skipped > 0
            ? "已补充 \(updated) 项，\(skipped) 项因未匹配或数据源未配置跳过"
            : "已补充 \(updated) 项"
        updateBackgroundTask(id: taskID, progress: 1, detail: detail)
        finishBackgroundTask(id: taskID, errors: errors)
        if errors.isEmpty {
            alert = AppAlert(title: "补充完成", message: detail)
        }
    }

    private func bestSupplementalVideoUpdate(for item: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate? {
        let apiKey = settings.tmdbAPIKey?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !apiKey.isEmpty else { return nil }
        let language = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        let threshold = settings.metadataMatchTolerance.videoThreshold
        guard let best = await bestTMDBVideoMatch(for: item, service: service, apiKey: apiKey, language: language),
              best.confidence >= threshold else { return nil }
        return await supplementalVideoUpdate(from: best.result, item: item, service: service)
    }

    private func supplementalVideoUpdate(from result: MetadataSearchResult, item: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate {
        let needsPoster = item.posterPath?.isEmpty ?? true
        var update = await service.materializedMetadataUpdate(
            for: result,
            itemID: item.id,
            artworkDirectory: needsPoster ? directories?.thumbnails : nil
        )
        update.title = nil
        update.originalTitle = nil
        if item.year != nil { update.year = nil }
        if item.overview?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.overview = nil }
        if !needsPoster { update.posterPath = nil }
        if item.backdropPath?.isEmpty == false { update.backdropPath = nil }
        if item.rating != nil { update.rating = nil }
        if item.runtime != nil { update.runtime = nil }
        if item.externalID?.isEmpty == false { update.externalID = nil }
        if item.metadataProvider?.isEmpty == false { update.metadataProvider = nil }
        if item.genre?.isEmpty == false { update.genre = nil }
        return update
    }

    private func bestSupplementalMusicUpdate(for track: MediaItem, service: MetadataSearchService) async -> MediaMetadataUpdate? {
        let query = [track.artist, track.title]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let results = try? await service.searchMusic(
            query: query.isEmpty ? track.title : query,
            provider: settings.musicMetadataProvider,
            lastfmAPIKey: settings.lastfmAPIKey
        ),
              let best = MetadataMatchScorer.bestMusicMatch(for: track, in: results),
              best.confidence >= settings.musicMetadataMatchTolerance.musicThreshold else {
            return nil
        }
        let needsCover = track.posterPath?.isEmpty ?? true
        var update = needsCover
            ? await service.materializedMetadataUpdate(
                for: best.result,
                itemID: track.id,
                artworkDirectory: directories?.thumbnails,
                preserveEmbeddedPoster: track.hasEmbeddedArtwork
            )
            : best.result.metadataUpdate
        update.title = nil
        update.originalTitle = nil
        if track.artist?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.artist = nil }
        if track.album?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false { update.album = nil }
        if track.trackNumber != nil { update.trackNumber = nil }
        if track.year != nil { update.year = nil }
        if !needsCover { update.posterPath = nil }
        update.backdropPath = nil
        return update
    }

    private func writeMusicTagsToSourceIfPossible(update: MediaMetadataUpdate, item: MediaItem) async {
        guard canWriteMusicFileTags(for: item) else { return }
        let draft = MusicTagDraft(
            artist: update.artist,
            album: update.album,
            trackNumber: update.trackNumber,
            year: update.year,
            artworkPath: update.posterPath,
            externalID: update.externalID,
            metadataProvider: update.metadataProvider
        )
        guard draft.hasWritableMetadata else { return }
        do {
            _ = try await MusicTagEditingService(logger: logger).write(draft, to: item)
        } catch {
            logger?.log("音乐标签写入源文件失败，已回落到 MediaLIB 索引：\(error.localizedDescription)", level: .warning)
        }
    }

    private func writeVideoMetadataSidecarIfPossible(item: MediaItem, update: MediaMetadataUpdate) throws {
        guard let source = source(for: item), source.sourceKind == .local else { return }
        let targetURL: URL?
        if item.type == .movie, let filePath = item.filePath {
            targetURL = URL(fileURLWithPath: filePath).deletingLastPathComponent().appendingPathComponent("movie.nfo")
        } else if item.type == .tvShow || item.type == .anime {
            let firstEpisodeURL = children(for: item).first?.filePath.map { URL(fileURLWithPath: $0) }
            targetURL = firstEpisodeURL?.deletingLastPathComponent().appendingPathComponent("tvshow.nfo")
        } else {
            targetURL = nil
        }
        guard let targetURL else { return }
        let directory = targetURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: directory.path) else { return }
        let xml = """
        <?xml version="1.0" encoding="UTF-8" standalone="yes"?>
        <\(item.type == .movie ? "movie" : "tvshow")>
          <title>\(xmlEscaped(update.title ?? item.title))</title>
          \(update.originalTitle.map { "<originaltitle>\(xmlEscaped($0))</originaltitle>" } ?? "")
          \(update.year.map { "<year>\($0)</year>" } ?? "")
          \(update.overview.map { "<plot>\(xmlEscaped($0))</plot>" } ?? "")
          \(update.rating.map { "<rating>\($0)</rating>" } ?? "")
          \(update.genre.map { "<genre>\(xmlEscaped($0))</genre>" } ?? "")
          \(update.externalID.map { "<uniqueid type=\"tmdb\">\(xmlEscaped($0))</uniqueid>" } ?? "")
        </\(item.type == .movie ? "movie" : "tvshow")>
        """
        try xml.write(to: targetURL, atomically: true, encoding: .utf8)
    }

    private func xmlEscaped(_ text: String) -> String {
        text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&apos;")
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
            copy.genre = metadata.genre ?? copy.genre
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
        let watchedThresholdChanged = abs(configuredWatchedThreshold - settings.watchedThreshold) > 0.0001
        configuredWatchedThreshold = settings.watchedThreshold
        settingsStore.save(settings)
        applyAppearance()
        if watchedThresholdChanged {
            rebuildDerivedItemCaches()
            libraryRevision += 1
        }
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
        cancelAllCancellableBackgroundTasks()
        activePlayerItem = nil
        quickPreviewItem = nil

        do {
            try database.restore(from: backupURL, safetyBackupDirectory: directories.databaseBackups)
            reload()
            restoreMusicQueueState()
            alert = AppAlert(
                title: "数据库恢复完成",
                message: "已从 \(backupURL.lastPathComponent) 恢复媒体索引、播放记录、喜欢、想看、视频集合、歌单和队列。用户媒体文件没有被修改。"
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
        logger?.log("远程受限服务器（白名单）：\(serverHost) — \(reason ?? "未知原因")", level: .error)
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
            source.autoScan && !source.sourceKind.isRemoteMediaServer
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
                .filter({ Self.isSourcePath(path, inside: $0.path) })
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

    /// 需要 TMDB 刷新的电视剧 / 动漫系列项：未匹配，或已匹配但语言标记与当前设置不一致。
    private var tmdbMatchCandidates: [MediaItem] {
        let expectedProvider = MetadataSearchService.tmdbProviderName(language: settings.tmdbLanguage)
        return topLevelItems.filter { item in
            (item.type == .tvShow || item.type == .anime)
                && Self.needsTMDBRefresh(item, expectedProvider: expectedProvider)
                && metadataFetchEnabled(for: item)
        }
    }

    private static func needsTMDBRefresh(_ item: MediaItem, expectedProvider: String) -> Bool {
        guard item.externalID?.hasPrefix("tmdb:") == true else { return true }
        guard let provider = item.metadataProvider, provider.hasPrefix("TMDB") else { return true }
        // 旧版本只写入 "TMDB"，没有语言信息；用户切换语言后需要允许按当前语言覆盖一次。
        return provider != expectedProvider
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

    /// 实际执行匹配：逐部用清洗后的剧名变体搜索 TMDB，取最佳结果、下载封面并写回元数据。
    /// 单部失败不影响整体；低置信候选保留给健康中心或手动补充复核。
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
            guard let best = await bestTMDBVideoMatch(for: item, service: service, apiKey: apiKey, language: language) else {
                lowConfidence += 1
                continue
            }
            guard best.confidence >= videoThreshold else {
                lowConfidence += 1
                logger?.log("TMDB 低置信跳过（\(item.title) → \(best.result.title) · \(String(format: "%.2f", best.confidence))）")
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

    private func bestTMDBVideoMatch(
        for item: MediaItem,
        service: MetadataSearchService,
        apiKey: String,
        language: String
    ) async -> (result: MetadataSearchResult, confidence: Double)? {
        let queries = videoSearchQueriesIncludingFolderNames(for: item)
        guard !queries.isEmpty else { return nil }
        var allResults: [MetadataSearchResult] = []
        var seenIDs: Set<String> = []
        var matchedQueries: [String: [String]] = [:]

        for query in queries.prefix(settings.metadataMatchTolerance == .loose ? 8 : 5) {
            if Task.isCancelled { break }
            do {
                let results = try await service.searchTMDB(
                    query: query,
                    itemType: item.type,
                    apiKey: apiKey,
                    language: language
                )
                for result in results {
                    matchedQueries[result.id, default: []].append(query)
                    if !seenIDs.contains(result.id) {
                        seenIDs.insert(result.id)
                        allResults.append(result)
                    }
                }
            } catch {
                logger?.log("TMDB 搜索失败（\(query)）：\(error.localizedDescription)", level: .error)
            }
        }

        return MetadataMatchScorer.bestVideoMatch(for: item, in: allResults, matchedQueries: matchedQueries)
    }

    private func videoSearchQueriesIncludingFolderNames(for item: MediaItem) -> [String] {
        var queries = MetadataMatchScorer.videoSearchQueries(for: item)
        queries.append(contentsOf: folderNameQueries(for: item))
        return uniqueTMDBQueries(queries)
    }

    private func folderNameQueries(for item: MediaItem) -> [String] {
        let episodes = children(for: item)
        let paths = episodes.compactMap(\.filePath)
        let directories = paths.flatMap { path -> [String] in
            let fileURL = URL(fileURLWithPath: path)
            let parent = fileURL.deletingLastPathComponent()
            let grandParent = parent.deletingLastPathComponent()
            return [parent.lastPathComponent, grandParent.lastPathComponent]
        }
        return directories
            .filter { !$0.isEmpty && $0 != "/" }
            .flatMap { MetadataMatchScorer.videoSearchQueries(for: folderProbeItem(title: $0, base: item)) }
    }

    private func folderProbeItem(title: String, base item: MediaItem) -> MediaItem {
        MediaItem(
            id: "\(item.id)-folder-probe-\(title)",
            type: item.type,
            title: title,
            originalTitle: item.originalTitle,
            year: item.year,
            sourcePath: item.sourcePath,
            collectionTitle: item.collectionTitle
        )
    }

    private func uniqueTMDBQueries(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.compactMap { raw in
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let key = trimmed.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return seen.insert(key).inserted ? trimmed : nil
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
