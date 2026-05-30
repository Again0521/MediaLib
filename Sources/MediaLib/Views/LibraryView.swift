import MediaLibCore
import SwiftUI

private enum LibrarySnapshotCache {
    struct Key: Hashable, Sendable {
        let destinationID: String
        let searchText: String
        let sortMode: LibrarySortMode
        let watchFilter: LibraryWatchFilter
        let revision: Int
    }

    private static var values: [Key: [MediaItem]] = [:]
    private static var accessOrder: [Key] = []

    static func items(for key: Key) -> [MediaItem]? {
        guard let value = values[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    static func store(_ items: [MediaItem], for key: Key) {
        values[key] = items
        markRecentlyUsed(key)
        if values.count > 24 {
            while values.count > 24, let oldestKey = accessOrder.first {
                accessOrder.removeFirst()
                values.removeValue(forKey: oldestKey)
            }
        }
    }

    private static func markRecentlyUsed(_ key: Key) {
        accessOrder.removeAll { $0 == key }
        accessOrder.append(key)
    }
}

private struct LibrarySnapshotBuildInput: Sendable {
    let items: [MediaItem]
    let searchText: String
    let sortMode: LibrarySortMode
    let watchFilter: LibraryWatchFilter
}

private enum LibrarySnapshotBuilder {
    static func visibleItems(from input: LibrarySnapshotBuildInput) -> [MediaItem] {
        let query = input.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let searched: [MediaItem]
        if query.isEmpty {
            searched = input.items
        } else {
            searched = input.items.filter {
                $0.title.localizedCaseInsensitiveContains(query) ||
                ($0.originalTitle?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.artist?.localizedCaseInsensitiveContains(query) ?? false) ||
                ($0.album?.localizedCaseInsensitiveContains(query) ?? false)
            }
        }

        let scoped = searched.filter { item in
            switch input.watchFilter {
            case .all: return true
            case .watching: return item.hasPlaybackTrace
            case .unwatched: return !item.watched && item.playProgress < 0.9
            case .watched: return item.watched || item.playProgress >= 0.9
            case .favorites: return item.favorite
            }
        }

        return scoped.sorted { lhs, rhs in
            switch input.sortMode {
            case .recentlyUpdated:
                return lhs.updatedAt > rhs.updatedAt
            case .title:
                return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .year:
                return (lhs.year ?? 0) > (rhs.year ?? 0)
            case .progress:
                return lhs.playProgress > rhs.playProgress
            }
        }
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    let destination: SidebarDestination
    @State private var searchText = ""
    @State private var sortMode: LibrarySortMode = .recentlyUpdated
    @State private var watchFilter: LibraryWatchFilter = .all
    @State private var didLoadViewState = false
    @State private var visibleItems: [MediaItem] = []
    @State private var visibleItemsDestinationID = ""
    @State private var isPreparingVisibleItems = false
    @State private var contentRefreshTask: Task<Void, Never>?
    @State private var searchRefreshTask: Task<Void, Never>?

    var body: some View {
        let displayedItems = currentItems

        Group {
            if (isPreparingVisibleItems || visibleItemsAreOutOfDate) && displayedItems.isEmpty {
                staticPage {
                    AppLoadingView(title: "正在载入\(title)", systemImage: destination.systemImage, rowCount: 4)
                }
            } else if displayedItems.isEmpty {
                staticPage {
                    EmptyStateView(
                        title: "暂无\(title)",
                        systemImage: destination.systemImage,
                        message: "添加媒体源并扫描后，这里会显示内容。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            } else {
                // P1：海报墙走原生 List 虚拟化；页头与筛选条作为列表前导行随内容一起滚动，
                // 返回顶部按钮内置于 PosterGridList。
                PosterGridList(items: displayedItems, bottomInset: scrollTopButtonBottomPadding) {
                    VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                        libraryHeader
                        libraryControls
                    }
                }
            }
        }
        .suppressListHighlight()
        .background(AppPageBackground())
        .navigationTitle(title)
        .onAppear {
            loadViewState()
            refreshVisibleItems(for: destination)
        }
        .onChange(of: searchText) { _ in
            scheduleSearchRefresh()
        }
        .onChange(of: destination) { newDestination in
            searchRefreshTask?.cancel()
            loadViewState(reset: true)
            refreshVisibleItems(for: newDestination, deferred: true)
        }
        .onChange(of: sortMode) { _ in
            saveViewState()
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: watchFilter) { _ in
            saveViewState()
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onDisappear {
            contentRefreshTask?.cancel()
            searchRefreshTask?.cancel()
        }
    }

    private var libraryHeader: some View {
        PageHeader(title: title, subtitle: "浏览、筛选和管理媒体条目。", systemImage: destination.systemImage) {
            if showsPlaybackHistoryAction {
                Button {
                    appState.clearPlaybackHistory(playbackTraceItems)
                } label: {
                    Label("清除记录", systemImage: "clock.badge.xmark")
                }
                .disabled(playbackTraceItems.isEmpty)
            }

            GlassSearchField(placeholder: "搜索\(title)", text: $searchText)
            Button {
                appState.scanSources(for: destination)
            } label: {
                Label("扫描", systemImage: "arrow.clockwise")
            }
            .disabled(appState.sources.isEmpty || appState.isScanning)

            if destination == .video(.privacy) {
                Button {
                    appState.lockPrivacy()
                } label: {
                    Label("锁定", systemImage: "lock")
                }
            }
        }
    }

    // 空状态 / 加载态：短内容仍用 ScrollView，复用页头与筛选条。
    private func staticPage<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                libraryHeader
                libraryControls
                content()
            }
            .pageContainer()
        }
        .suppressHoverEffectsDuringScroll()
    }

    private var title: String {
        destination == .video(.privacy) ? appState.settings.privacyVaultName : destination.title
    }

    private var scrollTopButtonBottomPadding: CGFloat {
        appState.activePlayerItem?.type == .music ? 122 : 22
    }

    private var currentItems: [MediaItem] {
        guard visibleItemsDestinationID != destination.id else { return visibleItems }
        return LibrarySnapshotCache.items(for: snapshotKey(for: destination)) ?? []
    }

    private var visibleItemsAreOutOfDate: Bool {
        visibleItemsDestinationID != destination.id &&
        LibrarySnapshotCache.items(for: snapshotKey(for: destination)) == nil
    }

    private func snapshotKey(for targetDestination: SidebarDestination) -> LibrarySnapshotCache.Key {
        LibrarySnapshotCache.Key(
            destinationID: targetDestination.id,
            searchText: searchText.trimmingCharacters(in: .whitespacesAndNewlines),
            sortMode: sortMode,
            watchFilter: watchFilter,
            revision: appState.libraryRevision
        )
    }

    private func refreshVisibleItems(for targetDestination: SidebarDestination, deferred: Bool = false) {
        contentRefreshTask?.cancel()
        let key = snapshotKey(for: targetDestination)
        if let cached = LibrarySnapshotCache.items(for: key) {
            visibleItems = cached
            visibleItemsDestinationID = targetDestination.id
            isPreparingVisibleItems = false
            return
        }

        // Only clear visible items when destination changes; keep showing old items
        // during filter/sort changes so the header doesn't jump.
        if visibleItemsDestinationID != targetDestination.id {
            visibleItemsDestinationID = ""
        }
        isPreparingVisibleItems = true
        contentRefreshTask = Task { @MainActor in
            if deferred {
                await Task.yield()
            }
            await computeVisibleItems(for: targetDestination, key: key)
        }
    }

    private func computeVisibleItems(for targetDestination: SidebarDestination, key: LibrarySnapshotCache.Key) async {
        guard !Task.isCancelled else { return }
        guard key == snapshotKey(for: targetDestination) else { return }

        let baseItems = appState.items(for: targetDestination, searchText: "")
        let input = LibrarySnapshotBuildInput(
            items: baseItems,
            searchText: key.searchText,
            sortMode: key.sortMode,
            watchFilter: key.watchFilter
        )
        let sorted = await Task.detached(priority: .userInitiated) {
            LibrarySnapshotBuilder.visibleItems(from: input)
        }.value

        guard !Task.isCancelled else { return }
        guard key == snapshotKey(for: targetDestination) else { return }
        visibleItems = sorted
        visibleItemsDestinationID = targetDestination.id
        isPreparingVisibleItems = false
        LibrarySnapshotCache.store(sorted, for: key)
    }

    private func scheduleSearchRefresh() {
        searchRefreshTask?.cancel()
        let targetDestination = destination
        searchRefreshTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 120_000_000)
            } catch {
                return
            }
            refreshVisibleItems(for: targetDestination, deferred: true)
        }
    }

    private var playbackTraceItems: [MediaItem] {
        currentItems.filter(\.hasPlaybackTrace)
    }

    private var showsPlaybackHistoryAction: Bool {
        switch destination {
        case .video(.watching), .emby(.recent):
            return true
        default:
            return false
        }
    }

    private var libraryControls: some View {
        HStack(spacing: 12) {
            LibraryWatchFilterCapsules(selection: $watchFilter)

            Spacer(minLength: 18)

            GlassMenuButton(title: sortMode.title, width: 156) {
                ForEach(LibrarySortMode.allCases) { mode in
                    Button {
                        sortMode = mode
                    } label: {
                        Label(mode.title, systemImage: sortMode == mode ? "checkmark" : "circle")
                    }
                }
            }
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity)
        .staticSurfaceBackground(cornerRadius: 16, thickness: 1.04)
    }

    private var stateKeyPrefix: String {
        "MediaLib.libraryState.\(destination.id)"
    }

    private func loadViewState(reset: Bool = false) {
        if reset {
            didLoadViewState = false
            sortMode = .recentlyUpdated
            watchFilter = .all
        }
        guard !didLoadViewState else { return }
        didLoadViewState = true
        sortMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sort")
            .flatMap(LibrarySortMode.init(rawValue:)) ?? .recentlyUpdated
        watchFilter = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).filter")
            .flatMap(LibraryWatchFilter.init(rawValue:)) ?? .all
    }

    private func saveViewState() {
        guard didLoadViewState else { return }
        UserDefaults.standard.set(sortMode.rawValue, forKey: "\(stateKeyPrefix).sort")
        UserDefaults.standard.set(watchFilter.rawValue, forKey: "\(stateKeyPrefix).filter")
    }
}

private struct LibraryWatchFilterCapsules: View {
    @Binding var selection: LibraryWatchFilter

    var body: some View {
        HStack(spacing: 7) {
            ForEach(LibraryWatchFilter.allCases) { filter in
                Button {
                    withAnimation(AppMotion.fast) {
                        selection = filter
                    }
                } label: {
                    GlassCapsuleControl(isSelected: selection == filter, enablePointerEdge: false) {
                        Text(filter.title)
                    }
                }
                .buttonStyle(.plain)
                .help(filter.title)
            }
        }
        .fixedSize()
    }
}


enum LibrarySortMode: String, CaseIterable, Identifiable, Sendable {
    case recentlyUpdated
    case title
    case year
    case progress

    var id: String { rawValue }

    var title: String {
        switch self {
        case .recentlyUpdated: return "最近更新"
        case .title: return "标题"
        case .year: return "年份"
        case .progress: return "观看进度"
        }
    }
}

enum LibraryWatchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case watching
    case unwatched
    case watched
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .watching: return "正在观看"
        case .unwatched: return "未观看"
        case .watched: return "已观看"
        case .favorites: return "收藏"
        }
    }
}
