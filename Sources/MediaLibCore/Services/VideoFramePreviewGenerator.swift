import AppKit
import AVFoundation
import Foundation

public struct VideoFrameStoryboardSummary: Sendable {
    public let requestedCount: Int
    public let generatedCount: Int
    public let cachedCount: Int
    public let failedCount: Int

    public init(requestedCount: Int, generatedCount: Int, cachedCount: Int, failedCount: Int) {
        self.requestedCount = requestedCount
        self.generatedCount = generatedCount
        self.cachedCount = cachedCount
        self.failedCount = failedCount
    }
}

private actor VideoPreviewGenerationGate {
    private let limit: Int
    private var activeCount = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(limit: Int) {
        self.limit = max(limit, 1)
    }

    func acquire() async {
        if activeCount < limit {
            activeCount += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func release() {
        if waiters.isEmpty {
            activeCount = max(activeCount - 1, 0)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

public enum VideoFramePreviewGenerator {
    private static let cache = NSCache<NSString, NSImage>()
    private static let previewSize = CGSize(width: 312, height: 176)
    private static let configurationLock = NSLock()
    private static var configuredDiskCacheDirectory: URL?
    private static let requestLock = NSLock()
    private static let generationGate = VideoPreviewGenerationGate(limit: 1)
    private static var inFlightRequests: [String: Task<SendableVideoPreviewImage, Never>] = [:]
    private static var activePrefetchAnchors = Set<String>()
    private static var recentPrefetchAnchors: [String: Date] = [:]
    private static var activePrefetchCount = 0

    public static func configure(diskCacheDirectory: URL) {
        configurationLock.lock()
        configuredDiskCacheDirectory = diskCacheDirectory
        configurationLock.unlock()
        try? FileManager.default.createDirectory(at: diskCacheDirectory, withIntermediateDirectories: true)
    }

    public static func bucket(for time: Double, duration: Double, preferCoarse: Bool) -> Int {
        let interval = segmentInterval(duration: duration, preferCoarse: preferCoarse)
        let segmentIndex = floor(max(time, 0) / interval)
        let sampleTime = min(max(segmentIndex * interval + interval * 0.5, 0), max(duration - 0.25, 0))
        return Int(sampleTime.rounded())
    }

    public static func storyboardBuckets(duration: Double, preferCoarse: Bool) -> [Int] {
        guard duration.isFinite, duration > 1 else { return [] }
        let interval = segmentInterval(duration: duration, preferCoarse: preferCoarse)
        var buckets: [Int] = []
        var seen = Set<Int>()
        var cursor: Double = 0
        while cursor <= duration {
            let bucket = bucket(for: cursor, duration: duration, preferCoarse: preferCoarse)
            if seen.insert(bucket).inserted {
                buckets.append(bucket)
            }
            cursor += interval
        }
        return buckets
    }

    public static func cachedImage(itemID: String, time: Double, duration: Double, preferFFmpeg: Bool) -> NSImage? {
        configureMemoryCacheLimits()
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let key = cacheKey(itemID: itemID, bucket: bucket)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        guard let diskCached = diskCachedImage(itemID: itemID, bucket: bucket) else { return nil }
        cache.setObject(diskCached, forKey: key as NSString, cost: imageCost(diskCached))
        return diskCached
    }

    public static func memoryCachedImage(itemID: String, time: Double, duration: Double, preferFFmpeg: Bool) -> NSImage? {
        configureMemoryCacheLimits()
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        return cache.object(forKey: cacheKey(itemID: itemID, bucket: bucket) as NSString)
    }

    public static func shouldDeferInteractiveRequest(
        itemID: String,
        time: Double,
        duration: Double,
        preferFFmpeg: Bool,
        maxQueuedRequests: Int = 2
    ) -> Bool {
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let key = cacheKey(itemID: itemID, bucket: bucket)
        requestLock.lock()
        defer { requestLock.unlock() }
        return inFlightRequests[key] == nil && inFlightRequests.count >= maxQueuedRequests
    }

    public static func prefetchAround(itemID: String, filePath: String, time: Double, duration: Double, preferFFmpeg: Bool) {
        let interval = segmentInterval(duration: duration, preferCoarse: preferFFmpeg)
        let candidates = [time + interval, time - interval]
            .filter { $0 >= 0 && (duration <= 0 || $0 <= duration) }
        guard !candidates.isEmpty else { return }
        let anchorBucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let anchorKey = "\(cacheKey(itemID: itemID, bucket: anchorBucket))-\(preferFFmpeg ? "coarse" : "fine")"
        guard beginPrefetch(anchorKey: anchorKey) else { return }
        Task.detached(priority: .background) {
            defer { Self.finishPrefetch(anchorKey: anchorKey) }
            do {
                try await Task.sleep(nanoseconds: 180_000_000)
            } catch {
                return
            }
            for candidate in candidates {
                if Task.isCancelled { return }
                if Self.memoryCachedImage(itemID: itemID, time: candidate, duration: duration, preferFFmpeg: preferFFmpeg) != nil { continue }
                _ = await Self.image(
                    itemID: itemID,
                    filePath: filePath,
                    time: candidate,
                    duration: duration,
                    preferFFmpeg: preferFFmpeg,
                    priority: .background
                )
            }
        }
    }

    public static func image(
        itemID: String,
        filePath: String,
        time: Double,
        duration: Double,
        preferFFmpeg: Bool,
        priority: TaskPriority = .utility
    ) async -> NSImage? {
        configureMemoryCacheLimits()
        let bucket = bucket(for: time, duration: duration, preferCoarse: preferFFmpeg)
        let key = cacheKey(itemID: itemID, bucket: bucket)
        if let cached = cache.object(forKey: key as NSString) {
            return cached
        }
        let task = imageTask(
            key: key,
            itemID: itemID,
            filePath: filePath,
            bucket: bucket,
            preferFFmpeg: preferFFmpeg,
            priority: priority
        )
        return await task.value.image.map { image in
            cache.setObject(image, forKey: key as NSString, cost: imageCost(image))
            return image
        }
    }

    private static func imageTask(
        key: String,
        itemID: String,
        filePath: String,
        bucket: Int,
        preferFFmpeg: Bool,
        priority: TaskPriority
    ) -> Task<SendableVideoPreviewImage, Never> {
        requestLock.lock()
        if let existing = inFlightRequests[key] {
            requestLock.unlock()
            return existing
        }
        let task = Task.detached(priority: priority) {
            if let cached = Self.diskCachedImage(itemID: itemID, bucket: bucket) {
                return SendableVideoPreviewImage(cached)
            }
            guard !Task.isCancelled else {
                return SendableVideoPreviewImage(nil)
            }
            await Self.generationGate.acquire()
            defer {
                Task { await Self.generationGate.release() }
            }
            guard !Task.isCancelled else {
                return SendableVideoPreviewImage(nil)
            }
            if let cached = Self.diskCachedImage(itemID: itemID, bucket: bucket) {
                return SendableVideoPreviewImage(cached)
            }
            let seconds = max(Double(bucket), 0)
            if !preferFFmpeg,
               let image = Self.avFoundationImage(filePath: filePath, seconds: seconds) {
                Self.writeDiskCache(image, itemID: itemID, bucket: bucket)
                return SendableVideoPreviewImage(image)
            }
            if let image = Self.ffmpegImage(itemID: itemID, filePath: filePath, bucket: bucket, seconds: seconds) {
                return SendableVideoPreviewImage(image)
            }
            if preferFFmpeg,
               let image = Self.avFoundationImage(filePath: filePath, seconds: seconds) {
                Self.writeDiskCache(image, itemID: itemID, bucket: bucket)
                return SendableVideoPreviewImage(image)
            }
            return SendableVideoPreviewImage(nil)
        }
        inFlightRequests[key] = task
        requestLock.unlock()
        Task.detached(priority: .background) {
            _ = await task.value
            Self.clearInFlightRequest(key: key)
        }
        return task
    }

    private static func clearInFlightRequest(key: String) {
        requestLock.lock()
        inFlightRequests[key] = nil
        requestLock.unlock()
    }

    private static func beginPrefetch(anchorKey: String) -> Bool {
        let now = Date()
        requestLock.lock()
        defer { requestLock.unlock() }
        recentPrefetchAnchors = recentPrefetchAnchors.filter { now.timeIntervalSince($0.value) < 4 }
        guard activePrefetchCount < 1,
              !activePrefetchAnchors.contains(anchorKey) else {
            return false
        }
        if let recent = recentPrefetchAnchors[anchorKey],
           now.timeIntervalSince(recent) < 1.8 {
            return false
        }
        activePrefetchCount += 1
        activePrefetchAnchors.insert(anchorKey)
        recentPrefetchAnchors[anchorKey] = now
        return true
    }

    private static func finishPrefetch(anchorKey: String) {
        requestLock.lock()
        activePrefetchAnchors.remove(anchorKey)
        activePrefetchCount = max(activePrefetchCount - 1, 0)
        requestLock.unlock()
    }

    public static func prewarmStoryboard(
        itemID: String,
        filePath: String,
        duration: Double,
        preferFFmpeg: Bool,
        progress: ((Int, Int, Int) async -> Void)? = nil
    ) async throws -> VideoFrameStoryboardSummary {
        let buckets = storyboardBuckets(duration: duration, preferCoarse: preferFFmpeg)
        guard !buckets.isEmpty else {
            return VideoFrameStoryboardSummary(requestedCount: 0, generatedCount: 0, cachedCount: 0, failedCount: 0)
        }

        var generated = 0
        var cached = 0
        var failed = 0
        for (index, bucket) in buckets.enumerated() {
            try Task.checkCancellation()
            if diskCachedImage(itemID: itemID, bucket: bucket) != nil {
                cached += 1
            } else if await image(itemID: itemID, filePath: filePath, time: Double(bucket), duration: duration, preferFFmpeg: preferFFmpeg) != nil {
                generated += 1
            } else {
                failed += 1
            }
            if index == buckets.count - 1 || index % 4 == 0 {
                await progress?(index + 1, buckets.count, generated + cached)
            }
        }
        return VideoFrameStoryboardSummary(
            requestedCount: buckets.count,
            generatedCount: generated,
            cachedCount: cached,
            failedCount: failed
        )
    }

    private static func configureMemoryCacheLimits() {
        cache.countLimit = 160
        cache.totalCostLimit = 32 * 1024 * 1024
    }

    private static func segmentInterval(duration: Double, preferCoarse: Bool) -> Double {
        guard duration.isFinite, duration > 0 else {
            return preferCoarse ? 18 : 12
        }
        let targetSegments = preferCoarse ? 84.0 : 96.0
        let minimum = preferCoarse ? 12.0 : 8.0
        let maximum = preferCoarse ? 120.0 : 90.0
        return min(max(duration / targetSegments, minimum), maximum)
    }

    private static func avFoundationImage(filePath: String, seconds: Double) -> NSImage? {
        let url: URL
        if let remoteURL = URL(string: filePath),
           let scheme = remoteURL.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            url = remoteURL
        } else {
            url = URL(fileURLWithPath: filePath)
        }
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = previewSize
        generator.requestedTimeToleranceBefore = CMTime(seconds: 1.0, preferredTimescale: 600)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 1.0, preferredTimescale: 600)
        guard let cgImage = try? generator.copyCGImage(
            at: CMTime(seconds: seconds, preferredTimescale: 600),
            actualTime: nil
        ), !Self.isLikelyBlackFrame(cgImage) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    private static func ffmpegImage(itemID: String, filePath: String, bucket: Int, seconds: Double) -> NSImage? {
        guard let ffmpegURL = Self.ffmpegExecutableURL() else { return nil }
        let outputURL = diskCacheURL(itemID: itemID, bucket: bucket)
        do {
            try FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        } catch {
            return nil
        }
        if let cached = diskCachedImage(itemID: itemID, bucket: bucket) {
            return cached
        }

        let seekTimes = [seconds, max(seconds + 1.5, 0), max(seconds - 1.5, 0)]
        for seek in seekTimes {
            try? FileManager.default.removeItem(at: outputURL)
            let arguments = [
                "-hide_banner",
                "-loglevel", "error",
                "-y",
                "-ss", String(format: "%.3f", seek),
                "-i", filePath,
                "-frames:v", "1",
                "-vf", "scale=312:176:force_original_aspect_ratio=decrease,pad=312:176:(ow-iw)/2:(oh-ih)/2",
                "-q:v", "4",
                outputURL.path
            ]
            if Self.runFFmpeg(ffmpegURL: ffmpegURL, arguments: arguments, timeout: 9),
               let image = Self.validateGeneratedFrame(outputURL) {
                return image
            }
        }
        try? FileManager.default.removeItem(at: outputURL)
        return nil
    }

    private static func ffmpegExecutableURL() -> URL? {
        var candidates: [URL] = []
        if let executableDirectory = Bundle.main.executableURL?.deletingLastPathComponent() {
            candidates.append(executableDirectory.appendingPathComponent("ffmpeg"))
        }
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/local/bin/ffmpeg"))
        candidates.append(URL(fileURLWithPath: "/usr/bin/ffmpeg"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    private static func runFFmpeg(ffmpegURL: URL, arguments: [String], timeout: TimeInterval) -> Bool {
        let process = Process()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardOutput = Pipe()
        process.standardError = Pipe()

        do {
            try process.run()
        } catch {
            return false
        }

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.04)
        }
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            return false
        }
        process.waitUntilExit()
        return process.terminationStatus == 0
    }

    private static func validateGeneratedFrame(_ url: URL) -> NSImage? {
        guard FileManager.default.fileExists(atPath: url.path),
              let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !Self.isLikelyBlackFrame(cgImage) else {
            try? FileManager.default.removeItem(at: url)
            return nil
        }
        return image
    }

    private static func diskCachedImage(itemID: String, bucket: Int) -> NSImage? {
        let url = diskCacheURL(itemID: itemID, bucket: bucket)
        guard let image = NSImage(contentsOf: url),
              let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              !Self.isLikelyBlackFrame(cgImage) else {
            return nil
        }
        return image
    }

    private static func writeDiskCache(_ image: NSImage, itemID: String, bucket: Int) {
        let url = diskCacheURL(itemID: itemID, bucket: bucket)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return }
            let bitmap = NSBitmapImageRep(cgImage: cgImage)
            guard let data = bitmap.representation(using: .jpeg, properties: [.compressionFactor: 0.78]) else { return }
            try data.write(to: url, options: [.atomic])
        } catch {
            return
        }
    }

    private static func diskCacheURL(itemID: String, bucket: Int) -> URL {
        diskCacheDirectory().appendingPathComponent("\(safeItemID(itemID))-\(bucket).jpg", isDirectory: false)
    }

    private static func diskCacheDirectory() -> URL {
        configurationLock.lock()
        let configured = configuredDiskCacheDirectory
        configurationLock.unlock()
        return configured ?? FileManager.default.temporaryDirectory.appendingPathComponent("MediaLibPreviewFrames", isDirectory: true)
    }

    private static func cacheKey(itemID: String, bucket: Int) -> String {
        "\(safeItemID(itemID))-\(bucket)"
    }

    private static func safeItemID(_ itemID: String) -> String {
        itemID.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "-", options: .regularExpression)
    }

    private static func imageCost(_ image: NSImage) -> Int {
        Int(max(image.size.width, 1) * max(image.size.height, 1) * 4)
    }

    private static func isLikelyBlackFrame(_ image: CGImage) -> Bool {
        guard let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else {
            return false
        }
        let bytesPerPixel = max(image.bitsPerPixel / 8, 1)
        let sampleCount = min(600, image.width * image.height)
        guard sampleCount > 0 else { return false }

        var darkSamples = 0
        let dataLength = CFDataGetLength(data)
        for i in 0..<sampleCount {
            let x = (i * 37) % image.width
            let y = (i * 53) % image.height
            let offset = y * image.bytesPerRow + x * bytesPerPixel
            guard offset + min(bytesPerPixel - 1, 2) < dataLength else { continue }
            let r = Int(bytes[offset])
            let g = bytesPerPixel > 1 ? Int(bytes[offset + 1]) : r
            let b = bytesPerPixel > 2 ? Int(bytes[offset + 2]) : r
            if (r + g + b) / 3 < 14 {
                darkSamples += 1
            }
        }
        return Double(darkSamples) / Double(sampleCount) > 0.90
    }
}

private struct SendableVideoPreviewImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}
