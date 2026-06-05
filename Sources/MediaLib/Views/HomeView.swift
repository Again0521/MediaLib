import MediaLibCore
import SwiftUI

private struct HomeContentSnapshotInput: Sendable {
    let items: [MediaItem]
    let filter: HomeContentFilter
    let searchText: String
    let appliesSearch: Bool
    let limit: Int?
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
        let base = filteredItems(input.items, filter: input.filter)
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

    private static func filteredItems(_ items: [MediaItem], filter: HomeContentFilter) -> [MediaItem] {
        switch filter {
        case .none:
            return items
        case .mediaType(let type):
            return items.filter { $0.type == type }
        case .videoFavorites:
            return items.filter { $0.type != .music && $0.favorite }
        case .unwatchedVideos:
            return items.filter { $0.type != .music && !$0.watched && $0.playProgress < 0.9 }
        }
    }
}

struct HomeView: View {
    @EnvironmentObject private var appState: AppState
    let onOpenHealthCenter: () -> Void
    @State private var searchText = ""
    @State private var visibleHomeItems: [MediaItem] = []
    @State private var visibleHomeItemsKey = ""
    @State private var isPreparingHomeItems = false
    @State private var homeContentRefreshTask: Task<Void, Never>?
    @State private var homeSearchRefreshTask: Task<Void, Never>?
    @AppStorage("MediaLib.home.selectedTab") private var selectedTabRaw = HomeTab.overview.rawValue

    init(onOpenHealthCenter: @escaping () -> Void = {}) {
        self.onOpenHealthCenter = onOpenHealthCenter
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
                // P1：首页海报型 tab 走原生 List 虚拟化；页头/扫描进度/标签栏/分区标题作为前导行随内容滚动。
                PosterGridList(items: gridItems, bottomInset: gridBottomInset, showsDeletePlaybackHistory: tab == .continueWatching || tab == .nextUp) {
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
                ScrollView {
                    VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                        header

                        if let progress = appState.scanProgress, appState.isScanning {
                            ScanProgressView(progress: progress)
                        }

                        if appState.sources.isEmpty {
                            EmptyLibraryView()
                        } else if isSearching {
                            GlobalSearchView(query: searchText) { item in
                                if item.type == .music {
                                    appState.play(item)
                                } else {
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
            }
        }
        .background(AppPageBackground())
        .navigationTitle("首页")
        .onAppear {
            normalizeSelectedTab()
            refreshHomeItems(for: currentTab)
        }
        .onChange(of: selectedTabRaw) { _ in
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: searchText) { _ in
            scheduleHomeSearchRefresh()
        }
        .onChange(of: appState.settings.enabledHomeTabs) { _ in
            normalizeSelectedTab()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            normalizeSelectedTab()
            homeSearchRefreshTask?.cancel()
            refreshHomeItems(for: currentTab, deferred: true)
        }
        .onChange(of: appState.favoriteRevision) { _ in
            // 喜欢乐观更新只 bump favoriteRevision；首页“喜欢”标签需据此刷新。
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
        PageHeader(title: "MediaLIB", subtitle: "家庭影音库", systemImage: "play.rectangle.on.rectangle") {
            if appState.isScanning {
                Label("队列 \(max(appState.scanQueueCount, 1))", systemImage: "waveform.path.ecg")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if showsPlaybackHistoryAction {
                Button(role: .destructive) {
                    appState.clearPlaybackHistory(homePlaybackTraceItems)
                } label: {
                    Label("清除记录", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.red)
                }
                .disabled(homePlaybackTraceItems.isEmpty)
            }
            GlassSearchField(placeholder: "搜索全部媒体", text: $searchText)
            Button {
                appState.scanSources(for: currentTab)
            } label: {
                Label("扫描", systemImage: "arrow.clockwise")
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
            LibraryHealthView(onOpen: onOpenHealthCenter)
        case .privacy where !appState.privacyPINConfigured || !appState.privacyUnlocked:
            PrivacyLockView()
                .frame(minHeight: 420)
        default:
            let items = displayedHomeItems(for: tab)
            if (isPreparingHomeItems || visibleHomeItemsAreOutOfDate(for: tab)) && items.isEmpty {
                AppLoadingView(title: "正在载入\(displayName(for: tab))", systemImage: tab.systemImage, rowCount: 4)
            } else if items.isEmpty {
                EmptyStateView(
                    title: "暂无\(displayName(for: tab))",
                    systemImage: tab.systemImage,
                    message: tab == .privacy ? "解锁后会显示保险库内容。" : "添加媒体源并扫描后，这里会显示内容。"
                )
                .frame(maxWidth: .infinity, minHeight: 360)
            } else {
                // 有内容的海报型 tab 已在 body 中走 PosterGridList 虚拟化，此分支不会到达。
                EmptyView()
            }
        }
    }

    private func displayName(for tab: HomeTab) -> String {
        tab == .privacy ? appState.settings.privacyVaultName : tab.displayName
    }

    private func baseHomeItems(for tab: HomeTab) -> [MediaItem] {
        switch tab {
        case .overview:
            return []
        case .nextUp:
            return appState.nextUpItems
        case .continueWatching:
            return Array(appState.continueWatchingItems.prefix(48))
        case .recent:
            return appState.topLevelItems
        case .movies:
            return appState.topLevelItems
        case .tvShows:
            return appState.topLevelItems
        case .anime:
            return appState.topLevelItems
        case .documentaries:
            return appState.topLevelItems
        case .variety:
            return appState.topLevelItems
        case .music:
            return appState.musicTracks
        case .other:
            return appState.topLevelItems
        case .favorites:
            return appState.topLevelItems
        case .unwatched:
            return appState.topLevelItems
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
            "\(appState.privacyUnlocked)"
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
            limit: itemLimit(for: tab)
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
        case .continueWatching, .recent:
            return displayedHomeItems(for: currentTab).filter(\.hasPlaybackTrace)
        default:
            return []
        }
    }

    private var showsPlaybackHistoryAction: Bool {
        switch currentTab {
        case .continueWatching, .recent:
            return true
        default:
            return false
        }
    }

    private func normalizeSelectedTab() {
        if !enabledTabs.contains(selectedTab) {
            selectedTab = enabledTabs.first ?? .overview
        }
    }
}

struct HomeTabBar: View {
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

    private var wrappedTabs: some View {
        let rows = Array(
            repeating: GridItem(.fixed(34), spacing: 8, alignment: .leading),
            count: 2
        )

        return ScrollView(.horizontal, showsIndicators: false) {
            LazyHGrid(rows: rows, alignment: .top, spacing: 10) {
                ForEach(tabs) { tab in
                    tabButton(tab)
                }
            }
            .padding(4)
        }
        .frame(height: 80)
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
    }

    private func tabButton(_ tab: HomeTab) -> some View {
        Button {
            withAnimation(AppMotion.fast) {
                selection = tab
            }
        } label: {
            GlassCapsuleControl(isSelected: selection == tab, height: 30, horizontalPadding: 12) {
                Label(tab.displayName, systemImage: tab.systemImage)
            }
        }
        .buttonStyle(.plain)
        .help(tab.displayName)
    }
}

struct HomeStatsView: View {
    @EnvironmentObject private var appState: AppState

    var body: some View {
        let stats = appState.homeStats

        LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 12)], spacing: 12) {
            if stats.movieCount > 0 {
                StatTile(title: "影片", value: "\(stats.movieCount)", systemImage: "film")
            }
            if stats.seriesCount > 0 {
                StatTile(title: "系列", value: "\(stats.seriesCount)", systemImage: "rectangle.stack")
            }
            if stats.episodeCount > 0 {
                StatTile(title: "剧集", value: "\(stats.episodeCount)", systemImage: "play.square.stack")
            }
            if stats.unwatchedCount > 0 {
                StatTile(title: "未观看", value: "\(stats.unwatchedCount)", systemImage: "eye")
            }
            if stats.favoriteCount > 0 {
                StatTile(title: "喜欢", value: "\(stats.favoriteCount)", systemImage: "heart")
            }
            if stats.watchedMovieCount > 0 {
                StatTile(title: "已看影片", value: "\(stats.watchedMovieCount)", systemImage: "checkmark.circle")
            }
            if stats.watchedEpisodeCount > 0 {
                StatTile(title: "已看剧集", value: "\(stats.watchedEpisodeCount)", systemImage: "checkmark.seal")
            }
            if stats.totalWatchedMinutes >= 60 {
                let hours = stats.totalWatchedMinutes / 60
                let label = hours >= 10000 ? "\(hours / 1000)K+" : (hours >= 1000 ? "\(hours / 100 * 100)+" : "\(hours)")
                StatTile(title: "已看时长(h)", value: label, systemImage: "clock.badge.checkmark")
            }
        }
    }
}

struct StatTile: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
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
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .staticSurfaceBackground()
        .scaleEffect(!reduceMotion && isHovering && !suppressHoverDuringScroll ? 1.022 : 1)
        .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering && !suppressHoverDuringScroll)
        .onHover { hovering in
            guard !suppressHoverDuringScroll else {
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
    }
}

struct LibraryHealthView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let onOpen: () -> Void
    @State private var isHovering = false

    var body: some View {
        let offline = appState.offlineSources
        let missingFiles = appState.missingFileItems
        let duplicateGroups = appState.duplicateTitleGroups
        let missingMetadata = appState.missingMetadataItems

        if !offline.isEmpty || !missingFiles.isEmpty || !duplicateGroups.isEmpty || !missingMetadata.isEmpty {
            let tipBlue = Color(red: 0.22, green: 0.52, blue: 0.92)
            let active = isHovering && !suppressHoverDuringScroll
            Button(action: onOpen) {
                HStack(spacing: 12) {
                    Image(systemName: "externaldrive.badge.exclamationmark")
                        .font(.title2)
                        .foregroundStyle(active ? AppColors.selectedGlassTint.opacity(0.92) : tipBlue)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("媒体库需要处理")
                            .font(.headline)
                        Text("\(offline.count) 个媒体源不可访问，\(missingFiles.count) 个文件路径失效，\(duplicateGroups.count) 组疑似重复条目，\(missingMetadata.count) 个条目缺少核心信息。")
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
                    .fill(tipBlue.opacity(colorScheme == .dark ? 0.12 : 0.09))
            )
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(
                        LinearGradient(
                            colors: [tipBlue.opacity(colorScheme == .dark ? 0.40 : 0.32), tipBlue.opacity(0.10)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .repeatedSurfaceHover(active, cornerRadius: 14, tint: tipBlue, intensity: 0.78)
            .brightness(active ? 0.006 : 0)
            .onHover { hovering in
                isHovering = suppressHoverDuringScroll ? false : hovering
            }
            .onChange(of: suppressHoverDuringScroll) { suppressing in
                if suppressing {
                    isHovering = false
                }
            }
            .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
        }
    }
}

struct EmptyLibraryView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var breathe = false

    var body: some View {
        VStack(spacing: 18) {
            PlayfulSymbolIcon(systemImage: "externaldrive.badge.plus", size: 62)
                .scaleEffect(breathe && !reduceMotion ? 1.04 : 1)
                .opacity(breathe && !reduceMotion ? 1 : 0.88)
                .animation(
                    reduceMotion ? nil : .easeInOut(duration: 2.2).repeatForever(autoreverses: true),
                    value: breathe
                )
            Text("还没有媒体源")
                .font(.title2.weight(.semibold))
            Text("添加本地文件夹、移动硬盘、网络挂载或 Emby 媒体库后即可开始扫描。")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
            HStack(spacing: 8) {
                Image(systemName: "arrow.right.circle.fill")
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.90))
                Text("前往 **媒体源** 添加")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(.top, 4)
        }
        // 内容在更高的卡片内水平+垂直居中，让磁盘动画位于空状态视觉中心。
        .frame(maxWidth: .infinity, minHeight: 480, alignment: .center)
        .padding(32)
        .staticSurfaceBackground(cornerRadius: 22)
        .onAppear { breathe = true }
    }
}

struct ScanProgressView: View {
    @EnvironmentObject private var appState: AppState
    let progress: ScanProgress

    var body: some View {
        let source = appState.sources.first { $0.id == progress.sourceID }
        let hidesPath = source?.mediaType == .privateCollection && !appState.privacyUnlocked

        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(hidesPath ? "正在扫描\(appState.settings.privacyVaultName)媒体源" : "正在扫描")
                    .font(.headline)
                Spacer()
                Text("\(progress.processedFiles)/\(progress.totalFiles)")
                    .foregroundStyle(.secondary)
            }
            ProgressView(value: progress.fraction)
                .tint(AppColors.selectedGlassTint)
            if hidesPath {
                Text("路径和文件名已隐藏")
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
