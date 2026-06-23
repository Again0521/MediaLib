import AppKit
import SwiftUI

/// 基于 `NSScrollView.magnification` 的无级缩放图片视图（GPU 加速、丝滑，等同 Apple「预览/照片」）。
/// 捏合 / 双击 / 滚轮缩放、拖动平移；不用 SwiftUI 的 `.scaleEffect`（对大图实时栅格化会卡）。
struct ZoomableImageView: NSViewRepresentable {
    let image: NSImage
    /// 条目身份；变化时把缩放复位到适配（翻页归零）。
    let identity: String

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> ZoomScrollView {
        let scroll = ZoomScrollView()
        scroll.allowsMagnification = true
        scroll.minMagnification = 1
        scroll.maxMagnification = 8
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.drawsBackground = false
        scroll.backgroundColor = .clear
        scroll.contentView = CenteringClipView()
        scroll.contentView.drawsBackground = false
        scroll.contentView.postsBoundsChangedNotifications = true

        let imageView = NSImageView()
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.imageAlignment = .alignCenter
        imageView.animates = false
        imageView.image = image
        imageView.frame = scroll.bounds
        imageView.autoresizingMask = [.width, .height]
        scroll.documentView = imageView

        let doubleClick = NSClickGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleDoubleClick(_:)))
        doubleClick.numberOfClicksRequired = 2
        scroll.addGestureRecognizer(doubleClick)

        context.coordinator.scroll = scroll
        context.coordinator.identity = identity
        return scroll
    }

    func updateNSView(_ nsView: ZoomScrollView, context: Context) {
        guard let imageView = nsView.documentView as? NSImageView else { return }
        if context.coordinator.identity != identity {
            // 翻到新照片：换图并复位缩放。
            imageView.image = image
            nsView.magnification = 1
            context.coordinator.identity = identity
        } else if imageView.image !== image {
            imageView.image = image
        }
    }

    final class Coordinator: NSObject {
        weak var scroll: ZoomScrollView?
        var identity: String = ""

        @objc func handleDoubleClick(_ gesture: NSClickGestureRecognizer) {
            guard let scroll, let document = scroll.documentView else { return }
            let point = gesture.location(in: document)
            if scroll.magnification > 1.01 {
                NSAnimationContext.runAnimationGroup { ctx in
                    ctx.duration = 0.2
                    scroll.animator().magnification = 1
                }
            } else {
                scroll.setMagnification(3, centeredAt: point)
            }
        }
    }
}

/// 文档比可视区小时把内容居中（默认 NSClipView 会贴左下角）。
final class CenteringClipView: NSClipView {
    override func constrainBoundsRect(_ proposedBounds: NSRect) -> NSRect {
        var rect = super.constrainBoundsRect(proposedBounds)
        guard let documentView else { return rect }
        let docFrame = documentView.frame
        if rect.width > docFrame.width {
            rect.origin.x = (docFrame.width - rect.width) / 2
        }
        if rect.height > docFrame.height {
            rect.origin.y = (docFrame.height - rect.height) / 2
        }
        return rect
    }
}

final class ZoomScrollView: NSScrollView {}

/// 把单个查看器条目（本地文件 / 远端 URL / 系统照片）加载为整图后交给 `ZoomableImageView` 无级缩放。
/// 整图未就绪前先用缩略图占位，避免黑屏。
struct ZoomablePhoto: View {
    @EnvironmentObject private var systemPhotoLibrary: SystemPhotoLibraryStore
    let entry: MediaImageViewerEntry
    @State private var fullImage: NSImage?

    var body: some View {
        ZStack {
            placeholder
            if let fullImage {
                ZoomableImageView(image: fullImage, identity: entry.id)
                    .transition(.opacity)
            }
        }
        .task(id: entry.id) { await loadFull() }
    }

    @ViewBuilder
    private var placeholder: some View {
        if let assetID = entry.photoAssetID {
            PhotoKitImage(assetID: assetID, targetSize: CGSize(width: 600, height: 600), contentMode: .aspectFit)
                .padding(20)
        } else if let path = entry.imagePath, !path.contains("://") {
            PhotoThumbnail(path: path, displaySide: 600, contentMode: .fit)
                .padding(20)
        } else {
            ProgressView().controlSize(.large).tint(.white)
        }
    }

    private func loadFull() async {
        let target = entry
        if let assetID = target.photoAssetID {
            fullImage = nil
            let maxPixel = NSScreen.main.map {
                max($0.frame.width, $0.frame.height) * $0.backingScaleFactor * 1.35
            } ?? 3200
            let aspect = target.pixelSize.map { $0.width / max($0.height, 1) } ?? 1
            let targetSize = aspect >= 1
                ? CGSize(width: maxPixel, height: maxPixel / max(aspect, 0.01))
                : CGSize(width: maxPixel * aspect, height: maxPixel)
            let image = await systemPhotoLibrary.fullResolutionImage(
                assetID: assetID,
                targetSize: targetSize
            )
            guard !Task.isCancelled, target.id == entry.id else { return }
            withAnimation(.easeOut(duration: 0.18)) { fullImage = image }
            return
        }
        if let cached = MediaImageFullResolutionCache.shared.cachedImage(for: target) {
            fullImage = cached
            return
        }
        fullImage = nil
        let image = await MediaImageFullResolutionCache.shared.image(for: target)
        guard !Task.isCancelled, target.id == entry.id else { return }
        withAnimation(.easeOut(duration: 0.18)) { fullImage = image }
    }
}

/// 查看器全图缓存：切回已看图片直接复用，切图时对相邻图片低优先级预取。
/// 本地图片按当前屏幕的高分辨率显示需求下采样，避免每次把超大原图完整解码进内存。
@MainActor
final class MediaImageFullResolutionCache {
    static let shared = MediaImageFullResolutionCache()

    private let cache = NSCache<NSString, NSImage>()
    private var inFlight: [String: Task<SendableViewerImage, Never>] = [:]

    private init() {
        cache.countLimit = 8
        cache.totalCostLimit = 320 * 1024 * 1024
    }

    func cachedImage(for entry: MediaImageViewerEntry) -> NSImage? {
        cache.object(forKey: entry.cacheKey as NSString)
    }

    func image(for entry: MediaImageViewerEntry, priority: TaskPriority = .userInitiated) async -> NSImage? {
        if let cached = cachedImage(for: entry) { return cached }
        if let task = inFlight[entry.cacheKey] { return await task.value.image }

        let task = Task(priority: priority) {
            await Self.load(entry)
        }
        inFlight[entry.cacheKey] = task
        let image = await task.value.image
        inFlight[entry.cacheKey] = nil
        if let image {
            cache.setObject(image, forKey: entry.cacheKey as NSString, cost: Self.cost(of: image))
        }
        return image
    }

    func prefetch(_ entries: [MediaImageViewerEntry]) {
        for entry in entries where !entry.isVideo
            && entry.photoAssetID == nil
            && cachedImage(for: entry) == nil
            && inFlight[entry.cacheKey] == nil {
            Task { _ = await image(for: entry, priority: .utility) }
        }
    }

    private static func load(_ entry: MediaImageViewerEntry) async -> SendableViewerImage {
        // 系统照片必须由场景级 SystemPhotoLibraryStore 的共享 PHCachingImageManager 加载；
        // 这个文件缓存仅处理本地与远程普通图片。
        guard entry.photoAssetID == nil else { return SendableViewerImage(nil) }
        guard let path = entry.imagePath else { return SendableViewerImage(nil) }
        let maxPixel = targetMaxPixel()
        if path.contains("://"), let url = URL(string: path) {
            guard let (data, _) = try? await URLSession.shared.data(from: url) else { return SendableViewerImage(nil) }
            return await Task.detached(priority: .userInitiated) {
                SendableViewerImage(downsampledImage(data: data, maxPixel: maxPixel))
            }.value
        }
        return await Task.detached(priority: .userInitiated) {
            SendableViewerImage(downsampledImage(url: URL(fileURLWithPath: path), maxPixel: maxPixel))
        }.value
    }

    private nonisolated static func downsampledImage(url: URL, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return downsampledImage(source: source, maxPixel: maxPixel)
    }

    private nonisolated static func downsampledImage(data: Data, maxPixel: CGFloat) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsampledImage(source: source, maxPixel: maxPixel)
    }

    private nonisolated static func downsampledImage(source: CGImageSource, maxPixel: CGFloat) -> NSImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: Int(maxPixel)
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func targetMaxPixel() -> CGFloat {
        let screen = NSScreen.main
        let longestSide = max(screen?.frame.width ?? 1728, screen?.frame.height ?? 1117)
        let scale = screen?.backingScaleFactor ?? 2
        return min(max(longestSide * scale * 1.5, 2400), 5120)
    }

    private static func cost(of image: NSImage) -> Int {
        guard let representation = image.representations.first else { return 16 * 1024 * 1024 }
        return max(representation.pixelsWide, 1) * max(representation.pixelsHigh, 1) * 4
    }
}

private struct SendableViewerImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}
