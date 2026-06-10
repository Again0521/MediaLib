import Foundation
import MediaLibCore

struct VideoCacheEntry: Codable, Hashable, Sendable {
    let itemID: String
    let parentID: String?
    let title: String
    let localPath: String
    let qualityID: String
    let qualityLabel: String
    let resolution: String?
    let videoBitrate: Int64?
    let fileSize: Int64?
    let createdAt: Date
    let lastAccessedAt: Date?

    init(
        itemID: String,
        parentID: String?,
        title: String,
        localPath: String,
        qualityID: String,
        qualityLabel: String,
        resolution: String?,
        videoBitrate: Int64?,
        fileSize: Int64?,
        createdAt: Date,
        lastAccessedAt: Date? = nil
    ) {
        self.itemID = itemID
        self.parentID = parentID
        self.title = title
        self.localPath = localPath
        self.qualityID = qualityID
        self.qualityLabel = qualityLabel
        self.resolution = resolution
        self.videoBitrate = videoBitrate
        self.fileSize = fileSize
        self.createdAt = createdAt
        self.lastAccessedAt = lastAccessedAt
    }
}

enum VideoSeriesCacheState: Equatable, Sendable {
    case none
    case partial
    case complete
}

struct VideoCacheQualityChoice: Identifiable, Hashable, Sendable {
    let id: String
    let label: String
    let detail: String
}

struct VideoCacheMaintenanceResult: Equatable, Sendable {
    let missingManifestEntries: Int
    let orphanManifestEntries: Int
    let untrackedFiles: Int
    let overLimitEntries: Int
    let bytesBeforeCleanup: Int64
    let bytesAfterCleanup: Int64
    let byteLimit: Int64?

    var totalRemoved: Int {
        missingManifestEntries + orphanManifestEntries + untrackedFiles + overLimitEntries
    }
}

struct VideoCacheStorageSummary: Equatable, Sendable {
    let entryCount: Int
    let totalBytes: Int64
    let byteLimit: Int64?

    var isOverLimit: Bool {
        guard let byteLimit, byteLimit > 0 else { return false }
        return totalBytes > byteLimit
    }
}

struct VideoCacheCleanupHint: Sendable {
    let watchedItemIDs: Set<String>
    let recentlyPlayedItemIDs: Set<String>

    init(watchedItemIDs: Set<String> = [], recentlyPlayedItemIDs: Set<String> = []) {
        self.watchedItemIDs = watchedItemIDs
        self.recentlyPlayedItemIDs = recentlyPlayedItemIDs
    }
}

enum VideoOfflineCacheStoreError: LocalizedError {
    case unsupportedItem
    case invalidRemoteURL
    case invalidCacheDirectory
    case missingDownloadedFile

    var errorDescription: String? {
        switch self {
        case .unsupportedItem:
            return "这个条目不是可缓存的远程视频。"
        case .invalidRemoteURL:
            return "远程视频地址无效，无法缓存。"
        case .invalidCacheDirectory:
            return "无法使用这个缓存目录，请选择可访问的文件夹。"
        case .missingDownloadedFile:
            return "下载完成后没有找到缓存文件。"
        }
    }
}

final class VideoOfflineCacheStore: @unchecked Sendable {
    static let sidecarSubtitleExtensions = Set(["srt", "ass", "ssa", "vtt"])

    private let manifestURL: URL
    private let defaultCacheRootDirectory: URL
    private let fileManager: FileManager
    private let lock = NSLock()
    private var entries: [String: VideoCacheEntry] = [:]
    private var customCacheRootDirectory: URL?

    init(
        applicationSupportDirectory: URL,
        defaultCacheDirectory: URL,
        customCacheDirectoryPath: String?,
        fileManager: FileManager = .default
    ) throws {
        self.manifestURL = applicationSupportDirectory.appendingPathComponent("VideoCacheManifest.json")
        self.defaultCacheRootDirectory = defaultCacheDirectory
        self.fileManager = fileManager
        self.customCacheRootDirectory = Self.validCustomCacheRoot(from: customCacheDirectoryPath, fileManager: fileManager)
        try fileManager.createDirectory(at: self.cacheDirectory, withIntermediateDirectories: true)
        self.entries = try Self.readManifest(from: manifestURL, fileManager: fileManager)
        self.entries = pruneMissingFilesLocked(self.entries)
        try saveLocked(self.entries)
    }

    func allEntries() -> [String: VideoCacheEntry] {
        lock.withLock { entries }
    }

    func refreshEntriesPruningMissingFiles() throws -> [String: VideoCacheEntry] {
        try lock.withLock {
            let pruned = pruneMissingFilesLocked(entries)
            if pruned.count != entries.count {
                entries = pruned
                try saveLocked(entries)
            }
            return entries
        }
    }

    func storageSummary(byteLimit: Int64?) -> VideoCacheStorageSummary {
        lock.withLock {
            VideoCacheStorageSummary(
                entryCount: entries.count,
                totalBytes: estimatedTotalBytesLocked(for: entries),
                byteLimit: Self.normalizedByteLimit(byteLimit)
            )
        }
    }

    func runMaintenance(
        validItemIDs: Set<String>,
        byteLimit: Int64?,
        cleanupHint: VideoCacheCleanupHint = VideoCacheCleanupHint()
    ) throws -> VideoCacheMaintenanceResult {
        try lock.withLock {
            let originalCount = entries.count
            var nextEntries = pruneMissingFilesLocked(entries)
            let missingManifestEntries = originalCount - nextEntries.count

            let orphanEntries = nextEntries.values.filter { !validItemIDs.contains($0.itemID) }
            for entry in orphanEntries {
                try removeCachedFilesLocked(for: entry)
                nextEntries.removeValue(forKey: entry.itemID)
            }

            let untrackedFiles = pruneUntrackedCacheFilesLocked(keeping: nextEntries)
            let byteLimit = Self.normalizedByteLimit(byteLimit)
            let bytesBeforeCleanup = totalTrackedBytesLocked(for: nextEntries)
            let overLimitEntries = pruneOverLimitEntriesLocked(
                entries: &nextEntries,
                byteLimit: byteLimit,
                cleanupHint: cleanupHint
            )
            let bytesAfterCleanup = totalTrackedBytesLocked(for: nextEntries)

            if nextEntries != entries ||
                missingManifestEntries > 0 ||
                !orphanEntries.isEmpty ||
                untrackedFiles > 0 ||
                overLimitEntries > 0 {
                entries = nextEntries
                try saveLocked(entries)
            }

            return VideoCacheMaintenanceResult(
                missingManifestEntries: missingManifestEntries,
                orphanManifestEntries: orphanEntries.count,
                untrackedFiles: untrackedFiles,
                overLimitEntries: overLimitEntries,
                bytesBeforeCleanup: bytesBeforeCleanup,
                bytesAfterCleanup: bytesAfterCleanup,
                byteLimit: byteLimit
            )
        }
    }

    func entry(for itemID: String) -> VideoCacheEntry? {
        lock.withLock {
            guard let entry = entries[itemID], fileManager.fileExists(atPath: entry.localPath) else { return nil }
            return entry
        }
    }

    func markAccessed(itemID: String, at date: Date = Date()) throws {
        try lock.withLock {
            guard var entry = entries[itemID],
                  fileManager.fileExists(atPath: entry.localPath) else { return }
            entry = VideoCacheEntry(
                itemID: entry.itemID,
                parentID: entry.parentID,
                title: entry.title,
                localPath: entry.localPath,
                qualityID: entry.qualityID,
                qualityLabel: entry.qualityLabel,
                resolution: entry.resolution,
                videoBitrate: entry.videoBitrate,
                fileSize: entry.fileSize,
                createdAt: entry.createdAt,
                lastAccessedAt: date
            )
            entries[itemID] = entry
            try saveLocked(entries)
        }
    }

    func upsert(_ entry: VideoCacheEntry) throws {
        try lock.withLock {
            entries[entry.itemID] = entry
            try saveLocked(entries)
        }
    }

    func setCustomCacheDirectoryPath(_ path: String?) throws {
        try lock.withLock {
            if path?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty != false {
                customCacheRootDirectory = nil
            } else if let root = Self.validCustomCacheRoot(from: path, fileManager: fileManager) {
                customCacheRootDirectory = root
            } else {
                throw VideoOfflineCacheStoreError.invalidCacheDirectory
            }
            try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
        }
    }

    var currentCacheDirectory: URL {
        lock.withLock { cacheDirectory }
    }

    func remove(itemIDs: Set<String>) throws -> [VideoCacheEntry] {
        guard !itemIDs.isEmpty else { return [] }
        return try lock.withLock {
            let removed = itemIDs.compactMap { entries[$0] }
            guard !removed.isEmpty else { return [] }
            for entry in removed {
                try removeCachedFilesLocked(for: entry)
            }
            for entry in removed {
                entries.removeValue(forKey: entry.itemID)
            }
            try saveLocked(entries)
            return removed
        }
    }

    func remove(_ itemID: String) throws -> VideoCacheEntry? {
        try remove(itemIDs: [itemID]).first
    }

    func destinationURL(for item: MediaItem, qualityID: String, remoteURL: URL, isTranscode: Bool) -> URL {
        let extensionHint: String
        if isTranscode {
            extensionHint = "mp4"
        } else {
            let pathExtension = remoteURL.pathExtension.trimmingCharacters(in: .whitespacesAndNewlines)
            extensionHint = pathExtension.isEmpty ? "mp4" : pathExtension
        }
        let filename = "\(safeComponent(item.id))-\(safeComponent(qualityID)).\(extensionHint)"
        return lock.withLock {
            cacheDirectory.appendingPathComponent(filename, isDirectory: false)
        }
    }

    func sidecarSubtitleURL(
        forVideoAt videoURL: URL,
        language: String?,
        streamIndex: Int,
        fileExtension: String
    ) -> URL {
        let cleanedExtension = Self.normalizedSubtitleExtension(fileExtension) ?? "srt"
        let languageComponent = language
            .map(safeComponent)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "subtitle"
        let base = videoURL.deletingPathExtension().lastPathComponent
        return videoURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base).\(languageComponent).\(streamIndex).\(cleanedExtension)", isDirectory: false)
    }

    static func itemWithCache(_ item: MediaItem, entry: VideoCacheEntry) -> MediaItem {
        var cached = item
        cached.filePath = entry.localPath
        cached.fileSize = entry.fileSize ?? item.fileSize
        cached.resolution = entry.resolution ?? item.resolution
        cached.videoBitrate = entry.videoBitrate ?? item.videoBitrate
        return cached
    }

    private static func readManifest(from url: URL, fileManager: FileManager) throws -> [String: VideoCacheEntry] {
        guard fileManager.fileExists(atPath: url.path) else { return [:] }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode([String: VideoCacheEntry].self, from: data)
    }

    private func pruneMissingFilesLocked(_ input: [String: VideoCacheEntry]) -> [String: VideoCacheEntry] {
        input.filter { _, entry in
            fileManager.fileExists(atPath: entry.localPath)
        }
    }

    private var cacheDirectory: URL {
        (customCacheRootDirectory ?? defaultCacheRootDirectory).appendingPathComponent("VideoCache", isDirectory: true)
    }

    private func saveLocked(_ entries: [String: VideoCacheEntry]) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(entries)
        try data.write(to: manifestURL, options: [.atomic])
    }

    private func removeCachedFilesLocked(for entry: VideoCacheEntry) throws {
        let url = URL(fileURLWithPath: entry.localPath)
        let directory = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        if fileManager.fileExists(atPath: url.path) {
            try fileManager.removeItem(at: url)
        }
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return }
        for file in files {
            guard Self.isSidecarBase(file.deletingPathExtension().lastPathComponent, forVideoBase: base),
                  Self.sidecarSubtitleExtensions.contains(file.pathExtension.lowercased()) else { continue }
            try? fileManager.removeItem(at: file)
        }
    }

    private func pruneOverLimitEntriesLocked(
        entries: inout [String: VideoCacheEntry],
        byteLimit: Int64?,
        cleanupHint: VideoCacheCleanupHint
    ) -> Int {
        guard let byteLimit, byteLimit > 0 else { return 0 }
        var totalBytes = totalTrackedBytesLocked(for: entries)
        guard totalBytes > byteLimit else { return 0 }

        let candidates = entries.values.sorted { lhs, rhs in
            let lhsScore = cleanupScore(for: lhs, hint: cleanupHint)
            let rhsScore = cleanupScore(for: rhs, hint: cleanupHint)
            if lhsScore != rhsScore { return lhsScore > rhsScore }
            return cacheRecencyDate(lhs) < cacheRecencyDate(rhs)
        }

        var removed = 0
        for entry in candidates where totalBytes > byteLimit {
            let bytes = trackedBytesLocked(for: entry)
            do {
                try removeCachedFilesLocked(for: entry)
                entries.removeValue(forKey: entry.itemID)
                totalBytes = max(totalBytes - bytes, 0)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    private func cleanupScore(for entry: VideoCacheEntry, hint: VideoCacheCleanupHint) -> Int {
        if hint.watchedItemIDs.contains(entry.itemID), !hint.recentlyPlayedItemIDs.contains(entry.itemID) { return 3 }
        if !hint.recentlyPlayedItemIDs.contains(entry.itemID) { return 2 }
        if hint.watchedItemIDs.contains(entry.itemID) { return 1 }
        return 0
    }

    private func cacheRecencyDate(_ entry: VideoCacheEntry) -> Date {
        entry.lastAccessedAt ?? entry.createdAt
    }

    private func totalTrackedBytesLocked(for entries: [String: VideoCacheEntry]) -> Int64 {
        entries.values.reduce(Int64(0)) { partial, entry in
            partial + trackedBytesLocked(for: entry)
        }
    }

    private func estimatedTotalBytesLocked(for entries: [String: VideoCacheEntry]) -> Int64 {
        // 设置页只需要轻量趋势值，避免滚动或播放缓存时同步枚举大量字幕旁路文件。
        // 真正删除前的容量回收仍通过 totalTrackedBytesLocked 做一次完整核算。
        entries.values.reduce(Int64(0)) { partial, entry in
            partial + max(entry.fileSize ?? fileSize(at: URL(fileURLWithPath: entry.localPath)) ?? 0, 0)
        }
    }

    private func trackedBytesLocked(for entry: VideoCacheEntry) -> Int64 {
        let videoURL = URL(fileURLWithPath: entry.localPath)
        var total = fileSize(at: videoURL) ?? entry.fileSize ?? 0
        let directory = videoURL.deletingLastPathComponent()
        let base = videoURL.deletingPathExtension().lastPathComponent
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else { return max(total, 0) }
        for file in files {
            guard Self.sidecarSubtitleExtensions.contains(file.pathExtension.lowercased()),
                  Self.isSidecarBase(file.deletingPathExtension().lastPathComponent, forVideoBase: base) else { continue }
            total += fileSize(at: file) ?? 0
        }
        return max(total, 0)
    }

    private func fileSize(at url: URL) -> Int64? {
        if let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
           let fileSize = values.fileSize {
            return Int64(fileSize)
        }
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return attributes?[.size] as? Int64
    }

    private func pruneUntrackedCacheFilesLocked(keeping entries: [String: VideoCacheEntry]) -> Int {
        let directory = cacheDirectory
        guard let files = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }

        let entryURLs = entries.values.map { URL(fileURLWithPath: $0.localPath) }
        let keptVideoPaths = Set(entryURLs.map(\.path))
        let keptSidecarBases = Set(entryURLs.map { $0.deletingPathExtension().lastPathComponent })
        var removed = 0

        for file in files {
            guard (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else { continue }
            if keptVideoPaths.contains(file.path) { continue }
            let base = file.deletingPathExtension().lastPathComponent
            let isTrackedSidecar = Self.sidecarSubtitleExtensions.contains(file.pathExtension.lowercased()) &&
                keptSidecarBases.contains { Self.isSidecarBase(base, forVideoBase: $0) }
            if isTrackedSidecar { continue }
            do {
                try fileManager.removeItem(at: file)
                removed += 1
            } catch {
                continue
            }
        }
        return removed
    }

    private static func isSidecarBase(_ candidateBase: String, forVideoBase videoBase: String) -> Bool {
        // Subtitle sidecars are written as "<video-base>.<language>.<stream>.<ext>".
        // Requiring the dot boundary prevents deleting "abcde.zh.srt" when the cached video is "abc.mp4".
        candidateBase == videoBase || candidateBase.hasPrefix("\(videoBase).")
    }

    private func safeComponent(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = raw.unicodeScalars.map { scalar -> Character in
            allowed.contains(scalar) ? Character(scalar) : "-"
        }
        let collapsed = String(scalars)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return collapsed.isEmpty ? UUID().uuidString : collapsed
    }

    private static func validCustomCacheRoot(from path: String?, fileManager: FileManager) -> URL? {
        guard let path = path?.trimmingCharacters(in: .whitespacesAndNewlines),
              !path.isEmpty else { return nil }
        let url = URL(fileURLWithPath: path, isDirectory: true)
        var isDirectory: ObjCBool = false
        if fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            return isDirectory.boolValue ? url : nil
        }
        do {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        } catch {
            return nil
        }
    }

    private static func normalizedSubtitleExtension(_ value: String) -> String? {
        let normalized = value
            .trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
            .lowercased()
        if normalized == "subrip" {
            return "srt"
        }
        if normalized == "webvtt" {
            return "vtt"
        }
        return sidecarSubtitleExtensions.contains(normalized) ? normalized : nil
    }

    private static func normalizedByteLimit(_ value: Int64?) -> Int64? {
        guard let value, value > 0 else { return nil }
        return value
    }
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
