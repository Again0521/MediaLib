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

    var totalRemoved: Int {
        missingManifestEntries + orphanManifestEntries + untrackedFiles
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

    func runMaintenance(validItemIDs: Set<String>) throws -> VideoCacheMaintenanceResult {
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
            if nextEntries != entries || missingManifestEntries > 0 || !orphanEntries.isEmpty || untrackedFiles > 0 {
                entries = nextEntries
                try saveLocked(entries)
            }

            return VideoCacheMaintenanceResult(
                missingManifestEntries: missingManifestEntries,
                orphanManifestEntries: orphanEntries.count,
                untrackedFiles: untrackedFiles
            )
        }
    }

    func entry(for itemID: String) -> VideoCacheEntry? {
        lock.withLock {
            guard let entry = entries[itemID], fileManager.fileExists(atPath: entry.localPath) else { return nil }
            return entry
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
            guard file.deletingPathExtension().lastPathComponent.hasPrefix(base),
                  Self.sidecarSubtitleExtensions.contains(file.pathExtension.lowercased()) else { continue }
            try? fileManager.removeItem(at: file)
        }
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
                keptSidecarBases.contains { base.hasPrefix($0) }
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
}

private extension NSLock {
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock()
        defer { unlock() }
        return try body()
    }
}
