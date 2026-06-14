import MediaLibCore
import SwiftUI

private struct HomeContentSnapshotInput: Sendable {
    let items: [MediaItem]
    let filter: HomeContentFilter
    let searchText: String
    let appliesSearch: Bool
    let limit: Int?
    let watchedThreshold: Double
}

private enum HomeContentFilter: Sendable {
    case none
    case mediaType(MediaType)
    case videoFavorites
    case unwatchedVideos
}

private enum HomeContentSnapshotBuilder {
    static func items(from input: HomeContentSnapshotInput) -> [MediaItem] {
        let trimmedSearch = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let base = filteredItems(from: input)
        let filtered: [MediaItem]
        if input.appliesSearch, !trimmedSearch.isEmpty {
            filtered = base.filter {
                $0.title.localizedCaseInsensitiveContains(trimmedSearch) ||
                ($0.originalTitle?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                ($0.artist?.localizedCaseInsensitiveContains(trimmedSearch) ?? false) ||
                ($0.album?.localizedCaseInsensitiveContains(trimmedSearch) ?? false)
            }
        } else {
            filtered = base
        }
        if let limit = input.limit {
            return Array(filtered.prefix(limit))
        }
        return filtered
    }

    private static func filteredItems(from input: HomeContentSnapshotInput) -> [MediaItem] {
        switch input.filter {
        case .none:
            return input.items
        case .mediaType(let type):
            return input.items.filter { $0.type == type }
        case .videoFavorites:
            return input.items.filter { $0.type != .music && $0.favorite }
        case .unwatchedVideos:
            return input.items.filter { $0.type != .music && !$0.watched && $0.playProgress < input.watchedThreshold }
        }
    }
}

private struct HomeOverviewBoardModel: Identifiable {
    let id: String
    let title: String
    let subtitle: String
    let systemImage: String
    let items: [MediaItem]
    let emptyMessage: String
}

private struct HomeRecommendationProfile {
    var genreWeights: [String: Double] = [:]
    var genreDisplayNames: [String: String] = [:]
    var typeWeights: [MediaType: Double] = [:]
    var signalItemIDs: Set<String> = []

    var hasSignals: Bool {
        !genreWeights.isEmpty || !typeWeights.isEmpty
    }

    var strongestGenre: String? {
        genreWeights
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key.localizedStandardCompare(rhs.key) == .orderedAscending
            }
            .first?
            .key
    }

    var strongestGenreDisplayName: String? {
        guard let strongestGenre else { return nil }
        return genreDisplayNames[strongestGenre] ?? strongestGenre
    }

    var maxGenreWeight: Double {
        genreWeights.values.max() ?? 0
    }

    var maxTypeWeight: Double {
        typeWeights.values.max() ?? 0
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let onOpenHealthCenter: () -> Void
    let onOpenSources: () -> Void
    @State private var searchText = ""
    @State private var visibleHomeItems: [MediaItem] = []
    @State private var visibleHomeItemsKey = ""
    @State private var isPreparingHomeItems = false
    @State private var homeContentRefreshTask: Task<Void, Never>?
    @State private var homeSearchRefreshTask: Task<Void, Never>?
    @State private var restoredOverviewAnchorID: String?
    @State private var overviewBoardsSnapshot: [HomeOverviewBoardModel] = []
    @State private var overviewBoardsKey = ""
    @AppStorage("MediaLib.home.selectedTab") private var selectedTabRaw = HomeTab.overview.rawValue

    init(onOpenHealthCenter: @escaping () -> Void = {}, onOpenSources: @escaping () -> Void = {}) {
        self.onOpenHealthCenter = onOpenHealthCenter
        self.onOpenSources = onOpenSources
    }

    private var selectedTab: HomeTab {
        get { HomeTab(rawValue: selectedTabRaw) ?? .overview }
        nonmutating set { selectedTabRaw = newValue.rawValue }
    }

    var body: some View {
        let tab = currentTab
        let gridItems = displayedHomeItems(for: tab)
        // 首页搜索框现在即"搜索全部媒体"：有输入时显示跨影音的全局结果（替代海报型分区路径）。
        let isSearching = !searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty

        Group {
            if !isSearching, !appState.sources.isEmpty, isPosterTab(tab), !gridItems.isEmpty {
                // 首页海报型 tab 走原生 List 虚拟化；页头、扫描进度、标签栏和分区标题作为前导行随内容滚动。
                PosterGridList(
                    items: gridItems,
                    bottomInset: gridBottomInset,
                    showsDeletePlaybackHistory: tab == .continueWatching || tab == .nextUp,
                    restoreAnchorID: appState.selectedItemReturnAnchorID,
                    onDidRestoreAnchor: { appState.selectedItemReturnAnchorID = nil }
                ) {
                    VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                        header
                        if let progress = appState.scanProgress, appState.isScanning {
                            ScanProgressView(progress: progress)
                        }
                        HomeTabBar(tabs: enabledTabs, selection: tabSelection)
                        Text(displayName(for: tab))
                            .font(.title2.weight(.semibold))
                    }
                }
            } else {
                ScrollViewReader { scrollProxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                            header

                            if let progress = appState.scanProgress, appState.isScanning {
                                ScanProgressView(progress: progress)
                            }

                            if appState.sources.isEmpty {
                                EmptyLibraryView(onOpenSources: onOpenSources)
                            } else if isSearching {
                                GlobalSearchView(query: searchText) { item in
                                    if item.type == .music {
                                        appState.play(item)
                                    } else {
                                        appState.selectedItemReturnAnchorID = item.id
                                        appState.selectedItem = item
                                    }
                                }
                                .environmentObject(appState)
                            } else {
                                HomeTabBar(tabs: enabledTabs, selection: tabSelection)
                                homeContent(for: tab)
                            }
                        }
                        .pageContainer()
                    }
                    .suppressHoverEffectsDuringScroll()
                    .onAppear {
                        restoreHomeInlineAnchorIfNeeded(
                            appState.selectedItemReturnAnchorID,
                            isSearching: isSearching,
                            scrollProxy: scrollProxy
                        )
                    }
                    .onChange(of: appState.selectedItemReturnAnchorID) { anchorID in
                        restoreHomeInlineAnchorIfNeeded(anchorID, isSearching: isSearching, scrollProxy: scrollProxy)
                    }
                }
            }
        }
        .background(AppPageBackground())
        .navigationTitle("首页")
        .transaction { transaction in
            if layoutTransitionActive {
                transaction.disablesAnimations = true
                transaction.animation = nil
            }
        }
        .onAppear {
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            refreshHomeItems(for: currentTab)
            appState.showInterfaceTipOnce(
                key: "home.overview.boards",
                message: "总览会把继续观看、下一集、推荐和已发布片单放在一起，适合先找今天要看的内容。"
            )
            appState.showInterfaceTipOnce(
                key: "home.recommendation.preference",
                message: "推荐会参考你看过、喜欢、想看和标星的题材，优先展示评分较高且还没看完的内容。"
            )
        }
        .onChange(of: selectedTabRaw) { _ in
            refreshOverviewBoardsIfNeeded()
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: searchText) { _ in
            scheduleHomeSearchRefresh()
        }
        .onChange(of: appState.settings.enabledHomeTabs) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.favoriteRevision) { _ in
            // 喜欢乐观更新只 bump favoriteRevision；首页“喜欢”标签需据此刷新。
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.watchlistRevision) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.ratingRevision) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.videoCacheRevision) { _ in
            normalizeSelectedTab()
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.settings.watchedThreshold) { _ in
            refreshOverviewBoardsIfNeeded(force: true)
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onDisappear {
            homeContentRefreshTask?.cancel()
            homeSearchRefreshTask?.cancel()
        }
    }

    private var enabledTabs: [HomeTab] {
        let configured = appState.settings.enabledHomeTabs.isEmpty ? AppSettings.defaultHomeTabs : appState.settings.enabledHomeTabs
        let available = configured.filter { appState.availableHomeTabs.contains($0) }
        return available.isEmpty ? [.overview] : available
    }

    private var currentTab: HomeTab {
        enabledTabs.contains(selectedTab) ? selectedTab : (enabledTabs.first ?? .overview)
    }

    private var header: some View {
        PageHeader(title: "MediaLIB", subtitle: appState.localized("家庭影音库"), systemImage: "play.rectangle.on.rectangle") {
            if appState.isScanning {
                Label("\(appState.localized("队列")) \(max(appState.scanQueueCount, 1))", systemImage: "waveform.path.ecg")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if showsPlaybackHistoryAction {
                Button(role: .destructive) {
                    appState.clearPlaybackHistory(homePlaybackTraceItems)
                } label: {
                    Label(appState.localized("清除记录"), systemImage: "clock.badge.xmark")
                        .foregroundStyle(.red)
                }
                .disabled(homePlaybackTraceItems.isEmpty)
            }
            GlassSearchField(placeholder: appState.localized("搜索全部媒体"), text: $searchText, minWidth: 178, maxWidth: 236)
            Button {
                appState.scanSources(for: currentTab)
            } label: {
                Label(appState.localized("扫描"), systemImage: "arrow.clockwise")
            }
            .disabled(appState.sources.isEmpty || appState.isScanning)
        }
    }

    private var tabSelection: Binding<HomeTab> {
        Binding(get: { selectedTab }, set: { selectedTab = $0 })
    }

    // 海报型 tab：非总览、且非锁定状态的保险库。这类 tab 有内容时走 PosterGridList 虚拟化。
    private func isPosterTab(_ tab: HomeTab) -> Bool {
        if tab == .overview { return false }
        if tab == .privacy, !appState.privacyPINConfigured || !appState.privacyUnlocked { return false }
        return true
    }

    private var gridBottomInset: CGFloat {
        appState.activePlayerItem?.type == .music ? 122 : 22
    }

    @ViewBuilder
    private func homeContent(for tab: HomeTab) -> some View {
        switch tab {
        case .overview:
            HomeStatsView()
            ForEach(overviewBoards) { board in
                HomeOverviewBoard(
                    title: board.title,
                    subtitle: board.subtitle,
                    systemImage: board.systemImage,
                    items: board.items,
                    emptyMessage: board.emptyMessage,
                    metadata: overviewMetadata(for:),
                    showsDeletePlaybackHistory: board.id == "continue" || board.id == "nextUp",
                    onSelect: { item in
                        appState.selectedItemReturnAnchorID = item.id
                        appState.selectedItem = item
                    },
                    restoreAnchorID: appState.selectedItemReturnAnchorID,
                    onDidRestoreAnchor: { appState.selectedItemReturnAnchorID = nil }
                )
                .id("overview-board-\(board.id)")
            }
            LibraryHealthView(onOpen: onOpenHealthCenter)
        case .privacy where !appState.privacyPINConfigured || !appState.privacyUnlocked:
            PrivacyLockView()
                .frame(minHeight: 420)
        default:
            let items = displayedHomeItems(for: tab)
            let tabName = displayName(for: tab)
            if (isPreparingHomeItems || visibleHomeItemsAreOutOfDate(for: tab)) && items.isEmpty {
                AppLoadingView(title: homePhrase(prefix: "正在载入", name: tabName), systemImage: tab.systemImage, rowCount: 4)
            } else if items.isEmpty {
	                EmptyStateView(
	                    title: homePhrase(prefix: "暂无", name: tabName),
	                    systemImage: tab.systemImage,
	                    message: emptyMessage(for: tab)
	                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                // 有内容的海报型 tab 已在 body 中走 PosterGridList 虚拟化，此分支不会到达。
                EmptyView()
            }
        }
    }

    // 把"前缀 + 分区名"按语言拼成自然短语：中文紧贴，英文/日文按各自语序加分隔。
    private func homePhrase(prefix: String, name: String) -> String {
        switch appState.settings.appLanguage {
        case .zhHans:
            return "\(prefix)\(name)"
        case .ja:
            return "\(name)\(appState.localized(prefix))"
        case .en:
            return "\(appState.localized(prefix)) \(name)"
        }
    }

    private func displayName(for tab: HomeTab) -> String {
        tab == .privacy ? appState.settings.privacyVaultName : appState.localized(tab.displayName)
    }

    private func baseHomeItems(for tab: HomeTab) -> [MediaItem] {
        switch tab {
        case .overview:
            return []
        case .nextUp:
            return appState.nextUpItems
        case .continueWatching:
            return Array(appState.continueWatchingItems.prefix(48))
        case .offline:
            return appState.homeOfflineVideoItems
        case .recent:
            return appState.homeVideoItems
        case .movies:
            return appState.homeVideoItems
        case .tvShows:
            return appState.homeVideoItems
        case .anime:
            return appState.homeVideoItems
        case .documentaries:
            return appState.homeVideoItems
        case .variety:
            return appState.homeVideoItems
        case .homeVideos:
            return appState.homeVideoItems
        case .music:
            return appState.musicTracks
        case .other:
            return appState.homeVideoItems
        case .favorites:
            return appState.homeVideoItems
        case .unwatched:
            return appState.homeVideoItems
        case .privacy:
            return appState.privateTopLevelItems
        }
    }

    private func displayedHomeItems(for tab: HomeTab) -> [MediaItem] {
        visibleHomeItemsKey == homeItemsKey(for: tab) ? visibleHomeItems : []
    }

    private func visibleHomeItemsAreOutOfDate(for tab: HomeTab) -> Bool {
        visibleHomeItemsKey != homeItemsKey(for: tab)
    }

    private func homeItemsKey(for tab: HomeTab) -> String {
        [
            tab.rawValue,
            searchApplies(to: tab) ? searchText.trimmingCharacters(in: .whitespacesAndNewlines) : "",
            "\(appState.libraryRevision)",
            "\(appState.favoriteRevision)",
            "\(appState.watchlistRevision)",
            "\(appState.ratingRevision)",
            "\(appState.videoCacheRevision)",
            "\(appState.privacyUnlocked)",
            "\(appState.settings.watchedThreshold)"
        ].joined(separator: "|")
    }

    private func searchApplies(to tab: HomeTab) -> Bool {
        switch tab {
        case .overview, .nextUp, .continueWatching:
            return false
        default:
            return true
        }
    }

    private func itemLimit(for tab: HomeTab) -> Int? {
        switch tab {
        case .recent:
            return 48
        default:
            return nil
        }
    }

    private func contentFilter(for tab: HomeTab) -> HomeContentFilter {
        switch tab {
        case .movies:
            return .mediaType(.movie)
        case .tvShows:
            return .mediaType(.tvShow)
        case .anime:
            return .mediaType(.anime)
        case .documentaries:
            return .mediaType(.documentary)
        case .variety:
            return .mediaType(.variety)
        case .homeVideos:
            return .mediaType(.homeVideo)
        case .other:
            return .mediaType(.other)
        case .favorites:
            return .videoFavorites
        case .unwatched:
            return .unwatchedVideos
        default:
            return .none
        }
    }

    private func emptyMessage(for tab: HomeTab) -> String {
        switch tab {
        case .privacy:
            return appState.localized("解锁后展示保险库内容。")
        case .offline:
            return appState.localized("右键视频或单集选择缓存后，离线副本会出现在这里。")
        default:
            return appState.localized("接入媒体源并完成扫描后，内容会自动归入此页。")
        }
    }

    private func refreshHomeItems(for tab: HomeTab, deferred: Bool = false) {
        homeContentRefreshTask?.cancel()
        guard tab != .overview else {
            visibleHomeItems = []
            visibleHomeItemsKey = homeItemsKey(for: tab)
            isPreparingHomeItems = false
            return
        }
        if tab == .privacy && (!appState.privacyPINConfigured || !appState.privacyUnlocked) {
            visibleHomeItems = []
            visibleHomeItemsKey = homeItemsKey(for: tab)
            isPreparingHomeItems = false
            return
        }

        let key = homeItemsKey(for: tab)
        let input = HomeContentSnapshotInput(
            items: baseHomeItems(for: tab),
            filter: contentFilter(for: tab),
            searchText: searchText,
            appliesSearch: searchApplies(to: tab),
            limit: itemLimit(for: tab),
            watchedThreshold: appState.settings.watchedThreshold
        )
        isPreparingHomeItems = true
        homeContentRefreshTask = Task { @MainActor in
            if deferred {
                await Task.yield()
            }
            let items = await Task.detached(priority: .userInitiated) {
                HomeContentSnapshotBuilder.items(from: input)
            }.value
            guard !Task.isCancelled, key == homeItemsKey(for: tab) else { return }
            visibleHomeItems = items
            visibleHomeItemsKey = key
            isPreparingHomeItems = false
        }
    }

    private func scheduleHomeSearchRefresh() {
        homeSearchRefreshTask?.cancel()
        let targetTab = currentTab
        homeSearchRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            guard currentTab == targetTab else { return }
            refreshHomeItems(for: targetTab, deferred: true)
        }
    }

    private var homePlaybackTraceItems: [MediaItem] {
        switch currentTab {
        case .continueWatching:
            return displayedHomeItems(for: currentTab).filter(\.hasPlaybackTrace)
        default:
            return []
        }
    }

    private var showsPlaybackHistoryAction: Bool {
        switch currentTab {
        case .continueWatching:
            return true
        default:
            return false
        }
    }

    private var overviewBoards: [HomeOverviewBoardModel] {
        overviewBoardsKey == overviewSnapshotKey ? overviewBoardsSnapshot : []
    }

    private var overviewSnapshotKey: String {
        [
            "\(appState.libraryRevision)",
            "\(appState.favoriteRevision)",
            "\(appState.watchlistRevision)",
            "\(appState.ratingRevision)",
            "\(appState.videoCacheRevision)",
            "\(appState.settings.watchedThreshold)",
            "\(overviewDaySeed)"
        ].joined(separator: "|")
    }

    private var overviewDaySeed: Int {
        Calendar.current.ordinality(of: .day, in: .era, for: Date()) ?? 0
    }

    private func refreshOverviewBoardsIfNeeded(force: Bool = false) {
        let key = overviewSnapshotKey
        guard force || overviewBoardsKey != key else { return }
        overviewBoardsSnapshot = makeOverviewBoards(daySeed: overviewDaySeed)
        overviewBoardsKey = key
    }

    private func makeOverviewBoards(daySeed: Int) -> [HomeOverviewBoardModel] {
        let visibleVideos = overviewCandidateVideos()
        let profile = recommendationProfile(from: visibleVideos)
        let recommendedItems = recommendedOverviewItems(
            daySeed: daySeed,
            visibleVideos: visibleVideos,
            profile: profile
        )
        let recommendedIDs = Set(recommendedItems.map(\.id))
        let themeItems = themedHighRatedItems(
            daySeed: daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs
        )
        let themeIDs = Set(themeItems.map(\.id))
        let highRatedSeriesItems = highRatedSeriesOverviewItems(
            daySeed: daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs.union(themeIDs)
        )
        let seriesIDs = Set(highRatedSeriesItems.map(\.id))
        let watchlistItems = watchlistOverviewItems(
            daySeed: daySeed,
            visibleVideos: visibleVideos,
            profile: profile
        )
        let recentHighRatedItems = recentHighRatedOverviewItems(
            daySeed: daySeed,
            visibleVideos: visibleVideos,
            profile: profile,
            excludedIDs: recommendedIDs.union(seriesIDs)
        )
        let offlineItems = offlineOverviewItems(
            daySeed: daySeed,
            profile: profile
        )

        var defaultBoards = [
            HomeOverviewBoardModel(
                id: "continue",
                title: appState.localized("继续观看"),
                subtitle: appState.localized("上次停下的地方还在这里。"),
                systemImage: "play.circle",
                items: Array(appState.continueWatchingItems.prefix(10)),
                emptyMessage: appState.localized("开始播放后，这里会留下继续观看的入口。")
            ),
            HomeOverviewBoardModel(
                id: "nextUp",
                title: appState.localized("下一集"),
                subtitle: appState.localized("把故事接着往下看。"),
                systemImage: "forward.end.circle",
                items: Array(appState.nextUpItems.prefix(10)),
                emptyMessage: appState.localized("看过系列剧集后，下一集会自动出现在这里。")
            ),
            HomeOverviewBoardModel(
                id: "recommend",
                title: appState.localized("为你精选"),
                subtitle: recommendationSubtitle(for: profile),
                systemImage: "sparkles.tv",
                items: recommendedItems,
                emptyMessage: appState.localized("看过、喜欢或标星一些内容后，推荐会更有方向。")
            )
        ]

        if !themeItems.isEmpty, let genreName = profile.strongestGenreDisplayName {
            defaultBoards.append(
                HomeOverviewBoardModel(
                    id: "theme-\(profile.strongestGenre ?? genreName)",
                    title: appState.settings.appLanguage == .zhHans ? "\(genreName)高分" : "\(appState.localized("高分")) · \(genreName)",
                    subtitle: appState.localized("沿着你最近常看的题材继续挑。"),
                    systemImage: "tag",
                    items: themeItems,
                    emptyMessage: ""
                )
            )
        }

        if !highRatedSeriesItems.isEmpty {
            defaultBoards.append(
                HomeOverviewBoardModel(
                    id: "high-rated-series",
                    title: appState.localized("高分剧集"),
                    subtitle: appState.localized("优先展示评分较高、还没看完的系列。"),
                    systemImage: "star.circle",
                    items: highRatedSeriesItems,
                    emptyMessage: ""
                )
            )
        }

        if !watchlistItems.isEmpty {
            defaultBoards.append(
                HomeOverviewBoardModel(
                    id: "watchlist",
                    title: appState.localized("想看清单"),
                    subtitle: appState.localized("你之前留意过的内容，按适合度重新排好。"),
                    systemImage: "bookmark.circle",
                    items: watchlistItems,
                    emptyMessage: ""
                )
            )
        }

        if !recentHighRatedItems.isEmpty {
            defaultBoards.append(
                HomeOverviewBoardModel(
                    id: "recent-high-rated",
                    title: appState.localized("高分精选"),
                    subtitle: appState.localized("避开上方推荐，优先展示电影、纪录片和综艺里的高评分内容。"),
                    systemImage: "clock.badge.star",
                    items: recentHighRatedItems,
                    emptyMessage: ""
                )
            )
        }

        if !offlineItems.isEmpty {
            defaultBoards.append(
                HomeOverviewBoardModel(
                    id: "offline-ready",
                    title: appState.localized("离线可看"),
                    subtitle: appState.localized("已经缓存好的内容，离线也能打开。"),
                    systemImage: "arrow.down.circle",
                    items: offlineItems,
                    emptyMessage: ""
                )
            )
        }

        let boards = defaultBoards + publishedCollectionBoards()
        return boards.enumerated()
            .sorted { lhs, rhs in
                let leftHasContent = !lhs.element.items.isEmpty
                let rightHasContent = !rhs.element.items.isEmpty
                if leftHasContent != rightHasContent { return leftHasContent }
                return lhs.offset < rhs.offset
            }
            .map(\.element)
    }

    private func overviewCandidateVideos() -> [MediaItem] {
        appState.homeVideoItems.filter { item in
            item.type != .music && item.type != .episode && item.type != .privateCollection
        }
    }

    private func recommendationSubtitle(for profile: HomeRecommendationProfile) -> String {
        if let genreName = profile.strongestGenreDisplayName {
            if appState.settings.appLanguage == .zhHans {
                return "根据你的观看和标星偏好，优先挑 \(genreName) 与高分系列。"
            }
            return appState.localized("根据你的观看和标星偏好，优先挑高分系列。")
        }
        return appState.localized("先从库内高分系列和近期偏好里挑一些适合看的。")
    }

    private func recommendationProfile(from visibleVideos: [MediaItem]) -> HomeRecommendationProfile {
        var profile = HomeRecommendationProfile()
        let now = Date()
        let signalItems = visibleVideos + appState.continueWatchingItems + appState.nextUpItems
        var seen = Set<String>()

        for item in signalItems where seen.insert(item.id).inserted {
            let signalWeight = recommendationSignalWeight(for: item, now: now)
            guard signalWeight > 0 else { continue }
            profile.signalItemIDs.insert(item.id)
            profile.typeWeights[item.type, default: 0] += signalWeight * (seriesRecommendationTypes.contains(item.type) ? 1.1 : 0.8)

            let genres = overviewGenres(for: item)
            guard !genres.isEmpty else { continue }
            let perGenreWeight = signalWeight / Double(genres.count)
            for genre in genres {
                profile.genreWeights[genre.key, default: 0] += perGenreWeight
                if profile.genreDisplayNames[genre.key] == nil {
                    profile.genreDisplayNames[genre.key] = genre.display
                }
            }
        }

        return profile
    }

    private func recommendationSignalWeight(for item: MediaItem, now: Date) -> Double {
        guard item.type != .music, item.type != .privateCollection else { return 0 }
        var weight = 0.0
        if item.favorite { weight += 4.2 }
        if item.watchlist { weight += 1.4 }
        if let userRating = item.userRating, userRating.isFinite {
            if userRating >= 4 {
                weight += userRating * 1.15
            } else if userRating >= 3 {
                weight += userRating * 0.65
            }
        }
        if item.watched || item.playProgress >= appState.settings.watchedThreshold {
            weight += 3.0
        } else if item.playProgress >= 0.12 {
            weight += min(item.playProgress, 0.95) * 2.4
        }
        if let lastPlayedAt = item.lastPlayedAt {
            let days = max(0, now.timeIntervalSince(lastPlayedAt) / 86_400)
            if days <= 120 {
                weight += max(0, 1.6 - days / 75)
            }
        }
        if normalizedProviderScore(item.rating) >= 8.0 {
            weight += 0.5
        }
        return weight
    }

    private func recommendedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let preferred = visibleVideos.filter { item in
            !isFinishedForRecommendation(item) || item.watchlist
        }
        let base = preferred.count >= 6 ? preferred : visibleVideos
        return rankedOverviewItems(from: base, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed)
        }
    }

    private func themedHighRatedItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        guard let strongestGenre = profile.strongestGenre else { return [] }
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            overviewGenres(for: item).contains { $0.key == strongestGenre } &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.6
        }
    }

    private func highRatedSeriesOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.2
        }
    }

    private func watchlistOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let candidates = visibleVideos.filter { $0.watchlist }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 2.0
        }
    }

    private func recentHighRatedOverviewItems(
        daySeed: Int,
        visibleVideos: [MediaItem],
        profile: HomeRecommendationProfile,
        excludedIDs: Set<String>
    ) -> [MediaItem] {
        let primaryCandidates = visibleVideos.filter { item in
            !excludedIDs.contains(item.id) &&
            !seriesRecommendationTypes.contains(item.type) &&
            isHighRatedForOverview(item) &&
            !isFinishedForRecommendation(item)
        }
        let candidates = primaryCandidates.count >= 6
            ? primaryCandidates
            : visibleVideos.filter { item in
                !excludedIDs.contains(item.id) &&
                isHighRatedForOverview(item) &&
                !isFinishedForRecommendation(item)
            }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            normalizedProviderScore(item.rating) * 1.8 +
            normalizedUserScore(item.userRating) * 1.4 +
            recencyScore(for: item.updatedAt, horizonDays: 240) * 1.2 +
            stableDailyVariation(for: item, daySeed: daySeed) * 0.35
        }
    }

    private func offlineOverviewItems(
        daySeed: Int,
        profile: HomeRecommendationProfile
    ) -> [MediaItem] {
        let candidates = appState.homeOfflineVideoItems.filter { item in
            item.type != .music && item.type != .episode && item.type != .privateCollection
        }
        return rankedOverviewItems(from: candidates, limit: 12) { item in
            recommendationScore(for: item, profile: profile, daySeed: daySeed) + 1.4
        }
    }

    private func rankedOverviewItems(
        from candidates: [MediaItem],
        limit: Int,
        score: (MediaItem) -> Double
    ) -> [MediaItem] {
        var seen = Set<String>()
        var unique: [MediaItem] = []
        unique.reserveCapacity(candidates.count)
        for item in candidates where seen.insert(item.id).inserted {
            unique.append(item)
        }
        let scored = unique.map { item in
            (item: item, score: score(item))
        }
        return Array(scored.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            return lhs.item.title.localizedCaseInsensitiveCompare(rhs.item.title) == .orderedAscending
        }.prefix(limit).map(\.item))
    }

    private func publishedCollectionBoards() -> [HomeOverviewBoardModel] {
        let manualBoards = appState.videoManualCollections.compactMap { collection -> HomeOverviewBoardModel? in
            guard collection.showOnHome else { return nil }
            let items = appState.videoManualCollectionHomeItems(collection)
            guard !items.isEmpty else { return nil }
            return HomeOverviewBoardModel(
                id: "manual-\(collection.id)",
                title: collection.name,
                subtitle: appState.localized("手动整理的专题片单。"),
                systemImage: "rectangle.stack",
                items: items,
                emptyMessage: ""
            )
        }

        let smartBoards = appState.videoSmartCollections.compactMap { collection -> HomeOverviewBoardModel? in
            guard collection.showOnHome else { return nil }
            let items = appState.videoSmartCollectionHomeItems(collection)
            guard !items.isEmpty else { return nil }
            return HomeOverviewBoardModel(
                id: "smart-\(collection.id)",
                title: collection.name,
                subtitle: appState.localized("按规则自动更新。"),
                systemImage: "sparkles.rectangle.stack",
                items: items,
                emptyMessage: ""
            )
        }

        return manualBoards + smartBoards
    }

    private var seriesRecommendationTypes: Set<MediaType> {
        [.tvShow, .anime, .documentary, .variety]
    }

    private func recommendationScore(
        for item: MediaItem,
        profile: HomeRecommendationProfile,
        daySeed: Int
    ) -> Double {
        let providerScore = normalizedProviderScore(item.rating)
        let userScore = normalizedUserScore(item.userRating)
        let ratingScore = max(providerScore, userScore)
        var score = ratingScore * 1.25
        score += profileAffinityScore(for: item, profile: profile)
        score += seriesRecommendationTypes.contains(item.type) ? 1.35 : 0.3
        score += item.watchlist ? 1.0 : 0
        score += item.favorite ? 0.4 : 0
        score += item.playProgress <= 0.02 && !item.watched ? 0.75 : 0
        score += stableDailyVariation(for: item, daySeed: daySeed) * 0.55

        if item.watched || item.playProgress >= appState.settings.watchedThreshold {
            score -= 3.8
        } else if item.playProgress > 0.12 {
            score -= 1.2
        }
        if profile.signalItemIDs.contains(item.id), !item.watchlist {
            score -= 0.7
        }
        return score
    }

    private func profileAffinityScore(for item: MediaItem, profile: HomeRecommendationProfile) -> Double {
        guard profile.hasSignals else { return 0 }
        let genres = overviewGenres(for: item)
        let rawGenreWeight = genres.reduce(0.0) { partial, genre in
            partial + (profile.genreWeights[genre.key] ?? 0)
        }
        let genreScore: Double
        if profile.maxGenreWeight > 0 {
            genreScore = min(rawGenreWeight / profile.maxGenreWeight, 2.4) * 2.1
        } else {
            genreScore = 0
        }
        let typeWeight = profile.typeWeights[item.type] ?? 0
        let typeScore = profile.maxTypeWeight > 0 ? min(typeWeight / profile.maxTypeWeight, 1.4) * 1.35 : 0
        return genreScore + typeScore
    }

    private func stableDailyVariation(for item: MediaItem, daySeed: Int) -> Double {
        let hash = (item.id + "-\(daySeed)").unicodeScalars.reduce(UInt64(5381)) { partial, scalar in
            ((partial &* 33) &+ UInt64(scalar.value))
        }
        return Double(hash % 997) / 997.0
    }

    private func isHighRatedForOverview(_ item: MediaItem) -> Bool {
        normalizedProviderScore(item.rating) >= 7.3 || normalizedUserScore(item.userRating) >= 8
    }

    private func isFinishedForRecommendation(_ item: MediaItem) -> Bool {
        item.watched || item.playProgress >= appState.settings.watchedThreshold
    }

    private func normalizedProviderScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return rating <= 5 ? rating * 2 : min(rating, 10)
    }

    private func normalizedUserScore(_ rating: Double?) -> Double {
        guard let rating, rating.isFinite, rating > 0 else { return 0 }
        return min(rating, 5) * 2
    }

    private func recencyScore(for date: Date?, horizonDays: Double) -> Double {
        guard let date else { return 0 }
        let days = max(0, Date().timeIntervalSince(date) / 86_400)
        guard horizonDays > 0 else { return 0 }
        return max(0, 1 - min(days, horizonDays) / horizonDays)
    }

    private func overviewGenres(for item: MediaItem) -> [(key: String, display: String)] {
        guard let genre = item.genre else { return [] }
        let separators = CharacterSet(charactersIn: ",，、/|;；")
        var seen = Set<String>()
        return genre
            .components(separatedBy: separators)
            .compactMap { raw -> (key: String, display: String)? in
                let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !display.isEmpty else { return nil }
                let key = display
                    .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: .current)
                    .lowercased()
                guard !key.isEmpty, seen.insert(key).inserted else { return nil }
                return (key, display)
            }
    }

    private func overviewMetadata(for item: MediaItem) -> String {
        var parts: [String] = []
        if item.type == .episode {
            parts.append(item.episodeLabel)
        } else {
            parts.append(item.type.displayName)
        }
        if item.year != nil {
            parts.append(item.displayYear)
        }
        if let rating = item.rating, rating > 0 {
            parts.append("★ \(String(format: "%.1f", rating))")
        }
        if item.playProgress > 0, item.playProgress < 0.98 {
            parts.append("\(appState.localized("已看")) \(Int((item.playProgress * 100).rounded()))%")
        }
        return parts.joined(separator: " · ")
    }

    private func normalizeSelectedTab() {
        if !enabledTabs.contains(selectedTab) {
            selectedTab = enabledTabs.first ?? .overview
        }
    }

    private func restoreOverviewAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard currentTab == .overview,
              let anchorID,
              restoredOverviewAnchorID != anchorID,
              let board = overviewBoards.first(where: { $0.items.contains(where: { $0.id == anchorID }) }) else { return }
        restoredOverviewAnchorID = anchorID
        let boardAnchorID = "overview-board-\(board.id)"
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo(boardAnchorID, anchor: .center)
        }
        Task { @MainActor in
            await Task.yield()
            var retryTransaction = Transaction()
            retryTransaction.disablesAnimations = true
            withTransaction(retryTransaction) {
                scrollProxy.scrollTo(boardAnchorID, anchor: .center)
            }
        }
    }

    private func restoreHomeInlineAnchorIfNeeded(
        _ anchorID: String?,
        isSearching: Bool,
        scrollProxy: ScrollViewProxy
    ) {
        if isSearching {
            guard let anchorID, restoredOverviewAnchorID != anchorID else { return }
            restoredOverviewAnchorID = anchorID
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
            }
            Task { @MainActor in
                await Task.yield()
                var retryTransaction = Transaction()
                retryTransaction.disablesAnimations = true
                withTransaction(retryTransaction) {
                    scrollProxy.scrollTo(anchorID, anchor: .center)
                }
                appState.selectedItemReturnAnchorID = nil
            }
        } else {
            restoreOverviewAnchorIfNeeded(anchorID, scrollProxy: scrollProxy)
        }
    }
}

struct HomeTabBar: View {
    @EnvironmentObject private var appState: AppState
    let tabs: [HomeTab]
    @Binding var selection: HomeTab

    var body: some View {
        ViewThatFits(in: .horizontal) {
            singleRowTabs
            wrappedTabs
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .staticSurfaceBackground(cornerRadius: 18, thickness: 1.04)
    }

    private var singleRowTabs: some View {
        HStack(spacing: 10) {
            ForEach(tabs) { tab in
                tabButton(tab)
            }
        }
        .padding(4)
        .frame(height: 46, alignment: .leading)
        .fixedSize(horizontal: true, vertical: false)
    }

    // 标签放不下时（英文 / 日文标签更长）不再换成挤在一起的两行网格，
    // 而是退化成单行横向滚动的胶囊，和能放下时的单行外观一致，避免排版错乱。
    private var wrappedTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(4)
        }
        .frame(height: 46)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        Button {
            withAnimation(AppMotion.fast) {
                selection = tab
            }
        } label: {
            GlassCapsuleControl(isSelected: selection == tab, height: 30, horizontalPadding: 12) {
                Label(appState.localized(tab.displayName), systemImage: tab.systemImage)
            }
        }
        .buttonStyle(.plain)
        .help(appState.localized(tab.displayName))
    }
}

struct HomeStatsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let stats = appState.homeStats

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            if stats.movieCount > 0 {
                StatTile(title: appState.localized("影片"), value: "\(stats.movieCount)", systemImage: "film")
            }
            if stats.seriesCount > 0 {
                StatTile(title: appState.localized("系列"), value: "\(stats.seriesCount)", systemImage: "rectangle.stack")
            }
            if stats.episodeCount > 0 {
                StatTile(title: appState.localized("剧集"), value: "\(stats.episodeCount)", systemImage: "play.square.stack")
            }
            if stats.unwatchedCount > 0 {
                StatTile(title: appState.localized("未观看"), value: "\(stats.unwatchedCount)", systemImage: "eye")
            }
            if stats.favoriteCount > 0 {
                StatTile(title: appState.localized("喜欢"), value: "\(stats.favoriteCount)", systemImage: "heart")
            }
            if stats.watchedMovieCount > 0 {
                StatTile(title: appState.localized("已看影片"), value: "\(stats.watchedMovieCount)", systemImage: "checkmark.circle")
            }
            if stats.watchedEpisodeCount > 0 {
                StatTile(title: appState.localized("已看剧集"), value: "\(stats.watchedEpisodeCount)", systemImage: "checkmark.seal")
            }
            if stats.totalWatchedMinutes >= 60 {
                let hours = stats.totalWatchedMinutes / 60
                let label = hours >= 10000 ? "\(hours / 1000)K+" : (hours >= 1000 ? "\(hours / 100 * 100)+" : "\(hours)")
                StatTile(title: appState.localized("已看时长(h)"), value: label, systemImage: "clock.badge.checkmark")
            }
        }
    }
}

struct HomeOverviewBoard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let title: String
    let subtitle: String
    let systemImage: String
    let items: [MediaItem]
    let emptyMessage: String
    let metadata: (MediaItem) -> String
    var showsDeletePlaybackHistory = false
    let onSelect: (MediaItem) -> Void
    var restoreAnchorID: String? = nil
    var onDidRestoreAnchor: (() -> Void)? = nil
    @State private var autoScrollIndex = 0
    @State private var isHoveringStrip = false
    @State private var isDraggingStrip = false
    @State private var restoredAnchorID: String?

    private var autoScrollKey: String {
        items.map(\.id).joined(separator: "|")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                PlayfulSymbolIcon(systemImage: systemImage, size: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            if items.isEmpty {
                Text(emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
            } else {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        LazyHStack(spacing: 12) {
                            ForEach(items) { item in
                                HomeOverviewPosterCard(
                                    item: item,
                                    metadata: metadata(item),
                                    showsDeletePlaybackHistory: showsDeletePlaybackHistory,
                                    onSelect: { onSelect(item) }
                                )
                                .id(item.id)
                            }
                        }
                        .padding(.vertical, 2)
                    }
                    .horizontalMouseDragScroll(enabled: !layoutTransitionActive) { dragging in
                        isDraggingStrip = dragging
                    }
                    .onHover { hovering in
                        isHoveringStrip = layoutTransitionActive ? false : hovering
                    }
                    .onAppear {
                        restoreAnchorIfNeeded(restoreAnchorID, scrollProxy: proxy)
                    }
                    .onChange(of: restoreAnchorID) { anchorID in
                        restoreAnchorIfNeeded(anchorID, scrollProxy: proxy)
                    }
                    .onChange(of: layoutTransitionActive) { active in
                        if active {
                            isHoveringStrip = false
                            isDraggingStrip = false
                        }
                    }
                    .task(id: "\(autoScrollKey)|\(layoutTransitionActive)") {
                        autoScrollIndex = 0
                        guard items.count > 1, !reduceMotion, !layoutTransitionActive else { return }
                        while !Task.isCancelled {
                            do {
                                try await Task.sleep(nanoseconds: 5_200_000_000)
                            } catch {
                                return
                            }
                            guard !Task.isCancelled, !isHoveringStrip, !isDraggingStrip, !items.isEmpty else { continue }
                            autoScrollIndex = (autoScrollIndex + 1) % items.count
                            let targetID = items[autoScrollIndex].id
                            withAnimation(AppMotion.page) {
                                proxy.scrollTo(targetID, anchor: .leading)
                            }
                        }
                    }
                }
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 20, thickness: 1.02)
    }

    private func restoreAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard let anchorID,
              restoredAnchorID != anchorID,
              let index = items.firstIndex(where: { $0.id == anchorID }) else { return }
        restoredAnchorID = anchorID
        autoScrollIndex = index
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            scrollProxy.scrollTo(anchorID, anchor: .center)
        }
        Task { @MainActor in
            await Task.yield()
            var retryTransaction = Transaction()
            retryTransaction.disablesAnimations = true
            withTransaction(retryTransaction) {
                scrollProxy.scrollTo(anchorID, anchor: .center)
            }
            onDidRestoreAnchor?()
        }
    }
}

private struct HomeOverviewPosterCard: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let item: MediaItem
    let metadata: String
    var showsDeletePlaybackHistory = false
    let onSelect: () -> Void
    @State private var isHovering = false

    private var active: Bool {
        isHovering && !suppressHoverDuringScroll && !layoutTransitionActive
    }

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 8) {
                ZStack(alignment: .bottomLeading) {
                    PosterImage(
                        path: item.posterPath,
                        title: item.cardTitle,
                        mediaType: item.type,
                        cacheTargetSize: CGSize(width: 180, height: 270)
                    )
                    .aspectRatio(2.0 / 3.0, contentMode: .fill)
                    .frame(width: 96, height: 144)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    if item.playProgress > 0, item.playProgress < 0.98 {
                        ProgressView(value: item.playProgress)
                            .tint(AppColors.selectedGlassTint)
                            .controlSize(.small)
                            .padding(.horizontal, 7)
                            .padding(.bottom, 7)
                    }
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(.white.opacity(active ? 0.56 : 0.26), lineWidth: active ? 1.1 : 0.7)
                }

                Text(item.cardTitle)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(width: 96, alignment: .leading)
            }
            .padding(8)
            .contentShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .staticSurfaceBackground(cornerRadius: 16, thickness: active ? 1.08 : 0.92)
            .repeatedSurfaceHover(active, cornerRadius: 16, intensity: 0.62)
            .scaleEffect(active && !reduceMotion ? 1.018 : 1)
        }
        .buttonStyle(.plain)
        .contextMenu {
            VideoItemContextMenuItems(
                item: item,
                showsDeletePlaybackHistory: showsDeletePlaybackHistory
            )
        }
        .onHover { hovering in
            isHovering = (suppressHoverDuringScroll || layoutTransitionActive) ? false : hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onChange(of: layoutTransitionActive) { active in
            if active {
                isHovering = false
            }
        }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
    }
}

struct StatTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let title: String
    let value: String
    let systemImage: String
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 12) {
            PlayfulSymbolIcon(systemImage: systemImage, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.58)
                    .allowsTightening(true)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 72, alignment: .leading)
        .staticSurfaceBackground()
        .scaleEffect(!reduceMotion && isHovering && !suppressHoverDuringScroll && !layoutTransitionActive ? 1.022 : 1)
        .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering && !suppressHoverDuringScroll && !layoutTransitionActive)
        .onHover { hovering in
            guard !suppressHoverDuringScroll, !layoutTransitionActive else {
                isHovering = false
                return
            }
            isHovering = hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .onChange(of: layoutTransitionActive) { active in
            if active {
                isHovering = false
            }
        }
    }
}

struct LibraryHealthView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.mainLayoutTransitionActive) private var layoutTransitionActive
    let onOpen: () -> Void
    @State private var isHovering = false

    private func libraryHealthSummary(offline: Int, missingFiles: Int, duplicateGroups: Int, missingMetadata: Int) -> String {
        switch appState.settings.appLanguage {
        case .zhHans:
            return "\(offline) 个媒体源不可访问，\(missingFiles) 个文件/播放路径失效，\(duplicateGroups) 组疑似重复条目，\(missingMetadata) 个条目缺少核心信息。"
        case .en:
            return "\(offline) sources unreachable, \(missingFiles) broken files/paths, \(duplicateGroups) likely duplicate groups, \(missingMetadata) items missing key info."
        case .ja:
            return "アクセス不可のソース \(offline) 件、無効なファイル/パス \(missingFiles) 件、重複の疑い \(duplicateGroups) 組、主要情報が不足 \(missingMetadata) 件。"
        }
    }

    var body: some View {
        let offline = appState.offlineSources
        let missingFiles = appState.missingFileItems
        let duplicateGroups = appState.duplicateTitleGroups
        let missingMetadata = appState.missingMetadataItems

        if !offline.isEmpty || !missingFiles.isEmpty || !duplicateGroups.isEmpty || !missingMetadata.isEmpty {
            let tint = AppColors.selectedGlassTint
            let active = isHovering && !suppressHoverDuringScroll && !layoutTransitionActive
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(active ? tint.opacity(0.96) : tint.opacity(0.82))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(appState.localized("媒体库需要处理"))
                            .font(.headline)
                        Text(libraryHealthSummary(offline: offline.count, missingFiles: missingFiles.count, duplicateGroups: duplicateGroups.count, missingMetadata: missingMetadata.count))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(tint.opacity(colorScheme == .dark ? 0.14 : 0.08))
            )
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(AppColors.cleanPanelFill.opacity(colorScheme == .dark ? 0.56 : 0.74))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? 0.34 : 0.70),
                                tint.opacity(colorScheme == .dark ? 0.34 : 0.24),
                                tint.opacity(0.10)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .repeatedSurfaceHover(active, cornerRadius: 14, tint: tint, intensity: 0.78)
            .brightness(active ? 0.006 : 0)
            .onHover { hovering in
                isHovering = (suppressHoverDuringScroll || layoutTransitionActive) ? false : hovering
            }
            .onChange(of: suppressHoverDuringScroll) { suppressing in
                if suppressing {
                    isHovering = false
                }
            }
            .onChange(of: layoutTransitionActive) { active in
                if active {
                    isHovering = false
                }
            }
            .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
        }
    }
}

struct EmptyLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let onOpenSources: () -> Void
    @State private var iconShakeStep = 0
    @State private var iconShakeTask: Task<Void, Never>?

    private var iconShakeAngle: Double {
        guard !reduceMotion else { return 0 }
        let pattern: [Double] = [0, -5.0, 4.6, -3.4, 2.6, -1.4, 0.7, 0]
        return pattern[iconShakeStep % pattern.count]
    }

    var body: some View {
        ZStack {
            PlayfulSymbolIcon(systemImage: "externaldrive.badge.plus", size: 62)
                .rotationEffect(.degrees(iconShakeAngle), anchor: .center)
                .scaleEffect(iconShakeStep == 0 || reduceMotion ? 1 : 1.012)
                .opacity(0.94)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.085), value: iconShakeStep)

            VStack(spacing: 18) {
	            Text(appState.localized("媒体源待添加"))
	                .font(.title2.weight(.semibold))
	            Text(appState.localized("接入本地文件夹、移动硬盘、网络挂载或 Emby 媒体库后，MediaLIB 会整理索引。"))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            Button(action: onOpenSources) {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.right.circle.fill")
                        .font(.callout.weight(.semibold))
                    Text(appState.localized("前往媒体源添加"))
                        .font(.callout.weight(.semibold))
                }
                .foregroundStyle(AppColors.selectedGlassTint)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(
                    Capsule()
                        .fill(AppColors.selectedGlassTint.opacity(0.10))
                        .overlay(
                            Capsule()
                                .stroke(AppColors.selectedGlassTint.opacity(0.28), lineWidth: 1)
                        )
                )
                .contentShape(Capsule())
            }
            .buttonStyle(.plain)
            .help(appState.localized("前往媒体源添加"))
            .padding(.top, 4)
            }
            .offset(y: 116)
        }
        // 内容在更高的卡片内水平+垂直居中，让磁盘固定在空状态视觉中心。
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .center)
        .padding(32)
        .staticSurfaceBackground(cornerRadius: 22)
        .onAppear { startIconShakeIfNeeded() }
        .onDisappear {
            iconShakeTask?.cancel()
            iconShakeTask = nil
        }
    }

    private func startIconShakeIfNeeded() {
        guard iconShakeTask == nil, !reduceMotion else { return }
        iconShakeTask = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 1_150_000_000)
                for step in 1...7 {
                    guard !Task.isCancelled else { return }
                    iconShakeStep = step
                    try? await Task.sleep(nanoseconds: 85_000_000)
                }
                iconShakeStep = 0
            }
        }
    }
}

struct ScanProgressView: View {
    @EnvironmentObject private var appState: AppState
    let progress: ScanProgress

    private func scanningVaultTitle(_ name: String) -> String {
        switch appState.settings.appLanguage {
        case .zhHans: return "正在扫描\(name)媒体源"
        case .en: return "Scanning \(name) source"
        case .ja: return "\(name)ソースをスキャン中"
        }
    }

    var body: some View {
        let source = appState.sources.first { $0.id == progress.sourceID }
        let hidesPath = source?.mediaType == .privateCollection && !appState.privacyUnlocked

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(hidesPath ? scanningVaultTitle(appState.settings.privacyVaultName) : appState.localized("正在扫描"))
                    .font(.headline)
                Spacer()
                Text("\(progress.processedFiles)/\(progress.totalFiles)")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(AppColors.selectedGlassTint)
            if hidesPath {
                Text(appState.localized("扫描详情已隐藏"))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if let currentPath = progress.currentPath {
                Text(currentPath)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(14)
        .staticSurfaceBackground()
    }
}
