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

    private enum ArtworkKind { case poster, backdrop }

    @State private var selectedEpisodeID: MediaItem.ID?

    var body: some View {
        let episodes = appState.children(for: item)

        // P1：原 ScrollView + VStack（剧集走 LazyVStack）不回收，超长剧集（动漫上千集）会累积视图与缩略图。
        // 改为原生 List 真正虚拟化：顶栏 / 主信息 / 剧集表头作为行，剧集逐行回收。交互语义全部保留。
        List {
            detailRow(top: 28, bottom: 8) { topBar }
            detailRow(top: 8, bottom: 8) { hero }

            if item.type != .music, item.externalID?.hasPrefix("tmdb:") == true {
                detailRow(top: 8, bottom: 8) {
                    MediaTMDBExtrasView(item: item)
                        .environmentObject(appState)
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
                ForEach(episodes) { episode in
                    episodeRow(episode)
                        .listRowInsets(EdgeInsets(top: 5, leading: AppSpacing.pageHorizontal, bottom: 5, trailing: AppSpacing.pageHorizontal))
                        .listRowBackground(Color.clear)
                        .listRowSeparator(.hidden)
                }
                detailRow(top: 6, bottom: 28) { Color.clear.frame(height: 1) }
            } else {
                detailRow(top: 12, bottom: 28) { fileStatus }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .environment(\.defaultMinListRowHeight, 0)
        .suppressHoverEffectsDuringScroll()
        .suppressListHighlight()
        .background(AppPageBackground())
        .frame(minWidth: 820, minHeight: 620)
        .sheet(isPresented: $showingMetadataSearch) {
            MetadataSearchView(item: item)
                .environmentObject(appState)
        }
        .onAppear(perform: refreshFileStatus)
        .onChange(of: item.id) { _ in
            refreshFileStatus()
            selectedEpisodeID = nil
        }
        .background {
            KeyCaptureView { key in
                if key == .space, appState.settings.enableQuickPreview,
                   let selected = episodes.first(where: { $0.id == selectedEpisodeID }) ?? episodes.first {
                    appState.quickPreviewItem = selected
                } else if key == .escape {
                    if appState.quickPreviewItem != nil {
                        appState.quickPreviewItem = nil
                    } else {
                        appState.selectedItem = nil
                    }
                }
            }
            .frame(width: 0, height: 0)
        }
    }

    @ViewBuilder
    private func detailRow<Content: View>(top: CGFloat, bottom: CGFloat, @ViewBuilder _ content: () -> Content) -> some View {
        content()
            .listRowInsets(EdgeInsets(top: top, leading: AppSpacing.pageHorizontal, bottom: bottom, trailing: AppSpacing.pageHorizontal))
            .listRowBackground(Color.clear)
            .listRowSeparator(.hidden)
    }

    private func episodeHeader(_ episodes: [MediaItem]) -> some View {
        HStack {
            Text("剧集")
                .font(.title3.weight(.semibold))
            Spacer()
            Text("\(episodes.count) 集")
                .foregroundStyle(.secondary)
            let allWatched = episodes.allSatisfy { $0.watched || $0.playProgress >= 0.9 }
            Button {
                appState.markAllWatched(episodes, watched: !allWatched)
            } label: {
                Label(allWatched ? "标记全未看" : "标记全已看",
                      systemImage: allWatched ? "eye.slash" : "eye.fill")
                    .font(.caption.weight(.semibold))
            }
            .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 9, minHeight: 28))
        }
    }

    private func episodeRow(_ episode: MediaItem) -> some View {
        EpisodeRowView(episode: episode, selected: selectedEpisodeID == episode.id)
            .contentShape(Rectangle())
            .background {
                EpisodeMouseDownSelectionMonitor {
                    selectedEpisodeID = episode.id
                }
            }
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
                withAnimation(AppMotion.page) {
                    appState.selectedItem = nil
                }
            } label: {
                Label("返回", systemImage: "chevron.left")
            }
            .keyboardShortcut(.escape, modifiers: [])

            let episodes = appState.children(for: item)
            if !episodes.isEmpty {
                Text("\(episodes.count) 集")
                    .foregroundStyle(.secondary)
            }
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
                .pointerInspectTilt(enabled: item.type != .music, cornerRadius: 12)
                .contextMenu {
                    if !appState.videoCacheQualityChoices(for: item).isEmpty {
                        VideoCacheMenuItems(item: item)
                        Divider()
                    }
                    Button {
                        chooseCustomArtwork(kind: .poster)
                    } label: {
                        Label("选择自定义封面", systemImage: "photo.badge.plus")
                    }
                    if item.type != .music {
                        Button {
                            chooseCustomArtwork(kind: .backdrop)
                        } label: {
                            Label("选择背景图", systemImage: "photo.on.rectangle.angled")
                        }
                    }
                }

            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(item.title)
                        .font(.system(size: 34, weight: .semibold))
                        .lineLimit(2)
                    Spacer()
                    Button {
                        appState.toggleWatchlist(item)
                    } label: {
                        Image(systemName: item.watchlist ? "bookmark.fill" : "bookmark")
                            .foregroundStyle(item.watchlist ? AppColors.selectedGlassTint : Color.primary)
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 14, horizontalPadding: 10, minHeight: 30))
                    .help(item.watchlist ? "移出想看" : "加入想看")
                    Button {
                        appState.toggleFavorite(item)
                    } label: {
                        Image(systemName: item.favorite ? "heart.fill" : "heart")
                            .foregroundStyle(item.favorite ? Color.red : Color.primary)
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 14, horizontalPadding: 10, minHeight: 30))
                    .help(item.favorite ? "取消喜欢" : "喜欢")
                }

                HStack(spacing: 12) {
                    Label(item.displayYear, systemImage: "calendar")
                    if let rating = item.rating {
                        Label(String(format: "%.1f", rating), systemImage: "star.fill")
                    }
                    if let runtime = item.runtime {
                        Label("\(runtime) 分钟", systemImage: "clock")
                    }
                    if let resolution = item.resolution {
                        Label(resolution, systemImage: "rectangle.expand.vertical")
                    }
                }
                .foregroundStyle(.secondary)

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

                Text(item.overview?.isEmpty == false ? item.overview! : "暂无简介。")
                    .foregroundStyle(.secondary)
                    .lineLimit(6)

                if !genreTags.isEmpty {
                    DetailGenreTagFlow(genres: genreTags)
                }

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        Button {
                            appState.play(item, preserveSelection: true)
                        } label: {
                            Label("播放", systemImage: "play.fill")
                        }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34, prominent: true))
                        .disabled(item.filePath == nil && appState.children(for: item).isEmpty)

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
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 12, minHeight: 34))
                    .fixedSize(horizontal: true, vertical: false)
                }
            }
        }
        .padding(18)
        .surfaceBackground(cornerRadius: 24)
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
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 11, horizontalPadding: 10, minHeight: 30))
            } else {
                Text("路径未记录。")
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .staticSurfaceBackground(cornerRadius: 14, thickness: 1.04)
    }

    private var remoteDisplayName: String {
        guard item.isRemoteResource else { return item.filePath ?? "" }
        if item.metadataProvider == "Emby" {
            return "Emby 流媒体 · \(item.title)"
        }
        return item.filePath ?? "远程流媒体"
    }

    private func chooseCustomArtwork(kind: ArtworkKind) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [
            UTType.jpeg,
            UTType.png,
            UTType.heic,
            UTType.tiff,
            UTType(filenameExtension: "webp"),
            UTType(filenameExtension: "bmp")
        ].compactMap { $0 }
        panel.message = kind == .poster ? "选择自定义封面图片" : "选择自定义背景图片"
        panel.prompt = "选择"
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let sourceURL = panel.url else { return }
        importArtwork(from: sourceURL, kind: kind)
    }

    private func importArtwork(from sourceURL: URL, kind: ArtworkKind) {
        guard let thumbnailsDir = appState.directories?.thumbnails else {
            appState.alert = AppAlert(title: "无法导入封面", message: "应用数据目录不可用。")
            return
        }
        let ext = sourceURL.pathExtension.isEmpty ? "jpg" : sourceURL.pathExtension.lowercased()
        let suffix = kind == .poster ? "custom-poster" : "custom-backdrop"
        let timestamp = Int(Date().timeIntervalSince1970)
        let destURL = thumbnailsDir.appendingPathComponent("\(item.id)-\(suffix)-\(timestamp).\(ext)")
        do {
            try FileManager.default.createDirectory(at: thumbnailsDir, withIntermediateDirectories: true)
            // 删除该条目同类型的旧自定义封面文件
            if let existing = try? FileManager.default.contentsOfDirectory(at: thumbnailsDir, includingPropertiesForKeys: nil) {
                for old in existing where old.lastPathComponent.hasPrefix("\(item.id)-\(suffix)-") {
                    try? FileManager.default.removeItem(at: old)
                }
            }
            try FileManager.default.copyItem(at: sourceURL, to: destURL)
            ArtworkImageCache.invalidateMissing(path: destURL.path)
            switch kind {
            case .poster:
                appState.applyMetadata(MediaMetadataUpdate(posterPath: destURL.path), to: item)
            case .backdrop:
                appState.applyMetadata(MediaMetadataUpdate(backdropPath: destURL.path), to: item)
            }
        } catch {
            appState.showError("封面导入失败", error)
        }
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
            let exists = await Task.detached(priority: .utility) {
                FileManager.default.fileExists(atPath: filePath)
            }.value
            guard fileStatusPath == filePath else { return }
            fileExists = exists
        }
    }
}

private struct DetailGenreTagFlow: View {
    let genres: [String]

    var body: some View {
        PosterBadgeFlowLayout(horizontalSpacing: 8, verticalSpacing: 7) {
            ForEach(genres, id: \.self) { genre in
                Text(genre)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppColors.selectedGlassTint.opacity(0.10), in: Capsule())
                    .overlay {
                        Capsule().stroke(AppColors.cleanPanelBorder, lineWidth: 0.75)
                    }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 只观察剧集行内的左键按下，不消费事件；选中态立即更新，SwiftUI 仍可继续识别单击和双击。
private struct EpisodeMouseDownSelectionMonitor: NSViewRepresentable {
    let onMouseDown: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onMouseDown = onMouseDown
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onMouseDown = onMouseDown
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onMouseDown: (() -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func startMonitoring() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window,
                      !isHidden,
                      alphaValue > 0 else {
                    return event
                }
                let point = convert(event.locationInWindow, from: nil)
                if bounds.contains(point) {
                    onMouseDown?()
                }
                return event
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

struct MetadataSearchView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.dismiss) private var dismiss
    let item: MediaItem

    @State private var query: String
    @State private var results: [MetadataSearchResult] = []
    @State private var isLoading = false
    @State private var applyingResultID: String?
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
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 10, minHeight: 32))
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
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
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
                            result: result,
                            applying: applyingResultID == result.id,
                            disabled: applyingResultID != nil
                        ) {
                            Task { await apply(result) }
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

    @MainActor
    private func apply(_ result: MetadataSearchResult) async {
        applyingResultID = result.id
        let update = await service.materializedMetadataUpdate(
            for: result,
            itemID: item.id,
            artworkDirectory: appState.directories?.thumbnails,
            preserveEmbeddedPoster: item.type == .music && item.hasEmbeddedArtwork
        )
        appState.applyMetadata(update, to: item)
        applyingResultID = nil
        dismiss()
    }
}

private struct MetadataResultCard: View {
    let result: MetadataSearchResult
    let applying: Bool
    let disabled: Bool
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
                Button(applying ? "应用中" : "应用") {
                    onApply()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 10, horizontalPadding: 10, minHeight: 28))
                .disabled(disabled)
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
                HStack(spacing: 8) {
                    Image(systemName: "key.horizontal").foregroundStyle(.orange)
                    Text("OpenSubtitles API Key 可在设置 → 元数据中配置。").font(.caption)
                }
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
                    minWidth: 96,
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
                Label(error, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .padding(10)
                    .staticSurfaceBackground(cornerRadius: 10)
            }

            if let path = downloadedPath {
                Label("已保存：\(URL(fileURLWithPath: path).lastPathComponent)", systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.green)
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
