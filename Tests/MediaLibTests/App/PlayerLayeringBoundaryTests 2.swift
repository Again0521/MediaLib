import XCTest

final class PlayerLayeringBoundaryTests: XCTestCase {
    func testPlayerViewNoLongerOwnsMpvControllerImplementation() throws {
        let root = repositoryRoot()
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(playerView.contains("final class MpvPlayerController"))
        XCTAssertTrue(controller.contains("final class MpvPlayerController"))
        XCTAssertFalse(controller.contains("struct PlayerView: View"))
    }

    func testVideoPlaybackControllingCommandSurfaceLivesInAppLayer() throws {
        let root = repositoryRoot()
        let protocolFile = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPlaybackControlling.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(protocolFile.contains("protocol VideoPlaybackControlling"))
        XCTAssertTrue(protocolFile.contains("extension MpvPlayerController: VideoPlaybackControlling"))
        XCTAssertTrue(playerView.contains("VideoPlaybackControlling"))
        XCTAssertFalse(playerView.contains("protocol VideoPlaybackControlling"))
    }

    func testDetailNavigationStoreOwnsDetailSelectionState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/DetailNavigationStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class DetailNavigationStore"))
        XCTAssertTrue(store.contains("@Published private(set) var selectedItem"))
        XCTAssertTrue(store.contains("@Published private(set) var selectedPersonID"))
        XCTAssertTrue(store.contains("@Published private(set) var detailReturnContext"))
        XCTAssertTrue(appState.contains("let detailNavigation = DetailNavigationStore()"))
        XCTAssertFalse(appState.contains("@Published var selectedItem"))
        XCTAssertFalse(appState.contains("@Published var selectedPersonID"))
        XCTAssertFalse(appState.contains("private var detailNavigationHistory"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testVideoCollectionStoreOwnsVideoCollectionState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoCollectionStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class VideoCollectionStore"))
        XCTAssertTrue(store.contains("@Published private(set) var smartCollections"))
        XCTAssertTrue(store.contains("@Published private(set) var manualCollections"))
        XCTAssertTrue(appState.contains("let videoCollectionStore: VideoCollectionStore"))
        XCTAssertFalse(appState.contains("@Published var videoSmartCollections"))
        XCTAssertFalse(appState.contains("@Published var videoManualCollections"))
        XCTAssertFalse(appState.contains("upsertVideoManualCollectionInMemory"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testVideoManualCollectionCreationStoreOwnsCreationRequestState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoManualCollectionCreationStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class VideoManualCollectionCreationStore"))
        XCTAssertTrue(store.contains("@Published private(set) var request"))
        XCTAssertTrue(appState.contains("let videoManualCollectionCreation = VideoManualCollectionCreationStore()"))
        XCTAssertFalse(appState.contains("@Published var videoManualCollectionCreationRequest"))
        XCTAssertFalse(store.contains("VideoManualCollectionRepository"))
        XCTAssertFalse(store.contains("VideoManualCollectionStore"))
        XCTAssertFalse(store.contains("VideoCollectionStore"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testVideoOfflineSubscriptionLimitStoreOwnsLimitRequestState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoOfflineSubscriptionLimitStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class VideoOfflineSubscriptionLimitStore"))
        XCTAssertTrue(store.contains("@Published private(set) var request"))
        XCTAssertTrue(appState.contains("let videoOfflineSubscriptionLimit = VideoOfflineSubscriptionLimitStore()"))
        XCTAssertFalse(appState.contains("@Published var videoOfflineSubscriptionLimitRequest"))
        XCTAssertFalse(store.contains("VideoOfflineCacheStore"))
        XCTAssertFalse(store.contains("VideoOfflineSubscriptionRepository"))
        XCTAssertFalse(store.contains("saveVideoOfflineSubscription"))
        XCTAssertFalse(store.contains("cacheableVideoCandidate"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testEmbyRestrictionNoticeStoreOwnsRestrictionSheetState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/EmbyRestrictionNoticeStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class EmbyRestrictionNoticeStore"))
        XCTAssertTrue(store.contains("@Published private(set) var notice"))
        XCTAssertTrue(appState.contains("let embyRestrictionNoticeStore = EmbyRestrictionNoticeStore()"))
        XCTAssertFalse(appState.contains("@Published var embyRestrictionNotice"))
        XCTAssertFalse(store.contains("EmbyService("))
        XCTAssertFalse(store.contains("isClientRestriction"))
        XCTAssertFalse(store.contains("RemoteConnectorStore"))
        XCTAssertFalse(store.contains("URLSession"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testStartupErrorStoreOwnsStartupErrorState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/StartupErrorStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class StartupErrorStore"))
        XCTAssertTrue(store.contains("@Published private(set) var message"))
        XCTAssertTrue(appState.contains("let startupErrorStore = StartupErrorStore()"))
        XCTAssertFalse(appState.contains("@Published var startupError"))
        XCTAssertFalse(store.contains("FileAccessService"))
        XCTAssertFalse(store.contains("DatabaseManager"))
        XCTAssertFalse(store.contains("SourceRepository"))
        XCTAssertFalse(store.contains("MediaRepository"))
        XCTAssertFalse(store.contains("VideoOfflineCacheStore"))
        XCTAssertFalse(store.contains("AppSettingsStore"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testTMDBMatchStateStoreOwnsMatchingFlagState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/TMDBMatchStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class TMDBMatchStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isMatching"))
        XCTAssertTrue(appState.contains("let tmdbMatchState = TMDBMatchStateStore()"))
        XCTAssertFalse(appState.contains("@Published var isMatchingTMDB"))
        XCTAssertFalse(store.contains("MetadataSearchService"))
        XCTAssertFalse(store.contains("TMDBMetadataClient"))
        XCTAssertFalse(store.contains("TMDBEnrichmentService"))
        XCTAssertFalse(store.contains("MediaRepository"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testMusicMetadataActivityStoreOwnsMetadataProgressState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MusicMetadataActivityStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class MusicMetadataActivityStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isFetching"))
        XCTAssertTrue(store.contains("@Published private(set) var isSupplementing"))
        XCTAssertTrue(store.contains("@Published private(set) var fetchProgress"))
        XCTAssertTrue(appState.contains("let musicMetadataActivity = MusicMetadataActivityStore()"))
        XCTAssertFalse(appState.contains("@Published var isFetchingMusicMetadata"))
        XCTAssertFalse(appState.contains("@Published var isSupplementingMetadata"))
        XCTAssertFalse(appState.contains("@Published var musicMetadataFetchProgress"))
        XCTAssertFalse(store.contains("MetadataSearchService"))
        XCTAssertFalse(store.contains("MusicMetadataProvider"))
        XCTAssertFalse(store.contains("BackgroundTaskSnapshot"))
        XCTAssertFalse(store.contains("MediaRepository"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testPrivacyLockStateStoreOwnsVaultLockFlags() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/PrivacyLockStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class PrivacyLockStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isUnlocked"))
        XCTAssertTrue(store.contains("@Published private(set) var isPINConfigured"))
        XCTAssertTrue(appState.contains("let privacyLockState = PrivacyLockStateStore()"))
        XCTAssertFalse(appState.contains("@Published var privacyUnlocked"))
        XCTAssertFalse(appState.contains("@Published var privacyPINConfigured"))
        XCTAssertFalse(store.contains("PrivacyLockService"))
        XCTAssertFalse(store.contains("AppSettingsStore"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("settings"))
        XCTAssertFalse(store.contains("stopPlaybackIfPrivate"))
        XCTAssertFalse(store.contains("clearDetailNavigation"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testFloatingNoticeStoreOwnsVisibleNoticeStateOnly() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/FloatingNoticeStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class FloatingNoticeStore"))
        XCTAssertTrue(store.contains("@Published private(set) var notices"))
        XCTAssertTrue(appState.contains("let floatingNoticeStore = FloatingNoticeStore()"))
        XCTAssertFalse(appState.contains("@Published private(set) var floatingNotices"))
        XCTAssertFalse(store.contains("PendingFloatingNotice"))
        XCTAssertFalse(store.contains("floatingNoticeQueue"))
        XCTAssertFalse(store.contains("foregroundFallbackNotices"))
        XCTAssertFalse(store.contains("SystemNotificationCenter"))
        XCTAssertFalse(store.contains("NSApplication"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("UserDefaults"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testSakuraEasterEggStateStoreOwnsTransientLaunchStateOnly() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/SakuraEasterEggStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let externalPlayback = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState+ExternalPlayback.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class SakuraEasterEggStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isActive"))
        XCTAssertTrue(store.contains("private(set) var shownThisLaunch"))
        XCTAssertTrue(appState.contains("let sakuraEasterEggState = SakuraEasterEggStateStore()"))
        XCTAssertFalse(appState.contains("@Published var sakuraEasterEggActive"))
        XCTAssertTrue(appState.contains("var sakuraEasterEggTask: Task<Void, Never>?"))
        XCTAssertTrue(externalPlayback.contains("triggerSakuraEasterEggIfNeeded"))
        XCTAssertTrue(externalPlayback.contains("アゲイン"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("SakuraFallView"))
        XCTAssertFalse(store.contains("アゲイン"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testOnboardingReplayStoreOwnsReplayRequestOnly() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/OnboardingReplayStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/ContentView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class OnboardingReplayStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isReplayRequested"))
        XCTAssertTrue(appState.contains("let onboardingReplay = OnboardingReplayStore()"))
        XCTAssertFalse(appState.contains("@Published var onboardingReplayRequested"))
        XCTAssertTrue(contentView.contains(".onChange(of: appState.onboardingReplayRequested)"))
        XCTAssertFalse(store.contains("ContentView"))
        XCTAssertFalse(store.contains("OnboardingView"))
        XCTAssertFalse(store.contains("runPostOnboardingStartupTasksIfNeeded"))
        XCTAssertFalse(store.contains("AppSettings"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testLastfmAuthorizationStateStoreOwnsAuthorizingFlagOnly() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/LastfmAuthorizationStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let lastfmExtension = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState+Lastfm.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class LastfmAuthorizationStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isAuthorizing"))
        XCTAssertTrue(appState.contains("let lastfmAuthorizationState = LastfmAuthorizationStateStore()"))
        XCTAssertFalse(appState.contains("@Published var isLastfmAuthorizing"))
        XCTAssertTrue(lastfmExtension.contains("guard !isLastfmAuthorizing else { return }"))
        XCTAssertTrue(lastfmExtension.contains("defer { self.isLastfmAuthorizing = false }"))
        XCTAssertFalse(store.contains("LastfmScrobbleService"))
        XCTAssertFalse(store.contains("lastfmPendingAuthToken"))
        XCTAssertFalse(store.contains("NSWorkspace"))
        XCTAssertFalse(store.contains("AppSettings"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testTraktSyncActivityStoreOwnsConnectionAndImportFlagsOnly() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/TraktSyncActivityStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let traktExtension = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState+TraktSync.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class TraktSyncActivityStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isConnecting"))
        XCTAssertTrue(store.contains("@Published private(set) var isImporting"))
        XCTAssertTrue(appState.contains("let traktSyncActivity = TraktSyncActivityStore()"))
        XCTAssertFalse(appState.contains("@Published var isTraktConnecting"))
        XCTAssertFalse(appState.contains("@Published var isImportingTraktState"))
        XCTAssertTrue(traktExtension.contains("guard !isTraktConnecting else { return }"))
        XCTAssertTrue(traktExtension.contains("defer { self.isTraktConnecting = false }"))
        XCTAssertTrue(traktExtension.contains("guard !isImportingTraktState else { return }"))
        XCTAssertTrue(traktExtension.contains("defer { self.isImportingTraktState = false }"))
        XCTAssertFalse(store.contains("TraktService"))
        XCTAssertFalse(store.contains("traktPollTask"))
        XCTAssertFalse(store.contains("TraktRemoteState"))
        XCTAssertFalse(store.contains("SyncConflict"))
        XCTAssertFalse(store.contains("RemoteConnectorAccount"))
        XCTAssertFalse(store.contains("NSWorkspace"))
        XCTAssertFalse(store.contains("AppSettings"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testThemeRefreshStoreOwnsOnlyRevisionCounters() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/ThemeRefreshStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let musicThemeExtension = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState+MusicTheme.swift"),
            encoding: .utf8
        )
        let contentView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/ContentView.swift"),
            encoding: .utf8
        )
        let musicPlayerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/MusicPlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class ThemeRefreshStore"))
        XCTAssertTrue(store.contains("@Published private(set) var themeRevision"))
        XCTAssertTrue(store.contains("@Published private(set) var musicThemeRevision"))
        XCTAssertTrue(appState.contains("let themeRefresh = ThemeRefreshStore()"))
        XCTAssertFalse(appState.contains("@Published var themeRevision"))
        XCTAssertFalse(appState.contains("@Published var musicThemeRevision"))
        XCTAssertTrue(musicThemeExtension.contains("themeRevision &+= 1"))
        XCTAssertTrue(musicThemeExtension.contains("musicThemeRevision &+= 1"))
        XCTAssertTrue(contentView.contains(".onChange(of: appState.themeRevision)"))
        XCTAssertTrue(contentView.contains(".id(appState.themeRevision)"))
        XCTAssertTrue(musicPlayerView.contains(".id(appState.musicThemeRevision)"))
        XCTAssertFalse(store.contains("AppColors"))
        XCTAssertFalse(store.contains("AppThemePreset"))
        XCTAssertFalse(store.contains("MusicThemeConfigStore"))
        XCTAssertFalse(store.contains("NSApp"))
        XCTAssertFalse(store.contains("NSWindow"))
        XCTAssertFalse(store.contains("Color"))
        XCTAssertFalse(store.contains("View"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testMediaSearchIndexStateStoreOwnsOnlySearchIndexState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MediaSearchIndexStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )
        let libraryView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/LibraryView.swift"),
            encoding: .utf8
        )
        let globalSearchView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/GlobalSearchView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class MediaSearchIndexStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var detailMetadataGapsByMediaID"))
        XCTAssertTrue(store.contains("@Published private(set) var detailSearchTermsByMediaID"))
        XCTAssertTrue(store.contains("@Published private(set) var revision"))
        XCTAssertTrue(appState.contains("let mediaSearchIndexState = MediaSearchIndexStateStore()"))
        XCTAssertFalse(appState.contains("@Published private(set) var detailMetadataGapsByMediaID"))
        XCTAssertFalse(appState.contains("@Published private(set) var detailSearchTermsByMediaID"))
        XCTAssertFalse(appState.contains("@Published private(set) var mediaSearchRevision"))
        XCTAssertTrue(appState.contains("private(set) var detailMetadataGapsByMediaID"))
        XCTAssertTrue(appState.contains("private(set) var detailSearchTermsByMediaID"))
        XCTAssertTrue(appState.contains("private(set) var mediaSearchRevision"))
        XCTAssertTrue(libraryView.contains("appState.mediaSearchRevision"))
        XCTAssertTrue(globalSearchView.contains("appState.mediaSearchRevision"))
        XCTAssertFalse(store.contains("MediaDetailRepository"))
        XCTAssertFalse(store.contains("matchesMediaSearch"))
        XCTAssertFalse(store.contains("mediaSearchFieldsCache"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("DatabaseManager"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("View"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testQuickPreviewStoreOwnsQuickPreviewSheetState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/QuickPreviewStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class QuickPreviewStore"))
        XCTAssertTrue(store.contains("@Published private(set) var item"))
        XCTAssertTrue(appState.contains("let quickPreview = QuickPreviewStore()"))
        XCTAssertFalse(appState.contains("@Published var quickPreviewItem"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testAppUpdateStateStoreOwnsUpdatePromptState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppUpdateStateStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class AppUpdateStateStore"))
        XCTAssertTrue(store.contains("@Published private(set) var availableUpdate"))
        XCTAssertTrue(store.contains("@Published private(set) var isCheckingForUpdates"))
        XCTAssertTrue(appState.contains("let appUpdateState = AppUpdateStateStore()"))
        XCTAssertFalse(appState.contains("@Published var availableUpdate"))
        XCTAssertFalse(appState.contains("@Published var isCheckingForUpdates"))
        XCTAssertFalse(store.contains("URLSession"))
        XCTAssertFalse(store.contains("UserDefaults"))
        XCTAssertFalse(store.contains("Task<"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testSponsorPromptStoreOwnsSponsorSheetState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/SponsorPromptStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class SponsorPromptStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isShowingInvite"))
        XCTAssertTrue(appState.contains("let sponsorPrompt = SponsorPromptStore()"))
        XCTAssertFalse(appState.contains("@Published var showingSponsorPrompt"))
        XCTAssertFalse(store.contains("UserDefaults"))
        XCTAssertFalse(store.contains("URLSession"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testNetworkStreamPromptStoreOwnsNetworkStreamSheetState() throws {
        let root = repositoryRoot()
        let store = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/NetworkStreamPromptStore.swift"),
            encoding: .utf8
        )
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(store.contains("final class NetworkStreamPromptStore"))
        XCTAssertTrue(store.contains("@Published private(set) var isShowingPrompt"))
        XCTAssertTrue(appState.contains("let networkStreamPrompt = NetworkStreamPromptStore()"))
        XCTAssertFalse(appState.contains("@Published var showingNetworkStreamPrompt"))
        XCTAssertFalse(store.contains("URL("))
        XCTAssertFalse(store.contains("AppAlert"))
        XCTAssertFalse(store.contains("MediaItem"))
        XCTAssertFalse(store.contains("LibMpvClient"))
        XCTAssertFalse(store.contains("MpvPlayerController"))
        XCTAssertFalse(store.contains("NSView"))
        XCTAssertFalse(store.contains("AVPlayer"))
    }

    func testVideoPlaybackEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPlaybackEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoPlaybackEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoPlaybackEngine"))
        XCTAssertTrue(engine.contains("protocol MpvCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("subtitle"))
        XCTAssertFalse(engine.contains("screenshot"))
        XCTAssertFalse(engine.contains("render("))
    }

    func testVideoTrackSelectionEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoTrackSelectionEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoTrackSelectionEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoTrackSelectionEngine"))
        XCTAssertTrue(engine.contains("protocol MpvTrackSelectionTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvTrackSelectionTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("schedule"))
        XCTAssertFalse(engine.contains("screenshot"))
        XCTAssertFalse(engine.contains("vf"))
    }

    func testVideoFrameCommandEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoFrameCommandEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoFrameCommandEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoFrameCommandEngine"))
        XCTAssertTrue(engine.contains("protocol MpvFrameCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvFrameCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("MpvRenderSurface"))
        XCTAssertFalse(engine.contains("captureFramePNGData"))
        XCTAssertFalse(engine.contains("renderView"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("FileManager"))
    }

    func testVideoScreenshotModePolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoScreenshotModePolicy.swift"),
            encoding: .utf8
        )
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoFrameCommandEngine.swift"),
            encoding: .utf8
        )
        let appSettings = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/AppSettings.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum VideoScreenshotModePolicy"))
        XCTAssertTrue(policy.contains("VideoScreenshotMode"))
        XCTAssertTrue(engine.contains("VideoScreenshotModePolicy.mpvArgument"))
        XCTAssertFalse(appSettings.contains("public var mpvArgument: String"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoLoopCommandEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoLoopCommandEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol VideoLoopCommandEngine"))
        XCTAssertTrue(engine.contains("final class MpvVideoLoopCommandEngine"))
        XCTAssertTrue(engine.contains("protocol MpvLoopCommandTransport"))
        XCTAssertTrue(engine.contains("extension LibMpvClient: MpvLoopCommandTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("import AVKit"))
        XCTAssertFalse(engine.contains("MpvRenderSurface"))
        XCTAssertFalse(engine.contains("PlayerABLoopSelection"))
        XCTAssertFalse(engine.contains("currentTime"))
        XCTAssertFalse(engine.contains("TrackPreferenceStore"))
        XCTAssertFalse(engine.contains("FileManager"))
        XCTAssertFalse(engine.contains("vf"))
        XCTAssertFalse(engine.contains("screenshot"))
    }

    func testPlaybackABLoopPolicyStaysInCoreWithoutViewControllerOrMpvOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackABLoopPolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackABLoopPolicy"))
        XCTAssertTrue(policy.contains("enum PlayerABLoopSelection"))
        XCTAssertTrue(controller.contains("PlaybackABLoopPolicy.cycleSelection"))
        XCTAssertFalse(controller.contains("time <= start + 0.20"))
        XCTAssertFalse(playerView.contains("enum PlayerABLoopSelection"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoAudioDeviceReaderLivesInAppLayerAndStaysReadOnly() throws {
        let root = repositoryRoot()
        let reader = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoAudioDeviceReader.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reader.contains("struct MpvAudioDevice"))
        XCTAssertTrue(reader.contains("struct VideoAudioDeviceSnapshot"))
        XCTAssertTrue(reader.contains("protocol VideoAudioDeviceReading"))
        XCTAssertTrue(reader.contains("final class MpvVideoAudioDeviceReader"))
        XCTAssertTrue(reader.contains("protocol MpvAudioDeviceReadTransport"))
        XCTAssertTrue(reader.contains("extension LibMpvClient: MpvAudioDeviceReadTransport"))
        XCTAssertFalse(reader.contains("import SwiftUI"))
        XCTAssertFalse(reader.contains("import AppKit"))
        XCTAssertFalse(reader.contains("import AVKit"))
        XCTAssertFalse(reader.contains("command("))
        XCTAssertFalse(reader.contains("setString"))
        XCTAssertFalse(reader.contains("setDouble"))
        XCTAssertFalse(reader.contains("TrackPreferenceStore"))
        XCTAssertFalse(reader.contains("schedule"))
        XCTAssertFalse(reader.contains("MpvRenderSurface"))
        XCTAssertFalse(reader.contains("screenshot"))
        XCTAssertFalse(reader.contains("vf"))
    }

    func testMpvTrackModelLivesInAppLayerInsteadOfPlayerView() throws {
        let root = repositoryRoot()
        let model = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvTrack.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(model.contains("struct MpvTrack"))
        XCTAssertTrue(model.contains("enum Kind"))
        XCTAssertTrue(model.contains("func withSelection"))
        XCTAssertFalse(playerView.contains("struct MpvTrack"))
        XCTAssertFalse(model.contains("import SwiftUI"))
        XCTAssertFalse(model.contains("import AppKit"))
        XCTAssertFalse(model.contains("import AVKit"))
        XCTAssertFalse(model.contains("MpvRenderSurface"))
        XCTAssertFalse(model.contains("MpvPlayerController"))
    }

    func testMpvVideoSnapshotReaderLivesInAppLayerWithoutViewOrRenderOwnership() throws {
        let root = repositoryRoot()
        let reader = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvVideoSnapshotReader.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(reader.contains("struct MpvChapter"))
        XCTAssertTrue(reader.contains("struct MpvVideoSnapshotRequest"))
        XCTAssertTrue(reader.contains("final class MpvVideoSnapshotReader"))
        XCTAssertFalse(controller.contains("final class MpvVideoSnapshotReader"))
        XCTAssertFalse(controller.contains("struct MpvVideoSnapshotRequest"))
        XCTAssertFalse(reader.contains("import SwiftUI"))
        XCTAssertFalse(reader.contains("import AppKit"))
        XCTAssertFalse(reader.contains("import AVKit"))
        XCTAssertFalse(reader.contains("MpvRenderSurface"))
        XCTAssertFalse(reader.contains("NSView"))
        XCTAssertFalse(reader.contains("captureFramePNGData"))
        XCTAssertFalse(reader.contains("PlayerView"))
        XCTAssertFalse(reader.contains("TrackPreferenceStore"))
    }

    func testTrackLanguageMatcherLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let matcher = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/TrackLanguageMatcher.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(matcher.contains("enum TrackLanguageMatcher"))
        XCTAssertTrue(matcher.contains("static func bestTrack"))
        XCTAssertFalse(controller.contains("private enum TrackLanguageMatcher"))
        XCTAssertFalse(matcher.contains("import SwiftUI"))
        XCTAssertFalse(matcher.contains("import AppKit"))
        XCTAssertFalse(matcher.contains("import AVKit"))
        XCTAssertFalse(matcher.contains("LibMpvClient"))
        XCTAssertFalse(matcher.contains("TrackPreferenceStore"))
        XCTAssertFalse(matcher.contains("ObservableObject"))
        XCTAssertFalse(matcher.contains("@Published"))
        XCTAssertFalse(matcher.contains("command("))
        XCTAssertFalse(matcher.contains("setString"))
        XCTAssertFalse(matcher.contains("NSView"))
    }

    func testMemoryAudioAssetLivesInAppLayerWithoutControllerUIOrMpvOwnership() throws {
        let root = repositoryRoot()
        let asset = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MemoryAudioAsset.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(asset.contains("final class MemoryAudioResourceLoader"))
        XCTAssertTrue(asset.contains("struct MemoryAudioAsset"))
        XCTAssertTrue(asset.contains("enum MemoryAudioResourceLoadingPolicy"))
        XCTAssertFalse(controller.contains("final class MemoryAudioResourceLoader"))
        XCTAssertFalse(controller.contains("private struct MemoryAudioAsset"))
        XCTAssertFalse(asset.contains("import SwiftUI"))
        XCTAssertFalse(asset.contains("import AppKit"))
        XCTAssertFalse(asset.contains("LibMpvClient"))
        XCTAssertFalse(asset.contains("ObservableObject"))
        XCTAssertFalse(asset.contains("@Published"))
        XCTAssertFalse(asset.contains("MpvRenderSurface"))
        XCTAssertFalse(asset.contains("TrackPreferenceStore"))
        XCTAssertFalse(asset.contains("command("))
        XCTAssertFalse(asset.contains("setString"))
    }

    func testMusicPlaybackEngineAdapterLivesInAppLayerAndStaysNarrow() throws {
        let root = repositoryRoot()
        let engine = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MusicPlaybackEngine.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(engine.contains("protocol MusicPlaybackEngine"))
        XCTAssertTrue(engine.contains("final class AVQueueMusicPlaybackEngine"))
        XCTAssertTrue(engine.contains("protocol MusicPlayerTransport"))
        XCTAssertTrue(engine.contains("final class AVQueueMusicPlayerTransport"))
        XCTAssertFalse(engine.contains("import SwiftUI"))
        XCTAssertFalse(engine.contains("import AppKit"))
        XCTAssertFalse(engine.contains("preload"))
        XCTAssertFalse(engine.contains("RouteProxy"))
        XCTAssertFalse(engine.contains("AirPlay"))
    }

    func testVideoAudioFilterPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoAudioFilterPolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoAudioFilterProperty"))
        XCTAssertTrue(policy.contains("enum VideoAudioFilterPolicy"))
        XCTAssertTrue(policy.contains("firequalizer"))
        XCTAssertTrue(policy.contains("MusicEqualizerPreset"))
        XCTAssertTrue(controller.contains("VideoAudioFilterPolicy.property"))
        XCTAssertFalse(controller.contains("setString(\n            \"af\""))
        XCTAssertFalse(controller.contains("setString(\"af\""))
        XCTAssertFalse(controller.contains("firequalizer"))
        XCTAssertFalse(controller.contains("gain_entry"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoFilterChainPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoFilterChainPolicy.swift"),
            encoding: .utf8
        )
        let appSettings = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/AppSettings.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoFilterChainProperty"))
        XCTAssertTrue(policy.contains("enum VideoFilterChainPolicy"))
        XCTAssertTrue(policy.contains("flipFilters(for:"))
        XCTAssertTrue(policy.contains("sharpenFilter(for:"))
        XCTAssertTrue(policy.contains("denoiseFilter(for:"))
        XCTAssertTrue(controller.contains("VideoFilterChainPolicy.property"))
        XCTAssertFalse(controller.contains("setString(\n            \"vf\""))
        XCTAssertFalse(controller.contains("setString(\"vf\""))
        XCTAssertFalse(controller.contains("filters.joined(separator: \",\")"))
        XCTAssertFalse(appSettings.contains("mpvFilters"))
        XCTAssertFalse(appSettings.contains("mpvFilter: String?"))
        XCTAssertFalse(appSettings.contains("hflip"))
        XCTAssertFalse(appSettings.contains("unsharp=la="))
        XCTAssertFalse(appSettings.contains("hqdn3d="))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoSubtitleStylePolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoSubtitleStylePolicy.swift"),
            encoding: .utf8
        )
        let subtitleStyle = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/VideoSubtitleStyle.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoSubtitleStyleProperties"))
        XCTAssertTrue(policy.contains("enum VideoSubtitleStyleProperty"))
        XCTAssertTrue(policy.contains("enum VideoSubtitleStylePolicy"))
        XCTAssertTrue(policy.contains("VideoSubtitleStyle.clampBackground"))
        XCTAssertTrue(policy.contains("colorValue(for:"))
        XCTAssertTrue(controller.contains("VideoSubtitleStylePolicy.playbackProperties"))
        XCTAssertFalse(subtitleStyle.contains("mpvColor"))
        XCTAssertFalse(subtitleStyle.contains("libmpv"))
        XCTAssertFalse(subtitleStyle.contains("sub-color"))
        XCTAssertFalse(controller.contains("setString(\"sub-font\""))
        XCTAssertFalse(controller.contains("setFlag(\"sub-bold\""))
        XCTAssertFalse(controller.contains("setString(\"sub-color\""))
        XCTAssertFalse(controller.contains("setDouble(\"sub-border-size\""))
        XCTAssertFalse(controller.contains("setString(\"sub-back-color\""))
        XCTAssertFalse(controller.contains("String(format: \"#%02X000000\""))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoColorAdjustmentPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoColorAdjustmentPolicy.swift"),
            encoding: .utf8
        )
        let colorAdjustments = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/VideoColorAdjustments.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoColorAdjustmentProperty"))
        XCTAssertTrue(policy.contains("enum VideoColorAdjustmentPolicy"))
        XCTAssertTrue(controller.contains("VideoColorAdjustmentPolicy.properties"))
        XCTAssertFalse(controller.contains("client.setDouble(\"brightness\", colorAdjustments.brightness)"))
        XCTAssertFalse(colorAdjustments.contains("libmpv"))
        XCTAssertFalse(colorAdjustments.contains("`brightness`"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoTimingAdjustmentPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoTimingAdjustmentPolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoTimingAdjustmentProperty"))
        XCTAssertTrue(policy.contains("enum VideoTimingAdjustmentPolicy"))
        XCTAssertTrue(controller.contains("VideoTimingAdjustmentPolicy.properties"))
        XCTAssertTrue(controller.contains("VideoTimingAdjustmentPolicy.audioDelayProperty"))
        XCTAssertTrue(controller.contains("VideoTimingAdjustmentPolicy.subtitleDelayProperty"))
        XCTAssertTrue(controller.contains("VideoTimingAdjustmentPolicy.subtitleScaleProperty"))
        XCTAssertTrue(controller.contains("VideoTimingAdjustmentPolicy.subtitlePositionProperty"))
        XCTAssertFalse(controller.contains("setDouble(\"audio-delay\""))
        XCTAssertFalse(controller.contains("setDouble(\"sub-delay\""))
        XCTAssertFalse(controller.contains("setDouble(\"sub-scale\""))
        XCTAssertFalse(controller.contains("setDouble(\"sub-pos\""))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoPitchCorrectionPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPitchCorrectionPolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoPitchCorrectionProperty"))
        XCTAssertTrue(policy.contains("enum VideoPitchCorrectionPolicy"))
        XCTAssertTrue(controller.contains("VideoPitchCorrectionPolicy.property"))
        XCTAssertFalse(controller.contains("setFlag(\"audio-pitch-correction\""))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testCoreModelsDoNotDocumentPlayerImplementationPropertyNames() throws {
        let root = repositoryRoot()
        let modelsDirectory = root.appendingPathComponent("Sources/MediaLibCore/Models")
        let urls = try FileManager.default.contentsOfDirectory(
            at: modelsDirectory,
            includingPropertiesForKeys: nil
        )
        let contents = try urls
            .filter { $0.pathExtension == "swift" }
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        XCTAssertFalse(contents.contains("libmpv"))
        XCTAssertFalse(contents.contains("tone-mapping"))
        XCTAssertFalse(contents.contains("audio-pitch-correction"))
        XCTAssertFalse(contents.contains("volume-max"))
        XCTAssertFalse(contents.contains("af 链"))
        XCTAssertFalse(contents.contains("mpv 原生支持"))
    }

    func testVideoDebandPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoDebandPolicy.swift"),
            encoding: .utf8
        )
        let appSettings = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/AppSettings.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoDebandProperties"))
        XCTAssertTrue(policy.contains("enum VideoDebandProperty"))
        XCTAssertTrue(policy.contains("enum VideoDebandPolicy"))
        XCTAssertTrue(policy.contains("VideoDebandMode"))
        XCTAssertTrue(controller.contains("VideoDebandPolicy.playbackProperties"))
        XCTAssertFalse(controller.contains("debandMode.threshold"))
        XCTAssertFalse(controller.contains("debandMode.range"))
        XCTAssertFalse(controller.contains("debandMode.grain"))
        XCTAssertFalse(controller.contains("setFlag(\"deband\""))
        XCTAssertFalse(controller.contains("setDouble(\"deband-threshold\""))
        XCTAssertFalse(controller.contains("setDouble(\"deband-range\""))
        XCTAssertFalse(controller.contains("setDouble(\"deband-grain\""))
        XCTAssertFalse(appSettings.contains("public var threshold: Double"))
        XCTAssertFalse(appSettings.contains("public var grain: Double"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoPlaybackPropertyPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoPlaybackPropertyPolicy.swift"),
            encoding: .utf8
        )
        let appSettings = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/AppSettings.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let libMpvClient = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/LibMpvClient.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum VideoPlaybackPropertyPolicy"))
        XCTAssertTrue(policy.contains("enum VideoPlaybackProperty"))
        XCTAssertTrue(policy.contains("aspectOverrideValue"))
        XCTAssertTrue(policy.contains("panscanValue"))
        XCTAssertTrue(policy.contains("hardwareDecodingValue"))
        XCTAssertTrue(controller.contains("VideoPlaybackPropertyPolicy.playbackProperties"))
        XCTAssertTrue(controller.contains("VideoPlaybackPropertyPolicy.aspectOverrideProperty"))
        XCTAssertTrue(controller.contains("VideoPlaybackPropertyPolicy.cropPanscanProperty"))
        XCTAssertTrue(libMpvClient.contains("VideoPlaybackPropertyPolicy.hardwareDecodingProperty"))
        XCTAssertFalse(controller.contains("setString(\"video-aspect-override\""))
        XCTAssertFalse(controller.contains("setDouble(\"panscan\""))
        XCTAssertFalse(controller.contains("setString(\"deinterlace\""))
        XCTAssertFalse(controller.contains("setString(\"video-rotate\""))
        XCTAssertFalse(controller.contains("setString(\"hwdec\""))
        XCTAssertFalse(libMpvClient.contains("setOptionString(\n            \"hwdec\""))
        XCTAssertFalse(appSettings.contains("public var mpvValue: String"))
        XCTAssertFalse(appSettings.contains("public var panscanValue: Double"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testVideoToneMappingPolicyLivesInAppLayerWithoutControllerOrUIOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/VideoToneMappingPolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("struct VideoToneMappingProperty"))
        XCTAssertTrue(policy.contains("enum VideoToneMappingPolicy"))
        XCTAssertTrue(policy.contains("VideoToneMappingMode"))
        XCTAssertTrue(controller.contains("VideoToneMappingPolicy.property"))
        XCTAssertFalse(controller.contains("setString(\"tone-mapping\""))
        XCTAssertFalse(controller.contains("setString(\"tone-mapping\", toneMappingMode.rawValue"))
        XCTAssertFalse(controller.contains("setString(\"tone-mapping\", mode.rawValue"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testPlayerStateProjectionIsGenericAndKeepsControllerCompatibilityAlias() throws {
        let root = repositoryRoot()
        let support = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerControllerSupport.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(support.contains("protocol PlayerStateProjecting"))
        XCTAssertTrue(support.contains("final class PlayerStateProjection<Controller: PlayerStateProjecting, Value: Equatable>"))
        XCTAssertTrue(support.contains("typealias PlayerControllerProjection<Value: Equatable> = PlayerStateProjection<MpvPlayerController, Value>"))
        XCTAssertFalse(support.contains("import AppKit"))
        XCTAssertFalse(support.contains("import SwiftUI"))
        XCTAssertFalse(support.contains("LibMpvClient"))
    }

    func testPlaybackQueuePolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackQueuePolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackQueuePolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackTimelinePolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackTimelinePolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackTimelinePolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackClockPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackClockPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackClockPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackSeekStateStaysInCoreWithoutPlatformImportsOrViewOwnership() throws {
        let root = repositoryRoot()
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )
        let seekState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekState.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(playerView.contains("struct PlaybackSeekState"))
        XCTAssertTrue(seekState.contains("struct PlaybackSeekState"))
        XCTAssertFalse(seekState.contains("import AppKit"))
        XCTAssertFalse(seekState.contains("import SwiftUI"))
        XCTAssertFalse(seekState.contains("import AVKit"))
        XCTAssertFalse(seekState.contains("LibMpvClient"))
    }

    func testPlaybackSeekCoordinatorStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let coordinator = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekCoordinator.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(coordinator.contains("enum PlaybackSeekCoordinator"))
        XCTAssertFalse(coordinator.contains("import AppKit"))
        XCTAssertFalse(coordinator.contains("import SwiftUI"))
        XCTAssertFalse(coordinator.contains("import AVKit"))
        XCTAssertFalse(coordinator.contains("LibMpvClient"))
    }

    func testPendingPlaybackSeekStaysInCoreWithoutPlatformImportsOrControllerPrivateOwnership() throws {
        let root = repositoryRoot()
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let pending = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PendingPlaybackSeek.swift"),
            encoding: .utf8
        )

        XCTAssertFalse(controller.contains("struct PendingTimelineSeek"))
        XCTAssertTrue(pending.contains("struct PendingPlaybackSeek"))
        XCTAssertFalse(pending.contains("import AppKit"))
        XCTAssertFalse(pending.contains("import SwiftUI"))
        XCTAssertFalse(pending.contains("import AVKit"))
        XCTAssertFalse(pending.contains("LibMpvClient"))
    }

    func testPlaybackSeekCommandPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackSeekCommandPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackSeekCommandPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testPlaybackClockSnapshotPolicyStaysInCoreWithoutPlatformImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PlaybackClockSnapshotPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PlaybackClockSnapshotPolicy"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
    }

    func testMusicOutputPolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/MusicOutputPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum MusicOutputPolicy"))
        XCTAssertTrue(policy.contains("effectiveVolume"))
        XCTAssertTrue(policy.contains("softFadeScale"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
    }

    func testPerceptualVolumeScaleStaysInCoreWithoutViewOrPlatformOwnership() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/PerceptualVolumeScale.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum PerceptualVolumeScale"))
        XCTAssertTrue(policy.contains("adjustedVolume"))
        XCTAssertFalse(playerView.contains("enum PerceptualVolumeScale"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("ObservableObject"))
        XCTAssertFalse(policy.contains("@Published"))
    }

    func testMusicPlaybackBufferPolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/MusicPlaybackBufferPolicy.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum MusicPlaybackBufferPolicy"))
        XCTAssertTrue(policy.contains("preferredForwardBufferDuration"))
        XCTAssertTrue(policy.contains("prefersPreciseTiming"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
    }

    func testCyclicModePolicyStaysInCoreWithoutPlatformOrControllerImports() throws {
        let root = repositoryRoot()
        let policy = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLibCore/Models/CyclicModePolicy.swift"),
            encoding: .utf8
        )
        let controller = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/MpvPlayerController.swift"),
            encoding: .utf8
        )
        let playerView = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/Views/PlayerView.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(policy.contains("enum CyclicModePolicy"))
        XCTAssertTrue(policy.contains("next<"))
        XCTAssertTrue(policy.contains("previous<"))
        XCTAssertFalse(controller.contains("private func nextMode"))
        XCTAssertFalse(playerView.contains("private func nextMode"))
        XCTAssertFalse(controller.contains("modes[(index + delta) % modes.count]"))
        XCTAssertFalse(playerView.contains("modes[(index + (clockwise ? 1 : modes.count - 1)) % modes.count]"))
        XCTAssertFalse(policy.contains("import AppKit"))
        XCTAssertFalse(policy.contains("import SwiftUI"))
        XCTAssertFalse(policy.contains("import AVKit"))
        XCTAssertFalse(policy.contains("import AVFoundation"))
        XCTAssertFalse(policy.contains("LibMpvClient"))
        XCTAssertFalse(policy.contains("MpvPlayerController"))
        XCTAssertFalse(policy.contains("AVPlayer"))
    }

    func testAppStateLibraryRemoteSessionScanAndTaskCenterStateAreOwnedByDomainStores() throws {
        let root = repositoryRoot()
        let appState = try String(
            contentsOf: root.appendingPathComponent("Sources/MediaLib/App/AppState.swift"),
            encoding: .utf8
        )

        XCTAssertTrue(appState.contains("let libraryDomain = LibraryDomainStore()"))
        XCTAssertTrue(appState.contains("let remoteConnectorStore = RemoteConnectorStore()"))
        XCTAssertTrue(appState.contains("let playbackSession = PlaybackSessionStore()"))
        XCTAssertTrue(appState.contains("let scanActivity = ScanActivityStore()"))
        XCTAssertTrue(appState.contains("let taskCenter = TaskCenterStore()"))
        XCTAssertTrue(appState.contains("let musicQueueStore = MusicQueueStore()"))
        XCTAssertFalse(appState.contains("@Published var sources"))
        XCTAssertFalse(appState.contains("@Published var items"))
        XCTAssertFalse(appState.contains("@Published private(set) var libraryRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var posterRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var favoriteRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var watchlistRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var ratingRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var videoCacheRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var musicProjectionRevision"))
        XCTAssertFalse(appState.contains("@Published private(set) var musicContentRevision"))
        XCTAssertFalse(appState.contains("@Published var remoteConnectorAccounts"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingEmby"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingJellyfin"))
        XCTAssertFalse(appState.contains("@Published private(set) var isConnectingPlex"))
        XCTAssertFalse(appState.contains("@Published var activePlayerItem"))
        XCTAssertFalse(appState.contains("@Published var videoQueue"))
        XCTAssertFalse(appState.contains("@Published var playbackCommandRequest"))
        XCTAssertFalse(appState.contains("@Published var scanProgress"))
        XCTAssertFalse(appState.contains("@Published var isScanning"))
        XCTAssertFalse(appState.contains("@Published var scanQueueCount"))
        XCTAssertFalse(appState.contains("@Published private(set) var backgroundTasks"))
        XCTAssertFalse(appState.contains("@Published var musicQueue"))
        XCTAssertFalse(appState.contains("@Published var musicRepeatMode"))
        XCTAssertFalse(appState.contains("@Published var musicShuffleEnabled"))
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
