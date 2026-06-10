import MediaLibCore
import SwiftUI

private enum LibrarySnapshotCache {
    struct Key: Hashable, Sendable {
        let destinationID: String
        let searchText: String
        let sortMode: LibrarySortMode
        let sortOrder: LibrarySortOrder
        let watchFilter: LibraryWatchFilter
        let genreFilter: String
        let revision: Int
        let favoriteRevision: Int
        let watchlistRevision: Int
        let ratingRevision: Int
        let videoCacheRevision: Int
        let cachedOnly: Bool
        let watchedThreshold: Double
    }

    private static var values: [Key: [MediaItem]] = [:]
    private static var accessTick: [Key: Int] = [:]
    private static var tickCounter = 0

    static func items(for key: Key) -> [MediaItem]? {
        guard let value = values[key] else { return nil }
        markRecentlyUsed(key)
        return value
    }

    static func store(_ items: [MediaItem], for key: Key) {
        values[key] = items
        markRecentlyUsed(key)
        if values.count > 24 {
            while values.count > 24,
                  let oldestKey = accessTick.min(by: { $0.value < $1.value })?.key {
                values.removeValue(forKey: oldestKey)
                accessTick.removeValue(forKey: oldestKey)
            }
        }
    }

    private static func markRecentlyUsed(_ key: Key) {
        tickCounter &+= 1
        accessTick[key] = tickCounter
    }
}

private struct LibrarySnapshotBuildInput: Sendable {
    let items: [MediaItem]
    let searchText: String
    let sortMode: LibrarySortMode
    let sortOrder: LibrarySortOrder
    let watchFilter: LibraryWatchFilter
    let genreFilter: String
    let cachedOnly: Bool
    let cachedScopeIDs: Set<String>
    let watchedThreshold: Double
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
            // 正在观看：点开看过、但还没完全看完的（看完的归入“已观看”，不再停留在这里）。
            case .watching: return item.hasPlaybackTrace && !(item.watched || item.playProgress >= input.watchedThreshold)
            case .unwatched: return !item.watched && item.playProgress < input.watchedThreshold
            case .watched: return item.watched || item.playProgress >= input.watchedThreshold
            case .favorites: return item.favorite
            case .watchlist: return item.watchlist
            }
        }

        let genreScoped: [MediaItem]
        if input.genreFilter.isEmpty {
            genreScoped = scoped
        } else {
            genreScoped = scoped.filter { item in
                guard let genre = item.genre else { return false }
                return genre.components(separatedBy: ", ").contains(input.genreFilter)
            }
        }

        let cacheScoped = input.cachedOnly
            ? genreScoped.filter { input.cachedScopeIDs.contains($0.id) }
            : genreScoped

        if input.sortMode == .collectionOrder {
            return input.sortOrder == .primary ? cacheScoped : Array(cacheScoped.reversed())
        }

        return cacheScoped.sorted { lhs, rhs in
            let primary: Bool
            switch input.sortMode {
            case .collectionOrder:
                primary = false
            case .recentlyUpdated:
                primary = lhs.updatedAt > rhs.updatedAt
            case .dateAdded:
                primary = lhs.createdAt > rhs.createdAt
            case .title:
                primary = lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
            case .year:
                primary = (lhs.year ?? 0) > (rhs.year ?? 0)
            case .runtime:
                primary = (lhs.runtime ?? 0) > (rhs.runtime ?? 0)
            case .progress:
                primary = lhs.playProgress > rhs.playProgress
            case .score:
                primary = (lhs.rating ?? 0) > (rhs.rating ?? 0)
            case .rating:
                primary = (lhs.userRating ?? 0) > (rhs.userRating ?? 0)
            }
            if primary { return input.sortOrder == .primary }
            let reversePrimary: Bool
            switch input.sortMode {
            case .collectionOrder:
                reversePrimary = false
            case .recentlyUpdated:
                reversePrimary = lhs.updatedAt < rhs.updatedAt
            case .dateAdded:
                reversePrimary = lhs.createdAt < rhs.createdAt
            case .title:
                reversePrimary = lhs.title.localizedStandardCompare(rhs.title) == .orderedDescending
            case .year:
                reversePrimary = (lhs.year ?? 0) < (rhs.year ?? 0)
            case .runtime:
                reversePrimary = (lhs.runtime ?? 0) < (rhs.runtime ?? 0)
            case .progress:
                reversePrimary = lhs.playProgress < rhs.playProgress
            case .score:
                reversePrimary = (lhs.rating ?? 0) < (rhs.rating ?? 0)
            case .rating:
                reversePrimary = (lhs.userRating ?? 0) < (rhs.userRating ?? 0)
            }
            if reversePrimary { return input.sortOrder == .reverse }
            return lhs.title.localizedStandardCompare(rhs.title) == .orderedAscending
        }
    }
}

private enum LibrarySortOrder: String, Sendable {
    case primary
    case reverse

    mutating func toggle() {
        self = self == .primary ? .reverse : .primary
    }

    var titleSuffix: String {
        self == .primary ? "正序" : "倒序"
    }

    var systemImage: String {
        self == .primary ? "arrow.down" : "arrow.up"
    }
}

struct LibraryView: View {
    @EnvironmentObject private var appState: AppState
    let destination: SidebarDestination
    @State private var searchText = ""
    @State private var sortMode: LibrarySortMode = .recentlyUpdated
    @State private var sortOrder: LibrarySortOrder = .primary
    @State private var watchFilter: LibraryWatchFilter = .all
    @State private var genreFilter: String = ""
    @State private var cachedOnly = false
    @State private var didLoadViewState = false
    @State private var visibleItems: [MediaItem] = []
    @State private var visibleItemsDestinationID = ""
    @State private var isPreparingVisibleItems = false
    @State private var contentRefreshTask: Task<Void, Never>?
    @State private var searchRefreshTask: Task<Void, Never>?
    @State private var smartCollectionEditor: VideoSmartCollectionEditorRequest?
    @State private var manualCollectionEditor: VideoManualCollectionEditorRequest?
    @State private var showBatchDeleteConfirm = false

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
                        message: "接入媒体源并完成扫描后，内容会自动归入此页。"
                    )
                    .frame(maxWidth: .infinity, minHeight: 420)
                }
            } else {
                // 海报墙走原生 List 虚拟化；页头与筛选条作为列表前导行随内容一起滚动，返回顶部按钮内置于 PosterGridList。
                PosterGridList(
                    items: displayedItems,
                    bottomInset: selectionBarBottomInset,
                    showsDeletePlaybackHistory: showsDeletePlaybackHistoryContextAction,
                    selectionEnabled: true,
                    restoreAnchorID: appState.selectedItemReturnAnchorID,
                    currentManualCollectionID: currentManualCollection?.id,
                    onDidRestoreAnchor: { appState.selectedItemReturnAnchorID = nil }
                ) {
                    VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                        libraryHeader
                        libraryControls
                    }
                }
                .overlay(alignment: .bottom) {
                    if appState.isSelectionModeActive {
                        batchActionBar(for: displayedItems)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.bottom, 18)
                            .transition(.move(edge: .bottom).combined(with: .opacity))
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
            presentContextTipsIfNeeded()
        }
        .onChange(of: searchText) { _ in
            scheduleSearchRefresh()
        }
        .onChange(of: destination) { newDestination in
            searchRefreshTask?.cancel()
            appState.exitSelectionMode()
            cachedOnly = false
            loadViewState(reset: true)
            refreshVisibleItems(for: newDestination, deferred: true)
        }
        .onChange(of: sortMode) { _ in
            saveViewState()
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: sortOrder) { _ in
            saveViewState()
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: watchFilter) { _ in
            saveViewState()
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: genreFilter) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: cachedOnly) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.libraryRevision) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.favoriteRevision) { _ in
            // 喜欢状态是乐观更新（只 bump favoriteRevision，不 bump libraryRevision）。
            // 没有这一处刷新，点喜欢后“喜欢”子筛选不会立即把新条目纳入。
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.watchlistRevision) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.ratingRevision) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onChange(of: appState.videoCacheRevision) { _ in
            searchRefreshTask?.cancel()
            refreshVisibleItems(for: destination, deferred: true)
        }
        .onDisappear {
            contentRefreshTask?.cancel()
            searchRefreshTask?.cancel()
            appState.exitSelectionMode()
        }
        .sheet(item: $smartCollectionEditor) { request in
            VideoSmartCollectionSheet(
                request: request,
                onSave: { collection in
                    smartCollectionEditor = nil
                    Task { @MainActor in
                        await Task.yield()
                        appState.saveVideoSmartCollection(collection)
                    }
                },
                onCancel: {
                    smartCollectionEditor = nil
                }
            )
        }
        .sheet(item: $manualCollectionEditor) { request in
            VideoManualCollectionSheet(
                request: request,
                onSave: { collection in
                    manualCollectionEditor = nil
                    Task { @MainActor in
                        await Task.yield()
                        appState.saveVideoManualCollection(collection)
                    }
                },
                onCancel: {
                    manualCollectionEditor = nil
                }
            )
        }
    }

    @ViewBuilder
    private var libraryHeader: some View {
        if let currentManualCollection {
            VideoManualCollectionPageHeader(
                title: title,
                subtitle: "按集合顺序整理专题片单。",
                previewItems: appState.videoManualCollectionPreviewItems(currentManualCollection, limit: 4)
            ) {
                libraryHeaderActions
            }
        } else {
            PageHeader(title: title, subtitle: "浏览、筛选和管理当前内容。", systemImage: destination.systemImage) {
                libraryHeaderActions
            }
        }
    }

    @ViewBuilder
    private var libraryHeaderActions: some View {
        if showsPlaybackHistoryAction {
            Button(role: .destructive) {
                appState.clearPlaybackHistory(playbackTraceItems)
            } label: {
                Label("清除记录", systemImage: "clock.badge.xmark")
                    .foregroundStyle(.red)
            }
            .disabled(playbackTraceItems.isEmpty)
        }

        if let smartCollection {
            Button {
                smartCollectionEditor = .edit(smartCollection)
            } label: {
                Label("编辑规则", systemImage: "slider.horizontal.3")
            }
            Button {
                appState.setVideoSmartCollectionHomeVisibility(smartCollection, showOnHome: !smartCollection.showOnHome)
            } label: {
                Label(smartCollection.showOnHome ? "从首页移除" : "发布到首页", systemImage: smartCollection.showOnHome ? "house.slash" : "house")
            }
        }

        if let currentManualCollection {
            Button {
                manualCollectionEditor = .edit(currentManualCollection)
            } label: {
                Label("重命名", systemImage: "pencil")
            }
            Button {
                appState.setVideoManualCollectionHomeVisibility(currentManualCollection, showOnHome: !currentManualCollection.showOnHome)
            } label: {
                Label(currentManualCollection.showOnHome ? "从首页移除" : "发布到首页", systemImage: currentManualCollection.showOnHome ? "house.slash" : "house")
            }
        }

        GlassSearchField(placeholder: "搜索\(title)", text: $searchText, minWidth: 158, maxWidth: 226)
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

        Button {
            withAnimation(AppMotion.fast) {
                appState.toggleSelectionMode()
            }
        } label: {
            Label(appState.isSelectionModeActive ? "完成" : "选择",
                  systemImage: appState.isSelectionModeActive ? "checkmark.circle" : "checklist")
        }
        .help("批量选择条目")
    }

    private func presentContextTipsIfNeeded() {
        switch destination {
        case .video, .embySection, .embyLibrary, .smartCollection, .manualCollection:
            appState.showInterfaceTipOnce(
                key: "library.video.context.cache",
                message: "想离线观看时，可以右键海报或单集选择缓存。"
            )
        default:
            break
        }
    }

    private var selectionBarBottomInset: CGFloat {
        appState.isSelectionModeActive ? scrollTopButtonBottomPadding + 64 : scrollTopButtonBottomPadding
    }

    /// C2 批量操作浮动栏：全选、标记已看/取消、想看、评级、清除记录、移出媒体库。
    @ViewBuilder
    private func batchActionBar(for displayedItems: [MediaItem]) -> some View {
        let selectedCount = appState.selectedItemIDs.count
        let allSelected = !displayedItems.isEmpty && displayedItems.allSatisfy { appState.selectedItemIDs.contains($0.id) }
        HStack(spacing: 12) {
            Button {
                withAnimation(AppMotion.fast) {
                    appState.setSelection(displayedItems.map(\.id), selected: !allSelected)
                }
            } label: {
                Label(allSelected ? "取消全选" : "全选", systemImage: allSelected ? "circle" : "checkmark.circle")
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 30, thickness: 0.94))

            Text("已选 \(selectedCount)")
                .font(.callout.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(minWidth: 56, alignment: .leading)

            Divider().frame(height: 20)

            Group {
                Button { appState.batchMarkWatched(watched: true) } label: {
                    Label("已看", systemImage: "eye.fill")
                }
                Button { appState.batchMarkWatched(watched: false) } label: {
                    Label("未看", systemImage: "eye.slash")
                }
                Button { appState.batchSetWatchlist(true) } label: {
                    Label("想看", systemImage: "bookmark.fill")
                }
                Menu {
                    VideoManualCollectionMenuItems(
                        items: appState.resolveSelectedItems(orderedBy: displayedItems),
                        currentCollectionID: currentManualCollection?.id
                    )
                } label: {
                    Label("集合", systemImage: "rectangle.stack.badge.plus")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                Menu {
                    ForEach((1...5).reversed(), id: \.self) { star in
                        Button("\(star) 星") { appState.batchUpdateRating(Double(star)) }
                    }
                    Divider()
                    Button("清除评级") { appState.batchUpdateRating(nil) }
                } label: {
                    Label("评级", systemImage: "star.fill")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()

                Button(role: .destructive) { appState.batchClearPlaybackHistory() } label: {
                    Label("清除记录", systemImage: "clock.badge.xmark")
                        .foregroundStyle(.red)
                }
                Button(role: .destructive) { showBatchDeleteConfirm = true } label: {
                    Label("移出库", systemImage: "trash")
                        .foregroundStyle(.red)
                }
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 30, thickness: 0.94))
            .disabled(selectedCount == 0)
        }
        .font(.callout)
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .liquidGlass(cornerRadius: 16)
        .confirmationDialog(
            "移出所选 \(selectedCount) 个条目？",
            isPresented: $showBatchDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("移出媒体库", role: .destructive) { appState.batchRemoveFromLibrary() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("仅从媒体库索引移除，磁盘上的原始文件不会被删除；本地来源在下次扫描后可能重新入库。")
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
        switch destination {
        case .video(.privacy):
            return appState.settings.privacyVaultName
        case .embyLibrary(let libraryID):
            return appState.embyLibraryTitle(libraryID)
        case .embySection(_, let section):
            return section.title
        case .smartCollection(let collectionID):
            return appState.videoSmartCollection(id: collectionID)?.name ?? "智能集合"
        case .manualCollection(let collectionID):
            return appState.videoManualCollection(id: collectionID)?.name ?? "集合"
        default:
            return destination.title
        }
    }

    private var scrollTopButtonBottomPadding: CGFloat {
        appState.activePlayerItem?.type == .music ? 122 : 22
    }

    private var smartCollection: VideoSmartCollection? {
        guard case .smartCollection(let collectionID) = destination else { return nil }
        return appState.videoSmartCollection(id: collectionID)
    }

    private var currentManualCollection: VideoManualCollection? {
        guard case .manualCollection(let collectionID) = destination else { return nil }
        return appState.videoManualCollection(id: collectionID)
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
            sortOrder: sortOrder,
            watchFilter: watchFilter,
            genreFilter: genreFilter,
            revision: appState.libraryRevision,
            favoriteRevision: appState.favoriteRevision,
            watchlistRevision: appState.watchlistRevision,
            ratingRevision: appState.ratingRevision,
            videoCacheRevision: appState.videoCacheRevision,
            cachedOnly: cachedOnly,
            watchedThreshold: appState.settings.watchedThreshold
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
        let cachedScopeIDs = key.cachedOnly ? appState.cachedVideoScopeIDs(in: baseItems) : []
        let input = LibrarySnapshotBuildInput(
            items: baseItems,
            searchText: key.searchText,
            sortMode: key.sortMode,
            sortOrder: key.sortOrder,
            watchFilter: key.watchFilter,
            genreFilter: key.genreFilter,
            cachedOnly: key.cachedOnly,
            cachedScopeIDs: cachedScopeIDs,
            watchedThreshold: key.watchedThreshold
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
        if watchFilter == .watching || watchFilter == .watched {
            return true
        }
        switch destination {
        case .video(.watching), .video(.watched), .embySection(_, .recent):
            return true
        default:
            return false
        }
    }

    private var showsDeletePlaybackHistoryContextAction: Bool {
        if showsPlaybackHistoryAction {
            return true
        }
        return destination == .video(.privacy)
    }

    private var libraryControls: some View {
        let genres = availableGenres
        let hasCachedVideos = appState.hasCachedVideos(in: appState.items(for: destination, searchText: ""))
        return HStack(spacing: 12) {
            LibraryWatchFilterCapsules(selection: $watchFilter)

            Spacer(minLength: 18)

            if hasCachedVideos {
                Button {
                    withAnimation(AppMotion.fast) {
                        cachedOnly.toggle()
                    }
                } label: {
                    GlassCapsuleControl(isSelected: cachedOnly, enablePointerEdge: false) {
                        Label("已缓存", systemImage: "arrow.down.circle.fill")
                    }
                }
                .buttonStyle(.plain)
                .help(cachedOnly ? "显示全部内容" : "只查看已缓存内容")
            }

            if !genres.isEmpty {
                GlassMenuButton(title: genreFilter.isEmpty ? "全部类型" : genreFilter) {
                    Button {
                        genreFilter = ""
                    } label: {
                        Label("全部类型", systemImage: genreFilter.isEmpty ? "checkmark" : "circle")
                    }
                    Divider()
                    ForEach(genres, id: \.self) { genre in
                        Button {
                            genreFilter = genre
                        } label: {
                            Label(genre, systemImage: genreFilter == genre ? "checkmark" : "circle")
                        }
                    }
                }
            }

            GlassMenuButton(title: "\(sortMode.title) · \(sortOrder.titleSuffix)") {
                ForEach(availableSortModes) { mode in
                    Button {
                        selectSortMode(mode)
                    } label: {
                        Label(mode.title, systemImage: sortMode == mode ? sortOrder.systemImage : "circle")
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
            sortMode = defaultSortMode(for: destination)
            sortOrder = .primary
            watchFilter = .all
            genreFilter = ""
            cachedOnly = false
        }
        guard !didLoadViewState else { return }
        didLoadViewState = true
        let defaultSortMode = defaultSortMode(for: destination)
        sortMode = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sort")
            .flatMap(LibrarySortMode.init(rawValue:)) ?? defaultSortMode
        let items = appState.items(for: destination, searchText: "")
        if sortMode.rawValue == "rating", !items.contains(where: { $0.userRating != nil }) && items.contains(where: { $0.rating != nil }) {
            sortMode = .score
        }
        if !availableSortModes.contains(sortMode) {
            sortMode = defaultSortMode
        }
        sortOrder = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).sortOrder")
            .flatMap(LibrarySortOrder.init(rawValue:)) ?? .primary
        watchFilter = UserDefaults.standard.string(forKey: "\(stateKeyPrefix).filter")
            .flatMap(LibraryWatchFilter.init(rawValue:)) ?? .all
    }

    private func saveViewState() {
        guard didLoadViewState else { return }
        UserDefaults.standard.set(sortMode.rawValue, forKey: "\(stateKeyPrefix).sort")
        UserDefaults.standard.set(sortOrder.rawValue, forKey: "\(stateKeyPrefix).sortOrder")
        UserDefaults.standard.set(watchFilter.rawValue, forKey: "\(stateKeyPrefix).filter")
    }

    private var availableGenres: [String] {
        var set = Set<String>()
        for item in appState.items(for: destination, searchText: "") {
            guard let genre = item.genre else { continue }
            for name in genre.components(separatedBy: ", ") where !name.trimmingCharacters(in: .whitespaces).isEmpty {
                set.insert(name)
            }
        }
        return set.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private var availableSortModes: [LibrarySortMode] {
        let items = appState.items(for: destination, searchText: "")
        let hasScore = items.contains { $0.rating != nil }
        let hasRating = items.contains { $0.userRating != nil }
        let hasRuntime = items.contains { ($0.runtime ?? 0) > 0 }
        let isManualCollection: Bool
        if case .manualCollection = destination {
            isManualCollection = true
        } else {
            isManualCollection = false
        }
        return LibrarySortMode.allCases.filter { mode in
            switch mode {
            case .collectionOrder: return isManualCollection
            case .score: return hasScore
            case .rating: return hasRating
            case .runtime: return hasRuntime
            default: return true
            }
        }
    }

    private func defaultSortMode(for targetDestination: SidebarDestination) -> LibrarySortMode {
        if case .manualCollection = targetDestination {
            return .collectionOrder
        }
        return .recentlyUpdated
    }

    private func selectSortMode(_ mode: LibrarySortMode) {
        if sortMode == mode {
            sortOrder.toggle()
        } else {
            sortMode = mode
            sortOrder = .primary
        }
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
    case collectionOrder
    case recentlyUpdated
    case dateAdded
    case title
    case year
    case runtime
    case progress
    case score
    case rating

    var id: String { rawValue }

    var title: String {
        switch self {
        case .collectionOrder: return "集合顺序"
        case .recentlyUpdated: return "最近更新"
        case .dateAdded: return "最近添加"
        case .title: return "标题"
        case .year: return "年份"
        case .runtime: return "时长"
        case .progress: return "观看进度"
        case .score: return "评分"
        case .rating: return "评级"
        }
    }
}

enum LibraryWatchFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case watching
    case unwatched
    case watched
    case watchlist
    case favorites

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: return "全部"
        case .watching: return "正在观看"
        case .unwatched: return "未观看"
        case .watched: return "已观看"
        case .watchlist: return "想看"
        case .favorites: return "喜欢"
        }
    }
}
