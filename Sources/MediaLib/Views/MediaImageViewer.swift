import AppKit
import AVKit
import ImageIO
import MediaLibCore
import Photos
import SwiftUI

/// 共享全屏媒体查看器：相册照片/录像、详情页艺术照都复用这一组件。
/// 图片支持捏合缩放、双击放大、拖动平移、左右翻页、信息面板、收藏、访达定位；录像显示首帧+播放按钮，
/// 点击转交外部 `onPlayVideo` 回调（一般是视频播放器窗口）。
struct MediaImageViewer: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme

    /// 可翻页的条目集合（可混合图片与视频）。
    let items: [MediaImageViewerEntry]
    @Binding var index: Int
    var allowsFavorite: Bool = true
    var onClose: () -> Void
    var onToggleFavorite: ((MediaImageViewerEntry) -> Void)? = nil
    var onPlayVideo: (MediaImageViewerEntry) -> Void = { _ in }
    var onShare: ((MediaImageViewerEntry) -> Void)? = nil
    var onDelete: ((MediaImageViewerEntry) -> Void)? = nil

    @State private var showInfo = false
    @State private var pixelSize: CGSize?
    @State private var videoPlaybackToggleRevision = 0

    private var current: MediaImageViewerEntry? {
        items.indices.contains(index) ? items[index] : nil
    }

    var body: some View {
        ZStack {
            // 背景用磨砂模糊（而非纯黑）：把身后的相册/详情页柔化模糊，叠一层轻微暗纱提升照片对比。
            ZStack {
                Rectangle().fill(.ultraThinMaterial)
                Color.black.opacity(0.28)
            }
            .ignoresSafeArea()
            .onTapGesture { onClose() }

            // 顶栏 / 图片区 / 底部缩略图条三段式：控制不再压在照片之上，底部是和其他相册软件一致的迷你预览条。
            VStack(spacing: 0) {
                topBar
                imageArea
                if items.count > 1 { filmstrip }
            }
            .ignoresSafeArea(.container, edges: [.top, .bottom])
        }
        .overlay(alignment: .topTrailing) { infoPanel }
        .background {
            RawKeyCaptureView { key in handleKey(key) }
                .frame(width: 0, height: 0)
        }
        .onChange(of: index) { _ in onItemChanged() }
        .task(id: index) { prefetchAdjacentImages() }
        .task(id: current?.id) { await loadPixelSize() }
    }

    private var imageArea: some View {
        content
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background {
                if items.count > 1 {
                    ViewerTrackpadNavigationCapture { direction in
                        step(direction)
                    }
                }
            }
    }

    // MARK: - 主内容

    @ViewBuilder
    private var content: some View {
        if let current {
            if current.isVideo {
                videoContent(current)
            } else {
                imageContent(current)
            }
        }
    }

    private func imageContent(_ entry: MediaImageViewerEntry) -> some View {
        // 无级缩放走 AppKit NSScrollView 放大（GPU、不卡）；整图未就绪前用缩略图占位。
        ZoomablePhoto(entry: entry)
            .id(entry.id)
    }

    @ViewBuilder
    private func videoContent(_ entry: MediaImageViewerEntry) -> some View {
        if let assetID = entry.photoAssetID {
            // 系统照片库录像：AVKit 内嵌播放。
            SystemPhotoVideoView(assetID: assetID, playbackToggleRevision: videoPlaybackToggleRevision)
                .padding(24)
                .id(entry.id)
        } else {
            localVideoContent(entry)
        }
    }

    private func localVideoContent(_ entry: MediaImageViewerEntry) -> some View {
        Group {
            if let fileURL = entry.fileURL {
                LocalAlbumVideoPreview(url: fileURL, playbackToggleRevision: videoPlaybackToggleRevision)
                    .id(entry.id)
            } else {
                PosterImage(path: entry.imagePath, title: entry.title, mediaType: entry.mediaType)
                    .scaledToFit()
                    .padding(24)
            }
        }
    }

    // MARK: - 顶栏

    private var topBar: some View {
        HStack(spacing: 9) {
            Text("\(index + 1) / \(items.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            if let current {
                Text(current.title)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }
            Spacer()
            if let current, allowsFavorite, (current.item != nil || onToggleFavorite != nil) {
                circleButton(systemImage: current.isFavorite ? "heart.fill" : "heart", tint: current.isFavorite ? .pink : .white) {
                    toggleFavorite(current)
                }
                .help(current.isFavorite ? "取消喜欢" : "加入喜欢")
            }
            circleButton(systemImage: "info.circle", tint: showInfo ? AppColors.selectedGlassTint : .white) {
                withAnimation(AppMotion.standard) { showInfo.toggle() }
            }
            .help("显示信息")
            if let onShare, let current {
                circleButton(systemImage: "square.and.arrow.up") { onShare(current) }
                    .help("分享")
            }
            if current?.fileURL != nil {
                circleButton(systemImage: "folder") { revealInFinder() }
                    .help("在访达中显示")
            }
            if let onDelete, let current {
                circleButton(systemImage: "trash", tint: .red) { onDelete(current) }
                    .help("删除")
            }
            if let current, current.isVideo, current.item != nil {
                circleButton(systemImage: "rectangle.arrowtriangle.2.outward") {
                    onPlayVideo(current)
                }
                .help("使用完整播放器")
            }
            circleButton(systemImage: "xmark") { onClose() }
                .help("关闭")
        }
        .padding(.horizontal, 10)
        .frame(height: 34)
        .background(.black.opacity(0.18))
    }

    // MARK: - 底部缩略图条（filmstrip）

    private var filmstrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 4) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { idx, entry in
                        ViewerThumbnail(entry: entry, isCurrent: idx == index)
                            .id(idx)
                            .onTapGesture {
                                withAnimation(AppMotion.standard) { index = idx }
                            }
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            }
            .onChange(of: index) { newIndex in
                withAnimation(AppMotion.standard) { proxy.scrollTo(newIndex, anchor: .center) }
            }
            .onAppear { proxy.scrollTo(index, anchor: .center) }
        }
        .frame(height: 74)
        .background(.black.opacity(0.28))
    }

    @ViewBuilder
    private var infoPanel: some View {
        if showInfo, let current {
            VStack(alignment: .leading, spacing: 10) {
                Label("信息", systemImage: "info.circle").font(.headline)
                infoRow("名称", current.title)
                if let date = current.captureDate {
                    infoRow("日期", Self.dateFormatter.string(from: date))
                }
                if let pixelSize {
                    infoRow("尺寸", "\(Int(pixelSize.width)) × \(Int(pixelSize.height))")
                }
                if let subtype = current.mediaSubtypeLabel {
                    infoRow("类型", subtype)
                }
                if let location = current.locationLabel {
                    infoRow("位置", location)
                }
                if let size = current.fileSize, size > 0 {
                    infoRow("大小", ByteCountFormatter.string(fromByteCount: size, countStyle: .file))
                }
                if let path = current.fileURL?.path {
                    infoRow("路径", path)
                }
            }
            .padding(16)
            .frame(width: 280, alignment: .leading)
            .modifier(ViewerInfoPanelChrome())
            .padding(.top, 42)
            .padding(.trailing, 20)
            .transition(.move(edge: .trailing).combined(with: .opacity))
        }
    }

    private func infoRow(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.caption2).foregroundStyle(.secondary)
            Text(value).font(.caption).textSelection(.enabled).lineLimit(3)
        }
    }

    // MARK: - 按钮


    private func circleButton(systemImage: String, tint: Color = .white, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .modifier(ViewerCircleChrome())
        }
        .buttonStyle(.plain)
    }

    // MARK: - 翻页 / 键位

    private func onItemChanged() {
        pixelSize = nil
    }

    private func prefetchAdjacentImages() {
        let nearby = [index - 1, index + 1]
            .compactMap { items.indices.contains($0) ? items[$0] : nil }
        MediaImageFullResolutionCache.shared.prefetch(nearby)
    }

    private func step(_ delta: Int) {
        let next = index + delta
        guard items.indices.contains(next) else { return }
        index = next
    }

    private func handleKey(_ key: RawCapturedKey) {
        switch key {
        case .escape:
            if showInfo { withAnimation(AppMotion.standard) { showInfo = false } }
            else { onClose() }
        case .leftArrow: step(-1)
        case .rightArrow: step(1)
        case .space:
            if let current, current.isVideo { videoPlaybackToggleRevision &+= 1 }
        case .character(let ch):
            switch String(ch).lowercased() {
            case "f":
                if let current, allowsFavorite { toggleFavorite(current) }
            case "i": withAnimation(AppMotion.standard) { showInfo.toggle() }
            default: break
            }
        default: break
        }
    }

    private func revealInFinder() {
        guard let url = current?.fileURL else { return }
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    private func toggleFavorite(_ entry: MediaImageViewerEntry) {
        if let onToggleFavorite {
            onToggleFavorite(entry)
        } else if let item = entry.item {
            appState.toggleFavorite(item)
        }
    }

    private func loadPixelSize() async {
        guard let entry = current, !entry.isVideo else { return }
        if let known = entry.pixelSize {
            pixelSize = known
            return
        }
        guard let url = entry.fileURL else { return }
        let size = await Task.detached(priority: .utility) { () -> CGSize? in
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = props[kCGImagePropertyPixelWidth] as? Double,
                  let height = props[kCGImagePropertyPixelHeight] as? Double else { return nil }
            return CGSize(width: width, height: height)
        }.value
        if current?.id == entry.id { pixelSize = size }
    }

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

/// 本地相册录像的轻量快速预览。使用 AVKit 原生控制层，不改变全局视频播放器设置，
/// 关闭或切图即停止并释放，适合相册里快速查看短视频。
private struct LocalAlbumVideoPreview: View {
    let url: URL
    let playbackToggleRevision: Int
    @State private var player: AVPlayer?
    @State private var isPlaying = false

    var body: some View {
        Group {
            if let player {
                VideoPlayer(player: player)
                    .onAppear {
                        player.play()
                        isPlaying = true
                    }
                    .onDisappear {
                        player.pause()
                        player.replaceCurrentItem(with: nil)
                        isPlaying = false
                    }
            } else {
                ProgressView()
                    .controlSize(.large)
                    .tint(.white)
            }
        }
        .padding(12)
        .task(id: url) {
            let next = AVPlayer(url: url)
            next.actionAtItemEnd = .pause
            player = next
        }
        .onChange(of: playbackToggleRevision) { _ in
            guard let player else { return }
            if isPlaying {
                player.pause()
            } else {
                player.play()
            }
            isPlaying.toggle()
        }
    }
}

/// SwiftUI 没有可区分“精准触控板横向滚动”和普通拖拽的手势 API。
/// 这个窄 AppKit 桥只监听当前图片区域内的触控板滚动：适配态左右滑切图，
/// 放大态则把事件完整交还 NSScrollView 用于平移。
private struct ViewerTrackpadNavigationCapture: NSViewRepresentable {
    let onNavigate: (Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onNavigate: onNavigate)
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        context.coordinator.hostView = view
        context.coordinator.installMonitor()
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onNavigate = onNavigate
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        weak var hostView: NSView?
        var onNavigate: (Int) -> Void
        private var monitor: Any?
        private var accumulatedX: CGFloat = 0
        private var didTrigger = false

        init(onNavigate: @escaping (Int) -> Void) {
            self.onNavigate = onNavigate
        }

        func installMonitor() {
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      event.hasPreciseScrollingDeltas,
                      let hostView,
                      event.window === hostView.window else { return event }
                let point = hostView.convert(event.locationInWindow, from: nil)
                guard hostView.bounds.contains(point) else { return event }

                if let hit = event.window?.contentView?.hitTest(event.locationInWindow),
                   let zoomView = Self.zoomScrollView(containing: hit),
                   zoomView.magnification > 1.02 {
                    self.resetIfNeeded(for: event)
                    return event
                }

                if event.phase == .began {
                    accumulatedX = 0
                    didTrigger = false
                }
                guard !didTrigger,
                      abs(event.scrollingDeltaX) > abs(event.scrollingDeltaY) * 1.15 else {
                    resetIfNeeded(for: event)
                    return event
                }
                accumulatedX += event.scrollingDeltaX
                if abs(accumulatedX) >= 72 {
                    didTrigger = true
                    let direction = accumulatedX < 0 ? 1 : -1
                    DispatchQueue.main.async { self.onNavigate(direction) }
                }
                resetIfNeeded(for: event)
                return event
            }
        }

        func removeMonitor() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
            monitor = nil
        }

        private func resetIfNeeded(for event: NSEvent) {
            if event.phase == .ended || event.phase == .cancelled {
                accumulatedX = 0
                didTrigger = false
            }
        }

        private static func zoomScrollView(containing view: NSView) -> ZoomScrollView? {
            var current: NSView? = view
            while let candidate = current {
                if let zoom = candidate as? ZoomScrollView { return zoom }
                current = candidate.superview
            }
            return nil
        }
    }
}

/// 查看器条目：既能由本地 `MediaItem` 构造（相册），也能由远端 URL 构造（详情页艺术照）。
struct MediaImageViewerEntry: Identifiable, Equatable {
    let id: String
    let title: String
    let imagePath: String?
    /// 原始媒体路径。录像的 imagePath 是缩略图，播放与访达定位必须使用 mediaPath。
    let mediaPath: String?
    let isVideo: Bool
    let mediaType: MediaType
    let captureDate: Date?
    let fileSize: Int64?
    let isFavorite: Bool
    let pixelSize: CGSize?
    let mediaSubtypeLabel: String?
    let locationLabel: String?
    /// 关联的本地条目（用于收藏/播放）；远端艺术照、系统照片为 nil。
    let item: MediaItem?
    /// 系统照片库资产的 localIdentifier；非系统照片为 nil（走 imagePath）。
    let photoAssetID: String?

    var cacheKey: String {
        if let photoAssetID { return "photos:\(photoAssetID)" }
        return imagePath.map { "path:\($0)" } ?? "entry:\(id)"
    }

    var fileURL: URL? {
        let path = mediaPath ?? imagePath
        guard let path, !path.contains("://") else { return nil }
        return URL(fileURLWithPath: path)
    }

    init(item: MediaItem) {
        self.id = item.id
        self.title = item.title
        self.imagePath = item.posterPath
        self.mediaPath = item.filePath
        self.isVideo = item.type != .photo
        self.mediaType = item.type
        self.captureDate = item.createdAt
        self.fileSize = item.fileSize
        self.isFavorite = item.favorite
        self.pixelSize = nil
        self.mediaSubtypeLabel = item.type == .photo ? "照片" : "录像"
        self.locationLabel = nil
        self.item = item
        self.photoAssetID = nil
    }

    /// 远端图片（如 TMDB 艺术照）：仅展示，无收藏/访达定位。
    init(id: String, title: String, remoteURL: String) {
        self.id = id
        self.title = title
        self.imagePath = remoteURL
        self.mediaPath = nil
        self.isVideo = false
        self.mediaType = .photo
        self.captureDate = nil
        self.fileSize = nil
        self.isFavorite = false
        self.pixelSize = nil
        self.mediaSubtypeLabel = nil
        self.locationLabel = nil
        self.item = nil
        self.photoAssetID = nil
    }

    /// 系统照片库资产：图像/录像都由 PhotoKit 按 localIdentifier 加载。
    init(systemAsset: SystemPhotoAsset) {
        self.id = systemAsset.id
        self.title = systemAsset.displayTitle
        self.imagePath = nil
        self.mediaPath = nil
        self.isVideo = systemAsset.isVideo
        self.mediaType = systemAsset.isVideo ? .homeVideo : .photo
        self.captureDate = systemAsset.creationDate
        self.fileSize = nil
        self.isFavorite = systemAsset.isFavorite
        self.pixelSize = systemAsset.pixelWidth > 0 && systemAsset.pixelHeight > 0
            ? CGSize(width: systemAsset.pixelWidth, height: systemAsset.pixelHeight)
            : nil
        self.mediaSubtypeLabel = systemAsset.mediaSubtypeLabel
        self.locationLabel = systemAsset.locationName
        self.item = nil
        self.photoAssetID = systemAsset.id
    }

    static func == (lhs: MediaImageViewerEntry, rhs: MediaImageViewerEntry) -> Bool {
        lhs.id == rhs.id && lhs.isFavorite == rhs.isFavorite
    }
}

/// 底部缩略图条的单个小图：方形填充裁切（与其它相册软件的 filmstrip 一致），当前项白边高亮。
private struct ViewerThumbnail: View {
    let entry: MediaImageViewerEntry
    let isCurrent: Bool

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 4, style: .continuous)
        return Group {
            if let assetID = entry.photoAssetID {
                PhotoKitImage(assetID: assetID, targetSize: CGSize(width: 120, height: 120))
            } else if let path = entry.imagePath, !path.contains("://") {
                // 本地文件走新的缩略图服务（内存+磁盘缓存，滑回不重载）。
                PhotoThumbnail(path: path, displaySide: 56)
            } else if entry.imagePath != nil {
                PosterImage(path: entry.imagePath, title: entry.title, mediaType: entry.mediaType, cacheTargetSize: CGSize(width: 120, height: 120))
            } else {
                Color.white.opacity(0.1)
            }
        }
        .frame(width: 56, height: 56)
        .clipShape(shape)
        .overlay {
            if entry.isVideo {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(3)
                    .background(.black.opacity(0.5), in: Circle())
            }
        }
        .overlay {
            shape.strokeBorder(isCurrent ? Color.white : Color.white.opacity(0.12), lineWidth: isCurrent ? 2.5 : 0.8)
        }
        .opacity(isCurrent ? 1 : 0.6)
        .contentShape(Rectangle())
    }
}

// MARK: - 查看器浮动 chrome（macOS 26+ 原生液态玻璃，旧系统保持原样式）

/// 查看器圆形按钮底色：图片查看器的控件浮在静态照片之上，是 Apple 液态玻璃
/// 的标准使用场景（内容之上的控件层）；照片不逐帧重绘，玻璃背景采样成本固定，
/// 不会触发播放器弹层那类 WindowServer 每帧重算模糊的问题。
private struct ViewerCircleChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular.interactive(), in: Circle())
        } else {
            content.background(.white.opacity(0.13), in: Circle())
        }
    }
}

/// 信息面板底色：macOS 26+ 用原生液态玻璃替代 ultraThinMaterial + 手绘描边。
private struct ViewerInfoPanelChrome: ViewModifier {
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *) {
            content.glassEffect(.regular, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(.white.opacity(0.16), lineWidth: 0.8) }
        }
    }
}
