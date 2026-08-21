import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Web 海报的受限缩略图派生器。原图始终先由资料库授权层决定可见性；本类型只在
/// 已授权后的本地文件或受限远程响应上工作，并把小 JPEG 缓存在非 Web 可寻址的私有目录中。
/// 这样海报墙无需让每个浏览器解码数十 MB 的原始图片，也不把源文件路径暴露给页面。
final class ServerArtworkThumbnailer {
    static let supportedMaximumPixels: Set<Int> = [160, 320, 640, 1_024]
    private static let maximumCacheByteLength = 192 * 1_024 * 1_024
    private static let maximumCacheEntryCount = 1_200
    private static let writesBeforePruning = 16
    /// 冷启动的海报墙上，这是最紧的一道串行点：8 路上游取图最终要漏斗进这里的
    /// N 路 decode + JPEG 编码。上限从 4 放到 8 并按可用核数取值——两路时 24 张
    /// 封面要走 12 轮解码，那比网络还慢。
    private static let defaultMaximumConcurrentGenerations = 2
    private static let generationCeiling = 8
    /// Keep this aligned with the private browser cache response. The alias
    /// never contains an upstream URL or token; it only points at a derived
    /// local JPEG which has already passed the item authorization boundary.
    private static let remoteAliasLifetime: TimeInterval = 300
    /// 远程缩略图的磁盘条目年龄上限：上游可能就地换图而地址不变。
    private static let remoteThumbnailMaximumAge: TimeInterval = 24 * 60 * 60

    private struct RemoteThumbnailKey: Hashable {
        let id: String
        let maximumPixel: Int
    }

    private struct RemoteThumbnailAlias {
        let fileURL: URL
        let expiresAt: Date
    }

    private let fileManager: FileManager
    private let cacheDirectory: URL
    /// A cold thumbnail is CPU and disk intensive.  We deliberately allow a
    /// tiny amount of parallelism for distinct posters, while making callers
    /// for the same cache key wait for the one authoritative write.
    private let generationCondition = NSCondition()
    private let maximumConcurrentGenerations: Int
    private let generationObserver: (() -> Void)?
    private var inFlightDestinations: Set<String> = []
    private var activeGenerationCount = 0
    private var writesSincePruning = 0
    private var isPruning = false
    private var remoteThumbnailAliases: [RemoteThumbnailKey: RemoteThumbnailAlias] = [:]
    /// 淘汰在自己的队列上跑。它要枚举上千个文件并逐个读属性，放在请求线程上、
    /// 又攥着生成协调锁，等于每 16 次写入就让所有缩略图生成一起停下来等磁盘。
    private let pruningQueue = DispatchQueue(
        label: "MediaLibServer.ArtworkThumbnailPruning", qos: .utility
    )

    init(
        cacheDirectory: URL? = nil,
        fileManager: FileManager = .default,
        maximumConcurrentGenerations: Int = defaultMaximumConcurrentGenerations,
        generationObserver: (() -> Void)? = nil
    ) {
        self.fileManager = fileManager
        self.maximumConcurrentGenerations = min(max(1, maximumConcurrentGenerations), Self.generationCeiling)
        self.generationObserver = generationObserver
        if let cacheDirectory {
            self.cacheDirectory = cacheDirectory
        } else {
            let base = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            self.cacheDirectory = base
                .appendingPathComponent("com.local.MediaLib/ServerArtworkThumbnails", isDirectory: true)
        }
        try? fileManager.createDirectory(
            at: self.cacheDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    /// 只接受固定桶，避免查询参数把服务端变成任意尺寸图片转换器。
    func thumbnail(for asset: ServerMediaAsset, maximumPixel: Int) -> ServerMediaAsset? {
        guard asset.remoteURL == nil,
              Self.supportedMaximumPixels.contains(maximumPixel),
              let identity = sourceIdentity(for: asset)
        else { return nil }
        return thumbnail(id: asset.id, sourceIdentity: identity, maximumPixel: maximumPixel) {
            self.downsample(asset.fileURL, maximumPixel: maximumPixel)
        }
    }

    /// 远程封面只能在路由层完成来源及权限校验后作为数据传入；缓存身份是内容摘要，
    /// 而不是上游 URL，因此 token 和服务端地址既不会出现在文件名也不会持久化。
    func thumbnail(
        forRemoteData data: Data,
        id: String,
        upstreamIdentity: String,
        maximumPixel: Int
    ) -> ServerMediaAsset? {
        guard !data.isEmpty,
              data.count <= ServerRemoteAssetFetcher.maximumArtworkByteLength,
              Self.supportedMaximumPixels.contains(maximumPixel),
              !upstreamIdentity.isEmpty
        else { return nil }
        // 磁盘键用**与凭据无关的上游身份**，而不是图片字节的摘要。用字节摘要时，
        // 想找到那张已经生成好的缩略图必须先把原图重新下载一遍——缓存等于没有。
        let generated = thumbnail(
            id: id, sourceIdentity: "remote:\(upstreamIdentity)", maximumPixel: maximumPixel
        ) {
            self.downsample(data, maximumPixel: maximumPixel)
        }
        if let generated {
            rememberRemoteThumbnail(generated, id: id, maximumPixel: maximumPixel)
        }
        return generated
    }

    /// 不联系上游就取回已派生的远程缩略图。
    ///
    /// 直接按上游身份推算磁盘路径，因此进程重启或短缓存过期都不需要重新下载原图。
    /// 上游可能就地替换封面而地址不变，所以这里给磁盘条目设一天的年龄上限：
    /// 过期即视为未命中并重新取一次，把陈旧窗口限制在可接受范围内。
    func cachedRemoteThumbnail(
        id: String,
        upstreamIdentity: String,
        maximumPixel: Int
    ) -> ServerMediaAsset? {
        guard !id.isEmpty, !upstreamIdentity.isEmpty,
              Self.supportedMaximumPixels.contains(maximumPixel)
        else { return nil }
        let destination = cacheDirectory.appendingPathComponent(
            Self.fileName(sourceIdentity: "remote:\(upstreamIdentity)", maximumPixel: maximumPixel),
            isDirectory: false
        )
        guard let values = try? destination.resourceValues(forKeys: [.contentModificationDateKey]),
              let modified = values.contentModificationDate,
              Date().timeIntervalSince(modified) <= Self.remoteThumbnailMaximumAge
        else { return nil }
        generationCondition.lock()
        defer { generationCondition.unlock() }
        return cachedAsset(at: destination, id: id)
    }

    /// Returns a recently generated remote thumbnail without contacting its
    /// upstream server. The short, in-memory alias is deliberately keyed only
    /// by the opaque item ID and requested bucket, so remote URLs and API keys
    /// never become filenames, database values or Web-visible data.
    func cachedRemoteThumbnail(id: String, maximumPixel: Int) -> ServerMediaAsset? {
        guard !id.isEmpty, Self.supportedMaximumPixels.contains(maximumPixel) else { return nil }
        let key = RemoteThumbnailKey(id: id, maximumPixel: maximumPixel)
        generationCondition.lock()
        defer { generationCondition.unlock() }
        guard let alias = remoteThumbnailAliases[key], alias.expiresAt > Date() else {
            remoteThumbnailAliases.removeValue(forKey: key)
            return nil
        }
        guard let cached = cachedAsset(at: alias.fileURL, id: id) else {
            remoteThumbnailAliases.removeValue(forKey: key)
            return nil
        }
        return cached
    }

    private func thumbnail(
        id: String,
        sourceIdentity: String,
        maximumPixel: Int,
        imageProvider: () -> CGImage?
    ) -> ServerMediaAsset? {
        let destination = cacheDirectory.appendingPathComponent(
            Self.fileName(sourceIdentity: sourceIdentity, maximumPixel: maximumPixel),
            isDirectory: false
        )
        let destinationKey = destination.path

        generationCondition.lock()
        while true {
            if let cached = cachedAsset(at: destination, id: id) {
                generationCondition.unlock()
                return cached
            }
            if inFlightDestinations.contains(destinationKey) {
                repeat { generationCondition.wait() } while inFlightDestinations.contains(destinationKey)
                let cached = cachedAsset(at: destination, id: id)
                generationCondition.unlock()
                return cached
            }
            if activeGenerationCount < maximumConcurrentGenerations {
                activeGenerationCount += 1
                inFlightDestinations.insert(destinationKey)
                generationCondition.unlock()
                break
            }
            generationCondition.wait()
        }

        generationObserver?()
        let generated: ServerMediaAsset?
        if let image = imageProvider(),
           writeJPEG(image, to: destination) {
            generated = cachedAsset(at: destination, id: id)
        } else {
            generated = nil
        }

        generationCondition.lock()
        var shouldPrune = false
        if generated != nil {
            writesSincePruning += 1
            if writesSincePruning >= Self.writesBeforePruning, !isPruning {
                writesSincePruning = 0
                isPruning = true
                shouldPrune = true
            }
        }
        activeGenerationCount -= 1
        inFlightDestinations.remove(destinationKey)
        generationCondition.broadcast()
        generationCondition.unlock()
        // 请求线程不等淘汰：它只是个上限维护，晚几百毫秒执行没有任何可观察差别，
        // 而同步跑会把这一次海报请求的延迟拉到上千个文件的属性读取上。
        if shouldPrune {
            pruningQueue.async { [weak self] in
                guard let self else { return }
                self.pruneCacheIfNeeded()
                self.generationCondition.lock()
                self.isPruning = false
                self.generationCondition.unlock()
            }
        }
        return generated
    }

    private func cachedAsset(at url: URL, id: String) -> ServerMediaAsset? {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= ServerArtworkKind.maximumByteLength
        else { return nil }
        return ServerMediaAsset(id: id, fileURL: url, byteLength: Int64(size))
    }

    private func rememberRemoteThumbnail(_ asset: ServerMediaAsset, id: String, maximumPixel: Int) {
        let key = RemoteThumbnailKey(id: id, maximumPixel: maximumPixel)
        generationCondition.lock()
        remoteThumbnailAliases[key] = RemoteThumbnailAlias(
            fileURL: asset.fileURL,
            expiresAt: Date().addingTimeInterval(Self.remoteAliasLifetime)
        )
        generationCondition.unlock()
    }

    private func sourceIdentity(for asset: ServerMediaAsset) -> String? {
        guard let values = try? asset.fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]),
              values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= ServerArtworkKind.maximumByteLength
        else { return nil }
        let modified = Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970)
        return "\(asset.fileURL.standardizedFileURL.path)|\(size)|\(modified)"
    }

    private func downsample(_ sourceURL: URL, maximumPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else { return nil }
        return downsample(source, maximumPixel: maximumPixel)
    }

    private func downsample(_ data: Data, maximumPixel: Int) -> CGImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return downsample(source, maximumPixel: maximumPixel)
    }

    private func downsample(_ source: CGImageSource, maximumPixel: Int) -> CGImage? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maximumPixel
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    private func writeJPEG(_ image: CGImage, to destination: URL) -> Bool {
        let temporary = cacheDirectory.appendingPathComponent(".\(UUID().uuidString).jpg", isDirectory: false)
        defer { try? fileManager.removeItem(at: temporary) }
        guard let writer = CGImageDestinationCreateWithURL(
            temporary as CFURL,
            UTType.jpeg.identifier as CFString,
            1,
            nil
        ) else { return false }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.82] as CFDictionary)
        guard CGImageDestinationFinalize(writer) else { return false }
        try? fileManager.removeItem(at: destination)
        do {
            try fileManager.moveItem(at: temporary, to: destination)
            return true
        } catch {
            return false
        }
    }

    /// 缓存只是加速层，不能随资料库增长而无限占用服务器磁盘。
    ///
    /// 在 `pruningQueue` 上执行，**不持有生成协调锁**：并行写入用的是隐藏临时文件
    /// （`.uuid.jpg`）且枚举跳过隐藏项，因此看不到未完成的写入；已经落位的文件被
    /// 删掉时，读取方拿到的是 `cachedAsset` 的 nil，会重新生成一次——代价是一次
    /// 多余的解码，换掉的是每 16 次写入就让所有生成停摆一次。
    /// `isPruning` 保证同一时刻只有一趟。
    private func pruneCacheIfNeeded() {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, byteLength: Int, modifiedAt: Date)] = []
        for url in urls {
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0
            else { continue }
            entries.append((url, size, values.contentModificationDate ?? .distantPast))
        }
        var total = entries.reduce(0) { $0 + $1.byteLength }
        guard entries.count > Self.maximumCacheEntryCount || total > Self.maximumCacheByteLength else { return }
        for entry in entries.sorted(by: { $0.modifiedAt < $1.modifiedAt }) {
            guard entries.count > Self.maximumCacheEntryCount || total > Self.maximumCacheByteLength else { break }
            guard (try? fileManager.removeItem(at: entry.url)) != nil else { continue }
            total -= entry.byteLength
            entries.removeAll { $0.url == entry.url }
        }
    }

    private static func fileName(sourceIdentity: String, maximumPixel: Int) -> String {
        let digest = SHA256.hash(data: Data("\(sourceIdentity)|\(maximumPixel)".utf8))
        return digest.map { String(format: "%02x", $0) }.joined() + ".jpg"
    }
}
