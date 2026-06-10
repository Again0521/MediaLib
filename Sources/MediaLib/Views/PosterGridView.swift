import AppKit
import MediaLibCore
import SwiftUI

/// 单行标题：过长时不换行；鼠标悬停时整段文字循环滚动（首尾相接、无缝循环），不再左右往返。
struct MarqueeText: View {
    let text: String
    var font: Font = .headline
    var alignment: Alignment = .leading
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @State private var textWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var offset: CGFloat = 0
    @State private var hovering = false

    private let gap: CGFloat = 46
    private var overflow: CGFloat { max(textWidth - containerWidth, 0) }
    private var hasOverflow: Bool { overflow > 1 }

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)

            ZStack(alignment: .leading) {
                // 隐藏副本：测量整段文字的真实宽度。
                measuredText
                    .hidden()

                if hovering, hasOverflow, !reduceMotion, !suppressHoverDuringScroll {
                    // 循环滚动：两份文字首尾相接，整体向左平移一个 (文字宽 + 间隙)，
                    // 到头瞬间复位再继续，形成无缝循环。
                    HStack(spacing: gap) {
                        measuredText
                        measuredText
                    }
                    .offset(x: offset)
                } else {
                    measuredText
                        .frame(width: width, alignment: alignment)
                }
            }
            .frame(width: width, alignment: .leading)
            .clipped()
            .mask(maskGradient)
            .contentShape(Rectangle())
            .onAppear { containerWidth = width }
            .onChange(of: width) { newValue in
                containerWidth = newValue
                restartIfNeeded()
            }
        }
        .clipped()
        .onHover { isHovering in
            guard hasOverflow, !reduceMotion, !suppressHoverDuringScroll else {
                stopLoop()
                return
            }
            if isHovering {
                startLoop()
            } else {
                stopLoop()
            }
        }
        .onChange(of: text) { _ in
            stopLoop()
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing { stopLoop() }
        }
    }

    private var measuredText: some View {
        Text(text)
            .font(font)
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .background(
                GeometryReader { textProxy in
                    Color.clear
                        .onAppear { textWidth = textProxy.size.width }
                        .onChange(of: textProxy.size.width) { textWidth = $0 }
                }
            )
            .allowsHitTesting(false)
    }

    private func startLoop() {
        hovering = true
        offset = 0
        let distance = textWidth + gap
        guard distance > 0 else { return }
        let speed: Double = 40 // 点/秒，匀速循环
        withAnimation(.linear(duration: Double(distance) / speed).repeatForever(autoreverses: false)) {
            offset = -distance
        }
    }

    private func stopLoop() {
        guard hovering || offset != 0 else { return }
        hovering = false
        withAnimation(.easeOut(duration: 0.22)) {
            offset = 0
        }
    }

    private func restartIfNeeded() {
        if hovering {
            startLoop()
        } else {
            offset = 0
        }
    }

    @ViewBuilder
    private var maskGradient: some View {
        if hasOverflow {
            let edge: CGFloat = 0.06
            LinearGradient(
                stops: [
                    .init(color: hovering ? .clear : .black, location: 0),
                    .init(color: .black, location: edge),
                    .init(color: .black, location: 1 - edge),
                    .init(color: .clear, location: 1)
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
        } else {
            Color.black
        }
    }
}
struct PosterGridList<Leading: View>: View {
    @EnvironmentObject private var appState: AppState
    let items: [MediaItem]
    var bottomInset: CGFloat = 16
    var showsDeletePlaybackHistory: Bool = false
    var selectionEnabled: Bool = false
    var restoreAnchorID: String? = nil
    var currentManualCollectionID: String? = nil
    var onDidRestoreAnchor: (() -> Void)? = nil
    @ViewBuilder var leading: () -> Leading
    @State private var restoredAnchorID: String?

    private let interItemSpacing: CGFloat = 20
    private let rowSpacing: CGFloat = 30

    var body: some View {
        GeometryReader { proxy in
            let columns = columnCount(for: proxy.size.width)
            let itemWidth = resolvedItemWidth(for: proxy.size.width, columns: columns)
            // 等宽 flexible 列：网格自动填满可用宽度，左右边界都与上方卡片栏对齐、随窗口自适应。
            let gridItems = Array(
                repeating: GridItem(.flexible(), spacing: interItemSpacing, alignment: .top),
                count: max(columns, 1)
            )
            let cacheSize = cacheTargetSize(itemWidth: itemWidth)

            ScrollViewReader { scrollProxy in
                ScrollView {
                    // 用 ScrollView + LazyVGrid 取代原生 List：彻底避开 NSTableView 的整行高亮，
                    // 右键不再出现蓝色方框、能精确命中单个海报；LazyVGrid 仍按需懒加载行。
                    LazyVStack(alignment: .leading, spacing: 0) {
                        Color.clear.frame(height: 0).id("top")

                        // 页头与筛选条随内容一起滚动（向下滑动时滑出界面外）。
                        leading()
                            .padding(.top, AppSpacing.pageVertical)
                            .padding(.horizontal, AppSpacing.pageHorizontal)
                            .padding(.bottom, AppSpacing.headerToControls)

                        LazyVGrid(columns: gridItems, alignment: .leading, spacing: rowSpacing) {
                            ForEach(items) { item in
                                PosterCardView(
                                    item: item,
                                    cacheTargetSize: cacheSize,
                                    showsDeletePlaybackHistory: showsDeletePlaybackHistory,
                                    selectionEnabled: selectionEnabled,
                                    currentManualCollectionID: currentManualCollectionID
                                )
                                    .id(item.id)
                            }
                        }
                        .padding(.horizontal, AppSpacing.pageHorizontal)

                        Color.clear.frame(height: bottomInset)
                    }
                }
                // 列数变化通常来自窗口缩放；避免把整棵 LazyVGrid 卷入显式动画事务，
                // 滚动和筛选刷新时能少一次大范围布局合成压力。
                .animation(nil, value: columns)
                .suppressListHighlight()
                .onAppear {
                    restoreAnchorIfNeeded(restoreAnchorID, scrollProxy: scrollProxy)
                }
                .onChange(of: restoreAnchorID) { anchorID in
                    restoreAnchorIfNeeded(anchorID, scrollProxy: scrollProxy)
                }
                .onChange(of: items.map(\.id)) { _ in
                    restoreAnchorIfNeeded(restoreAnchorID, scrollProxy: scrollProxy)
                }
                .overlay(alignment: .bottomTrailing) {
                    Button {
                        withAnimation(AppMotion.fast) {
                            scrollProxy.scrollTo("top", anchor: .top)
                        }
                    } label: {
                        Image(systemName: "arrow.up")
                            .frame(width: 38, height: 38)
                    }
                    .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 19, horizontalPadding: 0, minHeight: 38, thickness: 1.04))
                    .padding(.trailing, 22)
                    .padding(.bottom, max(bottomInset - 4, 18))
                    .help("返回顶部")
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height, alignment: .top)
        }
        .suppressHoverEffectsDuringScroll()
    }

    private func columnCount(for width: CGFloat) -> Int {
        let available = max(width - AppSpacing.pageHorizontal * 2, appState.settings.posterMinWidth)
        let minWidth = max(appState.settings.posterMinWidth, 80)
        return max(1, Int((available + interItemSpacing) / (minWidth + interItemSpacing)))
    }

    private func resolvedItemWidth(for width: CGFloat, columns: Int) -> CGFloat {
        let available = max(width - AppSpacing.pageHorizontal * 2, appState.settings.posterMinWidth)
        let spacing = interItemSpacing * CGFloat(max(columns - 1, 0))
        return max((available - spacing) / CGFloat(max(columns, 1)), 1)
    }

    private func cacheTargetSize(itemWidth: CGFloat) -> CGSize {
        let targetWidth = min(max(itemWidth * 1.6, 180), 460)
        return CGSize(width: targetWidth, height: targetWidth * 1.5)
    }

    private func restoreAnchorIfNeeded(_ anchorID: String?, scrollProxy: ScrollViewProxy) {
        guard let anchorID,
              restoredAnchorID != anchorID,
              items.contains(where: { $0.id == anchorID }) else { return }
        restoredAnchorID = anchorID
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

struct PosterBadgeFlowLayout: Layout {
    var horizontalSpacing: CGFloat = 5
    var verticalSpacing: CGFloat = 4

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = makeRows(sizes: sizes, availableWidth: proposal.width)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.enumerated().reduce(CGFloat(0)) { total, entry in
            total + entry.element.height + (entry.offset == 0 ? 0 : verticalSpacing)
        }
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let sizes = subviews.map { $0.sizeThatFits(.unspecified) }
        let rows = makeRows(sizes: sizes, availableWidth: bounds.width)
        var y = bounds.minY
        for row in rows {
            var x = bounds.minX
            for index in row.indices {
                subviews[index].place(
                    at: CGPoint(x: x, y: y),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(sizes[index])
                )
                x += sizes[index].width + horizontalSpacing
            }
            y += row.height + verticalSpacing
        }
    }

    private func makeRows(sizes: [CGSize], availableWidth proposedWidth: CGFloat?) -> [BadgeRow] {
        guard !sizes.isEmpty else { return [] }
        let naturalWidth = rowWidth(for: sizes.indices, sizes: sizes)
        let availableWidth = max(proposedWidth ?? naturalWidth, 1)
        if naturalWidth <= availableWidth || sizes.count <= 1 {
            return [BadgeRow(indices: Array(sizes.indices), width: naturalWidth, height: rowHeight(for: sizes.indices, sizes: sizes))]
        }

        var bestSplit: Int?
        var bestBottomWidth = CGFloat.zero
        if sizes.count > 2 {
            for split in 1..<sizes.count {
                let top = 0..<split
                let bottom = split..<sizes.count
                let topWidth = rowWidth(for: top, sizes: sizes)
                let bottomWidth = rowWidth(for: bottom, sizes: sizes)
                guard topWidth <= availableWidth, bottomWidth <= availableWidth else { continue }
                if bottomWidth > bestBottomWidth {
                    bestBottomWidth = bottomWidth
                    bestSplit = split
                }
            }
        }

        if let bestSplit {
            let top = 0..<bestSplit
            let bottom = bestSplit..<sizes.count
            return [
                BadgeRow(indices: Array(top), width: rowWidth(for: top, sizes: sizes), height: rowHeight(for: top, sizes: sizes)),
                BadgeRow(indices: Array(bottom), width: rowWidth(for: bottom, sizes: sizes), height: rowHeight(for: bottom, sizes: sizes))
            ]
        }

        var rows: [BadgeRow] = []
        var current: [Int] = []
        for index in sizes.indices {
            let candidate = current + [index]
            if !current.isEmpty, rowWidth(for: candidate, sizes: sizes) > availableWidth {
                rows.append(BadgeRow(indices: current, width: rowWidth(for: current, sizes: sizes), height: rowHeight(for: current, sizes: sizes)))
                current = [index]
            } else {
                current = candidate
            }
        }
        if !current.isEmpty {
            rows.append(BadgeRow(indices: current, width: rowWidth(for: current, sizes: sizes), height: rowHeight(for: current, sizes: sizes)))
        }
        return rows
    }

    private func rowWidth<S: Sequence>(for indices: S, sizes: [CGSize]) -> CGFloat where S.Element == Int {
        let values = Array(indices)
        guard !values.isEmpty else { return 0 }
        return values.reduce(CGFloat(0)) { $0 + sizes[$1].width } + horizontalSpacing * CGFloat(max(values.count - 1, 0))
    }

    private func rowHeight<S: Sequence>(for indices: S, sizes: [CGSize]) -> CGFloat where S.Element == Int {
        indices.map { sizes[$0].height }.max() ?? 0
    }
}

private struct BadgeRow {
    let indices: [Int]
    let width: CGFloat
    let height: CGFloat
}

struct PosterCardView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let item: MediaItem
    var cacheTargetSize: CGSize? = nil
    var showsDeletePlaybackHistory: Bool = false
    var selectionEnabled: Bool = false
    var currentManualCollectionID: String? = nil
    @State private var isHovering = false

    private var isSelectionActive: Bool { selectionEnabled && appState.isSelectionModeActive }
    private var isSelected: Bool { appState.selectedItemIDs.contains(item.id) }

    var body: some View {
        // 统一裁剪比例：视频海报 2:3，音乐 1:1。海报以 fill 模式裁剪到固定比例框，
        // 使同一网格内所有海报高度一致，消除上下间距不齐的问题。
        let cropRatio: CGFloat = item.type == .music ? 1 : (2.0 / 3.0)
        let hoverActive = isHovering && !suppressHoverDuringScroll

        VStack(alignment: .leading, spacing: 8) {
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .aspectRatio(cropRatio, contentMode: .fit)
                    .overlay {
                        PosterImage(path: item.posterPath, title: item.cardTitle, mediaType: item.type, cacheTargetSize: cacheTargetSize)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .strokeBorder(.white.opacity(hoverActive ? 0.54 : 0.24), lineWidth: hoverActive ? 1.1 : 0.7)
                    }
                    .overlay {
                        if hoverActive {
                            LinearGradient(
                                colors: [
                                    .white.opacity(0.18),
                                    .clear,
                                    AppColors.pointerLightTint.opacity(0.10)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                            .transition(.opacity)
                        }
                    }

                if !badgeTexts.isEmpty {
                    PosterBadgeFlowLayout(horizontalSpacing: 5, verticalSpacing: 4) {
                        ForEach(badgeTexts, id: \.self) { text in
                            badge(text)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                if hoverActive && !isSelectionActive {
                    VStack(alignment: .leading, spacing: 7) {
                        RatingStars(value: item.userRating, onRate: { rating in
                            appState.updateRating(item, rating: rating)
                        })
                        if let artistAlbum = item.artistAlbumLine {
                            Text(artistAlbum)
                                .font(.caption2.weight(.medium))
                                .lineLimit(2)
                        }
                    }
                    .padding(8)
                    .foregroundStyle(.white)
                    .background(.black.opacity(0.58), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                    .padding(8)
                    .transition(.opacity)
                    .onTapGesture {}
                }
            }
            .overlay(alignment: .topTrailing) {
                if isSelectionActive {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 22, weight: .semibold))
                        .symbolRenderingMode(.palette)
                        .foregroundStyle(.white, isSelected ? AppColors.selectedGlassTint : .black.opacity(0.35))
                        .background(Circle().fill(.black.opacity(0.28)).blur(radius: 2))
                        .padding(8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .overlay {
                if isSelectionActive && isSelected {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .strokeBorder(AppColors.selectedGlassTint, lineWidth: 2.5)
                }
            }
            .pointerInspectTilt(enabled: usesInspectHover && !isSelectionActive, cornerRadius: 10)
            .scaleEffect(hoverActive && !reduceMotion ? 1.018 : 1)
            .contentShape(Rectangle())
            .onTapGesture {
                handlePrimaryTap()
            }

            MarqueeText(text: item.cardTitle, font: .headline)
                .frame(height: 20)
                .contentShape(Rectangle())
                .onTapGesture {
                    handlePrimaryTap()
                }
        }
        .padding(10)
        .staticSurfaceBackground(cornerRadius: 18)
        .repeatedSurfaceHover(hoverActive, cornerRadius: 18, tint: AppColors.pointerLightTint, intensity: usesInspectHover ? 0.95 : 0.72)
        .animation(reduceMotion ? nil : AppMotion.listHover, value: hoverActive)
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
        .contextMenu {
            VideoItemContextMenuItems(
                item: item,
                showsDeletePlaybackHistory: showsDeletePlaybackHistory,
                currentManualCollectionID: currentManualCollectionID
            )
        }
    }

    /// 多选模式下点击切换选中状态；否则照常打开详情。
    private func handlePrimaryTap() {
        if isSelectionActive {
            withAnimation(reduceMotion ? nil : AppMotion.fast) {
                appState.toggleItemSelection(item.id)
            }
        } else {
            appState.selectedItemReturnAnchorID = item.id
            appState.selectedItem = item
        }
    }

    private var usesInspectHover: Bool {
        item.type != .music
    }

    private var badgeTexts: [String] {
        var texts: [String] = []
        switch appState.videoCacheState(for: item) {
        case .complete:
            texts.append(appState.children(for: item).isEmpty ? "已缓存" : "已全部缓存")
        case .partial:
            texts.append("部分已缓存")
        case .none:
            break
        }
        if item.watchlist {
            texts.append("想看")
        }
        if item.favorite {
            texts.append("喜欢")
        }
        if item.type != .music, item.watched || item.filePath != nil || item.type == .tvShow {
            texts.append(item.watched ? "已看" : "未看")
        }
        if item.type != .music, let year = item.year {
            texts.append(String(year))
        }
        if let resolution = item.resolution {
            texts.append(resolution)
        }
        return texts
    }

    private func badge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background {
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(.black.opacity(0.34))
                    .overlay {
                        LinearGradient(
                            colors: [
                                .white.opacity(0.22),
                                .white.opacity(0.08),
                                .black.opacity(0.16)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(.white.opacity(0.24), lineWidth: 0.5)
                    }
            }
    }
}

struct RatingStars: View {
    let value: Double?
    var onRate: ((Double?) -> Void)? = nil

    var body: some View {
        HStack(spacing: 2) {
            ForEach(1...5, id: \.self) { index in
                Button {
                    onRate?(Double(index))
                } label: {
                    Image(systemName: Double(index) <= (value ?? 0) ? "star.fill" : "star")
                        .font(.caption.weight(.semibold))
                }
                .buttonStyle(SubtleIconButtonStyle(minSize: 20))
                .disabled(onRate == nil)
            }
        }
        .accessibilityLabel(value.map { "评级 \(String(format: "%.0f", $0)) 星" } ?? "未评级")
    }
}

struct PosterImage: View {
    let path: String?
    let title: String
    let mediaType: MediaType?
    let cacheTargetSize: CGSize?

    init(path: String?, title: String, mediaType: MediaType? = nil, cacheTargetSize: CGSize? = nil) {
        self.path = path
        self.title = title
        self.mediaType = mediaType
        self.cacheTargetSize = cacheTargetSize
    }

    var body: some View {
        if usesDefaultMusicArtwork {
            MusicDefaultArtworkView(title: title)
        } else if let cacheTargetSize {
            // 海报墙：父级（aspectRatio + overlay）已给出确定尺寸，解码尺寸也稳定，
            // 因此无需每格 GeometryReader。去掉它可消除滚动时逐格的尺寸上报/布局抖动（闪烁卡顿主因之一）。
            posterContent(targetSize: cacheTargetSize)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        } else {
            // 其它用法（如详情页大图）未传入稳定解码尺寸时，仍用 GeometryReader 按显示尺寸解码，保证清晰度。
            GeometryReader { proxy in
                posterContent(targetSize: proxy.size)
                    .frame(width: proxy.size.width, height: proxy.size.height)
                    .clipped()
            }
        }
    }

    @ViewBuilder
    private func posterContent(targetSize: CGSize) -> some View {
        if let remoteURL = remoteURL {
            RemotePosterImage(url: remoteURL, title: title, targetSize: targetSize, placeholder: AnyView(placeholder))
        } else {
            LocalPosterImage(path: path, title: title, targetSize: targetSize, placeholder: AnyView(placeholder))
        }
    }

    private var usesDefaultMusicArtwork: Bool {
        guard mediaType == .music else { return false }
        guard let path else { return true }
        return path.hasSuffix("-default.jpg")
    }

    private var remoteURL: URL? {
        guard let path,
              let url = URL(string: path),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    private var placeholder: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(AppColors.accentGradient)
            // 占位图叠在实色渐变上，白色半透明覆盖层即可得到等效的磨砂观感，避免额外 material 通道。
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.white.opacity(0.52))
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.white.opacity(0.28), lineWidth: 1)
            VStack(spacing: 10) {
                ZStack {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(.white.opacity(0.26))
                        .frame(width: 58, height: 42)
                    Image(systemName: "play.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(AppColors.accentGradient)
                }
                Text(title)
                    .font(.caption.weight(.medium))
                    .multilineTextAlignment(.center)
                    .foregroundStyle(Color.primary.opacity(0.72))
                    .lineLimit(3)
                    .padding(.horizontal, 8)
            }
        }
    }
}

private struct RemotePosterImage: View {
    let url: URL
    let title: String
    let targetSize: CGSize
    let placeholder: AnyView
    @State private var image: NSImage?
    @State private var loadedKey = ""
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        // 优先同步命中内存缓存，避免列表行回收后重新出现时先闪一帧占位图（默认封面）再加载真图。
        let displayImage = image ?? ArtworkImageCache.cachedImage(path: url.absoluteString, targetSize: targetSize)
        Group {
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .redacted(reason: .placeholder)
            }
        }
        .task(id: cacheKey) {
            releaseTask?.cancel()
            let key = cacheKey
            guard image == nil || loadedKey != key else { return }
            loadedKey = key
            image = ArtworkImageCache.cachedImage(path: url.absoluteString, targetSize: targetSize)
            guard image == nil else { return }
            let loaded = SendablePosterImage(await ArtworkImageCache.remoteImageAsync(url: url, targetSize: targetSize))
            guard loadedKey == key else { return }
            image = loaded.image
        }
        .onDisappear {
            releaseTask?.cancel()
            releaseTask = Task { @MainActor in
                do {
                    try await Task.sleep(nanoseconds: 2_500_000_000)
                } catch {
                    return
                }
                image = nil
            }
        }
        .onAppear {
            releaseTask?.cancel()
            releaseTask = nil
        }
        .accessibilityLabel(title)
    }

    private var cacheKey: String {
        "\(url.absoluteString)-\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
    }
}

private struct MusicDefaultArtworkView: View {
    let title: String
    private static let equalizerBarFactors: [CGFloat] = [0.38, 0.62, 0.48, 0.72, 0.44]

    var body: some View {
        GeometryReader { proxy in
            let side = min(proxy.size.width, proxy.size.height)
            let cornerRadius = max(side * 0.12, 8)
            let artworkColors = AppColors.themedIconColors
            let primaryTone = artworkColors.first ?? AppColors.selectedGlassTint
            let secondaryTone = artworkColors.dropFirst().first ?? AppColors.solarEdgeTint
            let tertiaryTone = artworkColors.dropFirst(2).first ?? AppColors.solarLightTint

            ZStack {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                primaryTone.opacity(0.95),
                                secondaryTone.opacity(0.90),
                                tertiaryTone.opacity(0.84)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )

                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: side * 0.72, height: side * 0.72)
                    .offset(x: -side * 0.34, y: -side * 0.34)

                Circle()
                    .fill(AppColors.solarLightTint.opacity(0.24))
                    .frame(width: side * 0.58, height: side * 0.58)
                    .offset(x: side * 0.34, y: side * 0.34)

                RoundedRectangle(cornerRadius: cornerRadius * 0.78, style: .continuous)
                    // 实色图形上的白色半透明覆盖能模拟轻磨砂，同时避免为每个占位卡片创建 material。
                    .fill(.white.opacity(0.28))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius * 0.78, style: .continuous)
                            .fill(.white.opacity(0.14))
                    }
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius * 0.78, style: .continuous)
                            .stroke(.white.opacity(0.46), lineWidth: max(side * 0.012, 0.8))
                    }
                    .padding(side * 0.18)

                VStack(spacing: side * 0.07) {
                    Image(systemName: "music.note")
                        .font(.system(size: side * 0.30, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [primaryTone, secondaryTone],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )

                    HStack(spacing: max(side * 0.025, 2)) {
                        ForEach(Self.equalizerBarFactors.indices, id: \.self) { index in
                            Capsule()
                                .fill((index == 3 ? primaryTone : secondaryTone).opacity(0.72))
                                .frame(width: max(side * 0.025, 2), height: side * Self.equalizerBarFactors[index] * 0.22)
                        }
                    }

                    if side > 120 {
                        Text(title)
                            .font(.system(size: side * 0.055, weight: .semibold))
                            .foregroundStyle(.white.opacity(0.94))
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                            .padding(.horizontal, side * 0.12)
                    }
                }
            }
            .frame(width: proxy.size.width, height: proxy.size.height)
        }
    }
}

private struct LocalPosterImage: View {
    @EnvironmentObject private var appState: AppState
    let path: String?
    let title: String
    let targetSize: CGSize
    let placeholder: AnyView
    @State private var image: NSImage?
    @State private var loadedPath: String?
    @State private var loadedRevision = -1
    @State private var loadedTargetID = ""
    @State private var releaseTask: Task<Void, Never>?

    var body: some View {
        // 优先同步命中内存缓存，避免列表行回收后重新出现时先闪一帧占位图再加载真图（专辑封面闪烁）。
        let displayImage = image ?? ArtworkImageCache.cachedImage(path: path, targetSize: targetSize)
        Group {
            if let displayImage {
                Image(nsImage: displayImage)
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
            } else {
                placeholder
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .redacted(reason: path == nil ? [] : .placeholder)
            }
        }
        .task(id: cacheKey) {
            releaseTask?.cancel()
            // posterRevision 仅在 reload()（元数据/封面真实变化）时递增，
            // 文件存在性健康检查不触发它，避免该检查完成后全量图片重载。
            let revision = appState.posterRevision
            let targetID = targetIdentity
            guard image == nil || loadedPath != path || loadedRevision != revision || loadedTargetID != targetID else { return }
            loadedPath = path
            loadedRevision = revision
            loadedTargetID = targetID
            image = ArtworkImageCache.cachedImage(path: path, targetSize: targetSize)
            guard image == nil, path != nil else { return }
            let loaded = await Task.detached(priority: .utility) {
                SendablePosterImage(ArtworkImageCache.image(path: path, targetSize: targetSize))
            }.value
            guard loadedPath == path, loadedTargetID == targetID else { return }
            image = loaded.image
        }
        .onDisappear {
            releaseTask?.cancel()
            releaseTask = Task { @MainActor in
                do {
                    // 1.2s 足以覆盖快速滚动"回头"的场景；ArtworkImageCache 独立缓存兜底。
                    try await Task.sleep(nanoseconds: 1_200_000_000)
                } catch {
                    return
                }
                image = nil
            }
        }
        .onAppear {
            releaseTask?.cancel()
            releaseTask = nil
        }
    }

    private var cacheKey: String {
        "\(path ?? "nil")-\(appState.posterRevision)-\(targetIdentity)"
    }

    private var targetIdentity: String {
        "\(Int(targetSize.width.rounded()))x\(Int(targetSize.height.rounded()))"
    }
}

private struct SendablePosterImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

enum ArtworkMetrics {
    static func aspectRatio(for item: MediaItem) -> CGFloat {
        if let cached = ArtworkImageCache.cachedAspectRatio(path: item.posterPath) {
            return cached
        }
        if shouldUseVideoRatioFallback(for: item),
           let ratio = aspectRatio(from: item.resolution) {
            return ratio
        }
        return item.type == .episode ? 16.0 / 9.0 : 2.0 / 3.0
    }

    private static func shouldUseVideoRatioFallback(for item: MediaItem) -> Bool {
        guard item.type != .music else { return false }
        guard let posterPath = item.posterPath, !posterPath.isEmpty else { return item.filePath != nil }
        guard !posterPath.hasPrefix("http://"), !posterPath.hasPrefix("https://") else { return false }
        let stem = URL(fileURLWithPath: posterPath).deletingPathExtension().lastPathComponent
        return stem == item.id || stem == "\(item.id)-default"
    }

    private static func aspectRatio(from resolution: String?) -> CGFloat? {
        guard let resolution else { return nil }
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return CGFloat(min(max(width / height, 0.68), 1.78))
    }
}
