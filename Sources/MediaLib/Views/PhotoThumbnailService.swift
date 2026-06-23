import AppKit
import CryptoKit
import ImageIO
import SwiftUI

/// 相册本地照片/录像缩略图服务：参考 Apple PHCachingImageManager 思路。
/// 三级命中：内存 NSCache → 磁盘缩略图（小 JPEG）→ 原图按需下采样解码（解码一次，落盘后永久秒读）。
/// 解决：滑走滑回重复加载、LAN 大图加载慢、过采样浪费。
final class PhotoThumbnailService {
    static let shared = PhotoThumbnailService()

    private let memory = NSCache<NSString, NSImage>()
    private let diskDirectory: URL
    private let decodeQueue = DispatchQueue(label: "com.local.MediaLib.photoThumb", qos: .userInitiated, attributes: .concurrent)

    private init() {
        // ~512MB 内存预算，足以容纳一大段滚动窗口；磁盘缓存兜住其余。
        memory.totalCostLimit = 512 * 1024 * 1024
        memory.countLimit = 4000

        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        diskDirectory = caches.appendingPathComponent("com.local.MediaLib/PhotoThumbnails", isDirectory: true)
        try? FileManager.default.createDirectory(at: diskDirectory, withIntermediateDirectories: true)
    }

    /// 把显示边长换算成解码的最大像素：按屏幕缩放、并桶化到 128 的整数倍（稳定 key、跨布局复用），上限 512。
    static func maxPixel(forDisplay side: CGFloat) -> Int {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        let raw = max(side, 1) * scale
        let bucketed = ceil(raw / 128) * 128
        return Int(min(max(bucketed, 128), 512))
    }

    /// 同步读内存缓存（仅按 path+maxPixel，不做磁盘/stat），供视图首帧直出、避免滑回闪烁。
    func memoryImage(path: String, maxPixel: Int) -> NSImage? {
        memory.object(forKey: Self.memoryKey(path: path, maxPixel: maxPixel))
    }

    /// 预取（可视区前方预热）：内存已有则跳过，否则后台低优先解码进内存/磁盘缓存。
    func prefetch(path: String, displaySide: CGFloat) {
        let maxPixel = Self.maxPixel(forDisplay: displaySide)
        if memory.object(forKey: Self.memoryKey(path: path, maxPixel: maxPixel)) != nil { return }
        Task.detached(priority: .utility) { [weak self] in
            _ = await self?.thumbnail(path: path, maxPixel: maxPixel)
        }
    }

    /// 异步取缩略图：内存 → 磁盘 → 解码。可被 SwiftUI `.task(id:)` 取消。
    func thumbnail(path: String, maxPixel: Int) async -> NSImage? {
        let memKey = Self.memoryKey(path: path, maxPixel: maxPixel)
        if let cached = memory.object(forKey: memKey) { return cached }

        let directory = diskDirectory
        let result: NSImage? = await withCheckedContinuation { continuation in
            decodeQueue.async {
                let mtime = Self.modificationTimestamp(path: path)
                let diskURL = directory.appendingPathComponent(Self.diskFileName(path: path, maxPixel: maxPixel, mtime: mtime))

                // 磁盘命中：直接读小 JPEG（很快），不再整图重解。
                if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
                    continuation.resume(returning: image)
                    return
                }

                // 解码原图 → 写盘 → 返回。
                guard let image = Self.decode(path: path, maxPixel: maxPixel) else {
                    continuation.resume(returning: nil)
                    return
                }
                if let jpeg = Self.jpegData(from: image) {
                    try? jpeg.write(to: diskURL, options: .atomic)
                }
                continuation.resume(returning: image)
            }
        }

        if let result {
            memory.setObject(result, forKey: memKey, cost: Self.cost(of: result))
        }
        return result
    }

    private static func cost(of image: NSImage) -> Int {
        if let rep = image.representations.first {
            return max(rep.pixelsWide * rep.pixelsHigh * 4, 4 * 1024)
        }
        return max(Int(image.size.width * image.size.height) * 4, 4 * 1024)
    }

    // MARK: - 解码

    private static func decode(path: String, maxPixel: Int) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }

        // 先用嵌入缩略图（IfAbsent，LAN 上只读少量字节、最快）；若嵌入图不够清晰再整图下采样保证质量。
        let fastOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        if let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, fastOptions as CFDictionary),
           max(cg.width, cg.height) >= Int(Double(maxPixel) * 0.75) {
            return nsImage(from: cg)
        }

        let qualityOptions: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixel
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, qualityOptions as CFDictionary) else { return nil }
        return nsImage(from: cg)
    }

    private static func nsImage(from cg: CGImage) -> NSImage {
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        return NSImage(cgImage: cg, size: CGSize(width: CGFloat(cg.width) / scale, height: CGFloat(cg.height) / scale))
    }

    private static func jpegData(from image: NSImage) -> Data? {
        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff) else { return nil }
        return rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82])
    }

    // MARK: - Key / 文件名

    private static func memoryKey(path: String, maxPixel: Int) -> NSString {
        "\(path)|\(maxPixel)" as NSString
    }

    private static func diskFileName(path: String, maxPixel: Int, mtime: Int64) -> String {
        let raw = "\(path)|\(maxPixel)|\(mtime)"
        let digest = SHA256.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }

    private static func modificationTimestamp(path: String) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let date = attrs[.modificationDate] as? Date else { return 0 }
        return Int64(date.timeIntervalSince1970)
    }
}

/// 相册缩略图视图：用 `PhotoThumbnailService`，命中内存即首帧直出（滑回不重载），未命中占位→淡入。
struct PhotoThumbnail: View {
    let path: String?
    /// 期望显示边长（点）；内部换算解码像素。
    let displaySide: CGFloat
    var contentMode: ContentMode = .fill

    @State private var loaded: NSImage?

    private var maxPixel: Int { PhotoThumbnailService.maxPixel(forDisplay: displaySide) }

    var body: some View {
        let immediate = loaded ?? path.flatMap { PhotoThumbnailService.shared.memoryImage(path: $0, maxPixel: maxPixel) }
        ZStack {
            if let immediate {
                Image(nsImage: immediate)
                    .resizable()
                    .aspectRatio(contentMode: contentMode)
            } else {
                Rectangle().fill(AppColors.cleanPanelFill)
            }
        }
        .task(id: taskKey) { await load() }
    }

    private var taskKey: String { "\(path ?? "")|\(maxPixel)" }

    private func load() async {
        guard let path else { loaded = nil; return }
        if let cached = PhotoThumbnailService.shared.memoryImage(path: path, maxPixel: maxPixel) {
            loaded = cached
            return
        }
        let result = await PhotoThumbnailService.shared.thumbnail(path: path, maxPixel: maxPixel)
        guard !Task.isCancelled else { return }
        withAnimation(.easeOut(duration: 0.15)) { loaded = result }
    }
}
