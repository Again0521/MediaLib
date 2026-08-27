import AppKit
import Combine
import Foundation
import MediaLibCore
import MediaLibServerProtocol
import Network
import OSLog
import SwiftUI
import UniformTypeIdentifiers

private let versionMaintenanceLogger = Logger(
    subsystem: Bundle.main.bundleIdentifier ?? "MediaLib",
    category: "VersionMaintenance"
)

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// 自定义封面 / 背景图的目标类型。
enum VideoArtworkKind: Sendable {
    case poster
    case backdrop
}

/// URL 视频链接的健康状态：通过可达性与是否可解析判断。
enum URLItemHealthState: String, Sendable {
    case unknown      // 未探测（非 http(s) 协议或尚未检查）
    case checking     // 正在检查
    case ok           // 可达且像是可解析的视频
    case unreachable  // 无法访问（超时 / 4xx / 5xx）
    case unparseable  // 可访问但疑似不是视频（返回网页等）

    var isUnhealthy: Bool { self == .unreachable || self == .unparseable }

    var displayName: String {
        switch self {
        case .unknown: return "未检查"
        case .checking: return "检查中"
        case .ok: return "可访问"
        case .unreachable: return "无法访问"
        case .unparseable: return "无法解析"
        }
    }

    var systemImage: String {
        switch self {
        case .unknown: return "questionmark.circle"
        case .checking: return "arrow.triangle.2.circlepath"
        case .ok: return "checkmark.circle"
        case .unreachable: return "exclamationmark.circle"
        case .unparseable: return "questionmark.diamond"
        }
    }
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

    /// 由 AppAlert 的标题/正文推断浮窗语气：失败/无法/错误→error，成功/已完成→success，
    /// 否则 info。用于把原本"纯告知模态弹窗"统一收敛到浮窗时仍保留正确的图标与配色。
    static func inferred(fromTitle title: String, message: String? = nil) -> AppFloatingNoticeKind {
        let text = (title + " " + (message ?? "")).lowercased()
        let negativeKeywords = ["失败", "无法", "错误", "出错", "异常", "拒绝", "不支持", "未能", "error", "failed", "cannot", "unable"]
        if negativeKeywords.contains(where: text.contains) {
            return .error
        }
        let positiveKeywords = ["成功", "已完成", "已保存", "完成", "已更新", "已添加", "succeeded", "completed", "saved"]
        if positiveKeywords.contains(where: text.contains) {
            return .success
        }
        return .info
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

private actor ScanIncrementalLibraryPublisher {
    private let publish: @Sendable () async -> Void
    private var policy: PendingIDBatchPublishPolicy

    init(
        minimumInterval: TimeInterval = 1.2,
        minimumItemCount: Int = 18,
        publish: @escaping @Sendable () async -> Void
    ) {
        self.policy = PendingIDBatchPublishPolicy(
            minimumInterval: minimumInterval,
            minimumItemCount: minimumItemCount
        )
        self.publish = publish
    }

    func record(_ ids: Set<String>) async {
        let now = Date()
        if policy.record(ids, now: now) {
            await flush(now: now)
        }
    }

    func flush() async {
        await flush(now: Date())
    }

    private func flush(now: Date) async {
        guard policy.flush(now: now) else { return }
        await publish()
    }
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
    private var policy = ScanProgressPublishPolicy()

    func reset() {
        lock.lock()
        policy.reset()
        lock.unlock()
    }

    func shouldPublish(_ progress: ScanProgress) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.shouldPublish(progress)
    }
}

/// 视频缓存的 URLSession 回调可能非常密集；这里统一把任务中心进度压到约 5fps/1% 步进，
/// 避免远程缓存任务把主线程和浮动任务列表拖进高频刷新路径。
private final class VideoCacheProgressThrottler: @unchecked Sendable {
    private let lock = NSLock()
    private var policy = FractionalProgressPublishPolicy()

    func shouldPublish(_ progress: Double) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return policy.shouldPublish(progress)
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

private struct LibraryReloadSnapshot: Sendable {
    var sources: [MediaSource]
    var items: [MediaItem]
    var musicPlaylists: [MusicPlaylist]
    var musicSmartPlaylists: [MusicSmartPlaylist]
    var videoSmartCollections: [VideoSmartCollection]
    var videoManualCollections: [VideoManualCollection]
    var videoOfflineSubscriptions: [VideoOfflineSubscription]
    var metadataCorrectionCountsByMediaID: [String: Int]
    var metadataCorrectionRecordCount: Int
    var metadataCorrectionBatches: [MetadataCorrectionBatchSummary]
    var pendingSyncConflictCount: Int
    var pendingSyncConflicts: [SyncConflict]
    var remoteConnectorAccounts: [RemoteConnectorAccount]
    var musicProjectionSnapshot: MusicLibraryProjectionSnapshot
    var detailMetadataGapsByMediaID: [String: Set<String>]
    var detailSearchTermsByMediaID: [String: [String]]
    var detailBackdropPathsByMediaID: [String: String]
    var mediaExternalIDIndex: [String: String]
    var mediaIDsByPersonID: [String: Set<String>]
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

// LRCLibLyricsSearchResult 已随歌词获取移到 AppState+MetadataSupplement.swift。

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

// TraktImportReport 已随 Trakt 同步移到 AppState+TraktSync.swift。

// SyncConflictRemoteMutation / SyncConflictApplyError 已随同步冲突处理移到 AppState+SyncConflictResolution.swift。

private extension RemoteConnectorProvider {
    var mediaSourceScheme: String {
        switch self {
        case .plex:
            return "plex"
        case .jellyfin:
            return "jellyfin"
        case .mlink:
            return "mlink"
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
        case .mlink:
            return "MediaLIB Server"
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
        if self == .mlink {
            return """
            {"mediaSync":true,"librarySelection":true,"playbackReporting":true,"favoriteSync":false,"watchedSync":true,"tokenLogin":true,"nativeDecode":false,"webDecode":true}
            """
        }
        return """
        {"mediaSync":true,"librarySelection":true,"playbackReporting":true,"favoriteSync":true,"watchedSync":true}
        """
    }
}

@MainActor
final class AppState: ObservableObject {
    let libraryDomain = LibraryDomainStore()
    private var libraryDomainForwarding: AnyCancellable?
    var sources: [MediaSource] {
        get { libraryDomain.sources }
        set { libraryDomain.replaceSources(newValue) }
    }
    var items: [MediaItem] {
        get { libraryDomain.items }
        set { libraryDomain.replaceItems(newValue) }
    }
    @Published var settings: AppSettings
    /// 服务端设置独立于播放器偏好：它将同时服务于桌面端和未来的纯服务端镜像。
    let serverModeSettingsStore = ServerModeSettingsStore()
    let serverModeController = ServerModeProcessController()
    private var serverModeForwarding: AnyCancellable?
    let serverAdministrationStore = ServerAdministrationStore()
    private var serverAdministrationForwarding: AnyCancellable?
    @Published var serverModeConfiguration: ServerModeConfiguration
    let detailNavigation = DetailNavigationStore()
    private var detailNavigationForwarding: AnyCancellable?
    var selectedItem: MediaItem? {
        get { detailNavigation.selectedItem }
        set { detailNavigation.setSelectedItem(newValue) }
    }
    var selectedPersonID: String? {
        get { detailNavigation.selectedPersonID }
        set { detailNavigation.setSelectedPersonID(newValue) }
    }
    var detailReturnContext: DetailReturnContext? {
        detailNavigation.detailReturnContext
    }
    let playbackSession = PlaybackSessionStore()
    private var playbackSessionForwarding: AnyCancellable?
    var activePlayerItem: MediaItem? {
        get { playbackSession.activePlayerItem }
        set { playbackSession.setActivePlayerItem(newValue) }
    }
    /// 视频播放队列（播放器内剧集列表）：播放系列中的某一集时，
    /// 自动装入「当前集 + 之后的同系列剧集」；独立影片只含自身。
    var videoQueue: [MediaItem] {
        get { playbackSession.videoQueue }
        set { playbackSession.replaceVideoQueue(newValue) }
    }
    /// 「打开网络串流」输入弹窗。
    let networkStreamPrompt = NetworkStreamPromptStore()
    private var networkStreamPromptForwarding: AnyCancellable?
    var showingNetworkStreamPrompt: Bool {
        get { networkStreamPrompt.isShowingPrompt }
        set { networkStreamPrompt.setShowingPrompt(newValue) }
    }
    let appUpdateState = AppUpdateStateStore()
    private var appUpdateStateForwarding: AnyCancellable?
    /// 可用的新版本（驱动更新提示弹窗）。
    var availableUpdate: AppUpdateInfo? {
        get { appUpdateState.availableUpdate }
        set { appUpdateState.setAvailableUpdate(newValue) }
    }
    var isCheckingForUpdates: Bool {
        get { appUpdateState.isCheckingForUpdates }
        set { appUpdateState.setCheckingForUpdates(newValue) }
    }
    // internal（非 private）：供拆到 AppState+Updates.swift 的更新检查方法读写。
    var updateCheckTask: Task<Void, Never>?
    /// 第三次启动时弹出的赞赏邀请。
    let sponsorPrompt = SponsorPromptStore()
    private var sponsorPromptForwarding: AnyCancellable?
    var showingSponsorPrompt: Bool {
        get { sponsorPrompt.isShowingInvite }
        set { sponsorPrompt.setShowingInvite(newValue) }
    }
    let quickPreview = QuickPreviewStore()
    private var quickPreviewForwarding: AnyCancellable?
    var quickPreviewItem: MediaItem? {
        get { quickPreview.item }
        set { quickPreview.setItem(newValue) }
    }
    let scanActivity = ScanActivityStore()
    private var scanActivityForwarding: AnyCancellable?
    var scanProgress: ScanProgress? {
        get { scanActivity.progress }
        set { scanActivity.setProgress(newValue) }
    }
    var isScanning: Bool {
        get { scanActivity.isScanning }
        set { scanActivity.setScanning(newValue) }
    }
    var scanQueueCount: Int {
        get { scanActivity.queueCount }
        set { scanActivity.setQueueCount(newValue) }
    }
    let taskCenter = TaskCenterStore()
    private var taskCenterForwarding: AnyCancellable?
    var backgroundTasks: [BackgroundTaskSnapshot] {
        get { taskCenter.tasks }
        set { taskCenter.replaceTasks(newValue) }
    }
    /// 剧集 TMDB 一键匹配进行中（驱动设置页按钮的进度态）。
    let tmdbMatchState = TMDBMatchStateStore()
    private var tmdbMatchStateForwarding: AnyCancellable?
    var isMatchingTMDB: Bool {
        get { tmdbMatchState.isMatching }
        set { tmdbMatchState.setMatching(newValue) }
    }
    @Published var alert: AppAlert? {
        didSet {
            // AppAlert 是"纯告知"载体（仅标题/正文 + 一个"好"键），统一只走浮窗通知，
            // 不再叠加模态弹窗（ContentView 已移除 .alert(item:)），避免同一事件双重打扰。
            if let alert {
                showFloatingNotice(
                    title: alert.title,
                    message: alert.message.isEmpty ? nil : alert.message,
                    kind: AppFloatingNoticeKind.inferred(fromTitle: alert.title, message: alert.message)
                )
            }
        }
    }
    let floatingNoticeStore = FloatingNoticeStore()
    private var floatingNoticeForwarding: AnyCancellable?
    var floatingNotices: [AppFloatingNotice] {
        get { floatingNoticeStore.notices }
        set { floatingNoticeStore.replaceVisibleNotices(with: newValue) }
    }
    /// 受限远程媒体服务器提示（白名单拒绝）；非 nil 时弹出专用面板。
    let embyRestrictionNoticeStore = EmbyRestrictionNoticeStore()
    private var embyRestrictionNoticeForwarding: AnyCancellable?
    var embyRestrictionNotice: EmbyRestrictionNotice? {
        get { embyRestrictionNoticeStore.notice }
        set { embyRestrictionNoticeStore.setNotice(newValue) }
    }
    /// C2 批量操作：海报墙多选状态已抽到 SelectionStore（R1-ARCH-001 试水）。
    /// AppState 持有该 Store 并转发其 objectWillChange（见 init），下面的计算访问器
    /// 保持 `appState.isSelectionModeActive` / `appState.selectedItemIDs` 旧 API 不变（视图零改）。
    let selection = SelectionStore()
    private var selectionForwarding: AnyCancellable?
    var isSelectionModeActive: Bool { selection.isSelectionModeActive }
    var selectedItemIDs: Set<String> { selection.selectedItemIDs }
    /// 配色切换计数：每次切换预设 +1，驱动整窗"加载过场"覆盖层在下层刷新界面，避免逐控件慢慢变色。
    let themeRefresh = ThemeRefreshStore()
    private var themeRefreshForwarding: AnyCancellable?
    var themeRevision: Int {
        get { themeRefresh.themeRevision }
        set { themeRefresh.setThemeRevision(newValue) }
    }
    /// 音乐主题参数（MusicThemeConfig）刷新计数：用户「重新加载 / 恢复默认」后 +1，
    /// 触发音乐播放器主题子树按 .id 重建并重新读取 MusicThemeConfig.active（无需重启）。
    var musicThemeRevision: Int {
        get { themeRefresh.musicThemeRevision }
        set { themeRefresh.setMusicThemeRevision(newValue) }
    }
    let startupErrorStore = StartupErrorStore()
    private var startupErrorForwarding: AnyCancellable?
    var startupError: String? {
        get { startupErrorStore.message }
        set { startupErrorStore.setMessage(newValue) }
    }
    let privacyLockState = PrivacyLockStateStore()
    private var privacyLockStateForwarding: AnyCancellable?
    var privacyUnlocked: Bool {
        get { privacyLockState.isUnlocked }
        set { privacyLockState.setUnlocked(newValue) }
    }
    var privacyPINConfigured: Bool {
        get { privacyLockState.isPINConfigured }
        set { privacyLockState.setPINConfigured(newValue) }
    }
    let musicQueueStore = MusicQueueStore()
    private var musicQueueForwarding: AnyCancellable?
    var musicQueue: [MediaItem] {
        get { musicQueueStore.queue }
        set { musicQueueStore.replaceQueue(newValue) }
    }
    var musicRepeatMode: MusicRepeatMode {
        get { musicQueueStore.repeatMode }
        set { musicQueueStore.setRepeatMode(newValue) }
    }
    var musicShuffleEnabled: Bool {
        get { musicQueueStore.shuffleEnabled }
        set { musicQueueStore.setShuffleEnabled(newValue) }
    }
    // 随机播放的洗牌袋 + 历史已抽到 MusicShuffleNavigator（纯逻辑、可单测）。
    private let musicShuffleNavigator = MusicShuffleNavigator()
    // 音乐歌单（普通 + 智能）已抽到 MusicPlaylistStore；保留同名转发访问器使外部 API/视图零改。
    let musicPlaylistStore: MusicPlaylistStore
    private var musicPlaylistForwarding: AnyCancellable?
    var musicPlaylists: [MusicPlaylist] { musicPlaylistStore.playlists }
    let videoCollectionStore: VideoCollectionStore
    private var videoCollectionForwarding: AnyCancellable?
    var videoSmartCollections: [VideoSmartCollection] {
        videoCollectionStore.smartCollections
    }
    var videoManualCollections: [VideoManualCollection] {
        videoCollectionStore.manualCollections
    }
    @Published var videoOfflineSubscriptions: [VideoOfflineSubscription] = []
    // 元数据校正账本已抽到 MetadataCorrectionStore；保留同名转发访问器使外部 API/视图零改。
    let metadataCorrectionStore: MetadataCorrectionStore
    private var metadataCorrectionForwarding: AnyCancellable?
    var metadataCorrectionCountsByMediaID: [String: Int] { metadataCorrectionStore.countsByMediaID }
    var metadataCorrectionRecordCount: Int { metadataCorrectionStore.recordCount }
    var metadataCorrectionBatches: [MetadataCorrectionBatchSummary] { metadataCorrectionStore.batches }
    // 同步冲突待处理列表已抽到 SyncConflictStore；保留同名转发访问器使外部 API/视图零改。
    let syncConflictStore: SyncConflictStore
    private var syncConflictForwarding: AnyCancellable?
    var pendingSyncConflictCount: Int { syncConflictStore.pendingCount }
    var pendingSyncConflicts: [SyncConflict] { syncConflictStore.pendingConflicts }
    // 远程连接器账号与连接态已抽到 RemoteConnectorStore；保留同名访问器使设置页和同步扩展零改。
    let remoteConnectorStore = RemoteConnectorStore()
    private var remoteConnectorForwarding: AnyCancellable?
    var remoteConnectorAccounts: [RemoteConnectorAccount] {
        get { remoteConnectorStore.accounts }
        set { remoteConnectorStore.replaceAccounts(newValue) }
    }
    let mediaSearchIndexState = MediaSearchIndexStateStore()
    private var mediaSearchIndexForwarding: AnyCancellable?
    private(set) var detailMetadataGapsByMediaID: [String: Set<String>] {
        get { mediaSearchIndexState.detailMetadataGapsByMediaID }
        set { mediaSearchIndexState.replaceDetailMetadataGaps(newValue) }
    }
    private(set) var detailSearchTermsByMediaID: [String: [String]] {
        get { mediaSearchIndexState.detailSearchTermsByMediaID }
        set { mediaSearchIndexState.replaceDetailSearchTerms(newValue) }
    }
    private(set) var mediaSearchRevision: Int {
        get { mediaSearchIndexState.revision }
        set { mediaSearchIndexState.setRevision(newValue) }
    }
    private var mediaSearchFieldsCacheRevision = -1
    private var mediaSearchFieldsCache: [String: [String?]] = [:]
    let videoManualCollectionCreation = VideoManualCollectionCreationStore()
    private var videoManualCollectionCreationForwarding: AnyCancellable?
    var videoManualCollectionCreationRequest: VideoManualCollectionCreationRequest? {
        get { videoManualCollectionCreation.request }
        set { videoManualCollectionCreation.setRequest(newValue) }
    }
    let videoOfflineSubscriptionLimit = VideoOfflineSubscriptionLimitStore()
    private var videoOfflineSubscriptionLimitForwarding: AnyCancellable?
    var videoOfflineSubscriptionLimitRequest: VideoOfflineSubscriptionLimitRequest? {
        get { videoOfflineSubscriptionLimit.request }
        set { videoOfflineSubscriptionLimit.setRequest(newValue) }
    }
    var musicSmartPlaylists: [MusicSmartPlaylist] { musicPlaylistStore.smartPlaylists }
    var playbackCommandRequest: PlaybackCommandRequest? {
        get { playbackSession.playbackCommandRequest }
        set { playbackSession.setPlaybackCommandRequest(newValue) }
    }
    let musicMetadataActivity = MusicMetadataActivityStore()
    private var musicMetadataActivityForwarding: AnyCancellable?
    var isFetchingMusicMetadata: Bool {
        get { musicMetadataActivity.isFetching }
        set { musicMetadataActivity.setFetching(newValue) }
    }
    var isSupplementingMetadata: Bool {
        get { musicMetadataActivity.isSupplementing }
        set { musicMetadataActivity.setSupplementing(newValue) }
    }
    private(set) var isConnectingEmby: Bool {
        get { remoteConnectorStore.isConnectingEmby }
        set { remoteConnectorStore.setConnecting(.emby, newValue) }
    }
    private(set) var isConnectingJellyfin: Bool {
        get { remoteConnectorStore.isConnectingJellyfin }
        set { remoteConnectorStore.setConnecting(.jellyfin, newValue) }
    }
    private(set) var isConnectingPlex: Bool {
        get { remoteConnectorStore.isConnectingPlex }
        set { remoteConnectorStore.setConnecting(.plex, newValue) }
    }
    private(set) var isConnectingMlink: Bool {
        get { remoteConnectorStore.isConnectingMlink }
        set { remoteConnectorStore.setConnecting(.mlink, newValue) }
    }
    private var version122MaintenanceTask: Task<Void, Never>?
    var musicMetadataFetchProgress: String {
        get { musicMetadataActivity.fetchProgress }
        set { musicMetadataActivity.setFetchProgress(newValue) }
    }
    @Published private(set) var isLibraryReloading = false
    private(set) var libraryRevision: Int {
        get { libraryDomain.libraryRevision }
        set { libraryDomain.setLibraryRevision(newValue) }
    }
    /// 仅在 reload() 完成（元数据/封面路径真实变化）时递增；文件存在性检查不会触发它。
    /// LocalPosterImage 的 cacheKey 改用此值，避免文件健康检查后触发全量图片重载。
    private(set) var posterRevision: Int {
        get { libraryDomain.posterRevision }
        set { libraryDomain.setPosterRevision(newValue) }
    }
    private(set) var favoriteRevision: Int {
        get { libraryDomain.favoriteRevision }
        set { libraryDomain.setFavoriteRevision(newValue) }
    }
    private(set) var watchlistRevision: Int {
        get { libraryDomain.watchlistRevision }
        set { libraryDomain.setWatchlistRevision(newValue) }
    }
    private(set) var ratingRevision: Int {
        get { libraryDomain.ratingRevision }
        set { libraryDomain.setRatingRevision(newValue) }
    }
    private(set) var videoCacheRevision: Int {
        get { libraryDomain.videoCacheRevision }
        set { libraryDomain.setVideoCacheRevision(newValue) }
    }
    private(set) var musicProjectionRevision: Int {
        get { libraryDomain.musicProjectionRevision }
        set { libraryDomain.setMusicProjectionRevision(newValue) }
    }
    /// 音乐内容修订号：仅当音乐曲目本身（曲目集合或其字段）真实变化时递增。
    /// 音乐库各子页面的快照缓存以它为失效键，避免视频/扫描等无关 libraryRevision
    /// 抖动把音乐列表快照全部打失效、每次切页都重新全量排序重建。
    private(set) var musicContentRevision: Int {
        get { libraryDomain.musicContentRevision }
        set { libraryDomain.setMusicContentRevision(newValue) }
    }
    private var musicContentFingerprint = 0
    /// 详情横版剧照缓存修订号：后台补抓到新 backdrop 时递增，驱动首页 banner 换图。
    @Published private(set) var backdropRevision = 0
    private var heroBackdropWarmedIDs: Set<String> = []
    private var heroBackdropWarmupTask: Task<Void, Never>?
    private var lyricsBackfillTask: Task<Void, Never>?
    @Published private(set) var videoCacheStorageSummary = VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
    @Published private(set) var videoOfflineSubscriptionWiFiAvailable = false
    // 播放歌名含「アゲイン」的歌曲时触发一次轻量樱花动效，仅限本次启动首次播放。
    let sakuraEasterEggState = SakuraEasterEggStateStore()
    private var sakuraEasterEggStateForwarding: AnyCancellable?
    var sakuraEasterEggActive: Bool {
        get { sakuraEasterEggState.isActive }
        set { sakuraEasterEggState.setActive(newValue) }
    }
    // internal（非 private）：供拆到 AppState+ExternalPlayback.swift 的彩蛋触发方法读写。
    var sakuraEasterEggShownThisLaunch: Bool {
        get { sakuraEasterEggState.shownThisLaunch }
        set { sakuraEasterEggState.setShownThisLaunch(newValue) }
    }
    var sakuraEasterEggTask: Task<Void, Never>?
    // 只在本次进程内记住队列弹层上次停留位置，避免跨启动恢复到旧队列偏移。
    var musicQueueScrollAnchorID: String? {
        get { musicQueueStore.scrollAnchorID }
        set { musicQueueStore.scrollAnchorID = newValue }
    }
    let directories: AppDirectories?
    // internal：供 AppState+SyncConflictResolution 等 extension 访问。
    let database: DatabaseManager?
    private let sourceRepository: SourceRepository?
    // internal：供 AppState+BatchSelection 等 extension 跨文件访问。
    let mediaRepository: MediaRepository?
    // musicPlaylistRepository / musicSmartPlaylistRepository 已移入 MusicPlaylistStore 持有。
    private let musicQueueRepository: MusicQueueRepository?
    // videoSmartCollectionRepository / videoManualCollectionRepository 已移入 VideoCollectionStore 持有。
    private let videoOfflineSubscriptionRepository: VideoOfflineSubscriptionRepository?
    private let playbackMarkerRepository: PlaybackMarkerRepository?
    // metadataCorrectionRepository 已移入 MetadataCorrectionStore 持有。
    private let mediaDetailRepository: MediaDetailRepository?
    private let musicProjectionRepository: MusicLibraryProjectionRepository?
    // syncConflictRepository 已移入 SyncConflictStore 持有。
    // internal（非 private）：供拆到 AppState+TraktSync.swift 的方法使用。
    let remoteConnectorAccountRepository: RemoteConnectorAccountRepository?
    private let videoOfflineCacheStore: VideoOfflineCacheStore?
    let settingsStore = AppSettingsStore()   // internal：AppState+MusicTheme 等 extension 跨文件访问
    let logger: LoggingService?   // internal：供 AppState+Lastfm 等领域 extension 跨文件访问
    private let externalPlayerService = ExternalPlayerService()
    private let privacyLockService = PrivacyLockService()
    /// 把"保险库在这台机器上解锁着"这一个事实发布给服务进程。
    ///
    /// 网页由另一个进程提供，它读不到这里的内存状态——这正是"App 里已解锁、网页
    /// 上还是锁屏"的全部原因。发布的内容只有两个时间戳，口令始终留在
    /// `PrivacyLockService` 里。目录取应用支持根，与服务端的 `ServerDataDirectories.root`
    /// 解析到同一个位置。
    private var vaultUnlockSessionStore: VaultUnlockSessionStore?
    /// 解锁期间的续期定时器。会话本身会过期，所以 App 意外退出后网页最多在一个
    /// 有效期之后自己回到锁定，而不是永远敞着。
    private var vaultUnlockRefreshTask: Task<Void, Never>?
    /// 把首页那几条**推荐**栏目的名单发布给服务进程。
    ///
    /// 网页首页从前对同一批内容自己又推导了一遍（数据库按加入时间／评分各取一页，
    /// 「剧集推荐」就是"所有剧集"），于是同一个资料库在 App 和网页上给出两份不同的
    /// 片单，而且那份重算还要多跑两次全库排序查询。发布的内容只有**排好序的条目 ID**：
    /// 服务端拿到 ID 之后仍然要走它自己那套逐用户授权把条目查出来，客户端给的是
    /// 顺序，不是可见性。
    private var homeRecommendationStore: HomeRecommendationSnapshotStore?
    /// 上一次发布的内容摘要。首页看板每次重算都会调用发布，但名单通常一整天都不变，
    /// 没必要为此反复写盘。
    private var publishedHomeRecommendationDigest: String?
    /// 上一次发布的时刻。名单本身**会过期**（这是它在 App 崩溃后不至于永远陈旧的
    /// 兜底），所以即使内容一字未变，也要在过期之前续写一次——否则一台开着不动的
    /// 机器会在一天之后悄悄让网页失去这份名单。
    private var publishedHomeRecommendationsAt: Date?
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
    private var libraryReloadTask: Task<Void, Never>?
    private var libraryReloadGeneration = 0
    private var detailEnrichmentTasks: [String: Task<TMDBEnrichment?, Never>] = [:]
    private var videoCacheJobs: [UUID: VideoCacheJob] = [:]
    private var videoOfflineSubscriptionMaintenanceTask: Task<Void, Never>?
    private var videoOfflineSubscriptionExpirationTask: Task<Void, Never>?
    private var networkPathMonitor: NWPathMonitor?
    private let networkPathMonitorQueue = DispatchQueue(label: "MediaLIB.NetworkPathMonitor")
    var serverLANReconciliationTask: Task<Void, Never>?
    private var keyframeStoryboardTasks: [UUID: Task<Void, Never>] = [:]
    private var playbackMarkerAnalysisTasks: [UUID: Task<Void, Never>] = [:]
    private var musicProjectionTask: Task<Void, Never>?
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
    private var localFileEventMonitorConfigurationID = UUID()
    private var pendingFileEventPaths: [String: Set<String>] = [:]
    private var pendingFullScanSourceIDs: Set<String> = []
    private var remountingNetworkSourceIDs: Set<String> = []
    private var cachedTopLevelItems: [MediaItem] = []
    private var cachedPrivateTopLevelItems: [MediaItem] = []
    private var cachedItemsByID: [String: MediaItem] = [:]
    // 注：以下两个缓存放宽为 internal，供拆分到独立文件的 AppState extension（如歌单）读取。
    var cachedMusicTracks: [MediaItem] = []
    var cachedMusicTracksByID: [String: MediaItem] = [:]
    var cachedMusicTracksBySection: [MusicLibrarySection: [MediaItem]] = [:]
    var cachedMusicSmartTracksByPlaylistID: [String: [MediaItem]] = [:]
    private var cachedMusicAlbumSummaries: [MusicAlbumSummary] = []
    private var cachedMusicArtistSummaries: [MusicArtistSummary] = []
    private var cachedMusicProjectionRebuiltAt: Date?
    /// 首页专用的公开音乐投影：本地音乐和远程媒体服务器音乐合并，
    /// 但不改变音乐侧栏的本地库索引与来源归属。
    private var cachedHomeMusicTracks: [MediaItem] = []
    private var cachedHomeMusicPlayableTracks: [MediaItem] = []
    private var cachedHomeContinueListeningTracks: [MediaItem] = []
    private var cachedHomeMusicSignalTracks: [MediaItem] = []
    private var cachedEmbyTopLevelItems: [MediaItem] = []
    private var cachedAlbumItems: [MediaItem] = []
    private var cachedHomeVideoItems: [MediaItem] = []
    private var cachedHomeOfflineVideoItems: [MediaItem] = []
    private var cachedEmbyLibrarySummaries: [EmbyLibrarySummary] = []
    private var cachedChildrenByParentID: [String: [MediaItem]] = [:]
    // internal（非 private）：供拆到 AppState+TraktSync.swift 的方法读取。
    var cachedPrivateItemIDs: Set<String> = []
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
    private var cachedVideoSeriesStatesByID: [String: VideoSeriesCacheState] = [:]
    private var cachedOfflineSources: [MediaSource] = []
    private var cachedOfflineSourceIDs: Set<String> = []
    // URL 链接健康探测已抽到 URLSourceHealthMonitor（探测调度 + 结果存储，可注入 prober 单测）。
    let urlHealthMonitor = URLSourceHealthMonitor()
    private var urlHealthForwarding: AnyCancellable?
    private var cachedHomeStats = HomeStatsSnapshot()
    private var detailBackdropPathsByMediaID: [String: String] = [:]
    private var mediaExternalIDIndex: [String: String] = [:]
    private var mediaIDsByPersonID: [String: Set<String>] = [:]
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
    private var restoredArtworkWarmupTasks: [BackgroundTaskSnapshot] = []
    private let backgroundTaskPersistence = BackgroundTaskPersistenceScheduler()
    private var embyPlaySessionIDs: [String: String] = [:]
    private var playbackClearRevisionByItemID: [String: Date] = [:]
    /// B2 Scrobbling：当前待结算的听歌候选（开始播放即记录，达到时长门槛后 track.scrobble）。
    var pendingScrobble: (item: MediaItem, startedAt: Date, duration: Double)?   // internal：Last.fm extension 跨文件访问
    /// Last.fm 授权流程中临时持有的 request token（用户在浏览器授权后用它换 session）。
    var lastfmPendingAuthToken: String?   // internal：Last.fm extension 跨文件访问
    /// 配色等高频设置变更的防抖落盘任务。
    var settingsPersistTask: Task<Void, Never>?   // internal：AppState+MusicTheme extension 跨文件访问
    /// 正在进行 Last.fm 授权/连接操作。
    let lastfmAuthorizationState = LastfmAuthorizationStateStore()
    private var lastfmAuthorizationForwarding: AnyCancellable?
    var isLastfmAuthorizing: Bool {
        get { lastfmAuthorizationState.isAuthorizing }
        set { lastfmAuthorizationState.setAuthorizing(newValue) }
    }

    func presentDetail(
        _ item: MediaItem,
        from destinationID: String,
        anchorID: String,
        searchText: String? = nil
    ) {
        detailNavigation.presentDetail(
            item,
            from: destinationID,
            anchorID: anchorID,
            searchText: searchText
        )
    }

    func presentRelatedDetail(_ item: MediaItem) {
        detailNavigation.presentRelatedDetail(item)
    }

    func presentPersonDetail(_ personID: String) {
        detailNavigation.presentPersonDetail(personID)
    }

    func dismissDetail() {
        detailNavigation.dismissDetail { id in
            items.first { $0.id == id }
        }
    }

    func consumeDetailReturnContext(destinationID: String, anchorID: String) {
        detailNavigation.consumeReturnContext(destinationID: destinationID, anchorID: anchorID)
    }

    func clearDetailNavigation() {
        detailNavigation.clear()
    }

    init() {
        var loadedSettings = settingsStore.load()
        LiveTitleIconDebugTool.adjustSettingsForDebug(&loadedSettings)
        if ProcessInfo.processInfo.arguments.contains("--debug-force-onboarding") {
            loadedSettings.hasCompletedOnboarding = false
        }
        self.settings = loadedSettings
        self.serverModeConfiguration = serverModeSettingsStore.load()
        self.configuredWatchedThreshold = loadedSettings.watchedThreshold
        self.privacyLockState.setPINConfigured(loadedSettings.privacyPINEnabled && privacyLockService.hasPIN())
        // 首帧前就把用户配色写入全局色板，避免启动闪一帧默认配色。
        AppColors.activeTheme = AppThemeResolver.resolve(for: loadedSettings)

        do {
            let directories = try FileAccessService.appDirectories()
            VideoFramePreviewGenerator.configure(diskCacheDirectory: directories.previewFrames)
            let logger = LoggingService(logDirectory: directories.logs)
            let database = try DatabaseManager(url: directories.database, backupDirectory: directories.databaseBackups)
            self.directories = directories
            self.vaultUnlockSessionStore = VaultUnlockSessionStore(directory: directories.applicationSupport)
            self.homeRecommendationStore = HomeRecommendationSnapshotStore(directory: directories.applicationSupport)
            self.logger = logger
            self.database = database
            self.sourceRepository = SourceRepository(database: database)
            self.mediaRepository = MediaRepository(database: database)
            self.musicQueueRepository = MusicQueueRepository(database: database)
            self.videoCollectionStore = VideoCollectionStore(
                smartRepository: VideoSmartCollectionRepository(database: database),
                manualRepository: VideoManualCollectionRepository(database: database)
            )
            self.videoOfflineSubscriptionRepository = VideoOfflineSubscriptionRepository(database: database)
            self.musicPlaylistStore = MusicPlaylistStore(
                repository: MusicPlaylistRepository(database: database),
                smartRepository: MusicSmartPlaylistRepository(database: database)
            )
            self.playbackMarkerRepository = PlaybackMarkerRepository(database: database)
            self.metadataCorrectionStore = MetadataCorrectionStore(repository: MetadataCorrectionRepository(database: database))
            self.mediaDetailRepository = MediaDetailRepository(database: database)
            self.musicProjectionRepository = MusicLibraryProjectionRepository(database: database)
            self.syncConflictStore = SyncConflictStore(repository: SyncConflictRepository(database: database))
            self.remoteConnectorAccountRepository = RemoteConnectorAccountRepository(database: database)
            do {
                self.videoOfflineCacheStore = try VideoOfflineCacheStore(
                    applicationSupportDirectory: directories.applicationSupport,
                    defaultCacheDirectory: directories.cache,
                    customCacheDirectoryPath: loadedSettings.videoCacheDirectoryPath,
                    pruneOnInit: false
                )
                self.cachedVideoEntriesByItemID = self.videoOfflineCacheStore?.allEntries() ?? [:]
                self.videoCacheStorageSummary = VideoCacheStorageSummary(
                    entryCount: self.cachedVideoEntriesByItemID.count,
                    totalBytes: self.cachedVideoEntriesByItemID.values.reduce(Int64(0)) { partial, entry in
                        partial + max(entry.fileSize ?? 0, 0)
                    },
                    byteLimit: Self.videoCacheByteLimit(from: loadedSettings.videoCacheSizeLimitGB)
                )
            } catch {
                self.videoOfflineCacheStore = nil
                logger.log("视频缓存清单初始化失败：\(error.localizedDescription)", level: .warning)
            }
            scheduleBackgroundTaskRestore()
            scheduleLibraryReload(reason: "startup", delayNanoseconds: 120_000_000)
        } catch {
            self.directories = nil
            self.logger = nil
            self.database = nil
            self.sourceRepository = nil
            self.mediaRepository = nil
            self.musicQueueRepository = nil
            self.videoCollectionStore = VideoCollectionStore(smartRepository: nil, manualRepository: nil)
            self.videoOfflineSubscriptionRepository = nil
            self.musicPlaylistStore = MusicPlaylistStore(repository: nil, smartRepository: nil)
            self.playbackMarkerRepository = nil
            self.metadataCorrectionStore = MetadataCorrectionStore(repository: nil)
            self.mediaDetailRepository = nil
            self.musicProjectionRepository = nil
            self.syncConflictStore = SyncConflictStore(repository: nil)
            self.remoteConnectorAccountRepository = nil
            self.videoOfflineCacheStore = nil
            self.startupError = error.localizedDescription
        }
        serverAdministrationStore.configure(database: database)
        // 选择态变化转发到 AppState 自身的 objectWillChange，使既有 @EnvironmentObject 视图照常刷新
        // （等价于此前 isSelectionModeActive/selectedItemIDs 作为 AppState @Published 的行为）。
        selectionForwarding = selection.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 歌单数据变化同样转发到 AppState，使既有 @EnvironmentObject 视图照常刷新
        //（等价于此前 musicPlaylists/musicSmartPlaylists 作为 AppState @Published 的行为）。
        musicPlaylistForwarding = musicPlaylistStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        videoCollectionForwarding = videoCollectionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        videoManualCollectionCreationForwarding = videoManualCollectionCreation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        videoOfflineSubscriptionLimitForwarding = videoOfflineSubscriptionLimit.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        networkStreamPromptForwarding = networkStreamPrompt.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        quickPreviewForwarding = quickPreview.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        appUpdateStateForwarding = appUpdateState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sponsorPromptForwarding = sponsorPrompt.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        startupErrorForwarding = startupErrorStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // URL 链接健康结果变化转发到 AppState，使健康徽标/失效列表照常刷新。
        urlHealthForwarding = urlHealthMonitor.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 同步冲突列表/计数变化转发到 AppState，使设置页徽标/冲突列表照常刷新。
        syncConflictForwarding = syncConflictStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        remoteConnectorForwarding = remoteConnectorStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        embyRestrictionNoticeForwarding = embyRestrictionNoticeStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        // 元数据校正计数/批次变化转发到 AppState，使设置页徽标/撤销列表照常刷新。
        metadataCorrectionForwarding = metadataCorrectionStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        taskCenter.onTasksChanged = { [weak self] _ in
            self?.persistBackgroundTasksIfPossible()
        }
        taskCenterForwarding = taskCenter.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        tmdbMatchStateForwarding = tmdbMatchState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        scanActivityForwarding = scanActivity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        musicQueueForwarding = musicQueueStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        playbackSessionForwarding = playbackSession.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        libraryDomainForwarding = libraryDomain.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        detailNavigationForwarding = detailNavigation.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        serverModeForwarding = serverModeController.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        serverModeController.setHostControlApplyHandler { [weak self] configuration in
            Task { @MainActor [weak self] in
                await self?.applyServerRuntimeConfigurationFromHost(configuration)
            }
        }
        serverAdministrationForwarding = serverAdministrationStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        musicMetadataActivityForwarding = musicMetadataActivity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        privacyLockStateForwarding = privacyLockState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        floatingNoticeForwarding = floatingNoticeStore.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        sakuraEasterEggStateForwarding = sakuraEasterEggState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        onboardingReplayForwarding = onboardingReplay.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        lastfmAuthorizationForwarding = lastfmAuthorizationState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        traktSyncActivityForwarding = traktSyncActivity.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        themeRefreshForwarding = themeRefresh.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        mediaSearchIndexForwarding = mediaSearchIndexState.objectWillChange.sink { [weak self] _ in
            self?.objectWillChange.send()
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
        vaultUnlockRefreshTask?.cancel()
        version122MaintenanceTask?.cancel()
        libraryReloadTask?.cancel()
        backgroundTaskPersistence.cancel()
        detailEnrichmentTasks.values.forEach { $0.cancel() }
        networkPathMonitor?.cancel()
        serverLANReconciliationTask?.cancel()
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

    /// 相册条目（本地「相册」源里的照片与录像）。独立于视频库，仅在相册一级目录展示。
    var albumItems: [MediaItem] {
        cachedAlbumItems
    }

    /// 当前配置的「相册」源根路径集合（mediaType == .photo）。
    var albumSourcePaths: Set<String> {
        Set(sources.filter { $0.mediaType == .photo }.map(\.path))
    }

    /// 是否在侧边栏展示「相册」一级目录：有相册源/条目，或已接入系统照片图库。
    var showsAlbumSection: Bool {
        true
    }

    /// 判断条目是否属于相册（照片，或归属相册源的录像）。
    func isAlbumItem(_ item: MediaItem) -> Bool {
        guard !Self.isRemoteMediaServerItem(item),
              source(for: item)?.sourceKind.isRemoteMediaServer != true else {
            return false
        }
        if item.type == .photo { return true }
        guard let sourcePath = item.sourcePath else { return false }
        return albumSourcePaths.contains { Self.isSourcePath(sourcePath, inside: $0) }
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
        cachedMissingFileItems.filter {
            healthCheckEnabled(for: $0) && !isHealthIssueIgnored(category: Self.healthCategoryMissingFile, id: $0.id)
        }
    }

    var missingMetadataItems: [MediaItem] {
        cachedMissingMetadataItems.filter {
            healthCheckEnabled(for: $0) && !isHealthIssueIgnored(category: Self.healthCategoryMissingMetadata, id: $0.id)
        }
    }

    var detailMetadataGapItems: [MediaItem] {
        topLevelItems.filter {
            detailMetadataGapsByMediaID[$0.id] != nil &&
                healthCheckEnabled(for: $0) &&
                !isHealthIssueIgnored(category: Self.healthCategoryDetailMetadata, id: $0.id) &&
                !(isPrivateItem($0) && !canDisplayPrivateItems)
        }
    }

    func detailMetadataGapDescription(for item: MediaItem) -> String {
        let values = detailMetadataGapsByMediaID[item.id] ?? []
        return values.sorted().joined(separator: "、")
    }

    var offlineSources: [MediaSource] {
        cachedOfflineSources.filter {
            $0.includeInHealthCheck && !isHealthIssueIgnored(category: Self.healthCategoryOfflineSource, id: $0.id)
        }
    }

    var duplicateTitleGroups: [[MediaItem]] {
        cachedDuplicateTitleGroups
            .map { $0.filter(healthCheckEnabled(for:)) }
            .filter { $0.count > 1 && !isHealthIssueIgnored(category: Self.healthCategoryDuplicateGroup, id: duplicateHealthIssueID(for: $0)) }
    }

    static let healthCategoryMissingFile = "missing-file"
    static let healthCategoryMissingMetadata = "missing-metadata"
    static let healthCategoryDetailMetadata = "detail-metadata"
    static let healthCategoryOfflineSource = "offline-source"
    static let healthCategoryDuplicateGroup = "duplicate-group"
    static let healthCategoryUnhealthyURL = "unhealthy-url"

    func duplicateHealthIssueID(for group: [MediaItem]) -> String {
        group.map(\.id).sorted().joined(separator: "|")
    }

    func isHealthIssueIgnored(category: String, id: String) -> Bool {
        settings.ignoredHealthIssueIDs.contains(Self.healthIssueKey(category: category, id: id))
    }

    func ignoreHealthIssue(category: String, id: String, title: String? = nil) {
        settings.ignoredHealthIssueIDs.insert(Self.healthIssueKey(category: category, id: id))
        saveSettings()
        showFloatingNotice(title: "已忽略健康项", message: title ?? "可在设置中恢复显示。", kind: .success)
    }

    func clearIgnoredHealthIssues() {
        let count = settings.ignoredHealthIssueIDs.count
        guard count > 0 else { return }
        settings.ignoredHealthIssueIDs.removeAll()
        saveSettings()
        showFloatingNotice(title: "已恢复健康检查", message: "\(count) 项已重新纳入仪表盘。", kind: .success)
    }

    private static func healthIssueKey(category: String, id: String) -> String {
        "\(category):\(id)"
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

    var homeMusicPlayableTracks: [MediaItem] {
        cachedHomeMusicPlayableTracks
    }

    /// 首页的全部公开音乐条目，包含本地与已连接远程来源；保险库条目在构建派生缓存时已被排除。
    var homeMusicTracks: [MediaItem] {
        cachedHomeMusicTracks
    }

    var homeContinueListeningTracks: [MediaItem] {
        cachedHomeContinueListeningTracks
    }

    var homeMusicSignalTracks: [MediaItem] {
        cachedHomeMusicSignalTracks
    }

    var musicAlbumSummaries: [MusicAlbumSummary] {
        cachedMusicAlbumSummaries
    }

    var musicArtistSummaries: [MusicArtistSummary] {
        cachedMusicArtistSummaries
    }

    var musicProjectionRebuiltAt: Date? {
        cachedMusicProjectionRebuiltAt
    }

    func musicTracks(inAlbum album: MusicAlbumSummary) -> [MediaItem] {
        cachedMusicTracks.filter { track in
            Self.normalizedMusicProjectionKey(MusicLibraryProjectionRepository.displayAlbum(track.album)) == album.titleKey &&
            Self.normalizedMusicProjectionKey(MusicLibraryProjectionRepository.displayArtist(track.artist)) == album.artistKey
        }
    }

    func musicTracks(inArtist artist: MusicArtistSummary) -> [MediaItem] {
        cachedMusicTracks.filter { track in
            Self.normalizedMusicProjectionKey(MusicLibraryProjectionRepository.displayArtist(track.artist)) == artist.nameKey
        }
    }

    private static func normalizedMusicProjectionKey(_ value: String) -> String {
        value
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
            .lowercased()
    }

    func item(withID id: String) -> MediaItem? {
        cachedItemsByID[id] ?? items.first { $0.id == id }
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
        case .video(.homeVideos):
            base = topLevelItems.filter { $0.type == .homeVideo }
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
        case .album(let section):
            switch section {
            case .all:
                base = cachedAlbumItems
            case .photos:
                base = cachedAlbumItems.filter { $0.type == .photo }
            case .videos:
                base = cachedAlbumItems.filter { $0.type != .photo }
            }
        }

        guard !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return base }
        return base.filter { matchesMediaSearch(query: searchText, item: $0) }
    }

    func mediaSearchFields(for item: MediaItem) -> [String?] {
        if mediaSearchFieldsCacheRevision != mediaSearchRevision {
            mediaSearchFieldsCacheRevision = mediaSearchRevision
            mediaSearchFieldsCache.removeAll(keepingCapacity: true)
        }
        if let cached = mediaSearchFieldsCache[item.id] {
            return cached
        }
        var fields: [String?] = [
            item.title,
            item.originalTitle,
            item.artist,
            item.album,
            item.overview,
            item.genre,
            item.year.map(String.init),
            item.externalID,
            item.metadataProvider,
            item.collectionTitle,
            item.videoCodec,
            item.audioCodec,
            item.resolution
        ]
        fields.append(contentsOf: (detailSearchTermsByMediaID[item.id] ?? []).map(Optional.some))
        for episode in cachedChildrenByParentID[item.id] ?? [] {
            fields.append(contentsOf: [
                episode.title,
                episode.originalTitle,
                episode.overview,
                episode.genre,
                episode.episodeLabel,
                episode.seasonNumber.map { "第 \($0) 季" },
                episode.episodeNumber.map { "第 \($0) 集" }
            ])
        }
        mediaSearchFieldsCache[item.id] = fields
        return fields
    }

    func matchesMediaSearch(query: String, item: MediaItem) -> Bool {
        PinyinSearchMatcher.matches(query: query, in: mediaSearchFields(for: item))
    }

    func videoSmartCollection(id: String) -> VideoSmartCollection? {
        videoCollectionStore.smartCollection(id: id)
    }

    @discardableResult
    func saveVideoSmartCollection(_ collection: VideoSmartCollection, notify: Bool = true) -> VideoSmartCollection? {
        do {
            guard let result = try videoCollectionStore.saveSmart(collection) else { return nil }
            let saved = result.saved
            libraryRevision += 1
            if notify {
                let title = result.isNew ? "智能集合已创建" : "智能集合已保存"
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
        do {
            if try videoCollectionStore.deleteSmart(id: collection.id) {
                libraryRevision += 1
            }
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
        videoCollectionStore.manualCollection(id: id)
    }

    @discardableResult
    func saveVideoManualCollection(_ collection: VideoManualCollection, notify: Bool = true) -> VideoManualCollection? {
        do {
            guard let result = try videoCollectionStore.saveManual(collection) else { return nil }
            let saved = result.saved
            libraryRevision += 1
            if notify {
                let title = result.isNew ? "集合已创建" : "集合已保存"
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
        videoManualCollectionCreation.requestCreation(itemIDs: itemIDs)
    }

    func cancelVideoManualCollectionCreation(_ request: VideoManualCollectionCreationRequest) {
        videoManualCollectionCreation.clearIfCurrent(request)
    }

    @discardableResult
    func finishVideoManualCollectionCreation(_ request: VideoManualCollectionCreationRequest, name: String) -> VideoManualCollection? {
        guard videoManualCollectionCreation.isCurrent(request) else { return nil }
        let collection = createVideoManualCollectionAndNotify(
            name: name,
            itemIDs: request.itemIDs,
            successTitle: "已创建集合并加入"
        )
        videoManualCollectionCreation.clear()
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
        do {
            guard let collection = try videoCollectionStore.createManual(
                name: name,
                itemIDs: itemIDs
            ) else { return nil }
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
        do {
            if try videoCollectionStore.deleteManual(id: collection.id) {
                libraryRevision += 1
            }
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
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            if let updated = try videoCollectionStore.addManual(itemIDs: itemIDs, toCollectionID: collectionID) {
                libraryRevision += 1
                showFloatingNotice(title: "已加入集合", message: updated.name, kind: .success)
            }
        } catch {
            showError("加入集合失败", error)
        }
    }

    func removeFromVideoManualCollection(_ items: [MediaItem], collectionID: String) {
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            if let updated = try videoCollectionStore.removeManual(itemIDs: itemIDs, fromCollectionID: collectionID) {
                libraryRevision += 1
                showFloatingNotice(title: "已从集合移除", message: updated.name, kind: .info)
            }
        } catch {
            showError("移出集合失败", error)
        }
    }

    func canReorderVideoManualCollection(_ items: [MediaItem], collectionID: String, operation: VideoManualCollectionReorderOperation) -> Bool {
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        return videoCollectionStore.canReorderManual(
            itemIDs: itemIDs,
            collectionID: collectionID,
            operation: operation
        )
    }

    func reorderVideoManualCollection(_ items: [MediaItem], collectionID: String, operation: VideoManualCollectionReorderOperation) {
        let itemIDs = uniqueVideoCollectionItemIDs(items)
        guard !itemIDs.isEmpty else { return }
        do {
            if let saved = try videoCollectionStore.reorderManual(
                itemIDs: itemIDs,
                collectionID: collectionID,
                operation: operation
            ) {
                libraryRevision += 1
                showFloatingNotice(title: "集合顺序已更新", message: saved.name, kind: .success)
            }
        } catch {
            showError("调整集合顺序失败", error)
        }
    }

    func collections(containing item: MediaItem) -> [VideoManualCollection] {
        videoCollectionStore.manualCollections(containing: item.id)
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

    private func uniqueVideoCollectionItemIDs(_ items: [MediaItem]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for item in items where canUseInVideoManualCollection(item) {
            guard seen.insert(item.id).inserted else { continue }
            result.append(item.id)
        }
        return result
    }

    // MARK: - 音乐智能歌单
    // musicSmartPlaylist / saveMusicSmartPlaylist / deleteMusicSmartPlaylist / musicTracks(inSmart:)
    // 已拆到 AppState+MusicPlaylist.swift（缩小本超大文件）。

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
        cachedMusicTracksBySection[section] ?? []
    }

    /// 自增库版本号。供拆分到独立文件的 AppState extension 调用，保留 libraryRevision 的 private(set) 封装。
    func bumpLibraryRevision() {
        libraryRevision += 1
    }

    // 普通歌单 CRUD + M3U 导入导出（musicTracks(in:) / createMusicPlaylist / musicPlaylistM3UContent /
    // importMusicPlaylist / addMusicTracks / renameMusicPlaylist / deleteMusicPlaylist / removeMusicTracks /
    // moveMusicPlaylistItems / replaceMusicPlaylistItems）已拆到 AppState+MusicPlaylist.swift。
    // upsertMusicPlaylistInMemory 早已随歌单 CRUD 移入 MusicPlaylistStore。

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
        cachedVideoSeriesStatesByID[item.id] ?? (isVideoCached(item) ? .complete : .none)
    }

    func includesCachedVideo(_ item: MediaItem) -> Bool {
        if isVideoCached(item) { return true }
        return children(for: item).contains { isVideoCached($0) }
    }

    func hasCachedVideos(in items: [MediaItem]) -> Bool {
        items.contains { includesCachedVideo($0) }
    }

    private func rebuildHomeOfflineVideoCache() {
        rebuildVideoSeriesCacheStates()
        cachedHomeOfflineVideoItems = cachedHomeVideoItems.filter { includesCachedVideo($0) }
        if cachedHomeOfflineVideoItems.isEmpty {
            cachedAvailableHomeTabs.remove(.offline)
        } else {
            cachedAvailableHomeTabs.insert(.offline)
        }
    }

    private func rebuildVideoSeriesCacheStates() {
        cachedVideoSeriesStatesByID = VideoOfflinePolicy.seriesCacheStates(
            childrenByParentID: cachedChildrenByParentID,
            cachedItemIDs: Set(cachedVideoEntriesByItemID.keys)
        )
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
        videoOfflineSubscriptionLimit.presentRequest(
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
            videoOfflineSubscriptionLimit.clearIfCurrent(request)
            alert = AppAlert(title: "无法开启自动缓存", message: "这个系列已不在当前媒体库中。")
            return
        }
        saveVideoOfflineSubscription(
            for: item,
            mode: .nextUnwatched,
            episodeLimit: episodeLimit,
            qualityID: request.qualityID
        )
        videoOfflineSubscriptionLimit.clearIfCurrent(request)
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
        let path = url?.path
        Task { @MainActor [weak self] in
            do {
                try await store.setCustomCacheDirectoryPathAsync(path)
                guard let self else { return }
                settings.videoCacheDirectoryPath = path
                saveSettings()
                await refreshVideoCacheEntriesAsync()
                showFloatingNotice(
                    title: url == nil ? "已恢复默认缓存位置" : "视频缓存位置已更新",
                    message: videoCacheDirectoryDisplayPath,
                    kind: .success
                )
            } catch {
                self?.showError("缓存位置更新失败", error)
            }
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
        Task { @MainActor [weak self] in
            do {
                let removed = try await store.removeAsync(itemIDs: itemIDs)
                guard let self else { return }
                await refreshVideoCacheEntriesAsync()
                showFloatingNotice(
                    title: removed.count > 1 ? "系列缓存已删除" : "缓存文件已删除",
                    message: hidesDetail ? nil : item.title,
                    kind: .success
                )
            } catch {
                self?.showError("缓存删除失败", error)
            }
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
                let cacheResult = try await store?.runMaintenanceAsync(
                        validItemIDs: validItemIDs,
                        byteLimit: byteLimit,
                        cleanupHint: cleanupHint
                    )
                await MainActor.run {
                    guard let self else { return }
                    self.updateBackgroundTask(id: taskID, progress: 0.62, detail: "正在清理任务历史")
                }
                await self?.refreshVideoCacheEntriesAsync()

                let removedArtworkDirectories = await BlockingIOExecutor.run {
                    Self.removeEmptyArtworkCacheDirectories(in: directories?.cache)
                }
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
        let trimmed = BackgroundTaskListPolicy.trimmingInactiveHistory(
            from: backgroundTasks,
            existingInactiveCount: existingInactiveCount
        )
        if trimmed.removedCount > 0 {
            backgroundTasks = trimmed.tasks
        }
        return trimmed.removedCount
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
        MediaDuplicateKeyPolicy.duplicateKey(for: item)
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

    func userRatingNoticeSuffix(_ rating: Double?) -> String {
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
        case .mlink:
            return .mlink
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
        scheduleLibraryReload(reason: "reload")
    }

    /// 给还没有判定过歌词的曲目补上判定。
    ///
    /// schema 29 把 `has_lyrics` 建了出来，但迁移只填 0——在启动路径上遍历整个曲库
    /// 做文件探测会把一次升级变成一次几分钟的卡死。真实值一部分由扫描写入，剩下的
    /// 老数据由这里在后台慢慢补齐，每批有上限，不和用户抢盘。
    ///
    /// 判定完成前，这些曲目在「有歌词」筛选里是"没有"。这是可解释的过渡状态，
    /// 好过让整个音乐库在升级后卡住不动。
    func backfillMusicLyricsPresence(batchLimit: Int = 400) {
        guard let mediaRepository else { return }
        lyricsBackfillTask?.cancel()
        lyricsBackfillTask = Task { [weak self] in
            let updates = await BlockingIOExecutor.run { () -> [String: Bool] in
                guard let pending = try? mediaRepository.fetchMusicNeedingLyricsProbe(limit: batchLimit),
                      !pending.isEmpty
                else { return [:] }
                var results: [String: Bool] = [:]
                for track in pending {
                    guard let filePath = track.filePath else { continue }
                    // 内嵌歌词在扫描时就判定过了；这里补的是外挂文件这一路。
                    if MusicLyricsPresence.sidecarExists(filePath: filePath) {
                        results[track.id] = true
                    }
                }
                return results
            }
            guard !Task.isCancelled, !updates.isEmpty else { return }
            try? mediaRepository.updateLyricsPresence(updates)
            guard !Task.isCancelled else { return }
            await MainActor.run { self?.reload() }
        }
    }

    private func reloadMediaItemsDuringScan(runID: UUID) {
        guard scanRunID == runID, isScanning else { return }
        scheduleLibraryReload(reason: "scan incremental", delayNanoseconds: 260_000_000)
    }

    private func scheduleLibraryReload(reason: String, delayNanoseconds: UInt64 = 180_000_000) {
        guard let directories else { return }
        libraryReloadGeneration += 1
        let generation = libraryReloadGeneration
        libraryReloadTask?.cancel()
        libraryReloadTask = Task { @MainActor [weak self, directories] in
            if delayNanoseconds > 0 {
                try? await Task.sleep(nanoseconds: delayNanoseconds)
            }
            guard let self, !Task.isCancelled else { return }
            self.isLibraryReloading = true
            let reloadStart = Date()
            do {
                let snapshot = try await Self.loadLibraryReloadSnapshot(directories: directories)
                guard !Task.isCancelled else { return }
                guard self.libraryReloadGeneration == generation else { return }
                self.applyLibraryReloadSnapshot(snapshot, reason: reason, reloadStart: reloadStart)
                self.isLibraryReloading = false
            } catch is CancellationError {
                if self.libraryReloadGeneration == generation {
                    self.isLibraryReloading = false
                }
            } catch {
                if self.libraryReloadGeneration == generation {
                    self.isLibraryReloading = false
                    self.showError("加载媒体库失败", error)
                } else {
                    self.logger?.log("已忽略过期媒体库刷新错误：\(error.localizedDescription)", level: .warning)
                }
            }
        }
    }

    private nonisolated static func loadLibraryReloadSnapshot(directories: AppDirectories) async throws -> LibraryReloadSnapshot {
        // 全量 SQLite 读取（本库约 5.8 秒）属长阻塞 I/O，走专用队列而非协作池。
        try await BlockingIOExecutor.run {
            try Task.checkCancellation()
            ArtworkImageCache.invalidateMissingPaths()
            let database = try DatabaseManager(url: directories.database, backupDirectory: directories.databaseBackups)
            let sourceRepository = SourceRepository(database: database)
            let mediaRepository = MediaRepository(database: database)
            let musicPlaylistRepository = MusicPlaylistRepository(database: database)
            let musicSmartPlaylistRepository = MusicSmartPlaylistRepository(database: database)
            let videoSmartCollectionRepository = VideoSmartCollectionRepository(database: database)
            let videoManualCollectionRepository = VideoManualCollectionRepository(database: database)
            let videoOfflineSubscriptionRepository = VideoOfflineSubscriptionRepository(database: database)
            let metadataCorrectionRepository = MetadataCorrectionRepository(database: database)
            let syncConflictRepository = SyncConflictRepository(database: database)
            let remoteConnectorAccountRepository = RemoteConnectorAccountRepository(database: database)
            let mediaDetailRepository = MediaDetailRepository(database: database)
            let musicProjectionRepository = MusicLibraryProjectionRepository(database: database)

            let sources = try sourceRepository.fetchAll()
            let items = try mediaRepository.fetchAll()
            let detailCandidateIDs = items.compactMap { item -> String? in
                guard item.parentID == nil,
                      item.type != .music,
                      item.type != .photo,
                      item.type != .homeVideo,
                      item.type != .privateCollection else { return nil }
                return item.id
            }
            try Task.checkCancellation()

            return LibraryReloadSnapshot(
                sources: sources,
                items: items,
                musicPlaylists: try musicPlaylistRepository.fetchAll(),
                musicSmartPlaylists: try musicSmartPlaylistRepository.fetchAll(),
                videoSmartCollections: try videoSmartCollectionRepository.fetchAll(),
                videoManualCollections: try videoManualCollectionRepository.fetchAll(),
                videoOfflineSubscriptions: try videoOfflineSubscriptionRepository.fetchAll(),
                metadataCorrectionCountsByMediaID: try metadataCorrectionRepository.activeCountsByMediaID(),
                metadataCorrectionRecordCount: try metadataCorrectionRepository.activeRecordCount(),
                metadataCorrectionBatches: try metadataCorrectionRepository.fetchActiveBatches(limit: 120),
                pendingSyncConflictCount: try syncConflictRepository.pendingCount(),
                pendingSyncConflicts: try syncConflictRepository.fetchPending(limit: 120),
                remoteConnectorAccounts: try remoteConnectorAccountRepository.fetchAll(),
                musicProjectionSnapshot: try musicProjectionRepository.fetchSnapshot(),
                detailMetadataGapsByMediaID: try mediaDetailRepository.detailCompleteness(mediaIDs: detailCandidateIDs),
                detailSearchTermsByMediaID: try mediaDetailRepository.searchTermsByMediaID(),
                detailBackdropPathsByMediaID: try mediaDetailRepository.firstBackdropPathsByMediaID(),
                mediaExternalIDIndex: try mediaDetailRepository.externalMediaIDIndex(),
                mediaIDsByPersonID: try mediaDetailRepository.mediaIDsByPersonID()
            )
        }
    }

    private func applyLibraryReloadSnapshot(
        _ snapshot: LibraryReloadSnapshot,
        reason: String,
        reloadStart: Date
    ) {
        let applyStart = Date()
        libraryDomain.replaceLibrary(sources: snapshot.sources, items: snapshot.items)
        musicPlaylistStore.replaceLoaded(
            playlists: snapshot.musicPlaylists,
            smartPlaylists: snapshot.musicSmartPlaylists
        )
        videoCollectionStore.replaceLoaded(
            smartCollections: snapshot.videoSmartCollections,
            manualCollections: snapshot.videoManualCollections
        )
        videoOfflineSubscriptions = snapshot.videoOfflineSubscriptions
        metadataCorrectionStore.replaceLoaded(
            countsByMediaID: snapshot.metadataCorrectionCountsByMediaID,
            recordCount: snapshot.metadataCorrectionRecordCount,
            batches: snapshot.metadataCorrectionBatches
        )
        syncConflictStore.replaceLoaded(
            pendingCount: snapshot.pendingSyncConflictCount,
            pendingConflicts: snapshot.pendingSyncConflicts
        )
        remoteConnectorAccounts = snapshot.remoteConnectorAccounts
        applyMusicProjectionSnapshot(snapshot.musicProjectionSnapshot)
        detailMetadataGapsByMediaID = snapshot.detailMetadataGapsByMediaID
        detailSearchTermsByMediaID = snapshot.detailSearchTermsByMediaID
        detailBackdropPathsByMediaID = snapshot.detailBackdropPathsByMediaID
        mediaExternalIDIndex = snapshot.mediaExternalIDIndex
        mediaIDsByPersonID = snapshot.mediaIDsByPersonID
        mediaSearchRevision += 1
        logPerformance("reload.apply snapshot[\(reason)]: \(Self.milliseconds(since: applyStart))ms items=\(items.count) sources=\(sources.count) playlists=\(musicPlaylists.count)")

        let cacheStart = Date()
        rebuildDerivedItemCaches()
        if didRestoreMusicQueue {
            reconcileMusicQueueWithLibrary()
        } else {
            restoreMusicQueueState()
        }
        logPerformance("reload.rebuildDerivedItemCaches[\(reason)]: \(Self.milliseconds(since: cacheStart))ms")
        if let selectedItem, let refreshed = items.first(where: { $0.id == selectedItem.id }) {
            self.selectedItem = refreshed
        }
        let healthStart = Date()
        scheduleFileHealthRefresh()
        configureLocalFileEventMonitoring()
        configureAutomaticScan()
        configureAutomaticTMDBMatch()
        scheduleVersion122MaintenanceIfNeeded()
        scheduleRemoteMusicMetadataMigrationIfNeeded()
        logPerformance("reload.schedule background followups[\(reason)]: \(Self.milliseconds(since: healthStart))ms")
        libraryRevision += 1
        posterRevision += 1
        pruneExpiredVideoOfflineSubscriptions(reason: "library reload", notify: false)
        scheduleVideoOfflineSubscriptionExpirationCheck(reason: "library reload")
        scheduleVideoOfflineSubscriptionMaintenance(reason: "library reload")
        resumeRestoredArtworkWarmupTasksIfNeeded()
        scheduleMusicProjectionMaintenanceIfNeeded(reason: reason)
        logPerformance("reload.total[\(reason)]: \(Self.milliseconds(since: reloadStart))ms revision=\(libraryRevision) posterRevision=\(posterRevision)")
    }

    private func applyMusicProjectionSnapshot(_ snapshot: MusicLibraryProjectionSnapshot) {
        // 投影内容没变就不 bump 修订号：每次库刷新都无条件递增会把专辑/艺术家页
        // 的列表快照全部打失效，迫使切页时重新分组排序。
        let unchanged = cachedMusicAlbumSummaries == snapshot.albums &&
            cachedMusicArtistSummaries == snapshot.artists
        cachedMusicAlbumSummaries = snapshot.albums
        cachedMusicArtistSummaries = snapshot.artists
        cachedMusicProjectionRebuiltAt = snapshot.rebuiltAt
        if !unchanged {
            musicProjectionRevision += 1
        }
    }

    private func scheduleMusicProjectionMaintenanceIfNeeded(reason: String) {
        guard !cachedMusicTracks.isEmpty || !cachedMusicAlbumSummaries.isEmpty || !cachedMusicArtistSummaries.isEmpty else { return }
        scheduleMusicProjectionMaintenance(reason: reason, force: false)
    }

    func scheduleMusicProjectionMaintenance(reason: String, force: Bool, preferIncremental: Bool = false) {
        guard let musicProjectionRepository else { return }
        guard musicProjectionTask == nil else { return }
        musicProjectionTask = Task { @MainActor [weak self, musicProjectionRepository] in
            defer { self?.musicProjectionTask = nil }
            do {
                try await Task.sleep(nanoseconds: 420_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            do {
                let plan: MusicProjectionMaintenancePlan
                if force {
                    plan = .bootstrap
                } else if preferIncremental {
                    let detectedPlan = try await musicProjectionRepository.maintenancePlanAsync()
                    plan = detectedPlan == .bootstrap ? .bootstrap : .incremental
                } else {
                    plan = try await musicProjectionRepository.maintenancePlanAsync()
                }
                guard plan != .none, !Task.isCancelled else { return }

                switch plan {
                case .none:
                    return
                case .bootstrap:
                    let taskID = self.beginBackgroundTask(
                        kind: .musicIndex,
                        title: BackgroundTaskKind.musicIndex.title,
                        detail: "首次整理专辑与艺术家",
                        progress: nil,
                        isCancellable: false
                    )
                    do {
                        let result = try await musicProjectionRepository.rebuildAll()
                        let snapshot = try await musicProjectionRepository.fetchSnapshotAsync()
                        guard !Task.isCancelled else { return }
                        self.applyMusicProjectionSnapshot(snapshot)
                        self.updateBackgroundTask(
                            id: taskID,
                            progress: 1,
                            detail: "已整理 \(result.albumCount) 张专辑、\(result.artistCount) 位艺术家"
                        )
                        self.finishBackgroundTask(id: taskID, errors: [])
                        self.logger?.log(
                            "音乐索引已更新[\(reason)] albums=\(result.albumCount) artists=\(result.artistCount) tracks=\(result.musicItemCount)",
                            level: .info
                        )
                    } catch {
                        self.finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
                        throw error
                    }
                case .incremental:
                    let result = try await musicProjectionRepository.synchronizeIncremental()
                    let snapshot = try await musicProjectionRepository.fetchSnapshotAsync()
                    guard !Task.isCancelled else { return }
                    self.applyMusicProjectionSnapshot(snapshot)
                    self.logger?.log(
                        "音乐索引增量同步完成[\(reason)] albums=\(result.affectedAlbumCount) artists=\(result.affectedArtistCount) tracks=\(result.musicItemCount)",
                        level: .info
                    )
                }
            } catch {
                self.logger?.log("音乐索引维护失败[\(reason)]：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    func rebuildDerivedItemCaches() {
        // Pass 1：建立父子索引，并从保险库根节点向下传播私密标记。
        // 保险库可能是“集合 -> 剧集 -> 单集”的多层结构，只看直接 parent 会漏掉更深的后代。
        let hierarchy = MediaHierarchyPolicy.snapshot(for: items)
        let childrenByParentID = hierarchy.childrenByParentID
        let privateItemIDs = hierarchy.privateItemIDs

        // Pass 2：单次遍历分拣所有 item，同时收集统计数据。
        // 避免原来 12+ 次独立 filter/reduce 各自遍历全量数组。
        var topLevelRaw: [MediaItem] = []
        var privateTopLevelRaw: [MediaItem] = []
        var musicTracksRaw: [MediaItem] = []
        var albumRaw: [MediaItem] = []
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
        // 相册源根路径：照片与其录像归属相册，绝不串入视频库/首页/健康统计。
        let albumSourcePaths = sources.filter { $0.mediaType == .photo }.map(\.path)
        let remoteSourcePaths = sources.filter { $0.sourceKind.isRemoteMediaServer }.map(\.path)

        for item in items {
            let hasRemoteScheme = Self.isRemoteMediaServerItem(item)
            let isEmby = item.sourcePath.map { sourcePath in
                remoteSourcePaths.contains { Self.isSourcePath(sourcePath, inside: $0) }
            } ?? false
            let isPrivate = privateItemIDs.contains(item.id)
            // 已删除来源留下的远程孤儿不能回流到本地视频、相册或首页分类。
            if hasRemoteScheme && !isEmby {
                continue
            }
            let isRemoteMediaServerItem = hasRemoteScheme || isEmby
            let isAlbum = !isRemoteMediaServerItem && (
                item.type == .photo ||
                (item.sourcePath.map { sourcePath in
                    albumSourcePaths.contains { Self.isSourcePath(sourcePath, inside: $0) }
                } ?? false)
            )
            if isAlbum {
                if !isPrivate { albumRaw.append(item) }
                continue
            }

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

            // 其他视频（含 URL 来源）不参与元数据拉取，不计入元数据缺口。
            if !isPrivate, item.type != .homeVideo, Self.isMissingCoreMetadata(item),
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

        cachedChildrenByParentID = MediaHierarchyPolicy.sortedChildrenByParentID(childrenByParentID)
        rebuildVideoSeriesCacheStates()

        cachedTopLevelItems = topLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedPrivateTopLevelItems = privateTopLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        cachedEmbyTopLevelItems = embyTopLevelRaw.sorted { $0.updatedAt > $1.updatedAt }
        cachedMusicTracks = MusicTrackProjectionPolicy.sortedByAlbumTrackAndTitle(musicTracksRaw)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        rebuildMusicSectionCaches()
        // 相册按拍摄日期（扫描时写入 createdAt）倒序，最新在前，照片 App 习惯。
        cachedAlbumItems = albumRaw.sorted { $0.createdAt > $1.createdAt }
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

        cachedNextUpItems = HomeVideoProjectionPolicy.nextUpItems(
            from: cachedHomeVideoItems,
            childrenByParentID: cachedChildrenByParentID,
            watchedThreshold: watchedThreshold,
            limit: 12
        )

        cachedDuplicateTitleGroups = MediaDuplicateKeyPolicy.duplicateTitleGroups(
            in: cachedTopLevelItems,
            excludingSourcePaths: healthExcludedSourcePaths
        )

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

        cachedAvailableHomeTabs = HomeVideoProjectionPolicy.availableHomeTabs(
            HomeTabAvailabilityInput(
                homeVideoItems: cachedHomeVideoItems,
                nextUpItems: cachedNextUpItems,
                continueWatchingItems: cachedContinueWatchingItems,
                offlineVideoItems: cachedHomeOfflineVideoItems,
                musicTracks: cachedMusicTracks,
                privateTopLevelItems: cachedPrivateTopLevelItems,
                watchedThreshold: settings.watchedThreshold
            )
        )

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
            case .homeVideos:
                return availableVideoTypes.contains(.homeVideo)
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

    private func rebuildMusicSectionCaches(bumpContentRevision: Bool = true) {
        cachedMusicTracksBySection = [
            .songs: cachedMusicTracks,
            .albums: cachedMusicTracks,
            .artists: cachedMusicTracks,
            .playlists: [],
            .recent: MusicTrackProjectionPolicy.recentlyPlayedTracks(cachedMusicTracks),
            .favorites: cachedMusicTracks.filter(\.favorite),
            .unmatched: cachedMusicTracks.filter {
                ($0.artist?.isEmpty ?? true) || ($0.album?.isEmpty ?? true) || $0.metadataProvider == nil
            }
        ]
        // 首页不应被本地音乐库边界限制：合并已连接远程来源的公开音乐，但保持
        // cachedMusicTracks 仅服务于本地音乐页，避免远程来源在侧栏中重复出现。
        var seenHomeMusicIDs = Set<String>()
        let remoteMusic = cachedEmbyTopLevelItems.filter { $0.type == .music }
        cachedHomeMusicTracks = (cachedMusicTracks + remoteMusic)
            .filter { seenHomeMusicIDs.insert($0.id).inserted }
            .sorted { lhs, rhs in
                let left = lhs.lastPlayedAt ?? lhs.updatedAt
                let right = rhs.lastPlayedAt ?? rhs.updatedAt
                if left != right { return left > right }
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            }
        cachedHomeMusicPlayableTracks = cachedHomeMusicTracks.filter { $0.filePath != nil || $0.posterPath != nil }
        cachedHomeContinueListeningTracks = MusicTrackProjectionPolicy.continueListeningTracks(cachedHomeMusicTracks, limit: 6)
        cachedHomeMusicSignalTracks = MusicTrackProjectionPolicy.signalTracks(cachedHomeMusicTracks)
        cachedMusicSmartTracksByPlaylistID.removeAll(keepingCapacity: true)
        // 播放次数递增（每次点击播放都会调用）故意跳过这里：内容修订号驱动音乐列表快照缓存 key，
        // 高频、非展示语义的字段变化不应让整页列表快照失效重建。见 incrementMusicPlayCountInMemory。
        if bumpContentRevision {
            refreshMusicContentRevisionIfNeeded()
        }
    }

    /// 对全部音乐曲目取内容指纹，只有指纹变化才递增 musicContentRevision。
    /// 视频入库、观看进度、健康检查等只碰 libraryRevision 的操作不会再打失效音乐页快照。
    private func refreshMusicContentRevisionIfNeeded() {
        var hasher = Hasher()
        hasher.combine(cachedMusicTracks.count)
        for track in cachedMusicTracks {
            hasher.combine(track)
        }
        let fingerprint = hasher.finalize()
        guard fingerprint != musicContentFingerprint else { return }
        musicContentFingerprint = fingerprint
        musicContentRevision += 1
    }

    private static func isMissingCoreMetadata(_ item: MediaItem) -> Bool {
        MediaMetadataCompletenessPolicy.isMissingCoreMetadata(item)
    }

    private static func classifiedEmbyTopLevelItem(_ item: MediaItem) -> MediaItem {
        guard isEmbyItem(item), item.parentID == nil, item.type != .music else { return item }
        let hint: RemoteLibraryClassificationHint?
        if let sourcePath = item.sourcePath,
           let info = EmbyService.libraryInfo(from: sourcePath) {
            hint = RemoteLibraryClassificationHint(libraryName: info.name, collectionType: info.collectionType)
        } else {
            hint = nil
        }
        let type = RemoteLibraryClassificationPolicy.inferredMediaType(for: item, hint: hint)
        var copy = item
        copy.type = type
        return copy
    }

    private nonisolated static func playbackRecencySort(_ lhs: MediaItem, _ rhs: MediaItem) -> Bool {
        MediaPlaybackRecencyPolicy.isMoreRecent(lhs, than: rhs)
    }

    /// 条目的来源路径是否落在"不参与健康检查"的来源里。
    nonisolated static func sourcePathExcluded(_ sourcePath: String?, in excludedPaths: [String]) -> Bool {
        SourcePathPolicy.isExcluded(sourcePath, in: excludedPaths)
    }

    /// 来源归属判断必须有路径边界：`/Media/A` 不能匹配 `/Media/Anime`，
    /// `emby://server/source` 也不能匹配 `emby://server/source2`。所有来源过滤统一走这里。
    nonisolated static func isSourcePath(_ candidate: String?, inside sourceRoot: String) -> Bool {
        SourcePathPolicy.isSourcePath(candidate, inside: sourceRoot)
    }

    private func scheduleFileHealthRefresh() {
        fileHealthTask?.cancel()
        refreshURLSourceHealth()
        let refreshID = UUID()
        fileHealthRefreshID = refreshID
        // 记录清空前的结果：刷新结束若与上次完全一致就不 bump libraryRevision，
        // 避免每次库重载 20 秒后无意义地打失效全 App 的派生缓存/视图。
        let previousMissingIDs = Set(cachedMissingFileItems.map(\.id))
        let previousSafeMissingIDs = cachedSafeMissingFileItemIDs
        let previousOfflineSourceIDs = cachedOfflineSourceIDs
        cachedMissingFileItems = []
        cachedSafeMissingFileItemIDs = []
        cachedOfflineSources = []
        cachedOfflineSourceIDs = []

        let itemSnapshots = items
        let sourceSnapshots = sources
        let privateItemIDs = cachedPrivateItemIDs

        fileHealthTask = Task { [itemSnapshots, sourceSnapshots, privateItemIDs, refreshID] in
            let healthStart = Date()
            // 全库逐条 stat（本库 5.4 万次、NAS 上单次可达秒级）是长阻塞 I/O，
            // 绝不能占协作线程池——否则音乐列表等轻量后台构建会排队数秒。
            let health = await BlockingIOExecutor.run {
                FileHealthEvaluator.evaluate(
                    items: itemSnapshots,
                    sources: sourceSnapshots,
                    privateItemIDs: privateItemIDs
                )
            }

            guard !Task.isCancelled else { return }
            await MainActor.run {
                guard self.fileHealthRefreshID == refreshID else { return }
                self.cachedMissingFileItems = itemSnapshots.filter { health.missingItemIDs.contains($0.id) }
                self.cachedSafeMissingFileItemIDs = health.safeMissingItemIDs
                self.cachedOfflineSourceIDs = health.offlineSourceIDs
                self.cachedOfflineSources = sourceSnapshots.filter { health.offlineSourceIDs.contains($0.id) }
                let changed = health.missingItemIDs != previousMissingIDs ||
                    health.safeMissingItemIDs != previousSafeMissingIDs ||
                    health.offlineSourceIDs != previousOfflineSourceIDs
                if changed {
                    self.libraryRevision += 1
                }
                self.logPerformance("fileHealth.refresh: \(Self.milliseconds(since: healthStart))ms missing=\(health.missingItemIDs.count) offlineSources=\(health.offlineSourceIDs.count) changed=\(changed) revision=\(self.libraryRevision)")
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
        guard let mediaRepository else { return }
        // 批量删除移出主线程（deleteItemsAsync 在 DB 队列上单事务执行），避免上千行删除时卡住 UI；
        // 删除完成后回到主线程刷新与提示（AppState 为 @MainActor，await 后自动回到主线程）。
        Task {
            do {
                try await mediaRepository.deleteItemsAsync(ids: ids)
                reload()
                alert = AppAlert(title: "索引已清理", message: "已从 MediaLIB 内部索引移除 \(ids.count) 个失效条目，用户媒体文件没有被修改。")
            } catch {
                showError("失效索引清理失败", error)
            }
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
        let uniqueIDs = Array(Set(ids))
        let removedCount = removeItems.count
        let keptTitle = keptItem.title
        guard let mediaRepository else { return }
        // 同上：批量删除移出主线程，完成后回主线程刷新与提示。
        Task {
            do {
                try await mediaRepository.deleteItemsAsync(ids: uniqueIDs)
                reload()
                alert = AppAlert(
                    title: "已合并重复项",
                    message: "已保留「\(keptTitle)」，从索引移除其余 \(removedCount) 项（用户媒体文件未改动；若重新扫描仍存在的文件可能再次出现）。"
                )
            } catch {
                showError("合并重复项失败", error)
            }
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
            showInitialIndexingTipIfNeeded()
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
            showInitialIndexingTipIfNeeded()
        } catch {
            showError("添加媒体源失败", error)
        }
    }

    // MARK: - URL 视频媒体源

    /// 所有用户添加的 URL 视频聚合在这个虚拟来源路径下。
    static let urlMediaSourcePath = URLSourcePolicy.mediaSourcePath
    /// 串流地址允许的协议（mpv 原生支持）。
    static let urlMediaSchemes = URLSourcePolicy.mediaSchemes

    /// 当前的 URL 媒体源容器（最多一个）。
    var urlMediaSource: MediaSource? {
        sources.first { $0.sourceKind == .url }
    }

    /// URL 媒体源下的全部视频条目，按添加时间倒序。
    var urlSourceItems: [MediaItem] {
        items
            .filter { $0.sourcePath == Self.urlMediaSourcePath }
            .sorted { $0.createdAt > $1.createdAt }
    }

    @discardableResult
    private func ensureURLMediaSource() -> MediaSource? {
        if let existing = urlMediaSource { return existing }
        guard let sourceRepository else { return nil }
        let source = MediaSource(
            name: "URL媒体源",
            path: Self.urlMediaSourcePath,
            mediaType: .homeVideo,
            recursive: false,
            autoScan: false,
            includeInMetadataFetch: false,
            includeInHealthCheck: true
        )
        do {
            try sourceRepository.save(source)
            return source
        } catch {
            showError("创建 URL 媒体源失败", error)
            return nil
        }
    }

    /// 校验并规范化用户输入的视频地址。
    func normalizedURLSourceString(_ raw: String) -> String? {
        URLSourcePolicy.normalizedURLString(raw)
    }

    private func defaultTitle(forURL urlString: String) -> String {
        URLSourcePolicy.defaultTitle(forURL: urlString)
    }

    @discardableResult
    func addURLVideo(urlString: String, title: String = "") -> Bool {
        guard let mediaRepository else { return false }
        guard let normalized = normalizedURLSourceString(urlString) else {
            alert = AppAlert(title: "链接无效", message: "请输入以 http(s)、rtsp、rtmp 等协议开头的有效视频地址。")
            return false
        }
        let id = StableID.make(prefix: "url", value: normalized)
        if items.contains(where: { $0.id == id }) {
            alert = AppAlert(title: "链接已存在", message: "该地址已经在 URL 媒体源中。")
            return false
        }
        guard ensureURLMediaSource() != nil else { return false }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? defaultTitle(forURL: normalized) : trimmedTitle
        let item = MediaItem(
            id: id,
            type: .homeVideo,
            title: finalTitle,
            sourcePath: Self.urlMediaSourcePath,
            filePath: normalized
        )
        do {
            try mediaRepository.upsert(item)
            reload()
            // 自动从画面截取封面（失败静默，用户仍可手动截取或选择自定义封面）。
            if canCaptureVideoCover(for: item) {
                captureVideoCover(for: item, silent: true)
            }
            return true
        } catch {
            showError("添加 URL 视频失败", error)
            return false
        }
    }

    /// 统计一段文本里有多少个不重复的可添加链接（支持每行一个的批量粘贴）。
    func addableURLCount(in raw: String) -> Int {
        URLSourcePolicy.addableURLCount(in: raw)
    }

    /// 批量添加链接：每行一个，自动去重、跳过无效和已存在项。返回新增数量。
    @discardableResult
    func addURLVideos(fromMultiline raw: String) -> Int {
        let lines = raw.split(whereSeparator: { $0.isNewline })
            .map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        guard lines.count > 1 else {
            return addURLVideo(urlString: lines.first ?? raw) ? 1 : 0
        }
        guard let mediaRepository else { return 0 }
        var newItems: [MediaItem] = []
        var seenIDs = Set(items.map(\.id))
        for line in lines {
            guard let normalized = URLSourcePolicy.normalizedURLString(line) else { continue }
            let id = StableID.make(prefix: "url", value: normalized)
            guard seenIDs.insert(id).inserted else { continue }
            newItems.append(MediaItem(
                id: id,
                type: .homeVideo,
                title: defaultTitle(forURL: normalized),
                sourcePath: Self.urlMediaSourcePath,
                filePath: normalized
            ))
        }
        guard !newItems.isEmpty else {
            alert = AppAlert(title: "未添加任何链接", message: "这些地址要么无效，要么已存在。")
            return 0
        }
        guard ensureURLMediaSource() != nil else { return 0 }
        do {
            for item in newItems {
                try mediaRepository.upsert(item)
            }
            reload()
            for item in newItems where canCaptureVideoCover(for: item) {
                captureVideoCover(for: item, silent: true)
            }
            showFloatingNotice(title: "已添加 \(newItems.count) 个链接", kind: .success)
            return newItems.count
        } catch {
            showError("批量添加链接失败", error)
            return 0
        }
    }

    @discardableResult
    func updateURLVideo(_ item: MediaItem, urlString: String, title: String) -> Bool {
        guard let mediaRepository else { return false }
        guard let normalized = normalizedURLSourceString(urlString) else {
            alert = AppAlert(title: "链接无效", message: "请输入有效的视频地址。")
            return false
        }
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let finalTitle = trimmedTitle.isEmpty ? defaultTitle(forURL: normalized) : trimmedTitle
        let newID = StableID.make(prefix: "url", value: normalized)
        if newID != item.id, items.contains(where: { $0.id == newID }) {
            alert = AppAlert(title: "链接已存在", message: "已有相同地址的条目。")
            return false
        }
        var updated = item
        updated.id = newID
        updated.title = finalTitle
        updated.filePath = normalized
        updated.updatedAt = Date()
        do {
            if newID != item.id {
                try mediaRepository.deleteItems(ids: [item.id])
            }
            try mediaRepository.upsert(updated)
            reload()
            return true
        } catch {
            showError("更新 URL 视频失败", error)
            return false
        }
    }

    func removeURLVideos(ids: [String]) {
        guard let mediaRepository, !ids.isEmpty else { return }
        let removalSet = Set(ids)
        do {
            try mediaRepository.deleteItems(ids: ids)
            // URL 媒体源清空后，移除空的虚拟容器。
            let remaining = items.contains { $0.sourcePath == Self.urlMediaSourcePath && !removalSet.contains($0.id) }
            if !remaining, let source = urlMediaSource {
                try sourceRepository?.delete(id: source.id)
            }
            reload()
        } catch {
            showError("删除 URL 视频失败", error)
        }
    }

    /// 该条目是否属于 URL 媒体源。
    func isURLSourceItem(_ item: MediaItem) -> Bool {
        item.sourcePath == Self.urlMediaSourcePath
    }

    // MARK: - URL 链接健康（可达性 / 可解析）

    func urlItemHealthState(for item: MediaItem) -> URLItemHealthState {
        urlHealthMonitor.state(for: item.id)
    }

    /// URL 媒体源下被判定为失效（无法访问或无法解析）的链接。
    var unhealthyURLItems: [MediaItem] {
        guard urlMediaSource?.includeInHealthCheck ?? false else { return [] }
        return urlSourceItems.filter {
            urlHealthMonitor.healthByID[$0.id]?.isUnhealthy == true &&
                !isHealthIssueIgnored(category: Self.healthCategoryUnhealthyURL, id: $0.id)
        }
    }

    /// URL 媒体源整体是否健康（无失效链接）。
    var urlMediaSourceIsHealthy: Bool {
        unhealthyURLItems.isEmpty
    }

    /// 探测 URL 媒体源所有 http(s) 链接的可达性与可解析性。
    func refreshURLSourceHealth() {
        guard urlMediaSource?.includeInHealthCheck ?? false else {
            urlHealthMonitor.reset()
            return
        }
        let probeItems = URLSourcePolicy.probeItems(from: urlSourceItems)
        let liveIDs = Set(urlSourceItems.map(\.id))
        urlHealthMonitor.refresh(probeItems: probeItems, liveIDs: liveIDs) { [weak self] in
            self?.libraryRevision += 1
        }
    }

    // probeURLHealth / classifyURLResponse 已随健康探测一并移入 URLSourceHealthMonitor。

    // MARK: - 视频封面截取与自定义

    /// 是否可以从视频画面截取封面（有可解析的视频地址或存在的本地文件）。
    func canCaptureVideoCover(for item: MediaItem) -> Bool {
        guard item.type != .music,
              let filePath = item.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            return false
        }
        if item.isRemoteResource { return true }
        return FileManager.default.fileExists(atPath: filePath)
    }

    private func resolvedVideoURL(for item: MediaItem) -> URL? {
        guard let filePath = item.filePath?.trimmingCharacters(in: .whitespacesAndNewlines),
              !filePath.isEmpty else {
            return nil
        }
        if item.isRemoteResource {
            return URL(string: filePath)
        }
        return URL(fileURLWithPath: filePath)
    }

    /// 从视频画面截取一帧作为封面。`silent` 用于自动截取（仅成功提示）。
    func captureVideoCover(for item: MediaItem, silent: Bool = false) {
        guard let directories else {
            if !silent { alert = AppAlert(title: "无法截取封面", message: "应用数据目录不可用。") }
            return
        }
        guard let videoURL = resolvedVideoURL(for: item) else {
            if !silent { alert = AppAlert(title: "无法截取封面", message: "这个视频没有可解析的地址。") }
            return
        }
        if !silent {
            showFloatingNotice(title: "正在截取封面", message: item.title, kind: .info)
        }
        let thumbDir = directories.thumbnails
        let logger = self.logger
        let mediaID = "\(item.id)-cover-\(Int(Date().timeIntervalSince1970))"
        Task { [weak self] in
            let generator = ThumbnailGenerator(outputDirectory: thumbDir, logger: logger)
            let url = await generator.generateThumbnail(for: videoURL, mediaID: mediaID, ratio: 0.2, avoidBlackFrames: true)
            await MainActor.run {
                guard let self else { return }
                guard let url else {
                    if !silent {
                        self.showFloatingNotice(title: "封面截取失败", message: "无法从该视频读取画面。", kind: .warning)
                    }
                    return
                }
                guard let current = self.items.first(where: { $0.id == item.id }) else { return }
                ArtworkImageCache.invalidateMissing(path: url.path)
                self.applyMetadata(MediaMetadataUpdate(posterPath: url.path), to: current)
                if !silent {
                    self.showFloatingNotice(title: "已更新封面", message: item.title, kind: .success)
                }
            }
        }
    }

    /// 弹出文件选择器并把所选图片设为自定义封面或背景。
    func chooseCustomArtwork(for item: MediaItem, kind: VideoArtworkKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.jpeg, UTType.png, UTType.heic, UTType.tiff,
            UTType(filenameExtension: "webp"), UTType(filenameExtension: "bmp")
        ].compactMap { $0 }
        panel.message = kind == .poster ? "选择自定义封面图片" : "选择自定义背景图片"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        importCustomArtwork(for: item, from: sourceURL, kind: kind)
    }

    /// 把指定图片复制进缩略图目录并设为封面/背景。
    func importCustomArtwork(for item: MediaItem, from sourceURL: URL, kind: VideoArtworkKind) {
        guard let thumbnailsDir = directories?.thumbnails else {
            alert = AppAlert(title: "无法导入封面", message: "应用数据目录不可用。")
            return
        }

        Task { [weak self] in
            do {
                let destURL = try await CustomArtworkFileImporter.importArtwork(
                    itemID: item.id,
                    sourceURL: sourceURL,
                    thumbnailsDirectory: thumbnailsDir,
                    kind: kind
                )
                await MainActor.run {
                    guard let self else { return }
                    ArtworkImageCache.invalidateMissing(path: destURL.path)
                    switch kind {
                    case .poster:
                        self.applyMetadata(MediaMetadataUpdate(posterPath: destURL.path), to: item)
                    case .backdrop:
                        self.applyMetadata(MediaMetadataUpdate(backdropPath: destURL.path), to: item)
                    }
                }
            } catch {
                await MainActor.run {
                    self?.showError("封面导入失败", error)
                }
            }
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

    /// 连接 MediaLIB Server。Mlink 先做公开描述协商，再用 token 登录并同步受权分类；
    /// 不会把密码、token 或服务端媒体 URL 写入媒体源路径和索引。
    func connectMlinkServer(
        server: String,
        username: String,
        password: String,
        includeInMetadataFetch: Bool = true,
        includeInHealthCheck: Bool = true,
        remoteTraceSyncMode: RemoteTraceSyncMode = .bidirectional
    ) async {
        let provider: RemoteConnectorProvider = .mlink
        guard !isConnectingRemoteMediaServer(provider) else {
            alert = AppAlert(title: "MediaLIB Server 正在连接", message: "当前连接完成后会自动显示结果。")
            return
        }
        setConnectingRemoteMediaServer(provider, connecting: true)
        defer { setConnectingRemoteMediaServer(provider, connecting: false) }

        let serverText = server.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedServer = serverText.contains("://") ? serverText : "https://\(serverText)"
        guard let serverURL = URL(string: normalizedServer), !serverText.isEmpty else {
            alert = AppAlert(title: "MediaLIB Server 地址无效", message: "请输入服务器地址；局域网非回环服务必须使用 HTTPS。")
            return
        }
        let sourceID = UUID().uuidString
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "MediaLIB Server 同步",
            detail: "正在验证服务端并同步分类",
            progress: nil,
            isCancellable: false,
            retrySourceID: sourceID
        )
        var sourceSaved = false
        do {
            let client = MlinkAPIClient()
            let descriptor = try await client.discover(serverURL: serverURL)
            let tokens = try await client.login(
                serverURL: serverURL,
                username: username,
                password: password,
                deviceName: ProcessInfo.processInfo.hostName
            )
            let categories = try await client.categories(serverURL: serverURL, accessToken: tokens.accessToken)
            let source = MediaSource(
                id: sourceID,
                name: "MediaLIB Server · \(descriptor.serverName)",
                path: "mlink://\(sourceID)",
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
            try sourceRepository?.save(source)
            sourceSaved = true
            try await remoteCredentialStore.saveAsync(
                RemoteSourceCredential(
                    kind: provider.credentialKind,
                    serverURL: serverURL.absoluteString,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    password: nil,
                    accessToken: tokens.accessToken,
                    refreshToken: tokens.refreshToken,
                    userID: nil
                ),
                sourceID: sourceID
            )
            try remoteConnectorAccountRepository?.save(
                RemoteConnectorAccount(
                    provider: provider,
                    accountLabel: "MediaLIB Server · \(descriptor.serverName)",
                    serverURL: serverURL.absoluteString,
                    username: username.trimmingCharacters(in: .whitespacesAndNewlines),
                    sourceID: sourceID,
                    connectionMode: .library,
                    syncEnabled: true,
                    capabilitiesJSON: provider.mediaServerCapabilitiesJSON,
                    privacyNote: "Mlink access / refresh token 仅保存在本机 0600 受限凭据文件中；桌面端不保存服务端媒体路径。",
                    lastSyncedAt: Date()
                )
            )
            try await importMlinkItems(source: source, serverURL: serverURL, accessToken: tokens.accessToken, categories: categories.categories)
            reload()
            finishBackgroundTask(id: taskID, errors: [])
            alert = AppAlert(title: "MediaLIB Server 已连接", message: "\(descriptor.serverName) 的 \(categories.categories.count) 个分类已同步到 Mlink 目录。")
        } catch {
            if sourceSaved {
                try? remoteConnectorAccountRepository?.delete(sourceID: sourceID)
                await remoteCredentialStore.deleteAsync(sourceID: sourceID)
                try? sourceRepository?.delete(id: sourceID)
            }
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            showError("MediaLIB Server 连接失败", error)
        }
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
            try await remoteCredentialStore.saveAsync(
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
                do {
                    try remoteConnectorAccountRepository?.delete(sourceID: sourceID)
                } catch {
                    logger?.log("连接失败回滚：删除远程连接器账户失败(\(sourceID))：\(error.localizedDescription)", level: .warning)
                }
                await remoteCredentialStore.deleteAsync(sourceID: sourceID)
                do {
                    try sourceRepository?.delete(id: sourceID)
                } catch {
                    logger?.log("连接失败回滚：删除来源失败(\(sourceID))：\(error.localizedDescription)", level: .warning)
                }
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
            try await remoteCredentialStore.saveAsync(
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
                do {
                    try remoteConnectorAccountRepository?.delete(sourceID: sourceID)
                } catch {
                    logger?.log("连接失败回滚：删除远程连接器账户失败(\(sourceID))：\(error.localizedDescription)", level: .warning)
                }
                await remoteCredentialStore.deleteAsync(sourceID: sourceID)
                do {
                    try sourceRepository?.delete(id: sourceID)
                } catch {
                    logger?.log("连接失败回滚：删除来源失败(\(sourceID))：\(error.localizedDescription)", level: .warning)
                }
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
        case .mlink:
            return isConnectingMlink
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
        case .mlink:
            isConnectingMlink = connecting
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
            showInitialIndexingTipIfNeeded()
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
        if provider == .mlink {
            await refreshMlinkSource(source)
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

    private func refreshMlinkSource(_ source: MediaSource) async {
        let taskID = beginBackgroundTask(
            kind: .embySync,
            title: "MediaLIB Server 同步 · \(source.name)",
            detail: "正在同步服务端分类",
            progress: nil,
            isCancellable: false,
            retrySourceID: source.id
        )
        do {
            try await withValidMlinkAccessToken(for: source) { serverURL, accessToken in
                let client = MlinkAPIClient()
                let categories = try await client.categories(serverURL: serverURL, accessToken: accessToken)
                try await self.importMlinkItems(
                    source: source, serverURL: serverURL, accessToken: accessToken, categories: categories.categories
                )
            }
            finishBackgroundTask(id: taskID, errors: [])
            reload()
        } catch {
            finishBackgroundTask(id: taskID, errors: [error.localizedDescription])
            showError("MediaLIB Server 同步失败", error)
        }
    }

    func loadEmbyLibraries(for source: MediaSource) async throws -> [EmbyLibrarySummary] {
        guard source.sourceKind.isRemoteMediaServer else { return [] }
        if source.sourceKind == .mlink {
            return try await withValidMlinkAccessToken(for: source) { serverURL, accessToken in
                let categories = try await MlinkAPIClient().categories(serverURL: serverURL, accessToken: accessToken)
                return categories.categories.map { category in
                    EmbyLibrarySummary(
                        id: category.id,
                        sourceID: source.id,
                        viewID: category.id,
                        name: "\(category.title)（\(category.itemCount)）",
                        collectionType: category.id,
                        sourceName: source.name
                    )
                }
            }
        }
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
        try mediaDetailRepository?.prepareBackfill(
            mediaIDs: embyItems.filter { $0.parentID == nil && $0.type != .music }.map(\.id)
        )
        await scheduleEmbyArtworkWarmup(source: source, items: embyItems)
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
        try mediaDetailRepository?.prepareBackfill(
            mediaIDs: plexItems.filter { $0.parentID == nil && $0.type != .music }.map(\.id)
        )
        await scheduleEmbyArtworkWarmup(source: source, items: plexItems)
    }

    private func importMlinkItems(
        source: MediaSource,
        serverURL: URL,
        accessToken: String,
        categories: [ServerLibraryCategory]
    ) async throws {
        guard let mediaRepository else { return }
        var mlinkItems = try await MlinkLibrarySynchronizer().fetchItems(
            serverURL: serverURL,
            accessToken: accessToken,
            sourceID: source.id,
            sourcePath: source.path,
            categories: source.selectedEmbyLibraryIDs.isEmpty
                ? categories
                : categories.filter { source.selectedEmbyLibraryIDs.contains($0.id) }
        )
        if source.remoteTraceSyncMode == .disabled {
            mlinkItems = mlinkItems.map(preservingLocalTraceForDisabledEmbySync)
        }
        try mediaRepository.replaceRemoteItems(sourcePathPrefix: source.path, with: mlinkItems)
        // 这里**刻意**没有 Emby/Plex 那两行 `prepareBackfill` 与封面预热：Mlink 的
        // 目录是一份只读卡片投影，条目既不带上游图片地址也不带文件路径（见
        // `MlinkLibrarySynchronizer.localItem`），详情与封面都留在那台服务器自己的
        // 网页上。补一次 backfill 只会排队去取一批永远取不到的详情。
        // 与之配套的是 `detailExtrasAPI(for: .mlink) == nil`。
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

    private func scheduleEmbyArtworkWarmup(
        source: MediaSource,
        items: [MediaItem],
        resumingTaskID: UUID? = nil
    ) async {
        guard !isServerLightweightModeActive else { return }
        let urls = artworkWarmupURLs(for: items)
        guard !urls.isEmpty else { return }

        embyArtworkWarmupTasks[source.id]?.cancel()
        let currentURLStrings = Set(urls.map(\.absoluteString))
        let savedProgress = await artworkWarmupProgressRecord(for: source.id)
        var completedURLStrings = Set(savedProgress?.completedURLs ?? [])
        completedURLStrings.formIntersection(currentURLStrings)

        let totalCount = urls.count
        let remainingURLs = urls.filter { !completedURLStrings.contains($0.absoluteString) }
        let initialProgress = Double(completedURLStrings.count) / Double(max(totalCount, 1))
        let taskID = ensureArtworkWarmupBackgroundTask(
            source: source,
            taskID: resumingTaskID,
            totalCount: totalCount,
            completedCount: completedURLStrings.count,
            progress: initialProgress
        )

        guard !remainingURLs.isEmpty else {
            await clearArtworkWarmupProgress(sourceID: source.id)
            updateBackgroundTask(
                id: taskID,
                progress: 1,
                detail: "已缓存 \(totalCount)/\(totalCount) 张封面"
            )
            finishBackgroundTask(id: taskID, errors: [])
            return
        }

        await persistArtworkWarmupProgress(
            sourceID: source.id,
            completedURLs: completedURLStrings,
            totalCount: totalCount
        )

        // 每落盘一次要重写整份进度文件（读 → 解码 → 插入 → 排序 → 编码 → 原子写），
        // 所以绝不能每张封面落一次：三千张就是 O(N²) 的字节量，约 1.3GB 磁盘写外加
        // 三千次对不断变长数组的排序，而且全部 `await` 在取图循环里。改成按批次落盘。
        // 中断时丢掉的最多是最后一批的"已完成"标记，代价只是下次重跑那几张——它们
        // 已经在磁盘缓存里，重跑就是一次命中。
        let progressPersistBatchSize = 32
        let task = Task { [weak self] in
            guard let self else { return }
            var completed = completedURLStrings
            var failed = 0
            var unpersistedCompletions = 0

            // 串行预热是这条链路上最贵的一处：`ArtworkRemoteImageStore` 有 4 个取图
            // 许可，而这个循环一次只喂一张，有效并发是 1。三千张海报 × 一次 RTT
            // 就是几分钟的纯等待。同一仓库里 1.2.2 那条重建路径早就是分块并发了。
            await withTaskGroup(of: (url: String, succeeded: Bool).self) { group in
                var iterator = remainingURLs.makeIterator()
                let parallelism = min(4, remainingURLs.count)

                func enqueueNext() {
                    guard let url = iterator.next() else { return }
                    group.addTask(priority: .utility) {
                        guard !Task.isCancelled else { return (url.absoluteString, false) }
                        let succeeded = await ArtworkImageCache.prewarmRemoteImage(
                            url: url,
                            targetSize: ArtworkImageCache.posterGridTargetSize
                        )
                        return (url.absoluteString, succeeded)
                    }
                }

                for _ in 0..<parallelism { enqueueNext() }

                while let result = await group.next() {
                    if Task.isCancelled {
                        group.cancelAll()
                        break
                    }
                    if result.succeeded {
                        completed.insert(result.url)
                        unpersistedCompletions += 1
                        if unpersistedCompletions >= progressPersistBatchSize {
                            unpersistedCompletions = 0
                            await self.persistArtworkWarmupProgress(
                                sourceID: source.id,
                                completedURLs: completed,
                                totalCount: totalCount
                            )
                        }
                    } else {
                        failed += 1
                    }
                    let processed = completed.count + failed
                    if processed == totalCount || processed % 6 == 0 {
                        self.updateBackgroundTask(
                            id: taskID,
                            progress: Double(processed) / Double(max(totalCount, 1)),
                            detail: failed > 0
                                ? "已缓存 \(completed.count)/\(totalCount) 张封面，\(failed) 张稍后重试"
                                : "已缓存 \(completed.count)/\(totalCount) 张封面"
                        )
                    }
                    enqueueNext()
                }
            }
            // 被取消时也要把这一批记下来，否则下次从上一次落盘点重来。
            guard !Task.isCancelled else {
                if unpersistedCompletions > 0 {
                    await self.persistArtworkWarmupProgress(
                        sourceID: source.id,
                        completedURLs: completed,
                        totalCount: totalCount
                    )
                }
                return
            }
            self.embyArtworkWarmupTasks[source.id] = nil
            if failed == 0 {
                await self.clearArtworkWarmupProgress(sourceID: source.id)
                self.finishBackgroundTask(id: taskID, errors: [])
            } else {
                await self.persistArtworkWarmupProgress(
                    sourceID: source.id,
                    completedURLs: completed,
                    totalCount: totalCount
                )
                self.updateBackgroundTask(
                    id: taskID,
                    progress: 1,
                    detail: "已缓存 \(completed.count)/\(totalCount) 张封面，\(failed) 张将在下次刷新时继续补"
                )
                self.finishBackgroundTask(id: taskID, errors: [])
            }
        }
        embyArtworkWarmupTasks[source.id] = task
    }

    private func artworkWarmupURLs(for items: [MediaItem]) -> [URL] {
        let urlStrings = Set(items.compactMap { item -> String? in
            guard let posterPath = item.posterPath,
                  let url = URL(string: posterPath),
                  ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
            return url.absoluteString
        })
        return urlStrings.sorted().compactMap(URL.init(string:))
    }

    private func ensureArtworkWarmupBackgroundTask(
        source: MediaSource,
        taskID: UUID?,
        totalCount: Int,
        completedCount: Int,
        progress: Double
    ) -> UUID {
        if let taskID, let index = backgroundTasks.firstIndex(where: { $0.id == taskID }) {
            backgroundTasks[index].state = .running
            backgroundTasks[index].title = "封面预热 · \(source.name)"
            backgroundTasks[index].detail = completedCount > 0
                ? "继续缓存 \(completedCount)/\(totalCount) 张封面"
                : "准备缓存 \(totalCount) 张封面"
            backgroundTasks[index].progress = progress
            backgroundTasks[index].finishedAt = nil
            backgroundTasks[index].isCancellable = false
            backgroundTasks[index].retrySourceID = source.id
            return taskID
        }

        return beginBackgroundTask(
            kind: .artworkWarmup,
            title: "封面预热 · \(source.name)",
            detail: completedCount > 0
                ? "继续缓存 \(completedCount)/\(totalCount) 张封面"
                : "准备缓存 \(totalCount) 张封面",
            progress: progress,
            isCancellable: false,
            retrySourceID: source.id
        )
    }

    private func withValidEmbySession<T>(
        for source: MediaSource,
        operation: (EmbySession) async throws -> T
    ) async throws -> T {
        let provider = Self.remoteConnectorProvider(for: source) ?? .emby
        guard var credential = try await remoteCredentialStore.loadAsync(sourceID: source.id),
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
            try await remoteCredentialStore.saveAsync(credential, sourceID: source.id)
            logger?.log("\(provider.displayName) token 已自动恢复：\(source.name)")
            return try await operation(refreshed)
        }
    }

    private func withValidPlexSession<T>(
        for source: MediaSource,
        operation: (PlexSession) async throws -> T
    ) async throws -> T {
        guard let credential = try await remoteCredentialStore.loadAsync(sourceID: source.id),
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

    private func withValidMlinkAccessToken<T>(
        for source: MediaSource,
        operation: (URL, String) async throws -> T
    ) async throws -> T {
        guard var credential = try await remoteCredentialStore.loadAsync(sourceID: source.id),
              credential.kind == RemoteConnectorProvider.mlink.credentialKind,
              let serverURL = URL(string: credential.serverURL),
              let accessToken = credential.accessToken,
              let refreshToken = credential.refreshToken else {
            throw NSError(
                domain: "MediaLib.Mlink",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "\(source.name) 的 Mlink 登录信息不存在，请重新连接。"]
            )
        }
        do {
            return try await operation(serverURL, accessToken)
        } catch let error as MlinkAPIClient.Error {
            guard error == .requestFailed(401) else { throw error }
            let tokens = try await MlinkAPIClient().refresh(serverURL: serverURL, refreshToken: refreshToken)
            credential.accessToken = tokens.accessToken
            credential.refreshToken = tokens.refreshToken
            try await remoteCredentialStore.saveAsync(credential, sourceID: source.id)
            logger?.log("Mlink token 已轮换：\(source.name)")
            return try await operation(serverURL, tokens.accessToken)
        }
    }

    /// Mlink 的收藏、想看和评分以服务端当前用户为唯一真源。先乐观更新本地镜像，
    /// 再由 Bearer 请求写回；失败时完整回滚，绝不改走桌面端全局偏好或 Trakt/Emby 写回。
    private func updateMlinkPreference(
        _ item: MediaItem,
        source: MediaSource,
        update: MlinkAPIClient.MediaPreferenceUpdate
    ) {
        guard let externalID = item.externalID, MlinkAPIClient.isSafeWebItemIdentifier(externalID) else {
            showError("Mlink 偏好更新失败", MlinkAPIClient.Error.untrustedResponse)
            return
        }
        let original = currentSnapshot(for: item)
        applyMlinkPreferenceOptimistically(update, itemID: item.id)
        showMediaStateNotice(
            title: mlinkPreferenceNoticeTitle(update),
            item: item,
            suffix: mlinkPreferenceNoticeSuffix(update),
            kind: .success
        )

        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let preference = try await self.withValidMlinkAccessToken(for: source) { serverURL, accessToken in
                    try await MlinkAPIClient().updatePreference(
                        serverURL: serverURL, accessToken: accessToken, itemID: externalID, update: update
                    )
                }
                guard let mediaRepository = self.mediaRepository else { return }
                try mediaRepository.setFavorite(id: item.id, favorite: preference.isFavorite)
                try mediaRepository.setWatchlist(id: item.id, watchlist: preference.isWatchlist)
                try mediaRepository.updateRating(id: item.id, rating: preference.rating)
                await MainActor.run {
                    self.applyMlinkPreference(preference, itemID: item.id)
                }
            } catch {
                await MainActor.run {
                    self.applyMlinkPreference(
                        ServerMediaUserPreference(
                            isFavorite: original.favorite,
                            isWatchlist: original.watchlist,
                            rating: original.userRating
                        ),
                        itemID: item.id
                    )
                    let message = self.isPrivateItem(item) ? "状态已回滚，请解锁后重试。" : "\(item.cardTitle)：\(error.localizedDescription)"
                    self.deliverTaskNotice(
                        title: "Mlink 偏好同步失败",
                        message: message,
                        kind: .error,
                        systemTitle: "Mlink 偏好同步失败",
                        systemBody: message
                    )
                }
            }
        }
    }

    /// Mlink 项目由网页负责实际播放和进度上报；桌面目录的手动标记只转换为
    /// `completed` 或 `reset`，不会构造媒体 URL、启动桌面解码或伪造续播时间。
    private func updateMlinkWatched(_ item: MediaItem, source: MediaSource, watched: Bool) {
        guard let externalID = item.externalID, MlinkAPIClient.isSafeWebItemIdentifier(externalID) else {
            showError("Mlink 播放状态同步失败", MlinkAPIClient.Error.untrustedResponse)
            return
        }
        let original = currentSnapshot(for: item)
        applyMlinkPlaybackState(
            ServerMediaUserState(
                itemID: externalID,
                positionSeconds: 0,
                progress: watched ? 1 : 0,
                isWatched: watched,
                playCount: original.playCount ?? 0,
                lastPlayedAt: watched ? Date() : nil,
                updatedAt: Date()
            ),
            itemID: item.id
        )
        showMediaStateNotice(
            title: watched ? "已标记为已观看" : "已标记为未观看",
            item: item,
            kind: .success
        )
        let event: MlinkAPIClient.PlaybackStateEvent = watched ? .completed : .reset
        Task(priority: .utility) { [weak self] in
            guard let self else { return }
            do {
                let state = try await self.withValidMlinkAccessToken(for: source) { serverURL, accessToken in
                    try await MlinkAPIClient().updatePlaybackState(
                        serverURL: serverURL, accessToken: accessToken, itemID: externalID,
                        event: event, positionSeconds: 0, durationSeconds: nil
                    )
                }
                guard let mediaRepository = self.mediaRepository else { return }
                if state.isWatched {
                    try mediaRepository.markWatched(id: item.id, watched: true)
                } else {
                    try mediaRepository.clearPlaybackHistory(id: item.id)
                }
                await MainActor.run { self.applyMlinkPlaybackState(state, itemID: item.id) }
            } catch {
                await MainActor.run {
                    self.applyMlinkPlaybackState(
                        ServerMediaUserState(
                            itemID: externalID,
                            positionSeconds: original.playPosition,
                            progress: original.playProgress,
                            isWatched: original.watched,
                            playCount: original.playCount ?? 0,
                            lastPlayedAt: original.lastPlayedAt,
                            updatedAt: original.updatedAt
                        ),
                        itemID: item.id
                    )
                    self.deliverTaskNotice(
                        title: "Mlink 播放状态同步失败",
                        message: "\(item.cardTitle)：\(error.localizedDescription)",
                        kind: .error,
                        systemTitle: "Mlink 播放状态同步失败",
                        systemBody: "\(item.cardTitle)：\(error.localizedDescription)"
                    )
                }
            }
        }
    }

    private func applyMlinkPlaybackState(_ state: ServerMediaUserState, itemID: String) {
        func updated(_ value: MediaItem) -> MediaItem {
            guard value.id == itemID else { return value }
            var copy = value
            copy.playPosition = state.positionSeconds
            copy.playProgress = state.progress
            copy.watched = state.isWatched
            copy.playCount = state.playCount
            copy.lastPlayedAt = state.lastPlayedAt
            copy.updatedAt = state.updatedAt
            return copy
        }
        items = items.map(updated)
        musicQueue = musicQueue.map(updated)
        if let activePlayerItem { self.activePlayerItem = updated(activePlayerItem) }
        if let selectedItem { self.selectedItem = updated(selectedItem) }
        if let quickPreviewItem { self.quickPreviewItem = updated(quickPreviewItem) }
        rebuildDerivedItemCaches()
        libraryRevision += 1
    }

    private func applyMlinkPreferenceOptimistically(
        _ update: MlinkAPIClient.MediaPreferenceUpdate,
        itemID: String
    ) {
        switch update {
        case .favorite(let value): updateFavoriteInMemory(id: itemID, favorite: value)
        case .watchlist(let value): updateWatchlistInMemory(id: itemID, watchlist: value)
        case .rating(let value): updateRatingInMemory(id: itemID, rating: value)
        }
    }

    private func applyMlinkPreference(_ preference: ServerMediaUserPreference, itemID: String) {
        updateFavoriteInMemory(id: itemID, favorite: preference.isFavorite)
        updateWatchlistInMemory(id: itemID, watchlist: preference.isWatchlist)
        updateRatingInMemory(id: itemID, rating: preference.rating)
    }

    private func mlinkPreferenceNoticeTitle(_ update: MlinkAPIClient.MediaPreferenceUpdate) -> String {
        switch update {
        case .favorite(let value): return value ? "已加入喜欢" : "已取消喜欢"
        case .watchlist(let value): return value ? "已加入想看" : "已从想看移除"
        case .rating(let value): return value == nil ? "已清除评级" : "评级已更新"
        }
    }

    private func mlinkPreferenceNoticeSuffix(_ update: MlinkAPIClient.MediaPreferenceUpdate) -> String? {
        if case .rating(let value) = update { return userRatingNoticeSuffix(value) }
        return nil
    }

    private func embySource(for item: MediaItem) -> MediaSource? {
        guard Self.isEmbyItem(item) else { return nil }
        return sources.first { source in
            source.sourceKind.isRemoteMediaServer &&
            Self.isSourcePath(item.sourcePath, inside: source.path)
        }
    }

    private func mlinkSource(for item: MediaItem) -> MediaSource? {
        guard let source = embySource(for: item), source.sourceKind == .mlink else { return nil }
        return source
    }

    /// 该条目是否能展示详情页「详情」栏：已匹配 TMDB 的本地条目，或来自远程媒体服务器。
    func supportsDetailExtras(_ item: MediaItem) -> Bool {
        guard item.type != .music else { return false }
        if item.externalID?.hasPrefix("tmdb:") == true { return true }
        return embySource(for: item)?.sourceKind.isRemoteMediaServer == true
    }

    func cachedDetailSnapshot(for item: MediaItem) -> MediaDetailSnapshot? {
        try? mediaDetailRepository?.fetch(mediaID: item.id)
    }

    func cachedBackdropPath(for item: MediaItem) -> String? {
        detailBackdropPathsByMediaID[item.id]
    }

    /// 从详情快照的艺术图里挑首选横版剧照（与 MediaDetailRepository.firstBackdropPathsByMediaID 同规则）。
    static func preferredBackdropPath(in snapshot: MediaDetailSnapshot) -> String? {
        snapshot.artwork
            .filter { ($0.kind == "backdrop" || $0.aspectRatio >= 1.45) && $0.aspectRatio >= 1.3 }
            .sorted { lhs, rhs in
                if (lhs.kind == "backdrop") != (rhs.kind == "backdrop") {
                    return lhs.kind == "backdrop"
                }
                if lhs.localPath != rhs.localPath {
                    return lhs.localPath != nil
                }
                if abs(lhs.aspectRatio - rhs.aspectRatio) > 0.08 {
                    return lhs.aspectRatio > rhs.aspectRatio
                }
                return lhs.order < rhs.order
            }
            .first
            .flatMap { $0.localPath ?? ($0.fullURL.isEmpty ? nil : $0.fullURL) }
    }

    /// 把详情快照里的横版剧照回填进 banner 缓存（启动时整表加载，之后靠这里增量更新）。
    private func registerBackdropPath(from snapshot: MediaDetailSnapshot, mediaID: String) {
        guard let path = Self.preferredBackdropPath(in: snapshot),
              detailBackdropPathsByMediaID[mediaID] != path else { return }
        detailBackdropPathsByMediaID[mediaID] = path
        backdropRevision += 1
    }

    /// 首页 banner 的横版剧照兜底补抓：对没有任何横版图的推荐条目，后台通过
    /// TMDB/Emby 详情接口拉一张 backdrop 并回填缓存；期间 banner 先用竖版海报裁切显示，
    /// 拉到后随 backdropRevision 刷新自动换成横版图。每个条目每次启动只尝试一次。
    func warmHeroBackdrops(for items: [MediaItem]) {
        guard !isServerLightweightModeActive else { return }
        let candidates = items.filter { item in
            item.type != .music &&
            cachedBackdropPath(for: item) == nil &&
            (item.backdropPath ?? "").isEmpty &&
            supportsDetailExtras(item) &&
            !heroBackdropWarmedIDs.contains(item.id)
        }
        guard !candidates.isEmpty else { return }
        for item in candidates {
            heroBackdropWarmedIDs.insert(item.id)
        }
        let previousTask = heroBackdropWarmupTask
        heroBackdropWarmupTask = Task { @MainActor [weak self] in
            await previousTask?.value
            for item in candidates {
                guard let self, !Task.isCancelled else { return }
                guard let snapshot = await self.loadDetailSnapshot(for: item) else { continue }
                self.registerBackdropPath(from: snapshot, mediaID: item.id)
            }
        }
    }

    /// 轻量服务模式仅回收桌面视觉预热；扫描、索引和服务端媒体分发不能在这里取消。
    func cancelNonessentialVisualWarmupsForServerMode() {
        heroBackdropWarmupTask?.cancel()
        heroBackdropWarmupTask = nil
        embyArtworkWarmupTasks.values.forEach { $0.cancel() }
        embyArtworkWarmupTasks.removeAll()
    }

    func loadDetailSnapshot(for item: MediaItem, forceRefresh: Bool = false) async -> MediaDetailSnapshot? {
        let cached = cachedDetailSnapshot(for: item)
        let maxAge: TimeInterval = 30 * 24 * 60 * 60
        if !forceRefresh, let cached,
           Date().timeIntervalSince(cached.metadata.fetchedAt) < maxAge {
            return snapshotWithLocalMatches(cached)
        }
        guard let enrichment = await detailEnrichment(for: item, forceRefresh: forceRefresh) else {
            return cached.map(snapshotWithLocalMatches)
        }
        var snapshot = enrichment.snapshot(
            mediaID: item.id,
            provider: item.metadataProvider ?? "TMDB",
            language: settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        )
        if let source = embySource(for: item), let externalID = item.externalID {
            snapshot.externalIDs.append(
                MediaExternalID(provider: source.sourceKind.rawValue, value: externalID)
            )
        }
        snapshot = snapshotWithLocalMatches(snapshot)
        registerBackdropPath(from: snapshot, mediaID: item.id)
        do {
            try mediaDetailRepository?.save(snapshot)
            detailMetadataGapsByMediaID[item.id] = (
                try? mediaDetailRepository?.detailCompleteness(mediaIDs: [item.id])[item.id]
            ) ?? nil
            detailSearchTermsByMediaID = try mediaDetailRepository?.searchTermsByMediaID() ?? detailSearchTermsByMediaID
            mediaExternalIDIndex = try mediaDetailRepository?.externalMediaIDIndex() ?? mediaExternalIDIndex
            mediaIDsByPersonID = try mediaDetailRepository?.mediaIDsByPersonID() ?? mediaIDsByPersonID
            mediaSearchRevision += 1
        } catch {
            logger?.log("详情资料保存失败（\(item.title)）：\(error.localizedDescription)", level: .warning)
        }
        return snapshot
    }

    func personDetail(personID: String) async -> MediaPerson? {
        let cached = try? mediaDetailRepository?.fetchPerson(id: personID)
        if let cached,
           !cached.filmography.isEmpty,
           Date().timeIntervalSince(cached.updatedAt) < 30 * 24 * 60 * 60 {
            return cached
        }
        guard personID.hasPrefix("tmdb-person-"),
              let numericID = Int(personID.dropFirst("tmdb-person-".count)),
              let apiKey = settings.tmdbAPIKey,
              !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return cached
        }
        do {
            let person = try await TMDBEnrichmentService().fetchPerson(
                personID: numericID,
                apiKey: apiKey,
                language: settings.tmdbLanguage
            )
            try mediaDetailRepository?.savePerson(person)
            return person
        } catch {
            logger?.log("人物资料加载失败：\(error.localizedDescription)", level: .warning)
            return cached
        }
    }

    func cachedPersonDetail(personID: String) -> MediaPerson? {
        try? mediaDetailRepository?.fetchPerson(id: personID)
    }

    func libraryCredits(personID: String) -> [MediaPersonLibraryCredit] {
        let values = (try? mediaDetailRepository?.libraryCredits(personID: personID)) ?? []
        return values.filter { credit in
            !(isPrivateItem(credit.media) && !canDisplayPrivateItems)
        }
    }

    func libraryItems(
        person: MediaPerson,
        directCredits: [MediaPersonLibraryCredit]
    ) -> [MediaItem] {
        var resultByID: [String: MediaItem] = [:]
        for credit in directCredits {
            resultByID[credit.media.id] = credit.media
        }
        for work in person.knownFor + person.filmography {
            if let item = libraryItem(
                matchingExternalID: work.id,
                title: work.title,
                year: work.year
            ) {
                resultByID[item.id] = item
            }
        }
        return resultByID.values.sorted {
            if ($0.year ?? 0) != ($1.year ?? 0) {
                return ($0.year ?? 0) > ($1.year ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    func libraryItem(
        matchingExternalID externalID: String?,
        title: String,
        year: Int?
    ) -> MediaItem? {
        let candidates = visibleLibraryVideoItems
        if let externalID, !externalID.isEmpty {
            let normalizedID = externalID.lowercased()
            if let mediaID = mediaExternalIDIndex[normalizedID],
               let item = item(withID: mediaID),
               candidates.contains(where: { $0.id == mediaID }) {
                return item
            }
            if let item = candidates.first(where: {
                $0.id == externalID || $0.externalID?.caseInsensitiveCompare(externalID) == .orderedSame
            }) {
                return item
            }
        }

        let normalizedTitle = Self.normalizedMediaLookupTitle(title)
        guard !normalizedTitle.isEmpty else { return nil }
        var titleMatches = candidates.filter {
            Self.normalizedMediaLookupTitle($0.title) == normalizedTitle ||
                Self.normalizedMediaLookupTitle($0.originalTitle ?? "") == normalizedTitle
        }
        if let year {
            let closeYearMatches = titleMatches.filter {
                guard let itemYear = $0.year else { return false }
                return abs(itemYear - year) <= 1
            }
            if !closeYearMatches.isEmpty {
                titleMatches = closeYearMatches
            }
        }
        return titleMatches.count == 1 ? titleMatches[0] : nil
    }

    func libraryRecommendations(
        for item: MediaItem,
        snapshot: MediaDetailSnapshot,
        limit: Int = 24
    ) -> [MediaRelatedTitle] {
        let currentGenres = Self.mediaGenreKeys(item.genre)
        let currentPersonIDs = Set(snapshot.credits.map(\.personID))
        var sharedCreditCounts: [String: Int] = [:]
        for personID in currentPersonIDs {
            for mediaID in mediaIDsByPersonID[personID] ?? [] where mediaID != item.id {
                sharedCreditCounts[mediaID, default: 0] += 1
            }
        }

        return visibleLibraryVideoItems
            .filter { $0.id != item.id }
            .compactMap { candidate -> (MediaItem, Double)? in
                var score = 0.0
                let genreOverlap = currentGenres.intersection(Self.mediaGenreKeys(candidate.genre)).count
                score += Double(genreOverlap) * 2.0
                score += Double(sharedCreditCounts[candidate.id] ?? 0) * 3.0
                if candidate.type == item.type { score += 0.8 }
                if let year = candidate.year, let currentYear = item.year {
                    score += max(0, 1.0 - Double(abs(year - currentYear)) / 10.0)
                }
                if candidate.favorite { score += 0.5 }
                if candidate.watchlist { score += 0.6 }
                if candidate.watched || candidate.playProgress >= settings.watchedThreshold { score -= 1.2 }
                guard score >= 1.2 else { return nil }
                return (candidate, score)
            }
            .sorted {
                if $0.1 != $1.1 { return $0.1 > $1.1 }
                return ($0.0.rating ?? 0) > ($1.0.rating ?? 0)
            }
            .prefix(max(limit, 1))
            .enumerated()
            .map { index, value in
                let candidate = value.0
                return MediaRelatedTitle(
                    id: "library:\(candidate.id)",
                    mediaID: item.id,
                    relation: "library",
                    externalID: candidate.externalID ?? "local:\(candidate.id)",
                    title: candidate.title,
                    year: candidate.year,
                    posterURL: candidate.posterPath,
                    overview: candidate.overview,
                    rating: candidate.rating,
                    popularity: value.1,
                    localMediaID: candidate.id,
                    order: index
                )
            }
    }

    /// 统一加载详情页扩展数据：先由服务器给出角色与艺术图，再由 TMDB 补充人物身份和推荐。
    /// 哪一套接口能给这个来源取详情扩展（演员、剧照、制作信息）。
    ///
    /// 分派按来源种类穷举，不写成"是不是 Plex"。仓库里每一处
    /// `if plex { plexService } else { embyService }` 都有同一个缺口：**Mlink 也会
    /// 落进 Emby 分支**。Mlink 是本产品自己的服务端，说的是 Mlink 契约，那个请求
    /// 只会失败，然后在日志里留下一条「Mlink 详情扩展加载失败」——读者看到的是
    /// 详情栏永远空着。没有可用通道时就返回 nil，而不是拿另一个厂商的接口碰运气。
    enum RemoteDetailExtrasAPI: Equatable {
        /// Emby 与 Jellyfin 共用同一套 `/Items/<id>` 接口。
        case embyCompatible
        case plex
    }

    nonisolated static func detailExtrasAPI(for kind: MediaSourceKind) -> RemoteDetailExtrasAPI? {
        switch kind {
        case .emby, .jellyfin: return .embyCompatible
        case .plex: return .plex
        // Mlink 的目录是一份只读卡片投影：不带文件路径，也不带上游图片地址
        // （见 `MlinkLibrarySynchronizer.localItem`），详情资料留在那台服务器
        // 自己的网页上。
        case .mlink: return nil
        case .local, .smb, .ftp, .url: return nil
        }
    }

    private func detailEnrichment(for item: MediaItem, forceRefresh: Bool) async -> TMDBEnrichment? {
        let language = settings.tmdbLanguage.isEmpty ? "zh-CN" : settings.tmdbLanguage
        let apiKey = settings.tmdbAPIKey
        let taskKey = "\(item.id)|\(language)"
        if !forceRefresh, let task = detailEnrichmentTasks[taskKey] {
            return await task.value
        }

        let task = Task<TMDBEnrichment?, Never> { [weak self] in
            guard let self else { return nil }
            if item.externalID?.hasPrefix("tmdb:") == true {
                return try? await TMDBMetadataClient().fetch(
                    externalID: item.externalID ?? "",
                    apiKey: apiKey,
                    language: language
                )
            }

            guard let source = self.embySource(for: item),
                  source.sourceKind.isRemoteMediaServer,
                  let externalID = item.externalID else { return nil }

            let extras: EmbyDetailExtras
            do {
                // 按来源种类分派，不是"是不是 Plex"。
                //
                // 这里原本是 `if plex { plexService } else { embyService }`，于是
                // **Mlink 也走了 Emby 的 `/Items/<id>` 接口**——Mlink 是本产品自己的
                // 服务端，说的是 Mlink 契约，那个请求只会失败，然后在日志里留下一条
                // 「Mlink 详情扩展加载失败」，读者看到的是详情栏永远空着。仓库里
                // 每一处 `if plex … else emby` 的分叉都有同一个缺口。
                switch Self.detailExtrasAPI(for: source.sourceKind) {
                case .plex:
                    extras = try await self.withValidPlexSession(for: source) { session in
                        try await self.plexService.fetchExtras(session: session, itemID: externalID)
                    }
                case .embyCompatible:
                    extras = try await self.withValidEmbySession(for: source) { session in
                        try await self.embyService.fetchExtras(session: session, itemID: externalID)
                    }
                case nil:
                    return nil
                }
            } catch {
                self.logger?.log("\(source.sourceKind.displayName) 详情扩展加载失败：\(error.localizedDescription)", level: .warning)
                return nil
            }

            var tmdbEnrichment: TMDBEnrichment?
            if let tmdbID = extras.tmdbID, let kind = extras.tmdbKind,
               let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
                tmdbEnrichment = try? await TMDBMetadataClient().fetch(
                    externalID: "tmdb:\(kind):\(tmdbID)",
                    apiKey: apiKey,
                    language: language
                )
            }

            return Self.mergedDetailEnrichment(
                server: extras,
                tmdb: tmdbEnrichment,
                provider: source.sourceKind.displayName
            )
        }
        detailEnrichmentTasks[taskKey] = task
        let value = await task.value
        detailEnrichmentTasks[taskKey] = nil
        return value
    }

    nonisolated static func mergedDetailEnrichment(
        server: EmbyDetailExtras,
        tmdb: TMDBEnrichment?,
        provider: String
    ) -> TMDBEnrichment? {
        func mergedPeople(_ primary: [TMDBPerson], _ supplement: [TMDBPerson]) -> [TMDBPerson] {
            func nameKey(_ value: String) -> String {
                value.folding(
                    options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                    locale: .current
                )
            }
            let supplementalByName = Dictionary(
                supplement.map { (nameKey($0.name), $0) },
                uniquingKeysWith: { first, _ in first }
            )
            var values = primary.map { serverPerson -> TMDBPerson in
                guard let tmdbPerson = supplementalByName[nameKey(serverPerson.name)] else {
                    return serverPerson
                }
                return TMDBPerson(
                    id: tmdbPerson.id,
                    stableID: tmdbPerson.stableID,
                    name: serverPerson.name,
                    role: serverPerson.role,
                    profileURL: serverPerson.profileURL ?? tmdbPerson.profileURL,
                    category: serverPerson.category,
                    department: serverPerson.department ?? tmdbPerson.department
                )
            }
            var seenIDs = Set(values.map(\.stableID))
            let matchedNames = Set(primary.map { nameKey($0.name) })
            for person in supplement where !matchedNames.contains(nameKey(person.name)) {
                guard seenIDs.insert(person.stableID).inserted else { continue }
                values.append(person)
            }
            return values
        }
        func mergedImages(_ primary: [TMDBImage], _ supplement: [TMDBImage]) -> [TMDBImage] {
            var seen = Set<String>()
            return (primary + supplement).filter {
                seen.insert($0.fullURL).inserted
            }
        }
        let merged = TMDBEnrichment(
            title: tmdb?.title,
            originalTitle: tmdb?.originalTitle,
            overview: tmdb?.overview,
            posterURL: tmdb?.posterURL,
            backdropURL: tmdb?.backdropURL,
            rating: tmdb?.rating,
            runtime: tmdb?.runtime,
            genres: tmdb?.genres ?? [],
            cast: mergedPeople(server.cast, tmdb?.cast ?? []),
            crew: mergedPeople(server.crew, tmdb?.crew ?? []),
            similar: tmdb?.similar ?? [],
            images: mergedImages(server.images, tmdb?.images ?? []),
            trailerURL: tmdb?.trailerURL,
            imdbID: server.imdbID ?? tmdb?.imdbID,
            tmdbKind: server.tmdbKind ?? tmdb?.tmdbKind,
            tmdbID: server.tmdbID ?? tmdb?.tmdbID,
            // 制作信息以 TMDB 为准（更完整、且已按语言本地化），TMDB 没有时用
            // 媒体服务器自己给的。此前这几项**只**认 TMDB：一个没有配 TMDB key
            // 的 Emby 库，详情页的「制作」一栏永远空着，而这些字段服务器一直
            // 都在返回。
            status: tmdb?.status ?? server.status,
            firstAirDate: tmdb?.firstAirDate,
            endDate: tmdb?.endDate,
            seasonCount: tmdb?.seasonCount,
            episodeCount: tmdb?.episodeCount,
            contentRating: tmdb?.contentRating ?? server.contentRating,
            originalLanguage: tmdb?.originalLanguage,
            countries: tmdb?.countries.isEmpty == false ? (tmdb?.countries ?? []) : server.countries,
            productionCompanies: tmdb?.productionCompanies.isEmpty == false
                ? (tmdb?.productionCompanies ?? [])
                : server.productionCompanies,
            networks: tmdb?.networks ?? []
        )
        return merged.isEmpty ? nil : merged
    }

    private func snapshotWithLocalMatches(_ snapshot: MediaDetailSnapshot) -> MediaDetailSnapshot {
        var copy = snapshot
        copy.relatedTitles = copy.relatedTitles.map { value in
            var updated = value
            updated.localMediaID = libraryItem(
                matchingExternalID: value.externalID,
                title: value.title,
                year: value.year
            )?.id
            return updated
        }
        return copy
    }

    private var visibleLibraryVideoItems: [MediaItem] {
        var resultByID = Dictionary(uniqueKeysWithValues: homeVideoItems.map { ($0.id, $0) })
        if canDisplayPrivateItems {
            for item in privateTopLevelItems {
                resultByID[item.id] = item
            }
        }
        return Array(resultByID.values)
    }

    private static func normalizedMediaLookupTitle(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
            locale: .current
        )
        .lowercased()
        .unicodeScalars
        .filter { CharacterSet.alphanumerics.contains($0) }
        .map(String.init)
        .joined()
    }

    private static func mediaGenreKeys(_ value: String?) -> Set<String> {
        guard let value else { return [] }
        return Set(
            value.components(separatedBy: CharacterSet(charactersIn: ",，、/|;；"))
                .map {
                    $0.trimmingCharacters(in: .whitespacesAndNewlines)
                        .folding(
                            options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive],
                            locale: .current
                        )
                        .lowercased()
                }
                .filter { !$0.isEmpty }
        )
    }

    private static let version122MetadataAuditCompletedKey =
        "MediaLib.migration.1.2.2.videoMetadataAudit.completed"
    private static let version122ArtworkRebuildCompletedKey =
        "MediaLib.migration.1.2.2.remoteArtworkRebuild.completed"
    private static let version122MaintenanceCompletedKey =
        "MediaLib.migration.1.2.2.maintenance.completed"
    /// 一次性：把「旧版本导入、缺专辑/艺术家字段」的远程音乐重新同步一次，让新的远程音乐列表
    /// （专辑 / 艺术家目录）对老用户也能正常分组。仅当确有缺字段的远程音乐时才触发重扫；
    /// 数据已完整的用户与全新安装用户直接标记完成、不发任何多余网络请求。
    private static let remoteMusicMetadataMigrationKey =
        "MediaLib.migration.remoteMusicMetadata.completed"
    /// 标记“旧缓存已清理 + 任务已启动过一次”：用于在重新预热中途退出后，
    /// 下次启动时**继续**而不是再次清空已经预热好的封面、重头来过。
    private static let version122ArtworkRebuildStartedKey =
        "MediaLib.migration.1.2.2.remoteArtworkRebuild.started"
    /// 1.2.2 重新预热在封面进度文件中使用的保留键（真实媒体源 id 不会与之冲突）。
    private static let version122ArtworkRebuildProgressKey =
        "__medialib.migration.1.2.2.remoteArtworkRebuild__"

    /// 1.2.2 及以后首次启动只运行这一轮维护。两个任务串行执行，避免元数据网络请求、
    /// 封面下载和图片解码同时争抢资源；完整结束后写入永久标记，不在后续版本自动重跑。
    /// 老用户迁移：为「缺专辑/艺术家字段」的远程音乐做一次性重扫，让新的远程音乐列表能正常按专辑/艺术家分组。
    /// 只在确有缺字段的远程音乐时才触发对应来源的重新同步；新装用户或数据已完整的用户直接标记完成、零多余请求。
    private func scheduleRemoteMusicMetadataMigrationIfNeeded() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.remoteMusicMetadataMigrationKey) else { return }

        let staleSourceIDs = Set(items.compactMap { item -> String? in
            guard item.type == .music,
                  Self.isEmbyItem(item),
                  (item.album?.isEmpty ?? true),
                  (item.artist?.isEmpty ?? true) else { return nil }
            return sources.first {
                $0.sourceKind.isRemoteMediaServer && Self.isSourcePath(item.sourcePath, inside: $0.path)
            }?.id
        })

        // 一次性标记：即使离线导致本轮重扫没成功，也不反复触发；后续用户手动/自动刷新会补上，
        // 新音乐列表在字段补齐前也能优雅降级（专辑/艺术家目录先按已有数据显示）。
        defaults.set(true, forKey: Self.remoteMusicMetadataMigrationKey)

        guard !staleSourceIDs.isEmpty else { return }
        let staleSources = sources.filter { staleSourceIDs.contains($0.id) }
        logger?.log("远程音乐库升级：重新同步 \(staleSources.count) 个含旧音乐数据的来源以补齐专辑/艺术家信息。")
        refreshEmbySources(staleSources)
    }

    private func scheduleVersion122MaintenanceIfNeeded() {
        guard version122MaintenanceTask == nil else { return }
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: Self.version122MaintenanceCompletedKey) else { return }
        let needsMetadataAudit = !defaults.bool(forKey: Self.version122MetadataAuditCompletedKey)
        let needsArtworkRebuild = !defaults.bool(forKey: Self.version122ArtworkRebuildCompletedKey)
        guard needsMetadataAudit || needsArtworkRebuild else {
            defaults.set(true, forKey: Self.version122MaintenanceCompletedKey)
            return
        }
        versionMaintenanceLogger.info(
            "Scheduling 1.2.2 maintenance metadata=\(needsMetadataAudit) artwork=\(needsArtworkRebuild)"
        )

        version122MaintenanceTask = Task { [weak self] in
            defer { self?.version122MaintenanceTask = nil }
            do {
                try await Task.sleep(nanoseconds: 1_000_000_000)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            if needsMetadataAudit {
                await self.runVersion122VideoMetadataAudit()
            }
            guard !Task.isCancelled else { return }
            if needsArtworkRebuild {
                await self.runVersion122ArtworkRebuild()
            }
            guard !Task.isCancelled else { return }
            defaults.set(true, forKey: Self.version122MetadataAuditCompletedKey)
            defaults.set(true, forKey: Self.version122ArtworkRebuildCompletedKey)
            defaults.set(true, forKey: Self.version122MaintenanceCompletedKey)
            versionMaintenanceLogger.info("Completed 1.2.2 maintenance batch")
        }
    }

    private func runVersion122VideoMetadataAudit() async {
        let candidates = topLevelItems.filter {
            $0.type != .music &&
                $0.type != .photo &&
                $0.type != .homeVideo &&
                $0.type != .privateCollection &&
                metadataFetchEnabled(for: $0)
        }
        let taskID = beginBackgroundTask(
            kind: .metadataSupplement,
            title: "影视元数据核验与补全",
            detail: "正在检查 \(candidates.count) 个影视项目",
            progress: 0,
            isCancellable: false
        )
        versionMaintenanceLogger.info("Starting 1.2.2 video metadata audit candidates=\(candidates.count)")

        let localPosterPaths = candidates.compactMap { item -> (String, String)? in
            guard let path = item.posterPath,
                  URL(string: path)?.scheme == nil else { return nil }
            return (item.id, path)
        }
        // 逐条海报 stat（可达数万次）走阻塞 I/O 专用队列，不占协作池。
        let missingLocalPosterIDs = await BlockingIOExecutor.run {
            Set(localPosterPaths.compactMap { id, path in
                FileManager.default.fileExists(atPath: path) ? nil : id
            })
        }
        let completeness = (try? mediaDetailRepository?.detailCompleteness(
            mediaIDs: candidates.map(\.id)
        )) ?? [:]
        let auditItems = candidates.filter {
            Self.isMissingCoreMetadata($0) ||
                missingLocalPosterIDs.contains($0.id) ||
                completeness[$0.id] != nil
        }

        guard !auditItems.isEmpty else {
            updateBackgroundTask(id: taskID, progress: 1, detail: "视频元数据检查完成，无需补充")
            finishBackgroundTask(id: taskID, errors: [])
            UserDefaults.standard.set(true, forKey: Self.version122MetadataAuditCompletedKey)
            versionMaintenanceLogger.info("Completed 1.2.2 video metadata audit with no missing items")
            return
        }

        let hasTMDBKey = !(settings.tmdbAPIKey?
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let service = MetadataSearchService()
        var completed = 0
        var updated = 0
        var unresolved = 0
        var errors: [String] = []

        for item in auditItems {
            if Task.isCancelled { return }
            updateBackgroundTask(
                id: taskID,
                progress: Double(completed) / Double(max(auditItems.count, 1)),
                detail: "核验 \(completed + 1)/\(auditItems.count)：\(item.cardTitle)"
            )

            let needsCore = Self.isMissingCoreMetadata(item) || missingLocalPosterIDs.contains(item.id)
            if needsCore, hasTMDBKey {
                if let update = await bestSupplementalVideoUpdate(for: item, service: service) {
                    do {
                        try updateMetadata(id: item.id, metadata: update, source: "version-1.2.2-metadata-audit")
                        updated += 1
                    } catch {
                        errors.append(error.localizedDescription)
                    }
                } else {
                    unresolved += 1
                }
            } else if needsCore {
                unresolved += 1
            }

            if completeness[item.id] != nil {
                let canFetchDetails = Self.isRemoteMediaServerItem(item) || hasTMDBKey
                if canFetchDetails {
                    _ = await loadDetailSnapshot(for: item, forceRefresh: true)
                } else {
                    unresolved += 1
                }
            }
            completed += 1
        }

        reload()
        let remainingDetailGaps = (try? mediaDetailRepository?.detailCompleteness(
            mediaIDs: auditItems.map(\.id)
        ).count) ?? 0
        unresolved += remainingDetailGaps
        let summary = unresolved > 0
            ? "已核验 \(completed) 项，补充 \(updated) 项，\(unresolved) 项保留到片库健康中心"
            : "已核验 \(completed) 项，补充 \(updated) 项"
        updateBackgroundTask(id: taskID, progress: 1, detail: summary)
        finishBackgroundTask(id: taskID, errors: Array(errors.prefix(8)))
        UserDefaults.standard.set(true, forKey: Self.version122MetadataAuditCompletedKey)
        versionMaintenanceLogger.info(
            "Completed 1.2.2 video metadata audit checked=\(completed) updated=\(updated) unresolved=\(unresolved)"
        )
        logger?.log("1.2.2 视频元数据核验完成：checked=\(completed) updated=\(updated) unresolved=\(unresolved)")
    }

    private func runVersion122ArtworkRebuild() async {
        let defaults = UserDefaults.standard
        let progressKey = Self.version122ArtworkRebuildProgressKey
        // 首次运行需要先清空旧缓存；中途退出后再次进入则视为“继续”，跳过清空步骤，
        // 否则会把上次已经预热好的封面又全部抹掉、重头下载。
        // 兼容已经写过进度但还没来得及写 started 标记的旧任务：只要有 1.2.2 进度记录，
        // 就视为续跑，避免再次清空缓存导致从头下载。
        let hasSavedProgress = !(await artworkWarmupProgressRecord(for: progressKey)?.completedURLs.isEmpty ?? true)
        let isResuming = defaults.bool(forKey: Self.version122ArtworkRebuildStartedKey) || hasSavedProgress

        let taskID = beginBackgroundTask(
            kind: .artworkWarmup,
            title: "远程封面重新生成",
            detail: isResuming ? "正在恢复上次的预热进度" : "正在清理旧封面缓存",
            progress: 0,
            isCancellable: false
        )
        versionMaintenanceLogger.info("Starting 1.2.2 remote artwork rebuild resuming=\(isResuming)")

        embyArtworkWarmupTasks.values.forEach { $0.cancel() }
        embyArtworkWarmupTasks.removeAll()

        if !isResuming {
            // 首次：清掉整个进度文件（含各源旧的预热进度，与原行为一致）和旧的烘焙封面，
            // 然后立刻落一个“已启动”标记，确保即便清理后马上退出，下次也能从“继续”进入。
            await ArtworkWarmupProgressStore.removeFile(at: artworkWarmupProgressURL)
            await ArtworkImageCache.clearRemotePrebakedArtwork()
            posterRevision += 1
            defaults.set(true, forKey: Self.version122ArtworkRebuildStartedKey)
        }

        let urls = artworkWarmupURLs(for: items)
        guard !urls.isEmpty else {
            updateBackgroundTask(id: taskID, progress: 1, detail: "旧封面缓存已清理，当前没有远程封面")
            finishBackgroundTask(id: taskID, errors: [])
            await clearArtworkWarmupProgress(sourceID: progressKey)
            defaults.set(true, forKey: Self.version122ArtworkRebuildCompletedKey)
            versionMaintenanceLogger.info("Completed 1.2.2 remote artwork rebuild with no remote artwork")
            return
        }

        // 读取上次进度，并与本次需要预热的 URL 取交集（媒体源可能已变化），跳过已完成的。
        let currentURLStrings = Set(urls.map(\.absoluteString))
        var completedURLStrings = Set(await artworkWarmupProgressRecord(for: progressKey)?.completedURLs ?? [])
        completedURLStrings.formIntersection(currentURLStrings)
        let totalCount = urls.count
        let remainingURLs = urls.filter { !completedURLStrings.contains($0.absoluteString) }

        await persistArtworkWarmupProgress(
            sourceID: progressKey,
            completedURLs: completedURLStrings,
            totalCount: totalCount
        )

        var completed = completedURLStrings.count
        var failures = 0
        updateBackgroundTask(
            id: taskID,
            progress: Double(completed) / Double(max(totalCount, 1)),
            detail: completed > 0
                ? "继续预热 \(completed)/\(totalCount) 张封面"
                : "准备预热 \(totalCount) 张封面"
        )

        let chunks = stride(from: 0, to: remainingURLs.count, by: 4).map {
            Array(remainingURLs[$0..<min($0 + 4, remainingURLs.count)])
        }
        for chunk in chunks {
            // 取消（含退出 App）时直接返回：进度已逐块持久化，下次启动会从此处继续。
            if Task.isCancelled { return }
            let results = await withTaskGroup(of: (String, Bool).self) { group -> [(String, Bool)] in
                for url in chunk {
                    group.addTask {
                        let succeeded = await ArtworkImageCache.prewarmRemoteImage(
                            url: url,
                            targetSize: ArtworkImageCache.posterGridTargetSize
                        )
                        return (url.absoluteString, succeeded)
                    }
                }
                var collected: [(String, Bool)] = []
                for await result in group { collected.append(result) }
                return collected
            }
            for (urlString, succeeded) in results {
                completed += 1
                if !succeeded { failures += 1 }
                // 与 Emby 预热一致：无论成功与否都记为已处理，保证可终止、不重复下载。
                completedURLStrings.insert(urlString)
            }
            await persistArtworkWarmupProgress(
                sourceID: progressKey,
                completedURLs: completedURLStrings,
                totalCount: totalCount
            )
            updateBackgroundTask(
                id: taskID,
                progress: Double(completed) / Double(max(totalCount, 1)),
                detail: "已重新预热 \(completed)/\(totalCount) 张封面"
            )
        }

        let summary = failures > 0
            ? "已重新预热 \(completed - failures) 张，\(failures) 张下载失败"
            : "已重新预热 \(completed) 张封面"
        updateBackgroundTask(id: taskID, progress: 1, detail: summary)
        // 失败的远程 URL 已按“已处理”写入进度，确保任务可终止；这里不把任务中心标成失败，
        // 避免 1.2.2 一次性维护长期留在失败列表。用户可通过对应来源刷新继续补图。
        finishBackgroundTask(id: taskID, errors: [])
        await clearArtworkWarmupProgress(sourceID: progressKey)
        defaults.set(true, forKey: Self.version122ArtworkRebuildCompletedKey)
        versionMaintenanceLogger.info(
            "Completed 1.2.2 remote artwork rebuild total=\(totalCount) failed=\(failures)"
        )
        logger?.log("1.2.2 封面重新预热完成：total=\(totalCount) failed=\(failures)")
    }

    func syncEmbyPlayback(_ report: PlayerPlaybackReport) {
        guard let source = embySource(for: report.item),
              source.remoteTraceSyncMode == .bidirectional,
              let externalID = report.item.externalID else { return }

        // Mlink 的播放与进度上报由它自己的网页会话完成（`updateMlinkWatched` 走
        // MlinkAPIClient），桌面端不该把它的进度塞进 Emby 接口。
        guard source.sourceKind != .mlink else { return }
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
        // Mlink 走 `updateMlinkPreference`（调用方在更上层就分流了）；这里再兜一道，
        // 免得日后新增一个入口时又把它送进 Emby 接口。
        if source.sourceKind == .plex || source.sourceKind == .mlink {
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
        // 同上：Mlink 有自己的 `updateMlinkWatched`。
        guard source.sourceKind != .mlink else { return }
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
        let local = sources.filter { !$0.sourceKind.isRemoteMediaServer && $0.sourceKind != .url }
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
        case .album:
            scanLocalSources(mediaTypes: [.photo], emptyMessage: "当前没有可扫描的相册媒体源。")
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
        case .homeVideos:
            scanLocalSources(mediaTypes: [.homeVideo], emptyMessage: "当前其他视频分类没有可扫描的媒体源。")
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

    private static let videoScanTypes: Set<MediaType> = [.movie, .tvShow, .anime, .documentary, .variety, .homeVideo, .other]

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
        case .homeVideos:
            return [.homeVideo]
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
            !source.sourceKind.isRemoteMediaServer && source.sourceKind != .url && (mediaTypes.contains(source.mediaType) || source.mediaType == .auto)
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
        guard !sources.isEmpty else { return }
        Task { @MainActor [weak self] in
            let reachableIDs = await Self.reachableSourceIDs(in: sources)
            guard let self else { return }
            self.startScanQueueAfterReachabilityCheck(
                sources,
                reachableIDs: reachableIDs,
                silent: silent
            )
        }
    }

    private func startScanQueueAfterReachabilityCheck(
        _ sources: [MediaSource],
        reachableIDs: Set<String>,
        silent: Bool
    ) {
        let reachableSources = sources.filter { reachableIDs.contains($0.id) }
        let unreachableSources = sources.filter { !reachableIDs.contains($0.id) }
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

    private nonisolated static func reachableSourceIDs(in sources: [MediaSource]) async -> Set<String> {
        // NAS 可达性探测在挂载点半死时单次可阻塞数秒到分钟级：必须离开协作池。
        await BlockingIOExecutor.run {
            Set(sources.compactMap { source in
                if source.sourceKind.isRemoteMediaServer { return source.id }
                return FileAccessService.isReachableDirectory(source.path) ? source.id : nil
            })
        }
    }

    private nonisolated static func isSourceReachableOffMain(_ source: MediaSource) async -> Bool {
        await BlockingIOExecutor.run {
            source.sourceKind.isRemoteMediaServer || FileAccessService.isReachableDirectory(source.path)
        }
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
        if await Self.isSourceReachableOffMain(source) { return true }
        guard !remountingNetworkSourceIDs.contains(source.id) else { return false }
        remountingNetworkSourceIDs.insert(source.id)
        defer { remountingNetworkSourceIDs.remove(source.id) }

        guard let credential = try? await remoteCredentialStore.loadAsync(sourceID: source.id),
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
            if await Self.isSourceReachableOffMain(source) {
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

        scanTask = Task { [settings, logger, self] in
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
                let incrementalPublisher = ScanIncrementalLibraryPublisher {
                    await MainActor.run {
                        self.reloadMediaItemsDuringScan(runID: runID)
                    }
                }
                let summary = await scanner.scan(source: source, settings: settings) { [weak self] progress in
                    guard progressThrottler.shouldPublish(progress) else { return }
                    Task { @MainActor in
                        guard self?.scanRunID == runID else { return }
                        self?.scanProgress = progress
                        self?.updateBackgroundTask(id: taskID, with: progress)
                    }
                } onImportedIDs: { ids in
                    Task {
                        await incrementalPublisher.record(ids)
                    }
                }
                await incrementalPublisher.flush()
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

        scanTask = Task { [settings, logger, self] in
            var allErrors: [String] = []
            let progressThrottler = ScanProgressThrottler()
            for (sourceID, paths) in queuedChanges {
                if Task.isCancelled { return }
                guard let source = await MainActor.run(body: {
                    self.sources.first { $0.id == sourceID && $0.sourceKind == .local }
                }) else {
                    continue
                }
                guard await Self.isSourceReachableOffMain(source) else {
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
                let incrementalPublisher = ScanIncrementalLibraryPublisher {
                    await MainActor.run {
                        self.reloadMediaItemsDuringScan(runID: runID)
                    }
                }
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
                } onImportedIDs: { ids in
                    Task {
                        await incrementalPublisher.record(ids)
                    }
                }
                await incrementalPublisher.flush()
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
        persistBackgroundTasksIfPossible(immediate: true)
    }

    func clearBackgroundTask(id: UUID) {
        backgroundTasks.removeAll { task in
            task.id == id && !task.state.isActive
        }
        persistBackgroundTasksIfPossible(immediate: true)
    }

    func canRetryBackgroundTask(_ task: BackgroundTaskSnapshot) -> Bool {
        let source = backgroundTaskRetrySource(for: task)
        let item = backgroundTaskRetryItem(for: task)
        let sourceIsRemoteMediaServer = source?.sourceKind.isRemoteMediaServer
        let artworkWarmupHasSourceItems: Bool
        if task.kind == .artworkWarmup, let source {
            artworkWarmupHasSourceItems = items.contains { item in
                guard let sourcePath = item.sourcePath else { return false }
                return Self.isSourcePath(sourcePath, inside: source.path)
            }
        } else {
            artworkWarmupHasSourceItems = false
        }
        let hasVideoCacheQualityChoices: Bool
        if task.kind == .videoCache,
           videoOfflineCacheStore != nil,
           let item {
            hasVideoCacheQualityChoices = !videoCacheQualityChoices(for: item).isEmpty
        } else {
            hasVideoCacheQualityChoices = false
        }
        return BackgroundTaskRetryPolicy.canRetry(
            BackgroundTaskRetryPolicy.Input(
                task: task,
                activeTasks: backgroundTasks,
                retrySourceIsRemoteMediaServer: sourceIsRemoteMediaServer,
                artworkWarmupHasSourceItems: artworkWarmupHasSourceItems,
                hasVideoCacheStore: videoOfflineCacheStore != nil,
                hasVideoCacheQualityChoices: hasVideoCacheQualityChoices,
                canGenerateKeyframeStoryboard: item.map { canGenerateVideoFrameStoryboard(for: $0) } ?? false,
                canAnalyzeMarkers: item.map { canAnalyzeIntroOutroMarkers(for: $0) } ?? false,
                hasMusicProjectionRepository: musicProjectionRepository != nil,
                isSupplementingMetadata: isSupplementingMetadata
            )
        )
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
            Task { @MainActor [weak self] in
                await self?.scheduleEmbyArtworkWarmup(source: source, items: sourceItems)
            }
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
        case .musicIndex:
            scheduleMusicProjectionMaintenance(reason: "retry", force: true)
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
        guard settings.hasCompletedOnboarding else {
            floatingNoticeQueue.append(pending)
            if floatingNoticeQueue.count > 12 {
                floatingNoticeQueue.removeFirst(floatingNoticeQueue.count - 12)
            }
            return
        }
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
        floatingNoticeStore.present(notice)
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
        floatingNoticeStore.remove(id: id)
        presentNextFloatingNoticeIfNeeded()
    }

    private func presentNextFloatingNoticeIfNeeded() {
        guard floatingNotices.isEmpty, !floatingNoticeQueue.isEmpty else { return }
        let next = floatingNoticeQueue.removeFirst()
        presentFloatingNotice(next)
    }

    func releaseDeferredFloatingNoticesIfNeeded() {
        guard settings.hasCompletedOnboarding else { return }
        presentNextFloatingNoticeIfNeeded()
    }

    func deliverTaskNotice(
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
        let isFirstPresentation = shownInterfaceTipKeys.insert(key).inserted
        if isFirstPresentation {
            UserDefaults.standard.set(Array(shownInterfaceTipKeys).sorted(), forKey: Self.shownInterfaceTipDefaultsKey)
        } else {
            guard Double.random(in: 0..<1) < 0.05 else { return }
        }
        showFloatingNotice(title: title, message: message, kind: .tip, duration: 5.8)
    }

    private func showOneShotInterfaceTip(key: String, title: String = "提示", message: String, duration: TimeInterval = 6.2) {
        loadShownInterfaceTipKeysIfNeeded()
        guard shownInterfaceTipKeys.insert(key).inserted else { return }
        UserDefaults.standard.set(Array(shownInterfaceTipKeys).sorted(), forKey: Self.shownInterfaceTipDefaultsKey)
        showFloatingNotice(title: title, message: message, kind: .tip, duration: duration)
    }

    private func showInitialIndexingTipIfNeeded() {
        // 首次扫描的卡顿提示单独延长到 1 分钟：这条提示是关于"接下来一段时间可能会卡"的
        // 前瞻性提醒，短暂的默认时长(6.2s)读完就消失，用户往往还没真正遇到卡顿就看不到提示了。
        // 其它一次性提示(showOneShotInterfaceTip 的默认时长/showInterfaceTipOnce)不受影响。
        showOneShotInterfaceTip(
            key: "sources.initialIndexing.performance",
            title: "正在建立媒体索引",
            message: "首次加入媒体源时，MediaLIB 会整理文件、封面和基础信息，短时间内可能不够轻快；索引完成后，浏览和搜索会顺畅许多。",
            duration: 60
        )
    }

    private func loadShownInterfaceTipKeysIfNeeded() {
        guard !didLoadShownInterfaceTipKeys else { return }
        shownInterfaceTipKeys = Set(UserDefaults.standard.stringArray(forKey: Self.shownInterfaceTipDefaultsKey) ?? [])
        didLoadShownInterfaceTipKeys = true
    }

    func beginBackgroundTask(
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
        backgroundTasks = BackgroundTaskListPolicy.inserting(task, into: backgroundTasks)
        showBackgroundTaskQueuedNotice(task)
        return task.id
    }

    private var backgroundTasksURL: URL? {
        directories?.applicationSupport.appendingPathComponent("BackgroundTasks.json", isDirectory: false)
    }

    private var artworkWarmupProgressURL: URL? {
        directories?.applicationSupport.appendingPathComponent("ArtworkWarmupProgress.json", isDirectory: false)
    }

    private func scheduleBackgroundTaskRestore() {
        let url = backgroundTasksURL
        Task { @MainActor [weak self] in
            guard let decoded = await Self.loadBackgroundTasks(from: url),
                  let self else { return }
            self.applyRestoredBackgroundTasks(decoded)
        }
    }

    private nonisolated static func loadBackgroundTasks(from url: URL?) async -> [BackgroundTaskSnapshot]? {
        await BackgroundTaskPersistence.load(from: url)
    }

    private func applyRestoredBackgroundTasks(_ decoded: [BackgroundTaskSnapshot]) {
        isRestoringBackgroundTasks = true
        let restored = BackgroundTaskListPolicy.restoredTasks(from: decoded)
        backgroundTasks = restored.tasks
        isRestoringBackgroundTasks = false
        restoredArtworkWarmupTasks = restored.resumableArtworkWarmupTasks
        persistBackgroundTasksIfPossible(immediate: true)
    }

    private func resumeRestoredArtworkWarmupTasksIfNeeded() {
        guard !restoredArtworkWarmupTasks.isEmpty else { return }
        let tasks = restoredArtworkWarmupTasks
        restoredArtworkWarmupTasks.removeAll()

        for task in tasks {
            guard let source = backgroundTaskRetrySource(for: task) else {
                finishBackgroundTask(id: task.id, errors: ["找不到原来的媒体源，封面预热无法继续。"])
                continue
            }
            let sourceItems = items.filter { item in
                guard let sourcePath = item.sourcePath else { return false }
                return Self.isSourcePath(sourcePath, inside: source.path)
            }
            guard !sourceItems.isEmpty else {
                finishBackgroundTask(id: task.id, errors: ["这个媒体源暂时没有可预热的封面。"])
                continue
            }
            Task { @MainActor [weak self] in
                await self?.scheduleEmbyArtworkWarmup(source: source, items: sourceItems, resumingTaskID: task.id)
            }
        }
    }

    private func persistBackgroundTasksIfPossible(immediate: Bool = false) {
        guard !isRestoringBackgroundTasks, let url = backgroundTasksURL else { return }
        backgroundTaskPersistence.schedule(backgroundTasks, to: url, immediate: immediate)
    }

    private func artworkWarmupProgressRecord(for sourceID: String) async -> ArtworkWarmupProgressRecord? {
        await ArtworkWarmupProgressStore.record(for: sourceID, from: artworkWarmupProgressURL)
    }

    private func persistArtworkWarmupProgress(
        sourceID: String,
        completedURLs: Set<String>,
        totalCount: Int
    ) async {
        do {
            try await ArtworkWarmupProgressStore.persist(
                sourceID: sourceID,
                completedURLs: completedURLs,
                totalCount: totalCount,
                to: artworkWarmupProgressURL
            )
        } catch {
            logger?.log("封面预热进度保存失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func clearArtworkWarmupProgress(sourceID: String) async {
        do {
            try await ArtworkWarmupProgressStore.clear(sourceID: sourceID, from: artworkWarmupProgressURL)
        } catch {
            logger?.log("封面预热进度保存失败：\(error.localizedDescription)", level: .warning)
        }
    }

    func beginBackgroundTask(
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
        backgroundTasks = BackgroundTaskListPolicy.inserting(task, into: backgroundTasks)
        showBackgroundTaskQueuedNotice(task)
        return task.id
    }

    func updateBackgroundTask(id: UUID, with progress: ScanProgress) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        let previous = backgroundTasks[index].progress ?? 0
        let next = progress.fraction
        guard next >= 1 || abs(next - previous) >= 0.025 else { return }
        backgroundTasks[index].progress = next
    }

    func updateBackgroundTask(id: UUID, progress: Double?, detail: String? = nil) {
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

    func finishBackgroundTask(id: UUID, errors: [String]) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = errors.isEmpty ? .completed : .failed
        backgroundTasks[index].detail = backgroundTasks[index].hidesDetail ? nil : (errors.first ?? backgroundTasks[index].detail)
        backgroundTasks[index].progress = 1
        backgroundTasks[index].finishedAt = Date()
        backgroundTasks[index].isCancellable = false
        let task = backgroundTasks[index]
        persistBackgroundTasksIfPossible(immediate: true)
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
        persistBackgroundTasksIfPossible(immediate: true)
    }

    private func markBackgroundTaskCancelled(id: UUID, detail: String?) {
        guard let index = backgroundTasks.firstIndex(where: { $0.id == id }) else { return }
        backgroundTasks[index].state = .cancelled
        backgroundTasks[index].finishedAt = Date()
        backgroundTasks[index].isCancellable = false
        if let detail, !backgroundTasks[index].hidesDetail {
            backgroundTasks[index].detail = detail
        }
        persistBackgroundTasksIfPossible(immediate: true)
    }

    /// 首次启动引导完成 / 跳过后调用：标记完成，不再弹出。
    func completeOnboarding() {
        guard !settings.hasCompletedOnboarding else { return }
        settings.hasCompletedOnboarding = true
        saveSettings()
    }

    /// 设置页「重新查看引导」：驱动 ContentView 再次弹出引导。
    let onboardingReplay = OnboardingReplayStore()
    private var onboardingReplayForwarding: AnyCancellable?
    var onboardingReplayRequested: Bool {
        get { onboardingReplay.isReplayRequested }
        set { onboardingReplay.setReplayRequested(newValue) }
    }
    func replayOnboarding() {
        onboardingReplay.requestReplay()
    }

    /// 设置页开关：开启时立即向系统申请通知授权；被拒则回退关闭并提示。
    func setSystemPhotoLibraryEnabled(_ enabled: Bool) {
        settings.enableSystemPhotoLibrary = enabled
        saveSettings()
    }

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
        let cancelled = BackgroundTaskListPolicy.cancellingActiveScanTasks(in: backgroundTasks)
        if cancelled.changed {
            backgroundTasks = cancelled.tasks
        }
        persistBackgroundTasksIfPossible(immediate: true)
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
        let cancelled = BackgroundTaskListPolicy.cancellingAllActiveCancellableTasks(in: backgroundTasks)
        if cancelled.changed {
            backgroundTasks = cancelled.tasks
        }
        persistBackgroundTasksIfPossible(immediate: true)
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
        if openMlinkWebPlayerIfNeeded(for: item) {
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
                    let host = self.embySource(for: item).map(AppState.embyServerHost(for:)) ?? (item.sourcePath ?? "远程服务器")
                    if !self.presentEmbyRestrictionIfNeeded(error, serverHost: host) {
                        self.showError("远程播放准备失败", error)
                    }
                }
            }
            return
        }
        playPreparedItem(item, preserveSelection: preserveSelection)
    }

    /// Mlink 条目没有本地文件路径。客户端只负责打开无令牌的网页详情地址；浏览器使用
    /// 自己的受保护会话并以原生能力解码媒体，避免把服务端播放凭据交给本地播放器。
    func isMlinkWebPlaybackItem(_ item: MediaItem) -> Bool {
        guard embySource(for: item)?.sourceKind == .mlink,
              let itemID = item.externalID else { return false }
        return MlinkAPIClient.isSafeWebItemIdentifier(itemID)
    }

    func playbackActionTitle(for item: MediaItem) -> String {
        isMlinkWebPlaybackItem(item) ? "在网页中播放" : "播放"
    }

    func canStartPlayback(for item: MediaItem) -> Bool {
        isMlinkWebPlaybackItem(item) || item.filePath != nil || !children(for: item).isEmpty
    }

    @discardableResult
    private func openMlinkWebPlayerIfNeeded(for item: MediaItem) -> Bool {
        guard isMlinkWebPlaybackItem(item),
              let source = embySource(for: item),
              let itemID = item.externalID else { return false }
        Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                guard let credential = try await remoteCredentialStore.loadAsync(sourceID: source.id),
                      credential.kind == RemoteConnectorProvider.mlink.credentialKind,
                      let serverURL = URL(string: credential.serverURL) else {
                    throw NSError(
                        domain: "MediaLib.Mlink",
                        code: -2,
                        userInfo: [NSLocalizedDescriptionKey: "(source.name) 的服务器地址不可用，请重新连接。"]
                    )
                }
                let isSeries = item.sourcePath?.hasPrefix(source.path + "/series/") == true
                let webURL = try MlinkAPIClient().webItemURL(
                    serverURL: serverURL, itemID: itemID, isSeries: isSeries
                )
                guard NSWorkspace.shared.open(webURL) else {
                    throw NSError(
                        domain: "MediaLib.Mlink",
                        code: -3,
                        userInfo: [NSLocalizedDescriptionKey: "无法在默认浏览器中打开服务端详情页。"]
                    )
                }
                showFloatingNotice(
                    title: "已在网页中打开",
                    message: "请在浏览器中登录并播放；媒体由网页端解码。",
                    kind: .success
                )
            } catch {
                showError("无法打开 Mlink 网页播放", error)
            }
        }
        return true
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
            do {
                try store.markAccessed(itemID: item.id)
            } catch {
                logger?.log("视频缓存访问标记失败(\(item.id))：\(error.localizedDescription)", level: .warning)
            }
            updateVideoCacheStorageSummary()
            return VideoOfflineCacheStore.itemWithCache(item, entry: entry)
        }
        refreshVideoCacheEntries(pruningMissingFiles: true)
        return nil
    }

    private func cachedPlayableItemAsync(for item: MediaItem) async -> MediaItem? {
        guard let store = videoOfflineCacheStore else { return nil }
        if let entry = await store.entryAsync(for: item.id) {
            do {
                try await store.markAccessedAsync(itemID: item.id)
            } catch {
                logger?.log("视频缓存访问标记失败(\(item.id))：\(error.localizedDescription)", level: .warning)
            }
            await updateVideoCacheStorageSummaryAsync()
            return VideoOfflineCacheStore.itemWithCache(item, entry: entry)
        }
        await refreshVideoCacheEntriesAsync(pruningMissingFiles: true)
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
            applyVideoCacheEntries(next)
            updateVideoCacheStorageSummary()
        } catch {
            logger?.log("刷新视频缓存清单失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func refreshVideoCacheEntriesAsync(pruningMissingFiles: Bool = false) async {
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
            let next = pruningMissingFiles
                ? try await store.refreshEntriesPruningMissingFilesAsync()
                : await store.allEntriesAsync()
            applyVideoCacheEntries(next)
            await updateVideoCacheStorageSummaryAsync()
        } catch {
            logger?.log("刷新视频缓存清单失败：\(error.localizedDescription)", level: .warning)
        }
    }

    private func applyVideoCacheEntries(_ next: [String: VideoCacheEntry]) {
        if next != cachedVideoEntriesByItemID {
            cachedVideoEntriesByItemID = next
            rebuildHomeOfflineVideoCache()
            videoCacheRevision += 1
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
        try await removeExistingVideoCacheBeforeRedownload(itemID: item.id, taskID: taskID, store: store)
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
        try await store.upsertAsync(entry)
        await refreshVideoCacheEntriesAsync()
        await enforceVideoCacheLimitIfNeededAsync()
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
    ) async throws {
        guard videoCacheJobs[taskID]?.cleanedItemIDs.contains(itemID) == false else { return }
        let removed = try await store.removeAsync(itemIDs: [itemID])
        videoCacheJobs[taskID]?.cleanedItemIDs.insert(itemID)
        if !removed.isEmpty {
            await refreshVideoCacheEntriesAsync()
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
                self.scheduleServerLANReconciliation(reason: "网络地址变化")
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
        VideoOfflinePolicy.subscriptionCandidates(
            for: subscription,
            episodes: children(for: series),
            cachedItemIDs: Set(cachedVideoEntriesByItemID.keys),
            queuedItemIDs: queuedIDs,
            wifiAvailable: videoOfflineSubscriptionWiFiAvailable,
            watchedThreshold: settings.watchedThreshold
        )
    }

    private func videoOfflineSubscriptionSeasonNumber(from item: MediaItem, in series: MediaItem) -> Int? {
        VideoOfflinePolicy.preferredSubscriptionSeasonNumber(
            for: item,
            episodes: children(for: series),
            watchedThreshold: settings.watchedThreshold
        )
    }

    private func videoOfflineSubscriptionNetworkPolicyAllows(
        _ policy: VideoOfflineSubscriptionNetworkPolicy,
        item: MediaItem
    ) -> Bool {
        VideoOfflinePolicy.networkPolicyAllows(
            policy,
            item: item,
            wifiAvailable: videoOfflineSubscriptionWiFiAvailable
        )
    }

    private static func isLocalNetworkHost(_ host: String) -> Bool {
        VideoOfflinePolicy.isLocalNetworkHost(host)
    }

    private func nextUnwatchedEpisodes(in episodes: [MediaItem]) -> [MediaItem] {
        VideoOfflinePolicy.nextUnwatchedEpisodes(
            in: episodes,
            watchedThreshold: settings.watchedThreshold
        )
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

    private func updateVideoCacheStorageSummaryAsync() async {
        guard let store = videoOfflineCacheStore else {
            videoCacheStorageSummary = VideoCacheStorageSummary(entryCount: 0, totalBytes: 0, byteLimit: nil)
            return
        }
        videoCacheStorageSummary = await store.storageSummaryAsync(
            byteLimit: Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB)
        )
    }

    private func enforceVideoCacheLimitIfNeededAsync() async {
        guard let store = videoOfflineCacheStore,
              let byteLimit = Self.videoCacheByteLimit(from: settings.videoCacheSizeLimitGB) else {
            await updateVideoCacheStorageSummaryAsync()
            return
        }
        let validItemIDs = Set(items.map(\.id))
        let cleanupHint = videoCacheCleanupHint()
        do {
            let result = try await store.runMaintenanceAsync(
                validItemIDs: validItemIDs,
                byteLimit: byteLimit,
                cleanupHint: cleanupHint
            )
            await refreshVideoCacheEntriesAsync()
            if result.overLimitEntries > 0 {
                logger?.log("视频缓存超过容量上限，已自动回收 \(result.overLimitEntries) 个缓存。", level: .info)
            }
        } catch {
            await updateVideoCacheStorageSummaryAsync()
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
        VideoOfflinePolicy.isCacheableVideoCandidate(item)
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
        try await BlockingIOExecutor.run {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try data.write(to: url, options: [.atomic])
        }
    }

    nonisolated private static func moveVideoCacheDownload(
        temporaryURL: URL,
        response: URLResponse,
        destination: URL
    ) async throws -> Int64 {
        try await BlockingIOExecutor.run {
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
        }
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
    // startRadio / startGenreRadio / startArtistRadio / hasPlayableTracks / genreSet / buildRadioQueue
    // 已拆到 AppState+Radio.swift（缩小本超大文件）。

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
        playbackSession.requestCommand(command)
    }

    func toggleMusicShuffle() {
        musicShuffleEnabled.toggle()
        // 每次切换都重置洗牌袋与历史：开启时从干净的一轮开始，关闭时不残留陈旧状态。
        musicShuffleNavigator.reset()
        scheduleMusicQueuePersistence()
    }

    func cycleMusicRepeatMode() {
        musicRepeatMode = musicRepeatMode.next
        scheduleMusicQueuePersistence()
    }

    /// 直接设置循环模式（书架方案「下拉唱片开启单曲循环」用；现有 cycleMusicRepeatMode 行为不变）。
    func setMusicRepeatMode(_ mode: MusicRepeatMode) {
        guard musicRepeatMode != mode else { return }
        musicRepeatMode = mode
        scheduleMusicQueuePersistence()
    }

    /// 随机重排播放队列，但保持当前正在播放的曲目位置不变（书架方案「长按聚拢后晃动洗牌」用）。
    /// 仅打乱顺序、不切歌、不改其它行为；当前曲留在原下标，其余曲目随机填充剩余位置。
    func shuffleMusicQueueKeepingCurrent() {
        guard musicQueue.count > 2 else { return }
        if let current = activePlayerItem,
           let currentIndex = musicQueue.firstIndex(where: { $0.id == current.id }) {
            var others = musicQueue
            let pinned = others.remove(at: currentIndex)
            others.shuffle()
            others.insert(pinned, at: currentIndex)
            musicQueue = others
        } else {
            musicQueue.shuffle()
        }
        scheduleMusicQueuePersistence()
    }

    // 播放入口已拆到 AppState+ExternalPlayback.swift（presentBuiltInPlayer / playExternalFiles /
    // playNetworkStream / videoQueueItems / triggerSakuraEasterEggIfNeeded）。
    // 更新检查/启动邀请见 AppState+Updates.swift。

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
                try await BlockingIOExecutor.run {
                    try musicQueueRepository.save(snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                self?.logger?.log("音乐播放队列保存失败：\(error.localizedDescription)", level: .warning)
            }
        }
    }

    func uniqueMusicTracks(_ tracks: [MediaItem]) -> [MediaItem] {
        MusicTrackProjectionPolicy.uniquePlayableMusicTracks(tracks)
    }

    private func adjacentItem(to item: MediaItem, direction: Int) -> MediaItem? {
        if item.type == .music {
            prepareMusicQueue(for: item)
            let sequence = musicQueue
            if musicShuffleEnabled, musicRepeatMode != .repeatOne {
                let normalizedDirection = direction < 0 ? -1 : 1
                if normalizedDirection > 0 {
                    return musicShuffleNavigator.next(current: item, queue: sequence)
                } else if let previous = musicShuffleNavigator.previous(current: item, queue: sequence) {
                    return previous
                }
                // 随机模式下若无历史可回溯，落回下方顺序逻辑（保持原「上一首」兜底行为）。
            }
            guard let targetID = PlaybackQueuePolicy.musicAdjacentItemID(
                queueIDs: sequence.map(\.id),
                currentItemID: item.id,
                direction: direction,
                repeatModeRawValue: musicRepeatMode.rawValue
            ) else {
                return nil
            }
            return sequence.first { $0.id == targetID } ?? (targetID == item.id ? item : nil)
        }

        let sequence: [MediaItem]
        if let parentID = item.parentID,
           let parent = items.first(where: { $0.id == parentID }) {
            sequence = children(for: parent)
        } else {
            sequence = topLevelItems.filter { $0.type != .music && $0.filePath != nil }
        }
        guard let targetID = PlaybackQueuePolicy.adjacentItemID(
            queueIDs: sequence.map(\.id),
            currentItemID: item.id,
            direction: direction,
            wraps: false
        ) else {
            return nil
        }
        return sequence.first { $0.id == targetID }
    }

    // 顺序/循环相邻项策略已下沉到 MediaLibCore.PlaybackQueuePolicy；
    // 随机播放洗牌袋 / 历史逻辑已抽到 MusicShuffleNavigator（见 adjacentItem 的 music 分支调用）。

    func openExternally(_ item: MediaItem) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            let playableItem = await cachedPlayableItemAsync(for: item) ?? item
            guard let filePath = playableItem.filePath else {
                alert = AppAlert(title: "无法打开外部播放器", message: "此媒体没有文件路径。")
                return
            }
            let path = playableItem.type == .music ? settings.musicExternalPlayerPath : settings.videoExternalPlayerPath
            do {
                try await externalPlayerService.openAsync(filePath: filePath, preferredPlayerPath: path)
            } catch {
                showError("外部播放器不可用", error)
            }
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
            scheduleMusicProjectionMaintenance(reason: "music play count reset", force: false, preferIncremental: true)
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
            scheduleMusicProjectionMaintenance(reason: "music play counts reset", force: false, preferIncremental: true)
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
            incrementMusicPlayCountInMemory(id: item.id)
            scheduleMusicProjectionMaintenance(reason: "music play count increment", force: false, preferIncremental: true)
        } catch {
            logger?.log("播放次数更新失败：\(error.localizedDescription)", level: .warning)
        }
    }


    // MARK: - Trakt 同步（Phase 4）

    let traktSyncActivity = TraktSyncActivityStore()
    private var traktSyncActivityForwarding: AnyCancellable?
    var isTraktConnecting: Bool {
        get { traktSyncActivity.isConnecting }
        set { traktSyncActivity.setConnecting(newValue) }
    }
    var isImportingTraktState: Bool {
        get { traktSyncActivity.isImporting }
        set { traktSyncActivity.setImporting(newValue) }
    }
    // internal（非 private）：供拆到 AppState+TraktSync.swift 的方法读写。
    var traktPollTask: Task<Void, Never>?

    // Trakt 同步方法（traktService / isTraktConnected / beginTraktConnect / disconnectTrakt /
    // setTraktSyncEnabled / syncTraktHistory / syncTraktWatchlist / importTraktState 等）已拆到
    // AppState+TraktSync.swift（缩小本超大文件）。stored 属性仍在上方。

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
        for item in items where targetIDs.contains(item.id) {
            cachedItemsByID[item.id] = item
        }
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
        cachedMusicTracks = cachedMusicTracks.map(updated)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        rebuildMusicSectionCaches()
        if bumpRevision {
            libraryRevision += 1
        }
    }

    /// 单曲播放次数 +1 的轻量路径：每次点击播放都会走这里，绝不能像 `updateMusicPlayCountsInMemory`
    /// 那样 `.map` 整个 `items`/`musicQueue`/`cachedMusicTracks`（`items` 是全库，含全部影视条目，
    /// 可能数万条）。只按索引原地更新命中的那一条，且不刷新 `musicContentRevision`——
    /// 该修订号驱动音乐列表快照缓存 key，播放次数这种高频、非展示语义变化的字段不应让
    /// 用户每点一次播放就触发整页列表快照失效重建（表现为「点击播放就刷新一次界面」）。
    /// 播放次数在列表里的可见文案（徽标、"最多播放"排序）会在下一次真正的内容修订
    /// （收藏、评分、扫描、编辑元数据等）时自然跟上，不需要用整页刷新换取实时性。
    private func incrementMusicPlayCountInMemory(id: String) {
        func bump(_ item: MediaItem) -> MediaItem {
            var copy = item
            copy.playCount = (copy.playCount ?? 0) + 1
            return copy
        }
        if let index = items.firstIndex(where: { $0.id == id }) {
            items[index] = bump(items[index])
            cachedItemsByID[id] = items[index]
        }
        if let index = musicQueue.firstIndex(where: { $0.id == id }) {
            musicQueue[index] = bump(musicQueue[index])
        }
        if let activePlayerItem, activePlayerItem.id == id {
            self.activePlayerItem = bump(activePlayerItem)
        }
        if let selectedItem, selectedItem.id == id {
            self.selectedItem = bump(selectedItem)
        }
        if let quickPreviewItem, quickPreviewItem.id == id {
            self.quickPreviewItem = bump(quickPreviewItem)
        }
        if let index = cachedMusicTracks.firstIndex(where: { $0.id == id }) {
            cachedMusicTracks[index] = bump(cachedMusicTracks[index])
            cachedMusicTracksByID[id] = cachedMusicTracks[index]
        }
        rebuildMusicSectionCaches(bumpContentRevision: false)
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

    func updateWatchedInMemory(ids: [String], watched: Bool) {
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
        cachedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
        // 展开成 if-let，避免 `??` + flatMap 深链让编译器类型检查超时（行为不变：items→active→selected→item）。
        var currentFavorite = item.favorite
        if let match = items.first(where: { $0.id == item.id }) {
            currentFavorite = match.favorite
        } else if let active = activePlayerItem, active.id == item.id {
            currentFavorite = active.favorite
        } else if let selected = selectedItem, selected.id == item.id {
            currentFavorite = selected.favorite
        }
        let nextFavorite = !currentFavorite
        if let source = mlinkSource(for: item) {
            updateMlinkPreference(item, source: source, update: .favorite(nextFavorite))
            return
        }

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
                await MainActor.run {
                    guard item.type == .music else { return }
                    self?.scheduleMusicProjectionMaintenance(reason: "music favorite changed", force: false, preferIncremental: true)
                }
            } catch {
                await MainActor.run {
                    guard let self else { return }
                    do {
                        try mediaRepository.setFavorite(id: item.id, favorite: currentFavorite)
                    } catch {
                        self.logger?.log("喜欢状态回滚写入失败(\(item.id))：\(error.localizedDescription)", level: .warning)
                    }
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

    /// 相册批量收藏/取消收藏（选择模式下使用）。
    func setAlbumItemsFavorite(_ targets: [MediaItem], favorite: Bool) {
        let ids = Set(targets.map(\.id))
        guard !ids.isEmpty else { return }
        func updated(_ item: MediaItem) -> MediaItem {
            guard ids.contains(item.id) else { return item }
            var copy = item
            copy.favorite = favorite
            return copy
        }
        items = items.map(updated)
        rebuildDerivedItemCaches()
        libraryRevision += 1
        showFloatingNotice(
            title: favorite ? "已加入喜欢" : "已取消喜欢",
            message: "\(ids.count) 张照片",
            kind: favorite ? .success : .info
        )
        if let mediaRepository {
            Task(priority: .utility) { [mediaRepository, logger] in
                var failedCount = 0
                for id in ids {
                    do {
                        try mediaRepository.setFavorite(id: id, favorite: favorite)
                    } catch {
                        failedCount += 1
                    }
                }
                if failedCount > 0 {
                    logger?.log("批量喜欢状态写入失败 \(failedCount)/\(ids.count) 项", level: .warning)
                }
            }
        }
    }

    /// 相册删除：把照片/录像文件移到废纸篓（可在访达恢复），并从内部索引移除。
    func deleteAlbumItems(_ targets: [MediaItem]) {
        let albumTargets = targets.filter { isAlbumItem($0) }
        guard !albumTargets.isEmpty else { return }

        var trashedIDs: [String] = []
        var failures = 0
        for item in albumTargets {
            guard let path = item.filePath else { continue }
            let url = URL(fileURLWithPath: path)
            do {
                try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                trashedIDs.append(item.id)
            } catch {
                failures += 1
            }
        }

        guard !trashedIDs.isEmpty else {
            alert = AppAlert(title: "删除失败", message: "无法把所选项目移到废纸篓，请检查文件是否仍可访问。")
            return
        }

        do {
            try mediaRepository?.deleteItems(ids: trashedIDs)
            reload()
        } catch {
            showError("删除后清理索引失败", error)
            return
        }

        let suffix = failures > 0 ? "（\(failures) 项未能删除）" : ""
        showFloatingNotice(
            title: "已移到废纸篓",
            message: "\(trashedIDs.count) 项\(suffix)",
            kind: failures > 0 ? .warning : .success
        )
    }

    func updateFavoriteInMemory(id: String, favorite: Bool) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.favorite = favorite
            return copy
        }

        items = items.map(updated)
        cachedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        musicQueue = musicQueue.map(updated)
        if let parentID = items.first(where: { $0.id == id })?.parentID,
           let children = cachedChildrenByParentID[parentID] {
            cachedChildrenByParentID[parentID] = children.map(updated)
        }
        cachedTopLevelItems = cachedTopLevelItems.map(updated)
        cachedPrivateTopLevelItems = cachedPrivateTopLevelItems.map(updated)
        cachedMusicTracks = cachedMusicTracks.map(updated)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        if cachedMusicTracksByID[id] != nil {
            // 音乐曲目喜欢态是乐观更新（只 bump favoriteRevision）：分区基表（收藏等）
            // 与音乐内容指纹必须同步重建，否则「收藏」子页面与列表快照会保持陈旧。
            rebuildMusicSectionCaches()
        }
        cachedEmbyTopLevelItems = cachedEmbyTopLevelItems.map(updated)
        cachedHomeVideoItems = cachedHomeVideoItems.map(updated)
        cachedHomeOfflineVideoItems = cachedHomeOfflineVideoItems.map(updated)
        cachedContinueWatchingItems = cachedContinueWatchingItems.map(updated)
        cachedWatchingItems = cachedWatchingItems.map(updated)
        cachedPrivateWatchingItems = cachedPrivateWatchingItems.map(updated)
        cachedNextUpItems = cachedNextUpItems.map(updated)
        cachedAlbumItems = cachedAlbumItems.map(updated)
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
        // 展开成 if-let，避免 `??` + flatMap 深链让编译器类型检查超时（行为不变：items→active→selected→item）。
        var currentWatchlist = item.watchlist
        if let match = items.first(where: { $0.id == item.id }) {
            currentWatchlist = match.watchlist
        } else if let active = activePlayerItem, active.id == item.id {
            currentWatchlist = active.watchlist
        } else if let selected = selectedItem, selected.id == item.id {
            currentWatchlist = selected.watchlist
        }
        let nextWatchlist = !currentWatchlist
        if let source = mlinkSource(for: item) {
            updateMlinkPreference(item, source: source, update: .watchlist(nextWatchlist))
            return
        }
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
                    do {
                        try mediaRepository.setWatchlist(id: item.id, watchlist: currentWatchlist)
                    } catch {
                        self.logger?.log("待看状态回滚写入失败(\(item.id))：\(error.localizedDescription)", level: .warning)
                    }
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

    func updateWatchlistInMemory(id: String, watchlist: Bool) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.watchlist = watchlist
            return copy
        }

        items = items.map(updated)
        cachedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
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
        // 展开成早返回，避免 `??` + flatMap 深链让编译器类型检查超时（行为不变）。
        if let match = items.first(where: { $0.id == item.id }) { return match }
        if let active = activePlayerItem, active.id == item.id { return active }
        if let selected = selectedItem, selected.id == item.id { return selected }
        if let preview = quickPreviewItem, preview.id == item.id { return preview }
        return item
    }

    func shouldClearWatchlistWhenMarkedWatched(_ item: MediaItem, watched: Bool) -> Bool {
        watched && item.type != .music && item.watchlist
    }

    func markWatched(_ item: MediaItem, watched: Bool) {
        if let source = mlinkSource(for: item) {
            updateMlinkWatched(item, source: source, watched: watched)
            return
        }
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
        let mlinkItems = items.filter { mlinkSource(for: $0) != nil }
        let localItems = items.filter { mlinkSource(for: $0) == nil }

        // Mlink 条目只同步用户意图；实际播放与进度仍由网页播放器上报，桌面端不会取流或解码。
        mlinkItems.forEach { markWatched($0, watched: watched) }

        guard !localItems.isEmpty else { return }
        guard let mediaRepository else { return }
        var hadError = false
        var clearedWatchlistItems: [MediaItem] = []
        for item in localItems {
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
        scheduleEmbyPlayedSync(localItems, played: watched)
        syncTraktHistory(localItems, watched: watched)
        clearedWatchlistItems.forEach { syncTraktWatchlist($0, add: false) }
        if hadError {
            alert = AppAlert(title: "部分更新失败", message: "有条目的观看状态未能更新，请检查数据库状态。")
        } else {
            showFloatingNotice(
                title: watched ? "已标记为已观看" : "已标记为未观看",
                message: "\(localItems.count) 个本地内容",
                kind: .success,
                duration: 3.2
            )
        }
    }

    // MARK: - 批量选择操作（C2）

    // 以下选择态方法委托给 SelectionStore；保留方法名与签名以兼容既有调用方。
    // 选择态委托 + 批量动作（toggleSelectionMode / setSelection / batchMarkWatched /
    // batchSetWatchlist / batchUpdateRating / batchClearPlaybackHistory / batchRemoveFromLibrary 等）
    // 已拆到 AppState+BatchSelection.swift（缩小本超大文件）。

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
        if let source = mlinkSource(for: item) {
            updateMlinkPreference(item, source: source, update: .rating(rating))
            return
        }
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

    func updateRatingInMemory(id: String, rating: Double?) {
        func updated(_ item: MediaItem) -> MediaItem {
            guard item.id == id else { return item }
            var copy = item
            copy.userRating = rating
            copy.updatedAt = Date()
            return copy
        }

        items = items.map(updated)
        cachedItemsByID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        musicQueue = musicQueue.map(updated)
        if let parentID = items.first(where: { $0.id == id })?.parentID,
           let children = cachedChildrenByParentID[parentID] {
            cachedChildrenByParentID[parentID] = children.map(updated)
        }
        cachedTopLevelItems = cachedTopLevelItems.map(updated)
        cachedPrivateTopLevelItems = cachedPrivateTopLevelItems.map(updated)
        cachedMusicTracks = cachedMusicTracks.map(updated)
        cachedMusicTracksByID = Dictionary(uniqueKeysWithValues: cachedMusicTracks.map { ($0.id, $0) })
        if cachedMusicTracksByID[id] != nil {
            // 音乐曲目评级同样是乐观更新：同步刷新音乐分区基表与内容指纹。
            rebuildMusicSectionCaches()
        }
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
            if metadata.externalID?.hasPrefix("tmdb:") == true || source.hasPrefix("tmdb") {
                refreshDetailSnapshotAfterMetadataUpdate(itemID: item.id)
            }
        } catch {
            showError("元数据更新失败", error)
        }
    }

    func applyMetadataSearchResult(_ result: MetadataSearchResult, to item: MediaItem) {
        showFloatingNotice(title: "正在应用元数据", message: item.title, kind: .info)
        Task { [weak self] in
            guard let self else { return }
            let service = MetadataSearchService()
            let resolvedResult: MetadataSearchResult
            if result.id.hasPrefix("tmdb:") {
                let language = self.settings.tmdbLanguage.isEmpty ? "zh-CN" : self.settings.tmdbLanguage
                resolvedResult = await service.fetchTMDBDetailResult(
                    for: result,
                    apiKey: self.settings.tmdbAPIKey,
                    language: language
                ) ?? result
            } else {
                resolvedResult = result
            }
            let update = await service.materializedMetadataUpdate(
                for: resolvedResult,
                itemID: item.id,
                artworkDirectory: self.directories?.thumbnails,
                preserveEmbeddedPoster: item.type == .music && item.hasEmbeddedArtwork
            )
            await MainActor.run {
                do {
                    try self.updateMetadata(id: item.id, metadata: update, source: "manual")
                    self.updateMetadataInMemory(id: item.id, metadata: update)
                    if resolvedResult.id.hasPrefix("tmdb:") {
                        self.refreshDetailSnapshotAfterMetadataUpdate(itemID: item.id)
                    }
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

    private func refreshDetailSnapshotAfterMetadataUpdate(itemID: String) {
        guard let refreshed = items.first(where: { $0.id == itemID }) else { return }
        Task { [weak self] in
            _ = await self?.loadDetailSnapshot(for: refreshed, forceRefresh: true)
        }
    }

    func canUndoLatestMetadataCorrection(for item: MediaItem) -> Bool {
        metadataCorrectionStore.correctionCount(forMediaID: item.id) > 0
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
        guard let database, let mediaRepository, metadataCorrectionStore.isAvailable else { return }
        do {
            let records = try metadataCorrectionStore.latestUndoableBatch(mediaID: item.id)
            guard let batchID = records.first?.batchID, !records.isEmpty else {
                showFloatingNotice(title: "没有可撤销的元数据修正", message: item.title, kind: .info)
                return
            }
            let values = Dictionary(uniqueKeysWithValues: records.map { ($0.field, $0.oldValue) })
            try database.transaction {
                try mediaRepository.restoreMetadataValues(id: item.id, values: values)
                try metadataCorrectionStore.persistBatchUndone(batchID: batchID)
            }
            reload()
            showFloatingNotice(title: "已撤销元数据修正", message: item.title, kind: .success)
        } catch {
            showError("撤销元数据失败", error)
        }
    }

    func undoMetadataCorrectionBatch(_ batch: MetadataCorrectionBatchSummary) {
        guard let database, let mediaRepository, metadataCorrectionStore.isAvailable else { return }
        do {
            let records = try metadataCorrectionStore.records(batchID: batch.batchID, mediaID: batch.mediaID)
            guard !records.isEmpty else {
                showFloatingNotice(title: "没有可撤销的元数据修正", message: displayTitleForMediaID(batch.mediaID), kind: .info)
                return
            }
            let values = Dictionary(uniqueKeysWithValues: records.map { ($0.field, $0.oldValue) })
            try database.transaction {
                try mediaRepository.restoreMetadataValues(id: batch.mediaID, values: values)
                try metadataCorrectionStore.persistBatchUndone(batchID: batch.batchID)
            }
            reload()
            showFloatingNotice(title: "已撤销元数据修正", message: displayTitleForMediaID(batch.mediaID), kind: .success)
        } catch {
            showError("撤销元数据失败", error)
        }
    }

    // 同步冲突处理（resolveSyncConflict / resolveTraktSyncConflictUsingLocal / ignoreSyncConflict +
    // remoteMutation / localMutation / pushLocalMutationToTrakt / applyRemoteMutationInMemory 等）
    // 已拆到 AppState+SyncConflictResolution.swift（缩小本超大文件）。
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
    func updateMetadata(id: String, metadata: MediaMetadataUpdate, source: String) throws -> [MetadataCorrectionFieldChange] {
        guard let mediaRepository else { return [] }
        let changes = try mediaRepository.updateMetadata(id: id, metadata: metadata)
        if !changes.isEmpty {
            try metadataCorrectionStore.persistRecord(mediaID: id, changes: changes, source: source)
            metadataCorrectionStore.noteRecorded(mediaID: id, changeCount: changes.count)
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

    // 音乐元数据获取/补全/写回/歌词（fetchAllMusicMetadata / supplementMissingMetadataFromHealth /
    // performMetadataSupplement / writeMusicTagsToSourceIfPossible / fetchLyricsIfPossible 等）
    // 已拆到 AppState+MetadataSupplement.swift（缩小本超大文件）。
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

    func setAppLanguage(_ language: AppLanguage) {
        guard settings.appLanguage != language else { return }
        settings.appLanguage = language
        saveSettings()
        alert = AppAlert(title: language.nativeRestartTitle, message: language.nativeRestartMessage)
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
        Task { [weak self] in
            do {
                let backupURL = try await database.createBackupAsync(in: directories.databaseBackups)
                await MainActor.run {
                    self?.alert = AppAlert(
                        title: "数据库备份完成",
                        message: "已创建一致性备份：\(backupURL.lastPathComponent)"
                    )
                }
            } catch {
                await MainActor.run {
                    self?.showError("数据库备份失败", error)
                }
            }
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
            privacyLockState.configurePINAndUnlock()
            return true
        } catch {
            showError("隐私密码设置失败", error)
            return false
        }
    }

    func setPrivacyPINAsync(_ pin: String) async -> Bool {
        do {
            try await privacyLockService.setPINAsync(pin)
            settings.privacyPINEnabled = true
            await settingsStore.saveAsync(settings)
            privacyLockState.configurePINAndUnlock()
            return true
        } catch {
            showError("隐私密码设置失败", error)
            return false
        }
    }

    func verifyPrivacyPIN(_ pin: String) -> Bool {
        guard unlockPrivacyIfPINMatches(pin) else {
            alert = AppAlert(title: "无法解锁", message: "密码不正确，请输入 4 到 8 位数字密码。")
            return false
        }
        return true
    }

    func verifyPrivacyPINAsync(_ pin: String) async -> Bool {
        guard await unlockPrivacyIfPINMatchesAsync(pin) else {
            alert = AppAlert(title: "无法解锁", message: "密码不正确，请输入 4 到 8 位数字密码。")
            return false
        }
        return true
    }

    func unlockPrivacyIfPINMatches(_ pin: String) -> Bool {
        guard privacyLockService.verify(pin: pin) else {
            return false
        }
        settings.privacyPINEnabled = true
        settingsStore.save(settings)
        privacyLockState.configurePINAndUnlock()
        publishVaultUnlockSession()
        return true
    }

    func unlockPrivacyIfPINMatchesAsync(_ pin: String) async -> Bool {
        guard await privacyLockService.verifyAsync(pin: pin) else {
            return false
        }
        settings.privacyPINEnabled = true
        await settingsStore.saveAsync(settings)
        privacyLockState.configurePINAndUnlock()
        publishVaultUnlockSession()
        return true
    }

    func unlockPrivacyWithBiometrics() {
        Task { @MainActor in
            do {
                let unlocked = try await privacyLockService.unlockWithBiometrics()
                privacyLockState.setUnlocked(unlocked)
                if unlocked {
                    privacyLockState.setPINConfigured(true)
                    publishVaultUnlockSession()
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
        privacyLockState.lock()
        clearVaultUnlockSession()
        clearDetailNavigation()
        stopPlaybackIfPrivate()
    }

    /// 发布并开始续期一次解锁会话。写失败只影响网页侧的可见性，绝不能让 App 的
    /// 解锁本身失败——所以这里不抛错、不弹窗。
    private func publishVaultUnlockSession() {
        guard let vaultUnlockSessionStore else { return }
        vaultUnlockSessionStore.publish()
        vaultUnlockRefreshTask?.cancel()
        vaultUnlockRefreshTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(VaultUnlockSessionStore.refreshInterval * 1_000_000_000))
                guard !Task.isCancelled else { return }
                guard let self, self.privacyUnlocked else { return }
                self.vaultUnlockSessionStore?.publish()
            }
        }
    }

    /// 把首页推荐名单发布给服务进程（网页首页的同名栏目按它来排）。
    ///
    /// 只发布**顺序**：保险库条目在这里先剔一道（服务端还会再剔一道），除此之外
    /// 名单里没有标题、路径、封面，也没有任何痕迹——谁看到哪儿、谁收藏了什么，
    /// 网页那一侧读的永远是它自己的逐用户表。
    ///
    /// 写盘失败只影响网页的取材（它会回落到服务端自己的推导），所以这里不抛错、
    /// 不弹窗，也不阻塞首页那一帧。
    func publishHomeRecommendations(_ sections: [(section: HomeRecommendationSection, items: [MediaItem])]) {
        guard let homeRecommendationStore else { return }
        let entries: [HomeRecommendationSnapshot.Entry] = sections.compactMap { section in
            let ids = section.items
                .filter { $0.type != .privateCollection && !isPrivateItem($0) }
                .map(\.id)
            guard !ids.isEmpty else { return nil }
            return .init(section: section.section, itemIDs: ids)
        }
        guard !entries.isEmpty else { return }
        let digest = entries
            .map { "\($0.sectionID):\($0.itemIDs.joined(separator: ","))" }
            .joined(separator: "|")
        let now = Date()
        let isStale = publishedHomeRecommendationsAt
            .map { now.timeIntervalSince($0) >= HomeRecommendationSnapshotStore.lifetime / 3 } ?? true
        guard digest != publishedHomeRecommendationDigest || isStale else { return }
        publishedHomeRecommendationDigest = digest
        publishedHomeRecommendationsAt = now
        Task.detached(priority: .utility) {
            homeRecommendationStore.publish(entries: entries)
        }
    }

    /// 上锁、移除口令、退出——任何一条路径都要立刻收回网页侧的可见性。
    func clearVaultUnlockSession() {
        vaultUnlockRefreshTask?.cancel()
        vaultUnlockRefreshTask = nil
        vaultUnlockSessionStore?.clear()
    }

    func removePrivacyPIN() {
        guard privacyUnlocked else {
            alert = AppAlert(title: "需要先解锁", message: "请先解锁\(settings.privacyVaultName)，再移除保险库密码。")
            return
        }
        privacyLockService.removePIN()
        settings.privacyPINEnabled = false
        settingsStore.save(settings)
        privacyLockState.clearPINConfiguration()
        clearVaultUnlockSession()
        clearDetailNavigation()
        stopPlaybackIfPrivate()
    }

    func removePrivacyPINAsync() async {
        guard privacyUnlocked else {
            alert = AppAlert(title: "需要先解锁", message: "请先解锁\(settings.privacyVaultName)，再移除保险库密码。")
            return
        }
        await privacyLockService.removePINAsync()
        settings.privacyPINEnabled = false
        await settingsStore.saveAsync(settings)
        privacyLockState.clearPINConfiguration()
        clearVaultUnlockSession()
        clearDetailNavigation()
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
        embyRestrictionNoticeStore.presentNotice(
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
        localFileEventMonitorConfigurationID = UUID()
        let configurationID = localFileEventMonitorConfigurationID
        guard settings.automaticScanInterval != .disabled else {
            localFileEventMonitor.update(paths: [])
            return
        }
        let sourceSnapshots = sources
        Task { @MainActor [weak self] in
            let paths = await Self.localFileEventMonitorPaths(in: sourceSnapshots)
            guard let self,
                  self.localFileEventMonitorConfigurationID == configurationID,
                  self.settings.automaticScanInterval != .disabled else {
                return
            }
            self.localFileEventMonitor.update(paths: paths)
        }
    }

    nonisolated static func localFileEventMonitorPaths(in sources: [MediaSource]) async -> [String] {
        await BlockingIOExecutor.run {
            sources.compactMap { source -> String? in
                guard source.autoScan,
                      source.sourceKind == .local,
                      FileAccessService.isReachableDirectory(source.path) else {
                    return nil
                }
                return source.path
            }
        }
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

        tmdbMatchState.begin()
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
            let result = await service.fetchTMDBDetailResult(for: best.result, apiKey: apiKey, language: language) ?? best.result
            let update = await service.materializedMetadataUpdate(
                for: result,
                itemID: item.id,
                artworkDirectory: artworkDirectory
            )
            guard !Task.isCancelled else { break }
            applyMetadata(update, to: item, source: "tmdb-match")
            matched += 1
        }

        tmdbMatchState.finish()
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

    func bestTMDBVideoMatch(
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
        var singletonResultIDs: Set<String> = []

        let searchLimit: Int
        switch settings.metadataMatchTolerance {
        case .loose:
            searchLimit = 16
        case .standard:
            searchLimit = 10
        case .strict:
            searchLimit = 6
        }

        for query in queries.prefix(searchLimit) {
            if Task.isCancelled { break }
            do {
                let results = try await service.searchTMDB(
                    query: query,
                    itemType: item.type,
                    apiKey: apiKey,
                    language: language
                )
                if results.count == 1, Self.isSpecificTMDBQuery(query) {
                    singletonResultIDs.insert(results[0].id)
                }
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

        let best = MetadataMatchScorer.bestVideoMatch(for: item, in: allResults, matchedQueries: matchedQueries)
        // 「唯一解」优先：某个具体（非泛词）查询在 TMDB 上只召回一条结果，本身就是强证据——
        // TMDB 已用清洗后的剧名把候选收敛到唯一一部。跨语言库（文件名是罗马音/英文、而 TMDB 在
        // zh-CN 下返回中文/日文标题）里标题字符串相似度≈0，绝不能再拿相似度阈值把这种唯一命中挡掉，
        // 否则就出现用户反馈的「手动一搜是唯一解、自动却匹配不上」。
        if !singletonResultIDs.isEmpty {
            // 全局唯一＝所有具体查询都只指向同一部；此时相似度多低都接受（宽松档）。
            // 出现多个不同的唯一命中（罕见，多为同名作品）才退回到要一定相似度来消歧。
            let isGloballyUnique = Set(singletonResultIDs).count == 1
            let singletonMatches = allResults
                .filter { singletonResultIDs.contains($0.id) }
                .compactMap { result in
                    MetadataMatchScorer.bestVideoMatch(for: item, in: [result], matchedQueries: matchedQueries)
                }
            let singletonFloor = isGloballyUnique ? 0.0 : 0.30
            if let singletonBest = singletonMatches.max(by: { $0.confidence < $1.confidence }),
               singletonBest.confidence >= singletonFloor {
                // 仅当另有「分数明显更高、且确实是另一部」的多候选最佳解时才让路，
                // 避免唯一命中抢走本应胜出的高置信标题匹配。
                let betterDistinctCandidateWins = best != nil
                    && best!.result.id != singletonBest.result.id
                    && best!.confidence >= settings.metadataMatchTolerance.videoThreshold
                    && singletonBest.confidence < best!.confidence * 0.82
                if !betterDistinctCandidateWins {
                    // 唯一命中给到「刚好越过当前宽容度阈值」的置信度，确保上层 guard 放行；
                    // 宽松档(0.42)→0.52 放行，标准/严格档仍按各自更高阈值自然保持谨慎。
                    return (singletonBest.result, max(singletonBest.confidence, 0.52))
                }
            }
        }

        return best
    }

    private static func isSpecificTMDBQuery(_ query: String) -> Bool {
        let normalized = MetadataMatchScorer.normalized(query)
        guard normalized.count >= 3 else { return false }
        if normalized.range(of: #"^\d+$"#, options: .regularExpression) != nil { return false }
        let weakQueries: Set<String> = [
            "season", "series", "show", "tv", "anime", "movie", "episode",
            "第 季", "第 集", "全集", "完结", "完結"
        ]
        return !weakQueries.contains(normalized)
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

}
