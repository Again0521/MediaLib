import AppKit
import MediaLibCore
import SwiftUI
import UniformTypeIdentifiers

struct DetailView: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem
    let sourceTitle: String
    let sourceSystemImage: String
    @State private var showingMetadataSearch = false
    @State private var fileExists: Bool?
    @State private var fileStatusPath: String?

    init(item: MediaItem, sourceTitle: String = "详情", sourceSystemImage: String = "play.rectangle") {
        self.item = item
        self.sourceTitle = sourceTitle
        self.sourceSystemImage = sourceSystemImage
    }

    @State private var selectedEpisodeID: MediaItem.ID?
    @State private var artworkEntries: [MediaImageViewerEntry] = []
    @State private var artworkIndex: Int?
    @State private var detailSnapshot: MediaDetailSnapshot?
    @State private var isLoadingDetailSnapshot = false
    /// 已展开的季（多季时进入默认全部折叠）。
    @State private var expandedSeasonIDs: Set<String> = []

    /// 按季分组（保持剧集原有排序）；nil 季排最后。
    private struct SeasonGroup: Identifiable {
        let season: Int?
        let episodes: [MediaItem]

        var id: String { season.map(String.init) ?? "unspecified" }

        var title: String {
            guard let season else { return "未分季" }
            return season == 0 ? "特别篇" : "第 \(season) 季"
        }
    }

    private func seasonGroups(for episodes: [MediaItem]) -> [SeasonGroup] {
        let grouped = Dictionary(grouping: episodes) { $0.seasonNumber }
        return grouped
            .map { SeasonGroup(season: $0.key, episodes: $0.value) }
            .sorted { ($0.season ?? Int.max) < ($1.season ?? Int.max) }
    }

    /// 单条记忆化分季：原先每次 body 求值（滚动、展开/折叠季、详情快照加载等）都重跑 Dictionary 分组+排序。
    /// children(for:) 已是 O(1) 缓存读取，分季结果只取决于 (item.id, libraryRevision)，故以此为键单条缓存。
    /// 命中即返回，不改变任何分组/排序逻辑或展示。
    private enum SeasonGroupsCache {
        struct Key: Equatable {
            let itemID: String
            let revision: Int
        }
        static var cachedKey: Key?
        static var cachedValue: [SeasonGroup] = []
    }

    private func cachedSeasonGroups(for episodes: [MediaItem]) -> [SeasonGroup] {
        let key = SeasonGroupsCache.Key(itemID: item.id, revision: appState.libraryRevision)
        if let cachedKey = SeasonGroupsCache.cachedKey, cachedKey == key {
            return SeasonGroupsCache.cachedValue
        }
        let groups = seasonGroups(for: episodes)
        SeasonGroupsCache.cachedKey = key
        SeasonGroupsCache.cachedValue = groups
        return groups
    }

    var body: some View {
        let episodes = appState.children(for: item)

        // ★滚动抽搐/滑过底部露白的真正根因：把「头部变高内容(hero/extras/artist/表头)」和「剧集行」
        // 都塞进同一个 LazyVStack。LazyVStack 会回收滚出视口的行、并用「估算高度」占位；hero 和
        // TMDB 详情区是变高元素，一旦被回收再复现，高度从真实值退回估算值，整个内容总高度随之变化，
        // 表现为「滚动条一伸一缩、画面跳、快速上滑时漏掉一截、滑到底再滑露白」。
        // 修法：头部区块放进**非懒加载的普通 VStack**（永远布局、永不回收，高度恒为真实值）；
        // 只有「等高的剧集行」留在 LazyVStack 里（可能上千集需要懒加载），此时估算=真实，滚动稳定。
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                detailRow(top: 28, bottom: 8) { topBar }
                detailRow(top: 8, bottom: 8) { hero }

                if let detailSnapshot {
                    detailRow(top: 8, bottom: 8) {
                        MediaTMDBExtrasView(
                            item: item,
                            snapshot: detailSnapshot
                        ) { entries, index in
                                artworkEntries = entries
                                artworkIndex = index
                            }
                        .environmentObject(appState)
                    }
                } else if appState.supportsDetailExtras(item), isLoadingDetailSnapshot {
                    detailRow(top: 8, bottom: 8) {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text("正在整理演职人员、艺术照和相关作品…")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if item.type == .music, let artist = item.artist, !artist.trimmingCharacters(in: .whitespaces).isEmpty {
                    detailRow(top: 8, bottom: 8) {
                        MusicArtistInfoView(artistName: artist)
                            .environmentObject(appState)
                    }
                }

                if !episodes.isEmpty {
                    detailRow(top: 12, bottom: 6) { episodeHeader(episodes) }
                    let groups = cachedSeasonGroups(for: episodes)
                    LazyVStack(alignment: .leading, spacing: 0) {
                        if groups.count > 1 {
                            // 多季：按季分组、可折叠；进入详情默认全部折叠。
                            ForEach(groups) { group in
                                detailRow(top: 5, bottom: 5) { seasonHeader(group) }
                                    .id("season-header-\(group.id)")
                                if expandedSeasonIDs.contains(group.id) {
                                    ForEach(group.episodes) { episode in
                                        episodeRow(episode)
                                            .id("episode-\(episode.id)")
                                            .padding(.top, 5)
                                            .padding(.bottom, 5)
                                            .padding(.horizontal, AppSpacing.pageHorizontal)
                                    }
                                }
                            }
                        } else {
                            // 单季（或没有季信息）：直接平铺，不显示季分组。
                            ForEach(episodes) { episode in
                                episodeRow(episode)
                                    .id("episode-\(episode.id)")
                                    .padding(.top, 5)
                                    .padding(.bottom, 5)
                                    .padding(.horizontal, AppSpacing.pageHorizontal)
                            }
                        }
                    }
                    detailRow(top: 6, bottom: 28) { Color.clear.frame(height: 1) }
                } else {
                    detailRow(top: 12, bottom: 28) { fileStatus }
                }
            }
        }
        .transaction { transaction in
            transaction.animation = nil
        }
        .suppressHoverEffectsDuringScroll()
        .background(AppPageBackground())
        .overlay {
            if let index = artworkIndex, !artworkEntries.isEmpty {
                MediaImageViewer(
                    items: artworkEntries,
                    index: Binding(
                        get: { artworkIndex ?? index },
                        set: { artworkIndex = $0 }
                    ),
                    allowsFavorite: false,
                    onClose: { artworkIndex = nil }
                )
                .environmentObject(appState)
                .transition(.opacity)
                .zIndex(60)
            }
        }
        .frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $showingMetadataSearch) {
            MetadataSearchView(item: item)
                .environmentObject(appState)
        }
        .onAppear(perform: refreshFileStatus)
        .task(id: item.id) {
            guard appState.supportsDetailExtras(item) else {
                detailSnapshot = nil
                return
            }
            detailSnapshot = appState.cachedDetailSnapshot(for: item)
            isLoadingDetailSnapshot = detailSnapshot == nil
            detailSnapshot = await appState.loadDetailSnapshot(for: item) ?? detailSnapshot
            isLoadingDetailSnapshot = false
        }
        .task(id: "\(item.id)-episode-artwork-\(episodes.count)-\(appState.libraryRevision)") {
            let paths = Array(episodes.compactMap(\.posterPath).prefix(180))
            guard !paths.isEmpty else { return }
            await Task.yield()
            await ArtworkImageCache.prewarmImages(
                paths: paths,
                targetSize: CGSize(width: 240, height: 136)
            )
        }
        .onChange(of: item.id) { _ in
            refreshFileStatus()
            selectedEpisodeID = nil
            expandedSeasonIDs = []
            detailSnapshot = nil
            isLoadingDetailSnapshot = false
        }
        .background {
            RawKeyCaptureView { key in
                if key == .space, appState.settings.enableQuickPreview,
                   let selected = episodes.first(where: { $0.id == selectedEpisodeID }) ?? episodes.first {
                    appState.quickPreviewItem = selected
                } else if key == .escape {
                    if appState.quickPreviewItem != nil {
                        appState.quickPreviewItem = nil
                    } else {
                        appState.dismissDetail()
                    }
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func detailRow<Content: View>(top: CGFloat, bottom: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, top)
            .padding(.bottom, bottom)
            .padding(.horizontal, AppSpacing.pageHorizontal)
    }

    private func episodeHeader(_ episodes: [MediaItem]) -> some View {
        HStack {
            Text("剧集")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("\(episodes.count) 集")
                .monospacedDigit()
                .foregroundStyle(.secondary)
            let watchedThreshold = appState.settings.watchedThreshold
            let allWatched = episodes.allSatisfy { $0.watched || $0.playProgress >= watchedThreshold }
            Button {
                appState.markAllWatched(episodes, watched: !allWatched)
            } label: {
                Label(allWatched ? "标记全未看" : "标记全已看",
                      systemImage: allWatched ? "eye.slash" : "eye.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(AppStandardButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 28))
        }
    }

    private func seasonHeader(_ group: SeasonGroup) -> some View {
        let expanded = expandedSeasonIDs.contains(group.id)
        let watchedThreshold = appState.settings.watchedThreshold
        let watchedCount = group.episodes.filter { $0.watched || $0.playProgress >= watchedThreshold }.count
        return Button {
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                if expanded {
                    expandedSeasonIDs.remove(group.id)
                } else {
                    expandedSeasonIDs.insert(group.id)
                }
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                    // 只给箭头补旋转过渡：季行本体保持 disablesAnimations 的瞬时插入
                    // （大量剧集行做布局动画会重新触发滚动抽搐），叶子级 animation 不受其影响。
                    .animation(AppMotion.fast, value: expanded)
                Text(group.title)
                    .font(.headline.weight(.semibold))
                Text("\(group.episodes.count) 集")
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                if watchedCount > 0 {
                    Text(watchedCount == group.episodes.count ? "已看完" : "已看 \(watchedCount) 集")
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(watchedCount == group.episodes.count ? AppColors.selectedGlassTint.opacity(0.92) : Color.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .frame(height: 40)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .staticSurfaceBackground(selected: false, thickness: 1.12)
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        EpisodeRowView(episode: episode, selected: selectedEpisodeID == episode.id)
            .contentShape(Rectangle())
            .onTapGesture(count: 2) {
                selectedEpisodeID = episode.id
                appState.play(episode, preserveSelection: true)
            }
            .onTapGesture {
                selectedEpisodeID = episode.id
            }
            .contextMenu {
                Button {
                    appState.play(episode, preserveSelection: true)
                } label: {
                    Label("播放", systemImage: "play.fill")
                }
                Button {
                    appState.quickPreviewItem = episode
                } label: {
                    Label("快速预览", systemImage: "eye")
                }
                Button {
                    appState.openExternally(episode)
                } label: {
                    Label("外部打开", systemImage: "arrow.up.forward.app")
                }
                VideoCacheMenuItems(item: episode)
                VideoManualCollectionMenuItems(items: [episode])
                Divider()
                // #10 右键具体剧集只标记该集；已看完时提供“清除已观看”。
                if episode.watched {
                    Button {
                        appState.markWatched(episode, watched: false)
                    } label: {
                        Label("清除已观看", systemImage: "eye.slash")
                    }
                } else {
                    Button {
                        appState.markWatched(episode, watched: true)
                    } label: {
                        Label("标记为已观看", systemImage: "eye")
                    }
                }
            }
    }

    private var topBar: some View {
        PageHeader(title: sourceTitle, subtitle: nil, systemImage: sourceSystemImage) {
            Button {
                appState.dismissDetail()
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
    }

    private var hero: some View {
        let artworkAspectRatio = ArtworkMetrics.aspectRatio(for: item)
        let artworkWidth: CGFloat = artworkAspectRatio > 1.1 ? 320 : 210

        return HStack(alignment: .top, spacing: 24) {
            PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                .aspectRatio(artworkAspectRatio, contentMode: .fit)
                .frame(width: artworkWidth)
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.white.opacity(0.34), lineWidth: 0.85)
                }
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.10), .clear, AppColors.pointerLightTint.opacity(0.035)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                }
                .pointerInspectTilt(enabled: item.type != .music, cornerRadius: 12)
                .contextMenu {
                    if !appState.videoCacheQualityChoices(for: item).isEmpty {
                        VideoCacheMenuItems(item: item)
                        Divider()
                    }
                    if appState.canUseInVideoManualCollection(item) {
                        VideoManualCollectionMenuItems(items: [item])
                        Divider()
                    }
                    if appState.canCaptureVideoCover(for: item) {
                        Button {
                            appState.captureVideoCover(for: item)
                        } label: {
                            Label("从视频截取封面", systemImage: "camera.viewfinder")
                        }
                    }
                    Button {
                        appState.chooseCustomArtwork(for: item, kind: .poster)
                    } label: {
                        Label("选择自定义封面", systemImage: "photo.badge.plus")
                    }
                    if item.type != .music {
                        Button {
                            appState.chooseCustomArtwork(for: item, kind: .backdrop)
                        } label: {
                            Label("选择背景图", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                // 收藏/想看按钮与标题文字垂直居中对齐（firstTextBaseline 会让胶囊按钮相对 34pt 大标题偏低）。
                HStack(alignment: .center, spacing: 8) {
                    Text(item.title)
                        .font(.system(size: 34, weight: .semibold))
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Button {
                        appState.toggleWatchlist(item)
                    } label: {
                        Image(systemName: item.watchlist ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(item.watchlist ? AppColors.selectedGlassTint : Color.primary)
                    }
                    .buttonStyle(AppStandardButtonStyle(cornerRadius: 14, horizontalPadding: 10, minHeight: 30))
                    .help(item.watchlist ? "移出想看" : "加入想看")
                    .accessibilityLabel(item.watchlist ? "移出想看" : "加入想看")
                    Button {
                        appState.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.favorite ? "heart.fill" : "heart")
                            .foregroundStyle(item.favorite ? Color.red : Color.primary)
                    }
                    .buttonStyle(AppStandardButtonStyle(cornerRadius: 14, horizontalPadding: 10, minHeight: 30))
                    .help(item.favorite ? "取消喜欢" : "喜欢")
                    .accessibilityLabel(item.favorite ? "取消喜欢" : "喜欢")
                }

                DetailMetadataFlow {
                    DetailMetadataChip(title: item.displayYear, systemImage: "calendar")
                    if let rating = item.rating {
                        DetailMetadataChip(title: String(format: "%.1f", rating), systemImage: "star.fill")
                    }
                    if let runtime = item.runtime {
                        DetailMetadataChip(title: "\(runtime) 分钟", systemImage: "clock")
                    }
                    if let resolution = item.resolution {
                        DetailMetadataChip(title: resolution, systemImage: "rectangle.expand.vertical")
                    }
                    if let status = detailSnapshot?.metadata.status, !status.isEmpty {
                        DetailMetadataChip(title: status, systemImage: "dot.radiowaves.left.and.right")
                    }
                    if let rating = detailSnapshot?.metadata.contentRating, !rating.isEmpty {
                        DetailMetadataChip(title: rating, systemImage: "person.crop.circle.badge.checkmark")
                    }
                    if let seasonCount = detailSnapshot?.metadata.seasonCount, seasonCount > 0 {
                        DetailMetadataChip(title: "\(seasonCount) 季", systemImage: "rectangle.stack")
                    }
                    if let episodeCount = detailSnapshot?.metadata.episodeCount, episodeCount > 0 {
                        DetailMetadataChip(title: "\(episodeCount) 集", systemImage: "list.number")
                    }
                }

                ratingControl

                if let collection = item.collectionTitle {
                    Label(collection, systemImage: "square.stack.3d.up")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 5)
                        .background(AppColors.selectedGlassTint.opacity(0.12), in: Capsule())
                        .overlay {
                            Capsule().stroke(AppColors.cleanPanelBorder, lineWidth: 0.8)
                        }
                        .fixedSize()
                }

                Text(item.overview.flatMap { $0.isEmpty ? nil : $0 } ?? "暂无简介。")
                    .foregroundStyle(.secondary)
                    .lineLimit(6)

                if !genreTags.isEmpty {
                    DetailGenreTagFlow(genres: genreTags)
                }

                if let detailSnapshot {
                    let organizations = detailSnapshot.metadata.networks + detailSnapshot.metadata.productionCompanies
                    if !organizations.isEmpty {
                        Label(
                            Array(organizations.prefix(4)).joined(separator: " · "),
                            systemImage: "building.2"
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                    }
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            appState.play(item, preserveSelection: true)
                        } label: {
                            Label(
                                appState.playbackActionTitle(for: item),
                                systemImage: appState.isMlinkWebPlaybackItem(item) ? "safari" : "play.fill"
                            )
                        }
                        .buttonStyle(AppPrimaryButtonStyle(horizontalPadding: 14, minHeight: 34))
                        .disabled(!appState.canStartPlayback(for: item))
                        .accessibilityHint(
                            appState.isMlinkWebPlaybackItem(item)
                                ? "在默认浏览器中打开服务端详情页，由网页端解码播放。"
                                : "开始播放此媒体。"
                        )

                        Button {
                            appState.openExternally(item)
                        } label: {
                            Label("外部打开", systemImage: "arrow.up.forward.app")
                        }
                        .disabled(item.filePath == nil)

                        Button {
                            appState.markWatched(item, watched: !item.watched)
                        } label: {
                            Label(item.watched ? "标记未看" : "标记已看", systemImage: item.watched ? "eye.slash" : "eye")
                        }

                        Button {
                            showingMetadataSearch = true
                        } label: {
                            Label(item.type == .music ? "搜索音乐信息" : "搜索 TMDB", systemImage: "magnifyingglass")
                        }

                        if appState.canUndoLatestMetadataCorrection(for: item) {
                            Button {
                                appState.undoLatestMetadataCorrection(for: item)
                            } label: {
                                Label("撤销元数据", systemImage: "arrow.uturn.backward")
                            }
                        }

                        if item.type == .movie,
                           item.externalID?.hasPrefix("tmdb:movie:") == true,
                           item.collectionTitle == nil {
                            Button {
                                Task { await appState.fetchTMDBCollection(for: item) }
                            } label: {
                                Label("获取合集", systemImage: "square.stack.3d.up")
                            }
                        }
                    }
                    .buttonStyle(AppStandardButtonStyle(horizontalPadding: 12, minHeight: 34))
                    .fixedSize(horizontal: true, vertical: false)
                }
                // 横向操作条会吞掉落在按钮上的纵向触控板滚动，放行给外层详情列表。
                .verticalScrollPassthroughFromNestedHorizontal()
            }
        }
        .padding(18)
        // 去掉原本盖在卡片上的灰色氛围层（模糊海报 + cleanPanelFill 灰渐变），
        // 仅保留下面这张圆角玻璃卡片本体与描边。
        // 性能：hero 是详情列表里最大的一张卡，原先用实时 .regularMaterial 玻璃，
        // 列表上滑时这块大面积模糊层每帧都要离屏重合成，是“上滑卡顿”的主因。
        // 改用与海报卡同源的静态玻璃（无离屏材质、不采样指针），滚动恒定流畅；
        // 厚度由加强后的 flatSurface 投影补足，观感不降。
        .staticSurfaceBackground(cornerRadius: 24, thickness: 1.3)
        .repeatedCardChrome(false, cornerRadius: 24)
    }

    private var genreTags: [String] {
        guard item.type != .music,
              let genre = item.genre,
              !genre.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return []
        }
        var seen = Set<String>()
        return genre
            .components(separatedBy: CharacterSet(charactersIn: ",，/、"))
            .compactMap { raw in
                let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !value.isEmpty else { return nil }
                return seen.insert(value).inserted ? value : nil
            }
    }

    // 评级控件：与海报右键菜单「评级」共用同一份用户评级（item.userRating，1–5 星）。
    private var ratingControl: some View {
        let current = min(item.userRating.map { Int($0.rounded()) } ?? 0, 5)
        return HStack(spacing: 8) {
            Text("评级")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(spacing: 3) {
                ForEach(1...5, id: \.self) { star in
                    Button {
                        appState.updateRating(item, rating: star == current ? nil : Double(star))
                    } label: {
                        Image(systemName: star <= current ? "star.fill" : "star")
                            .font(.system(size: 15))
                            .foregroundStyle(star <= current ? Color.yellow : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(SubtleIconButtonStyle(minSize: 22))
                    .help("\(star) 星")
                }
            }
            if current > 0 {
                Button {
                    appState.updateRating(item, rating: nil)
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleIconButtonStyle(minSize: 22))
                .help("清除评级")
            }
        }
    }

    private var fileStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("文件")
                .font(.title3.weight(.semibold))
            if let filePath = item.filePath {
                let isRemote = item.isRemoteResource
                let exists = isRemote || (fileExists ?? false)
                let displayPath = isRemote ? remoteDisplayName : filePath
                HStack {
                    Image(systemName: exists ? (isRemote ? "cloud" : "checkmark.circle") : (fileExists == nil ? "hourglass" : "exclamationmark.triangle"))
                    Text(displayPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    if isRemote {
                        Button {
                            appState.play(item, preserveSelection: true)
                        } label: {
                            Label("打开", systemImage: "play.rectangle")
                        }
                    } else {
                        Button {
                            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                        } label: {
                            Label("定位", systemImage: "folder")
                        }
                        .disabled(!exists)
                    }
                }
                .foregroundStyle(exists ? Color.secondary : Color.orange)
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 10, minHeight: 30))
            } else {
                Text("路径未记录。")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: AppRadius.card, thickness: 1.04)
    }

    private var remoteDisplayName: String {
        guard item.isRemoteResource else { return item.filePath ?? "" }
        if let provider = item.metadataProvider,
           provider.localizedCaseInsensitiveContains("emby") ||
            provider.localizedCaseInsensitiveContains("jellyfin") {
            return "\(provider) 流媒体 · \(item.title)"
        }
        return item.filePath ?? "远程流媒体"
    }

    private func refreshFileStatus() {
        guard let filePath = item.filePath else {
            fileExists = nil
            fileStatusPath = nil
            return
        }
        fileStatusPath = filePath
        if item.isRemoteResource {
            fileExists = true
            return
        }
        fileExists = nil
        Task { @MainActor in
            let exists = await Self.localFileExists(atPath: filePath)
            guard fileStatusPath == filePath else { return }
            fileExists = exists
        }
    }

    nonisolated static func localFileExists(atPath path: String) async -> Bool {
        await BlockingIOExecutor.run {
            FileManager.default.fileExists(atPath: path)
        }
    }
}

private struct DetailMetadataFlow<Content: View>: View {
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        PosterBadgeFlowLayout(horizontalSpacing: 8, verticalSpacing: 7) {
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct DetailMetadataChip: View {
    let title: String
    let systemImage: String

    var body: some View {
        // 统一胶囊规格（C-R1 .appPillBadge）：中性元数据用中性色 tint，与类型标签的强调 tint 同源同形。
        Label(title, systemImage: systemImage)
            .appPillBadge(tint: AppColors.refSecondaryText)
    }
}

private struct DetailGenreTagFlow: View {
    let genres: [String]

    var body: some View {
        PosterBadgeFlowLayout(horizontalSpacing: 8, verticalSpacing: 7) {
            ForEach(genres, id: \.self) { genre in
                // 与元数据胶囊同一规格（C-R1 .appPillBadge），类型标签用强调 tint 区分。
                Text(genre)
                    .appPillBadge(tint: AppColors.selectedGlassTint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct MetadataSearchView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem

    @State private var query: String
    @State private var results: [MetadataSearchResult] = []
    @State private var isLoading = false
    @State private var message: String?

    private let service = MetadataSearchService()

    init(item: MediaItem) {
        self.item = item
        _query = State(initialValue: item.type == .music ? [item.artist, item.title].compactMap { $0 }.joined(separator: " ") : item.title)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.type == .music ? "搜索音乐信息" : "搜索 TMDB 信息")
                        .font(.title2.weight(.semibold))
                    Text(providerDescription)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    dismiss()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 10, minHeight: AppControlMetrics.defaultButtonHeight))
                .keyboardShortcut(.escape, modifiers: [])
            }

            HStack {
                TextField("搜索关键词", text: $query)
                    .glassFormField()
                    .onSubmit {
                        Task { await search() }
                    }
                Button {
                    Task { await search() }
                } label: {
                    Label("搜索", systemImage: "magnifyingglass")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: AppControlMetrics.defaultButtonHeight, prominent: true))
                .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isLoading)
            }

            if isLoading {
                ProgressView("正在搜索")
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else if let message {
                EmptyStateView(title: "暂无可用结果", systemImage: "magnifyingglass", message: message)
                    .frame(maxWidth: .infinity, minHeight: 220)
            } else {
                List {
                    ForEach(results) { result in
                        MetadataResultCard(
                            result: result
                        ) {
                            apply(result)
                        }
                        .listRowInsets(EdgeInsets(top: 5, leading: 2, bottom: 5, trailing: 2))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .suppressHoverEffectsDuringScroll()
                .frame(minHeight: 280)
            }
        }
        .padding(22)
        .frame(minWidth: 620, minHeight: 460)
        .background(AppPageBackground())
        .onAppear {
            if results.isEmpty, message == nil {
                Task { await search() }
            }
        }
    }

    private var providerDescription: String {
        if item.type == .music {
            return "当前音乐元数据源：\(appState.settings.musicMetadataProvider.displayName)"
        }
        return "使用设置中的 TMDB API 搜索电影和剧集信息。"
    }

    @MainActor
    private func search() async {
        let cleaned = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        isLoading = true
        message = nil
        do {
            if item.type == .music {
                results = try await service.searchMusic(query: cleaned, provider: appState.settings.musicMetadataProvider, lastfmAPIKey: appState.settings.lastfmAPIKey)
            } else {
                results = try await service.searchTMDB(
                    query: cleaned,
                    itemType: item.type,
                    apiKey: appState.settings.tmdbAPIKey,
                    language: appState.settings.tmdbLanguage
                )
            }
            if results.isEmpty {
                message = "未找到匹配结果，可调整关键词后重新搜索。"
            }
        } catch {
            results = []
            message = error.localizedDescription
        }
        isLoading = false
    }

    private func apply(_ result: MetadataSearchResult) {
        dismiss()
        appState.applyMetadataSearchResult(result, to: item)
    }
}

private struct MetadataResultCard: View {
    let result: MetadataSearchResult
    let onApply: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.title)
                        .font(.headline)
                        .lineLimit(2)
                    if let subtitle = result.subtitle, !subtitle.isEmpty {
                        Text(subtitle)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 12)
                Text(result.provider)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .staticSurfaceBackground(cornerRadius: 8, thickness: 0.80)
            }

            if let overview = result.overview, !overview.isEmpty {
                Text(overview)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }

            HStack {
                if let year = result.year {
                    Label("\(year)", systemImage: "calendar")
                }
                if let rating = result.rating {
                    Label(String(format: "%.1f", rating), systemImage: "star.fill")
                }
                Spacer()
                Button("应用") {
                    onApply()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28))
            }
            .font(.caption)
        }
        .padding(14)
        .staticSurfaceBackground(cornerRadius: 16)
    }
}

// MARK: - 字幕搜索弹层

struct SubtitleSearchSheet: View {
    @EnvironmentObject private var appState: AppState
    let item: MediaItem

    @State private var language: String = "zh-CN"
    @State private var results: [SubtitleResult] = []
    @State private var isSearching = false
    @State private var isDownloading = false
    @State private var statusMessage: String = ""
    @State private var downloadedPath: String?
    @State private var errorMessage: String?
    @Environment(\.dismiss) private var dismiss

    private let service = SubtitleSearchService()

    private let languageOptions: [(code: String, label: String)] = [
        ("zh-CN", "简体中文"),
        ("zh-TW", "繁体中文"),
        ("en", "English"),
        ("ja", "日本語"),
        ("ko", "한국어"),
        ("fr", "Français"),
        ("de", "Deutsch"),
        ("es", "Español")
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            content
        }
        .appSheetChrome(width: AppSheetMetrics.standardWidth, minHeight: 440)
        .onAppear {
            language = appState.settings.subtitleLanguage
            if appState.settings.openSubtitlesAPIKey?.isEmpty == false {
                Task { await runSearch() }
            }
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            AppSheetHeader(
                title: "搜索字幕",
                subtitle: item.title,
                systemImage: "captions.bubble",
                subtitleLineLimit: 1,
                truncationMode: .middle
            )
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 30, thickness: 0.92))
            .help("关闭")
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            // API Key 提示
            if appState.settings.openSubtitlesAPIKey?.isEmpty != false {
                AppInlineNoticeLabel(
                    text: "OpenSubtitles API Key 可在设置 → 元数据中配置。",
                    systemImage: "key.horizontal"
                )
                .padding(10)
                .staticSurfaceBackground(cornerRadius: 10)
            }

            // 语言 + 搜索
            HStack(spacing: 10) {
                Picker("语言", selection: $language) {
                    ForEach(languageOptions, id: \.code) { opt in
                        Text(opt.label).tag(opt.code)
                    }
                }
                .adaptiveMenuControl(
                    selectedTitle: languageOptions.first(where: { $0.code == language })?.label ?? language,
                    minWidth: 76,
                    maxWidth: 260
                )
                .onChange(of: language) { _ in
                    appState.settings.subtitleLanguage = language
                    appState.saveSettings()
                }

                Button {
                    Task { await runSearch() }
                } label: {
                    Label(isSearching ? "搜索中…" : "搜索", systemImage: "magnifyingglass")
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 30))
                .disabled(isSearching || isDownloading || appState.settings.openSubtitlesAPIKey?.isEmpty != false)
            }

            if let error = errorMessage {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle")
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                    Text(error)
                        .foregroundStyle(.orange)
                }
                .font(.caption)
                    .padding(10)
                    .staticSurfaceBackground(cornerRadius: 10)
            }

            if let path = downloadedPath {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                    Text("已保存：\(URL(fileURLWithPath: path).lastPathComponent)")
                        .foregroundStyle(.green)
                }
                .font(.caption)
                    .padding(10)
                    .staticSurfaceBackground(cornerRadius: 10)
            }

            if isSearching {
                HStack { Spacer(); ProgressView(); Spacer() }.padding()
            } else if results.isEmpty && !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center).padding()
            } else {
                List {
                    ForEach(results) { result in
                        subtitleRow(result)
                            .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                    }
                }
                .listStyle(.plain)
                .scrollContentBackground(.hidden)
                .environment(\.defaultMinListRowHeight, 0)
                .transaction { transaction in
                    transaction.animation = nil
                }
                .suppressHoverEffectsDuringScroll()
            }

            Spacer(minLength: 0)
        }
    }

    private func subtitleRow(_ result: SubtitleResult) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(result.displayName)
                    .font(.callout.weight(.medium))
                    .lineLimit(2)
                HStack(spacing: 8) {
                    Text(result.language.uppercased())
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 5).padding(.vertical, 2)
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                        .background(AppColors.selectedGlassTint.opacity(0.10), in: Capsule())
                        .overlay {
                            Capsule().stroke(AppColors.cleanPanelBorder, lineWidth: 0.7)
                        }
                    Text("\(result.downloadCount) 次下载")
                        .font(.caption2).foregroundStyle(.secondary)
                    if result.isHearingImpaired {
                        Label("听障版", systemImage: "ear.and.waveform")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            Spacer()
            Button {
                Task { await downloadSubtitle(result) }
            } label: {
                if isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.down.circle")
                }
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 10, horizontalPadding: 8, minHeight: 30, thickness: 0.96))
            .disabled(isDownloading || item.filePath == nil)
        }
        .padding(12)
        .staticSurfaceBackground(cornerRadius: 12)
    }

    private func runSearch() async {
        guard let apiKey = appState.settings.openSubtitlesAPIKey, !apiKey.isEmpty else {
            errorMessage = SubtitleError.missingAPIKey.errorDescription
            return
        }
        isSearching = true
        errorMessage = nil
        downloadedPath = nil
        defer { isSearching = false }

        do {
            let found = try await service.search(
                title: item.title,
                year: item.year,
                imdbID: item.externalID?.hasPrefix("tt") == true ? item.externalID : nil,
                language: language,
                apiKey: apiKey
            )
            results = found
            statusMessage = found.isEmpty ? "未找到匹配字幕，可尝试切换语言或用英文标题搜索。" : ""
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func downloadSubtitle(_ result: SubtitleResult) async {
        guard let apiKey = appState.settings.openSubtitlesAPIKey, !apiKey.isEmpty else { return }
        guard let videoPath = item.filePath else { return }
        isDownloading = true
        errorMessage = nil
        defer { isDownloading = false }

        do {
            let outputURL = try await service.downloadAndSave(fileID: result.fileID, videoPath: videoPath, apiKey: apiKey)
            downloadedPath = outputURL.path
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
