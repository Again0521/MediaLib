import AppKit
import ImageIO
import MediaLibCore
import SwiftUI

/// 相册一级目录的内容页：照片 App 风格的方形缩略图网格，按拍摄日期分组，二级分段「全部 / 照片 / 录像」。
/// 照片点开走共享全屏查看器（缩放/平移/翻页/信息），录像点开直接交给现有视频播放器。
enum AlbumContentSource: String, CaseIterable, Identifiable {
    case local
    case system
    var id: String { rawValue }
    var title: String { self == .local ? "本地相册" : "系统照片" }
}

/// 相册网格排版方式：原比例瀑布式（保留宽高比）/ 方形裁切（统一正方形）。
enum AlbumLayoutStyle: String, CaseIterable, Identifiable {
    case aspect
    case square
    var id: String { rawValue }
    var title: String { self == .aspect ? "原比例" : "方形" }
    var icon: String { self == .aspect ? "rectangle.3.offgrid" : "square.grid.2x2" }
}

/// 排序方式：按拍摄时间从新到旧 / 从旧到新。
enum AlbumSortOrder: String, CaseIterable, Identifiable {
    case newest
    case oldest
    var id: String { rawValue }
    var title: String { self == .newest ? "最新在前" : "最早在前" }
}

/// 缩略图大小（影响每行高度 / 方形边长）。
enum AlbumThumbnailSize: String, CaseIterable, Identifiable {
    case small
    case medium
    case large
    var id: String { rawValue }
    var title: String {
        switch self {
        case .small: return "小"
        case .medium: return "中"
        case .large: return "大"
        }
    }
    /// 原比例模式的目标行高。
    var rowHeight: CGFloat {
        switch self {
        case .small: return 120
        case .medium: return 168
        case .large: return 220
        }
    }
    /// 方形模式的最小边长。
    var squareMin: CGFloat {
        switch self {
        case .small: return 96
        case .medium: return 132
        case .large: return 176
        }
    }
}

struct AlbumLibraryView: View {
    @EnvironmentObject private var appState: AppState
    @EnvironmentObject private var systemPhotoLibrary: SystemPhotoLibraryStore
    let section: AlbumLibrarySection

    /// 当前在全屏查看器中的条目下标（指向 `items`）。nil 表示查看器关闭。
    @State private var viewerIndex: Int?
    @AppStorage("MediaLib.album.contentSource") private var contentSourceRaw = AlbumContentSource.local.rawValue
    @AppStorage("MediaLib.album.systemCollection") private var systemCollectionID = "all"
    @AppStorage("MediaLib.album.layoutStyle") private var layoutStyleRaw = AlbumLayoutStyle.aspect.rawValue
    @AppStorage("MediaLib.album.thumbnailSize") private var thumbnailSizeRaw = AlbumThumbnailSize.medium.rawValue
    @AppStorage("MediaLib.album.sortOrder") private var sortOrderRaw = AlbumSortOrder.newest.rawValue
    @StateObject private var aspectStore = AlbumAspectRatioStore()
    @State private var selectionMode = false
    @State private var selectedIDs: Set<String> = []
    @State private var showDeleteConfirm = false
    @State private var viewerPendingDelete: MediaItem?
    @State private var viewerPendingSystemDeleteID: String?

    private var contentSource: AlbumContentSource {
        AlbumContentSource(rawValue: contentSourceRaw) ?? .local
    }
    private var layoutStyle: AlbumLayoutStyle { AlbumLayoutStyle(rawValue: layoutStyleRaw) ?? .aspect }
    private var thumbnailSize: AlbumThumbnailSize { AlbumThumbnailSize(rawValue: thumbnailSizeRaw) ?? .medium }
    private var sortOrder: AlbumSortOrder { AlbumSortOrder(rawValue: sortOrderRaw) ?? .newest }

    private func aspectRatio(for item: MediaItem) -> Double {
        aspectStore.ratio(for: item)
    }

    private var itemIndexByID: [String: Int] {
        Dictionary(uniqueKeysWithValues: items.enumerated().map { ($0.element.id, $0.offset) })
    }

    /// 可视区前向预取：某 cell 出现时，预热其后约 16 张缩略图（disk/内存暖起来，前滚不卡）。
    private func prefetchAfter(_ item: MediaItem, indexMap: [String: Int]) {
        guard let idx = indexMap[item.id] else { return }
        let side = layoutStyle == .square ? thumbnailSize.squareMin : thumbnailSize.rowHeight
        let end = min(idx + 16, items.count)
        guard idx + 1 < end else { return }
        for i in (idx + 1)..<end {
            if let path = items[i].posterPath, !path.contains("://") {
                PhotoThumbnailService.shared.prefetch(path: path, displaySide: side)
            }
        }
    }

    private func stepThumbnailSize(_ delta: Int) {
        let all = AlbumThumbnailSize.allCases
        guard let idx = all.firstIndex(of: thumbnailSize) else { return }
        let next = min(max(idx + delta, 0), all.count - 1)
        if all[next] != thumbnailSize {
            withAnimation(AppMotion.standard) { thumbnailSizeRaw = all[next].rawValue }
        }
    }

    private var items: [MediaItem] {
        let base = appState.items(for: .album(section))   // 默认拍摄时间从新到旧
        return sortOrder == .oldest ? Array(base.reversed()) : base
    }

    private var systemAssets: [SystemPhotoAsset] {
        systemPhotoLibrary.assets(for: section, sortOrder: sortOrder)
    }

    private var dateGroups: [AlbumDateGroup] {
        // 性能：分组涉及逐项 Calendar.startOfDay + 每组 DateFormatter，原先每次 body 求值都全量重算，
        // 是相册/系统照片页滑动掉帧的主因之一。cachedAlbumItems 只在媒体库变更（libraryRevision 自增）时改变，
        // 故以 (section, sortOrder, libraryRevision) 为键做单条记忆化；命中时连 items（filter+reverse）都不重算。
        AlbumDateGroupCache.groups(
            key: AlbumDateGroupCache.Key(
                section: section,
                sortOrder: sortOrder,
                revision: appState.libraryRevision
            ),
            build: { items }
        )
    }

    var body: some View {
        GeometryReader { geo in
            let gridWidth = max(geo.size.width - AppSpacing.pageHorizontal * 2, 0)
            ScrollView {
                VStack(alignment: .leading, spacing: AppSpacing.headerToControls) {
                    header
                    // 控制条置于网格之上参与命中测试：即便布局/光效层与首行照片相邻，
                    // 落在来源切换按钮上的点击也始终交给按钮，而不是被下方照片单元抢走。
                    albumControls
                        .zIndex(1)

                    if contentSource == .system {
                        SystemPhotoGridView(
                            assets: systemAssets,
                            section: section,
                            containerWidth: gridWidth,
                            layoutStyle: layoutStyle,
                            thumbnailSize: thumbnailSize,
                            sortOrder: sortOrder,
                            selectionMode: selectionMode,
                            selectedIDs: selectedIDs,
                            onActivate: activateSystemAsset
                        )
                            .environmentObject(appState)
                    } else if items.isEmpty {
                        EmptyStateView(
                            title: emptyTitle,
                            systemImage: section.systemImage,
                            message: emptyMessage
                        )
                        .frame(maxWidth: .infinity, minHeight: 360)
                    } else {
                        groupedContent(width: gridWidth)
                    }
                }
                .pageContainer()
            }
            // 用 simultaneousGesture 而非 gesture：捏合缩放不再与控制条按钮的点击/悬停竞争，
            // 避免落在「本地相册 / 系统照片」按钮上的点击被手势识别器拦截或转交到下方网格。
            .simultaneousGesture(
                MagnificationGesture()
                    .onEnded { value in
                        if value > 1.18 { stepThumbnailSize(1) }
                        else if value < 0.85 { stepThumbnailSize(-1) }
                    }
            )
            .task(id: items.count) {
                if layoutStyle == .aspect { aspectStore.ensureLoaded(items) }
            }
            .task(id: "\(contentSource.rawValue)|\(systemCollectionID)") {
                if contentSource == .system {
                    await systemPhotoLibrary.activate(collectionID: systemCollectionID)
                    if !systemPhotoLibrary.collections.contains(where: { $0.id == systemCollectionID }) {
                        systemCollectionID = "all"
                    }
                }
            }
            .onChange(of: layoutStyleRaw) { _ in
                if layoutStyle == .aspect { aspectStore.ensureLoaded(items) }
            }
            .onChange(of: contentSourceRaw) { _ in
                exitSelection()
                viewerIndex = nil
            }
        }
        .background(AppPageBackground())
        .background {
            // ⌘+ / ⌘- 调整缩略图大小（Apple 照片习惯）。
            VStack {
                Button("") { stepThumbnailSize(1) }.keyboardShortcut("=", modifiers: .command)
                Button("") { stepThumbnailSize(1) }.keyboardShortcut("+", modifiers: .command)
                Button("") { stepThumbnailSize(-1) }.keyboardShortcut("-", modifiers: .command)
            }
            .opacity(0)
            .frame(width: 0, height: 0)
        }
        .overlay { viewerOverlay }
        .confirmationDialog(
            contentSource == .system
                ? "从系统照片图库删除所选的 \(selectedIDs.count) 项？"
                : "删除所选的 \(selectedIDs.count) 项？",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button(contentSource == .system ? "移到最近删除" : "移到废纸篓", role: .destructive) {
                if contentSource == .system {
                    let ids = Array(selectedIDs)
                    Task {
                        if await systemPhotoLibrary.delete(assetIDs: ids) {
                            exitSelection()
                        }
                    }
                } else {
                    appState.deleteAlbumItems(selectedItems)
                    exitSelection()
                }
            }
            Button("取消", role: .cancel) {}
        } message: {
            Text(contentSource == .system
                 ? "这些项目会进入系统「照片」App 的“最近删除”，不会操作本地相册文件。"
                 : "文件会被移到废纸篓，可在访达中恢复。")
        }
        .confirmationDialog(
            "删除这张照片？",
            isPresented: Binding(get: { viewerPendingDelete != nil }, set: { if !$0 { viewerPendingDelete = nil } }),
            titleVisibility: .visible,
            presenting: viewerPendingDelete
        ) { item in
            Button("移到废纸篓", role: .destructive) {
                let wasLast = items.count <= 1
                appState.deleteAlbumItems([item])
                viewerPendingDelete = nil
                if wasLast { viewerIndex = nil }
            }
            Button("取消", role: .cancel) { viewerPendingDelete = nil }
        } message: { _ in
            Text("文件会被移到废纸篓，可在访达中恢复。")
        }
        .confirmationDialog(
            "从系统照片图库删除这个项目？",
            isPresented: Binding(
                get: { viewerPendingSystemDeleteID != nil },
                set: { if !$0 { viewerPendingSystemDeleteID = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("移到最近删除", role: .destructive) {
                guard let id = viewerPendingSystemDeleteID else { return }
                Task {
                    if await systemPhotoLibrary.delete(assetIDs: [id]) {
                        viewerPendingSystemDeleteID = nil
                        reconcileSystemViewerAfterChange()
                    }
                }
            }
            Button("取消", role: .cancel) { viewerPendingSystemDeleteID = nil }
        } message: {
            Text("该项目会进入系统「照片」App 的“最近删除”。")
        }
        .alert(
            "系统照片",
            isPresented: Binding(
                get: { systemPhotoLibrary.errorMessage != nil },
                set: { if !$0 { systemPhotoLibrary.errorMessage = nil } }
            )
        ) {
            Button("好") { systemPhotoLibrary.errorMessage = nil }
        } message: {
            Text(systemPhotoLibrary.errorMessage ?? "")
        }
    }

    // MARK: - 选择模式

    private var selectedItems: [MediaItem] {
        items.filter { selectedIDs.contains($0.id) }
    }

    private var selectedSystemAssets: [SystemPhotoAsset] {
        systemAssets.filter { selectedIDs.contains($0.id) }
    }

    private var allSelected: Bool {
        let ids = currentIDs
        return !ids.isEmpty && selectedIDs.count == ids.count
    }

    private var currentIDs: [String] {
        contentSource == .system ? systemAssets.map(\.id) : items.map(\.id)
    }

    private var albumControls: some View {
        AppAdaptiveControlBar {
            if selectionMode {
                Button(allSelected ? "取消全选" : "全选") {
                    if allSelected {
                        selectedIDs.removeAll()
                    } else {
                        selectedIDs = Set(currentIDs)
                    }
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 10,
                    horizontalPadding: 12,
                    minHeight: AppControlMetrics.defaultButtonHeight
                ))

                Text("\(selectedIDs.count) 已选")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            } else {
                ForEach(AlbumContentSource.allCases) { source in
                    Button {
                        contentSourceRaw = source.rawValue
                    } label: {
                        GlassCapsuleControl(isSelected: contentSource == source, enablePointerEdge: false) {
                            Label(
                                source.title,
                                systemImage: source == .local ? "externaldrive" : "photo.stack"
                            )
                        }
                        // 让整个胶囊（含内边距）都是可靠的命中区域，避免点击落在文字/图标之间的空隙时失效。
                        .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                }
            }
        } trailing: {
            if selectionMode {
                if let progress = systemPhotoLibrary.transferProgress {
                    ProgressView(value: progress)
                        .frame(width: 86)
                        .help("正在准备系统照片分享内容")
                }

                Button {
                    shareSelected()
                } label: {
                    Label("分享", systemImage: "square.and.arrow.up")
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 10,
                    horizontalPadding: 12,
                    minHeight: AppControlMetrics.defaultButtonHeight
                ))
                .disabled(selectedIDs.isEmpty || systemPhotoLibrary.isManaging)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Label("删除", systemImage: "trash").foregroundStyle(.red)
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 10,
                    horizontalPadding: 12,
                    minHeight: AppControlMetrics.defaultButtonHeight
                ))
                .disabled(selectedIDs.isEmpty || systemPhotoLibrary.isManaging)

                Button("完成") { exitSelection() }
                    .buttonStyle(LiquidGlassButtonStyle(
                        cornerRadius: 10,
                        horizontalPadding: 12,
                        minHeight: AppControlMetrics.defaultButtonHeight,
                        prominent: true
                    ))
            } else {
                if contentSource == .system {
                    GlassMenuButton(title: systemPhotoLibrary.selectedCollection.title) {
                        ForEach(systemPhotoLibrary.collections) { collection in
                            Button {
                                systemCollectionID = collection.id
                            } label: {
                                Label(
                                    collection.title,
                                    systemImage: systemCollectionID == collection.id
                                        ? "checkmark"
                                        : collection.systemImage
                                )
                            }
                        }
                    }
                }

                displayMenu

                Button {
                    if contentSource == .system {
                        Task { await systemPhotoLibrary.reload() }
                    } else {
                        appState.scanSources(for: .album(section))
                    }
                } label: {
                    Label(
                        contentSource == .system ? "刷新" : "扫描",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(LiquidGlassButtonStyle(
                    cornerRadius: 12,
                    horizontalPadding: 12,
                    minHeight: AppControlMetrics.defaultButtonHeight
                ))
                .disabled(contentSource == .system
                          ? systemPhotoLibrary.isLoading
                          : appState.isScanning)

                if !currentIDs.isEmpty {
                    Button {
                        selectionMode = true
                    } label: {
                        Label("选择", systemImage: "checkmark.circle")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(
                        cornerRadius: 12,
                        horizontalPadding: 12,
                        minHeight: AppControlMetrics.defaultButtonHeight
                    ))
                }
            }
        }
    }

    private var displayMenu: some View {
        GlassMenuButton(title: "显示") {
            Picker("排版", selection: layoutStyleBinding) {
                ForEach(AlbumLayoutStyle.allCases) { style in
                    Label(style.title, systemImage: style.icon).tag(style)
                }
            }
            Picker("缩略图大小", selection: thumbnailSizeBinding) {
                ForEach(AlbumThumbnailSize.allCases) { size in
                    Text(size.title).tag(size)
                }
            }
            Picker("排序", selection: sortOrderBinding) {
                ForEach(AlbumSortOrder.allCases) { order in
                    Text(order.title).tag(order)
                }
            }
        }
    }

    private func activate(_ item: MediaItem) {
        if selectionMode {
            if selectedIDs.contains(item.id) { selectedIDs.remove(item.id) }
            else { selectedIDs.insert(item.id) }
        } else {
            open(item)
        }
    }

    private func activateSystemAsset(_ asset: SystemPhotoAsset) {
        if selectionMode {
            if selectedIDs.contains(asset.id) {
                selectedIDs.remove(asset.id)
            } else {
                selectedIDs.insert(asset.id)
            }
        } else {
            systemPhotoLibrary.enrichResourceMetadata(assetID: asset.id)
            viewerIndex = systemAssets.firstIndex(of: asset)
        }
    }

    private func exitSelection() {
        selectionMode = false
        selectedIDs.removeAll()
    }

    private func shareSelected() {
        if contentSource == .system {
            shareSystemAssets(Array(selectedIDs))
        } else {
            share(selectedItems)
        }
    }

    private func share(_ targets: [MediaItem]) {
        let urls = targets.compactMap { $0.filePath.map { URL(fileURLWithPath: $0) } }
        showSharingPicker(urls)
    }

    private func shareSystemAssets(_ ids: [String]) {
        Task {
            let urls = await systemPhotoLibrary.export(assetIDs: ids)
            showSharingPicker(urls)
        }
    }

    private func showSharingPicker(_ urls: [URL]) {
        guard !urls.isEmpty, let window = NSApp.keyWindow, let view = window.contentView else { return }
        let picker = NSSharingServicePicker(items: urls)
        picker.show(relativeTo: .zero, of: view, preferredEdge: .minY)
    }

    // MARK: - 头部

    private var header: some View {
        PageHeader(
            title: section.title,
            subtitle: contentSource == .system ? systemCountSummary : "相册 · \(countSummary)",
            systemImage: section.systemImage
        )
    }

    private var layoutStyleBinding: Binding<AlbumLayoutStyle> {
        Binding(get: { layoutStyle }, set: { layoutStyleRaw = $0.rawValue })
    }

    private var thumbnailSizeBinding: Binding<AlbumThumbnailSize> {
        Binding(get: { thumbnailSize }, set: { thumbnailSizeRaw = $0.rawValue })
    }

    private var sortOrderBinding: Binding<AlbumSortOrder> {
        Binding(get: { sortOrder }, set: { sortOrderRaw = $0.rawValue })
    }

    private var countSummary: String {
        let photos = items.filter { $0.type == .photo }.count
        let videos = items.count - photos
        switch section {
        case .all:
            return "\(items.count) 项 · \(photos) 张照片 · \(videos) 段录像"
        case .photos:
            return "\(photos) 张照片"
        case .videos:
            return "\(videos) 段录像"
        }
    }

    private var systemCountSummary: String {
        let photos = systemAssets.filter { !$0.isVideo }.count
        let videos = systemAssets.count - photos
        return "\(systemPhotoLibrary.selectedCollection.title) · \(systemAssets.count) 项 · \(photos) 张照片 · \(videos) 段录像"
    }

    // MARK: - 分组网格

    private func groupedContent(width: CGFloat) -> some View {
        let indexMap = itemIndexByID
        return LazyVStack(alignment: .leading, spacing: 24) {
            ForEach(dateGroups) { group in
                VStack(alignment: .leading, spacing: 10) {
                    Text(group.title)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    if layoutStyle == .square {
                        LazyVGrid(columns: squareColumns, spacing: 3) {
                            ForEach(group.items) { item in
                                Color.clear
                                    .aspectRatio(1, contentMode: .fit)
                                    .overlay {
                                        AlbumGridCell(
                                            item: item,
                                            displaySize: CGSize(width: thumbnailSize.squareMin, height: thumbnailSize.squareMin),
                                            selectionMode: selectionMode,
                                            isSelected: selectedIDs.contains(item.id)
                                        ) { activate(item) }
                                    }
                                    .clipped()
                                    .onAppear { prefetchAfter(item, indexMap: indexMap) }
                            }
                        }
                    } else {
                        JustifiedPhotoGrid(
                            items: group.items,
                            containerWidth: width,
                            aspectRatio: aspectRatio(for:),
                            targetRowHeight: thumbnailSize.rowHeight
                        ) { item, size in
                            AlbumGridCell(
                                item: item,
                                displaySize: size,
                                selectionMode: selectionMode,
                                isSelected: selectedIDs.contains(item.id)
                            ) { activate(item) }
                            .onAppear { prefetchAfter(item, indexMap: indexMap) }
                        }
                    }
                }
            }
        }
    }

    private var squareColumns: [GridItem] {
        [GridItem(.adaptive(minimum: thumbnailSize.squareMin, maximum: thumbnailSize.squareMin * 1.6), spacing: 3)]
    }

    private func open(_ item: MediaItem) {
        viewerIndex = items.firstIndex(where: { $0.id == item.id })
    }

    // MARK: - 全屏查看器

    @ViewBuilder
    private var viewerOverlay: some View {
        if contentSource == .local, let start = viewerIndex, items.indices.contains(start) {
            MediaImageViewer(
                items: items.map(MediaImageViewerEntry.init(item:)),
                index: Binding(
                    get: { viewerIndex ?? start },
                    set: { viewerIndex = $0 }
                ),
                allowsFavorite: false,
                onClose: { viewerIndex = nil },
                onPlayVideo: { entry in
                    viewerIndex = nil
                    if let item = entry.item { appState.play(item) }
                },
                onShare: { entry in if let item = entry.item { share([item]) } },
                onDelete: { entry in viewerPendingDelete = entry.item }
            )
            .environmentObject(appState)
            .transition(.opacity)
            .zIndex(50)
        } else if contentSource == .system,
                  let start = viewerIndex,
                  systemAssets.indices.contains(start) {
            MediaImageViewer(
                items: systemAssets.map(MediaImageViewerEntry.init(systemAsset:)),
                index: Binding(
                    get: { viewerIndex ?? start },
                    set: { viewerIndex = $0 }
                ),
                allowsFavorite: false,
                onClose: { viewerIndex = nil },
                onShare: { entry in
                    guard let id = entry.photoAssetID else { return }
                    shareSystemAssets([id])
                },
                onDelete: { entry in
                    viewerPendingSystemDeleteID = entry.photoAssetID
                }
            )
            .environmentObject(appState)
            .transition(.opacity)
            .zIndex(50)
        }
    }

    private func reconcileSystemViewerAfterChange() {
        guard let current = viewerIndex else { return }
        if systemAssets.isEmpty {
            viewerIndex = nil
        } else {
            viewerIndex = min(current, systemAssets.count - 1)
        }
    }

    private var emptyTitle: String {
        switch section {
        case .all: return "相册还是空的"
        case .photos: return "暂无照片"
        case .videos: return "暂无录像"
        }
    }

    private var emptyMessage: String {
        "前往「媒体源」把一个图片/视频文件夹添加为「照片」类型，即可在这里浏览相册。"
    }
}

// MARK: - 日期分组

struct AlbumDateGroup: Identifiable {
    let id: String
    let title: String
    let items: [MediaItem]

    static func grouped(_ items: [MediaItem]) -> [AlbumDateGroup] {
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [MediaItem]] = [:]
        for item in items {
            let day = calendar.startOfDay(for: item.createdAt)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(item)
        }
        // items 已按 createdAt 倒序，order 自然也是从新到旧。
        return order.map { day in
            AlbumDateGroup(
                id: ISO8601DateFormatter.albumDay.string(from: day),
                title: Self.title(for: day, calendar: calendar),
                items: buckets[day] ?? []
            )
        }
    }

    private static func title(for day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year) ? "M月d日" : "yyyy年M月d日"
        return formatter.string(from: day)
    }
}

private extension ISO8601DateFormatter {
    static let albumDay: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withFullDate]
        return formatter
    }()
}

/// 相册日期分组的单条记忆化缓存。相册一次只展示一个分区，last-one-wins 单条缓存即可命中绝大多数
/// 重复 body 求值；仅在主线程的 SwiftUI body 中访问（与同模块的 MusicLibrarySnapshotCache 同样模式），
/// 故无需上限或加锁。无副作用、命中即返回上次结果，不改变任何分组逻辑或视觉表现。
private enum AlbumDateGroupCache {
    struct Key: Equatable {
        let section: AlbumLibrarySection
        let sortOrder: AlbumSortOrder
        let revision: Int
    }

    private static var cachedKey: Key?
    private static var cachedValue: [AlbumDateGroup] = []

    static func groups(key: Key, build: () -> [MediaItem]) -> [AlbumDateGroup] {
        if let cachedKey, cachedKey == key { return cachedValue }
        let groups = AlbumDateGroup.grouped(build())
        cachedKey = key
        cachedValue = groups
        return groups
    }
}

// MARK: - 网格单元

private struct AlbumGridCell: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let displaySize: CGSize
    var selectionMode: Bool = false
    var isSelected: Bool = false
    let onOpen: () -> Void

    @State private var hovering = false

    private var isVideo: Bool { item.type != .photo }

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
                PhotoThumbnail(path: item.posterPath, displaySide: max(displaySize.width, displaySize.height))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipShape(shape)
                .overlay { if hovering, !selectionMode { shape.fill(.white.opacity(0.16)) } }
                .overlay {
                    if selectionMode {
                        shape.strokeBorder(isSelected ? AppColors.selectedGlassTint : .white.opacity(0.5), lineWidth: isSelected ? 3 : 1.5)
                    }
                }
                .overlay(alignment: .topLeading) {
                    if selectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(isSelected ? AppColors.selectedGlassTint : Color.white)
                            .background(Circle().fill(.black.opacity(isSelected ? 0 : 0.25)).padding(2))
                            .shadow(color: .black.opacity(0.35), radius: 2, y: 1)
                            .padding(6)
                    }
                }
                if isVideo {
                    HStack(spacing: 4) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                        if let label = durationLabel {
                            Text(label).font(.system(size: 10, weight: .semibold)).monospacedDigit()
                        }
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 4)
                    .background(.black.opacity(0.55), in: Capsule())
                    .padding(7)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(item.title)
        .contextMenu {
            Button(isVideo ? "播放" : "查看", systemImage: isVideo ? "play.fill" : "eye") { onOpen() }
            if let path = item.filePath {
                Divider()
                Button("在访达中显示", systemImage: "folder") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                }
                Button("拷贝文件", systemImage: "doc.on.doc") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.writeObjects([URL(fileURLWithPath: path) as NSURL])
                }
            }
        }
    }

    private var durationLabel: String? {
        guard let duration = item.duration, duration > 0 else { return nil }
        let total = Int(duration.rounded())
        let minutes = total / 60
        let seconds = total % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

// MARK: - 宽高比缓存

/// 相册照片宽高比来源：优先用扫描时写入的 resolution；旧库照片若缺尺寸，
/// 在后台读图片文件头（CGImageSource，仅元数据、很快）补齐，避免必须重扫才能按原比例排版。
@MainActor
final class AlbumAspectRatioStore: ObservableObject {
    @Published private var cached: [String: Double] = [:]
    private var inFlight: Set<String> = []

    func ratio(for item: MediaItem) -> Double {
        if let parsed = Self.parse(item.resolution) { return parsed }
        if let path = item.filePath, let value = cached[path] { return value }
        return 1
    }

    func ensureLoaded(_ items: [MediaItem]) {
        let missing = items.compactMap { item -> String? in
            guard item.type == .photo, Self.parse(item.resolution) == nil,
                  let path = item.filePath, cached[path] == nil, !inFlight.contains(path) else { return nil }
            return path
        }
        guard !missing.isEmpty else { return }
        missing.forEach { inFlight.insert($0) }
        Task.detached(priority: .utility) {
            var results: [String: Double] = [:]
            for path in missing {
                if let ratio = Self.readAspect(path) { results[path] = ratio }
            }
            let resolvedResults = results
            await MainActor.run {
                for (key, value) in resolvedResults { self.cached[key] = value }
                missing.forEach { self.inFlight.remove($0) }
            }
        }
    }

    private static func parse(_ resolution: String?) -> Double? {
        guard let resolution else { return nil }
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2, let w = Double(parts[0]), let h = Double(parts[1]), w > 0, h > 0 else { return nil }
        return w / h
    }

    nonisolated private static func readAspect(_ path: String) -> Double? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Double,
              let h = props[kCGImagePropertyPixelHeight] as? Double,
              w > 0, h > 0 else { return nil }
        return w / h
    }
}
