import AppKit
import AVFoundation
import CoreLocation
import Photos
import SwiftUI

struct SystemPhotoAsset: Identifiable, Equatable, Sendable {
    let id: String
    let isVideo: Bool
    let creationDate: Date
    let duration: Double
    let pixelWidth: Int
    let pixelHeight: Int
    let isFavorite: Bool
    let mediaSubtypesRawValue: UInt
    let originalFilename: String?
    let locationName: String?

    var displayTitle: String {
        originalFilename?.isEmpty == false
            ? originalFilename!
            : SystemPhotoAsset.titleFormatter.string(from: creationDate)
    }

    var mediaSubtypeLabel: String? {
        let subtypes = PHAssetMediaSubtype(rawValue: mediaSubtypesRawValue)
        if subtypes.contains(.photoLive) { return "实况照片" }
        if subtypes.contains(.photoPanorama) { return "全景照片" }
        if subtypes.contains(.photoScreenshot) { return "屏幕快照" }
        if subtypes.contains(.videoHighFrameRate) { return "慢动作视频" }
        if subtypes.contains(.videoTimelapse) { return "延时视频" }
        return isVideo ? "录像" : "照片"
    }

    private static let titleFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy年M月d日 HH:mm"
        return formatter
    }()
}

struct SystemPhotoCollection: Identifiable, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case all
        case recent
        case favorites
        case videos
        case userAlbum(String)
    }

    let id: String
    let title: String
    let systemImage: String
    let kind: Kind

    static let builtIns: [SystemPhotoCollection] = [
        .init(id: "all", title: "所有照片", systemImage: "photo.on.rectangle.angled", kind: .all),
        .init(id: "recent", title: "最近项目", systemImage: "clock", kind: .recent),
        .init(id: "favorites", title: "个人收藏", systemImage: "heart", kind: .favorites),
        .init(id: "videos", title: "视频", systemImage: "video", kind: .videos)
    ]
}

struct SystemPhotoLibrarySnapshot: Sendable {
    let collections: [SystemPhotoCollection]
    let assets: [SystemPhotoAsset]
}

struct SystemPhotoDateGroup: Identifiable, Sendable {
    let id: String
    let title: String
    let assets: [SystemPhotoAsset]
}

@MainActor
protocol SystemPhotoLibraryClient: AnyObject {
    var imageManager: PHCachingImageManager { get }
    func authorizationStatus() -> PHAuthorizationStatus
    func requestAuthorization() async -> PHAuthorizationStatus
    func loadSnapshot(collectionID: String) async throws -> SystemPhotoLibrarySnapshot
    func asset(withID id: String) -> PHAsset?
    func originalFilename(assetID: String) -> String?
    func setFavorite(assetIDs: [String], favorite: Bool) async throws
    func delete(assetIDs: [String]) async throws
    func export(assetIDs: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> [URL]
    func cleanupExportDirectory()
}

@MainActor
final class DefaultSystemPhotoLibraryClient: SystemPhotoLibraryClient {
    let imageManager = PHCachingImageManager()
    private var assetsByID: [String: PHAsset] = [:]

    func authorizationStatus() -> PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .readWrite)
    }

    func requestAuthorization() async -> PHAuthorizationStatus {
        await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    }

    func loadSnapshot(collectionID: String) async throws -> SystemPhotoLibrarySnapshot {
        let collections = Self.loadCollections()
        let selected = collections.first(where: { $0.id == collectionID }) ?? SystemPhotoCollection.builtIns[0]
        let result = Self.fetchAssets(for: selected)
        var nextAssets: [SystemPhotoAsset] = []
        var nextLookup: [String: PHAsset] = [:]
        nextAssets.reserveCapacity(result.count)
        nextLookup.reserveCapacity(result.count)

        result.enumerateObjects { asset, _, _ in
            guard asset.mediaType == .image || asset.mediaType == .video else { return }
            nextLookup[asset.localIdentifier] = asset
            nextAssets.append(SystemPhotoAsset(
                id: asset.localIdentifier,
                isVideo: asset.mediaType == .video,
                creationDate: asset.creationDate ?? .distantPast,
                duration: asset.duration,
                pixelWidth: asset.pixelWidth,
                pixelHeight: asset.pixelHeight,
                isFavorite: asset.isFavorite,
                mediaSubtypesRawValue: asset.mediaSubtypes.rawValue,
                originalFilename: nil,
                locationName: Self.locationName(asset.location)
            ))
        }

        assetsByID = nextLookup
        return SystemPhotoLibrarySnapshot(collections: collections, assets: nextAssets)
    }

    func asset(withID id: String) -> PHAsset? {
        if let cached = assetsByID[id] { return cached }
        return PHAsset.fetchAssets(withLocalIdentifiers: [id], options: nil).firstObject
    }

    func originalFilename(assetID: String) -> String? {
        guard let asset = asset(withID: assetID) else { return nil }
        return PHAssetResource.assetResources(for: asset).first?.originalFilename
    }

    func setFavorite(assetIDs: [String], favorite: Bool) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            assets.enumerateObjects { asset, _, _ in
                PHAssetChangeRequest(for: asset).isFavorite = favorite
            }
        }
    }

    func delete(assetIDs: [String]) async throws {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        try await PHPhotoLibrary.shared().performChanges {
            PHAssetChangeRequest.deleteAssets(assets)
        }
    }

    func export(assetIDs: [String], progress: @escaping @Sendable (Double) -> Void) async throws -> [URL] {
        cleanupExportDirectory()
        let directory = Self.exportDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let assets = PHAsset.fetchAssets(withLocalIdentifiers: assetIDs, options: nil)
        var exported: [URL] = []
        exported.reserveCapacity(assets.count)
        var completed = 0

        for index in 0..<assets.count {
            let asset = assets.object(at: index)
            guard let resource = Self.preferredResource(for: asset) else { continue }
            let safeName = Self.safeFilename(resource.originalFilename, fallbackIndex: index)
            let target = Self.uniqueURL(in: directory, filename: safeName)
            let options = PHAssetResourceRequestOptions()
            options.isNetworkAccessAllowed = true
            options.progressHandler = { value in
                progress((Double(completed) + value) / Double(max(assets.count, 1)))
            }
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().writeData(for: resource, toFile: target, options: options) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
            completed += 1
            progress(Double(completed) / Double(max(assets.count, 1)))
            exported.append(target)
        }
        return exported
    }

    func cleanupExportDirectory() {
        try? FileManager.default.removeItem(at: Self.exportDirectory)
    }

    private static func loadCollections() -> [SystemPhotoCollection] {
        var result = SystemPhotoCollection.builtIns
        let albums = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: nil)
        albums.enumerateObjects { collection, _, _ in
            guard let title = collection.localizedTitle, !title.isEmpty else { return }
            result.append(SystemPhotoCollection(
                id: "album:\(collection.localIdentifier)",
                title: title,
                systemImage: "rectangle.stack",
                kind: .userAlbum(collection.localIdentifier)
            ))
        }
        return result
    }

    private static func fetchAssets(for collection: SystemPhotoCollection) -> PHFetchResult<PHAsset> {
        let options = PHFetchOptions()
        options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
        switch collection.kind {
        case .all:
            return PHAsset.fetchAssets(with: options)
        case .recent:
            if let recent = PHAssetCollection.fetchAssetCollections(
                with: .smartAlbum,
                subtype: .smartAlbumRecentlyAdded,
                options: nil
            ).firstObject {
                return PHAsset.fetchAssets(in: recent, options: options)
            }
            return PHAsset.fetchAssets(with: options)
        case .favorites:
            options.predicate = NSPredicate(format: "favorite == YES")
            return PHAsset.fetchAssets(with: options)
        case .videos:
            options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.video.rawValue)
            return PHAsset.fetchAssets(with: options)
        case .userAlbum(let id):
            guard let album = PHAssetCollection.fetchAssetCollections(
                withLocalIdentifiers: [id],
                options: nil
            ).firstObject else {
                return PHAsset.fetchAssets(withLocalIdentifiers: [], options: nil)
            }
            return PHAsset.fetchAssets(in: album, options: options)
        }
    }

    private static func locationName(_ location: CLLocation?) -> String? {
        guard let coordinate = location?.coordinate else { return nil }
        return String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude)
    }

    private static func preferredResource(for asset: PHAsset) -> PHAssetResource? {
        let resources = PHAssetResource.assetResources(for: asset)
        if asset.mediaType == .video {
            return resources.first(where: { $0.type == .fullSizeVideo || $0.type == .video })
                ?? resources.first
        }
        return resources.first(where: { $0.type == .fullSizePhoto || $0.type == .photo })
            ?? resources.first
    }

    private static func safeFilename(_ name: String, fallbackIndex: Int) -> String {
        let sanitized = name.replacingOccurrences(of: "/", with: "-")
        return sanitized.isEmpty ? "MediaLIB-\(fallbackIndex + 1)" : sanitized
    }

    private static func uniqueURL(in directory: URL, filename: String) -> URL {
        let original = directory.appendingPathComponent(filename)
        guard FileManager.default.fileExists(atPath: original.path) else { return original }
        let stem = original.deletingPathExtension().lastPathComponent
        let ext = original.pathExtension
        for suffix in 2...999 {
            let candidateName = ext.isEmpty ? "\(stem)-\(suffix)" : "\(stem)-\(suffix).\(ext)"
            let candidate = directory.appendingPathComponent(candidateName)
            if !FileManager.default.fileExists(atPath: candidate.path) { return candidate }
        }
        return directory.appendingPathComponent("\(UUID().uuidString)-\(filename)")
    }

    private static var exportDirectory: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-SystemPhotoShare", isDirectory: true)
    }
}

enum SystemPhotoResourcePhase: Equatable {
    case placeholder
    case loading(Double?)
    case ready(NSImage, degraded: Bool)
    case failed(String)

    static func == (lhs: SystemPhotoResourcePhase, rhs: SystemPhotoResourcePhase) -> Bool {
        switch (lhs, rhs) {
        case (.placeholder, .placeholder): return true
        case (.loading(let lhsValue), .loading(let rhsValue)): return lhsValue == rhsValue
        case (.ready(let lhsImage, let lhsDegraded), .ready(let rhsImage, let rhsDegraded)):
            return lhsImage === rhsImage && lhsDegraded == rhsDegraded
        case (.failed(let lhsMessage), .failed(let rhsMessage)): return lhsMessage == rhsMessage
        default: return false
        }
    }
}

private final class SystemPhotoVideoRequestBox: @unchecked Sendable {
    var requestID: PHImageRequestID = PHInvalidImageRequestID
    var resumed = false
}

@MainActor
final class SystemPhotoLibraryStore: NSObject, ObservableObject, PHPhotoLibraryChangeObserver {
    @Published private(set) var authorizationStatus: PHAuthorizationStatus
    @Published private(set) var collections = SystemPhotoCollection.builtIns
    @Published private(set) var assets: [SystemPhotoAsset] = [] {
        didSet { timelineCache.removeAll(keepingCapacity: true) }
    }
    @Published private(set) var isLoading = false
    @Published private(set) var isManaging = false
    @Published private(set) var transferProgress: Double?
    @Published var errorMessage: String?

    let client: SystemPhotoLibraryClient
    private var selectedCollectionID = "all"
    private var reloadTask: Task<Void, Never>?
    private var assetsByID: [String: SystemPhotoAsset] = [:]
    private var imageCache = NSCache<NSString, NSImage>()
    private struct PendingImageRequest {
        var requestID: PHImageRequestID
        var callbacks: [UUID: @MainActor (SystemPhotoResourcePhase) -> Void]
    }
    private var pendingImageRequests: [String: PendingImageRequest] = [:]
    private var imageRequestKeysByToken: [UUID: String] = [:]
    private var activeCacheAssets: [PHAsset] = []
    private var activeCacheSize = CGSize.zero
    private var timelineCache: [String: [SystemPhotoDateGroup]] = [:]

    override convenience init() {
        self.init(client: DefaultSystemPhotoLibraryClient())
    }

    init(client: SystemPhotoLibraryClient) {
        self.client = client
        self.authorizationStatus = client.authorizationStatus()
        super.init()
        imageCache.totalCostLimit = 192 * 1024 * 1024
        client.cleanupExportDirectory()
        PHPhotoLibrary.shared().register(self)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(applicationDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification,
            object: nil
        )
    }

    deinit {
        PHPhotoLibrary.shared().unregisterChangeObserver(self)
        NotificationCenter.default.removeObserver(self)
    }

    var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .limited
    }

    var selectedCollection: SystemPhotoCollection {
        collections.first(where: { $0.id == selectedCollectionID }) ?? SystemPhotoCollection.builtIns[0]
    }

    func activate(collectionID: String) async {
        selectedCollectionID = collectionID
        authorizationStatus = client.authorizationStatus()
        guard isAuthorized else { return }
        await reload()
    }

    func requestAccessAndLoad(collectionID: String) async {
        selectedCollectionID = collectionID
        authorizationStatus = await client.requestAuthorization()
        guard isAuthorized else { return }
        await reload()
    }

    func refreshAuthorizationAndReload() async {
        let next = client.authorizationStatus()
        let changed = next != authorizationStatus
        authorizationStatus = next
        if isAuthorized, changed || assets.isEmpty {
            await reload()
        } else if !isAuthorized {
            assets = []
            assetsByID = [:]
        }
    }

    func reload() async {
        reloadTask?.cancel()
        isLoading = true
        defer { isLoading = false }
        do {
            let snapshot = try await client.loadSnapshot(collectionID: selectedCollectionID)
            guard !Task.isCancelled else { return }
            collections = snapshot.collections
            if !collections.contains(where: { $0.id == selectedCollectionID }) {
                selectedCollectionID = "all"
                let fallback = try await client.loadSnapshot(collectionID: "all")
                collections = fallback.collections
                assets = fallback.assets
            } else {
                assets = snapshot.assets
            }
            assetsByID = Dictionary(uniqueKeysWithValues: assets.map { ($0.id, $0) })
        } catch {
            errorMessage = "读取系统照片失败：\(error.localizedDescription)"
        }
    }

    func asset(id: String) -> SystemPhotoAsset? {
        assetsByID[id]
    }

    func enrichResourceMetadata(assetID: String) {
        guard let current = assetsByID[assetID],
              current.originalFilename == nil,
              let filename = client.originalFilename(assetID: assetID) else { return }
        let enriched = SystemPhotoAsset(
            id: current.id,
            isVideo: current.isVideo,
            creationDate: current.creationDate,
            duration: current.duration,
            pixelWidth: current.pixelWidth,
            pixelHeight: current.pixelHeight,
            isFavorite: current.isFavorite,
            mediaSubtypesRawValue: current.mediaSubtypesRawValue,
            originalFilename: filename,
            locationName: current.locationName
        )
        assetsByID[assetID] = enriched
        if let index = assets.firstIndex(where: { $0.id == assetID }) {
            assets[index] = enriched
        }
    }

    func assets(for section: AlbumLibrarySection, sortOrder: AlbumSortOrder) -> [SystemPhotoAsset] {
        let filtered: [SystemPhotoAsset]
        switch section {
        case .all: filtered = assets
        case .photos: filtered = assets.filter { !$0.isVideo }
        case .videos: filtered = assets.filter(\.isVideo)
        }
        return sortOrder == .newest ? filtered : Array(filtered.reversed())
    }

    func timelineGroups(
        for section: AlbumLibrarySection,
        sortOrder: AlbumSortOrder
    ) -> [SystemPhotoDateGroup] {
        let key = "\(section.rawValue)|\(sortOrder.rawValue)"
        if let cached = timelineCache[key] { return cached }
        let source = assets(for: section, sortOrder: sortOrder)
        let calendar = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [SystemPhotoAsset]] = [:]
        for asset in source {
            let day = calendar.startOfDay(for: asset.creationDate)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(asset)
        }
        let groups = order.map { day in
            SystemPhotoDateGroup(
                id: "\(day.timeIntervalSince1970)",
                title: Self.dayTitle(day, calendar: calendar),
                assets: buckets[day] ?? []
            )
        }
        timelineCache[key] = groups
        return groups
    }

    func setFavorite(assetIDs: [String], favorite: Bool) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        isManaging = true
        defer { isManaging = false }
        do {
            try await client.setFavorite(assetIDs: assetIDs, favorite: favorite)
            await reload()
            return true
        } catch {
            errorMessage = "更新个人收藏失败：\(error.localizedDescription)"
            return false
        }
    }

    func delete(assetIDs: [String]) async -> Bool {
        guard !assetIDs.isEmpty else { return false }
        isManaging = true
        defer { isManaging = false }
        do {
            try await client.delete(assetIDs: assetIDs)
            await reload()
            return true
        } catch {
            errorMessage = "删除系统照片失败：\(error.localizedDescription)"
            return false
        }
    }

    func export(assetIDs: [String]) async -> [URL] {
        guard !assetIDs.isEmpty else { return [] }
        isManaging = true
        transferProgress = 0
        defer {
            isManaging = false
            transferProgress = nil
        }
        do {
            return try await client.export(assetIDs: assetIDs) { [weak self] progress in
                Task { @MainActor in self?.transferProgress = progress }
            }
        } catch {
            errorMessage = "准备分享内容失败：\(error.localizedDescription)"
            return []
        }
    }

    @discardableResult
    func requestImage(
        assetID: String,
        targetSize: CGSize,
        contentMode: PHImageContentMode,
        completion: @escaping @MainActor (SystemPhotoResourcePhase) -> Void
    ) -> UUID? {
        let cacheKey = "\(assetID)|\(Int(targetSize.width))x\(Int(targetSize.height))|\(contentMode.rawValue)" as NSString
        if let cached = imageCache.object(forKey: cacheKey) {
            completion(.ready(cached, degraded: false))
            return nil
        }
        let stringKey = cacheKey as String
        let token = UUID()
        if var pending = pendingImageRequests[stringKey] {
            pending.callbacks[token] = completion
            pendingImageRequests[stringKey] = pending
            imageRequestKeysByToken[token] = stringKey
            completion(.loading(nil))
            return token
        }
        guard let asset = client.asset(withID: assetID) else {
            completion(.failed("照片已不可用"))
            return nil
        }

        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .opportunistic
        options.resizeMode = .fast
        options.progressHandler = { [weak self] progress, error, _, _ in
            Task { @MainActor in
                guard let self else { return }
                if let error {
                    self.finishImageRequest(
                        key: stringKey,
                        phase: .failed(error.localizedDescription)
                    )
                } else {
                    self.publishImagePhase(
                        key: stringKey,
                        phase: .loading(progress),
                        completesRequest: false
                    )
                }
            }
        }
        completion(.loading(nil))
        pendingImageRequests[stringKey] = PendingImageRequest(
            requestID: PHInvalidImageRequestID,
            callbacks: [token: completion]
        )
        imageRequestKeysByToken[token] = stringKey
        let requestID = client.imageManager.requestImage(
            for: asset,
            targetSize: targetSize,
            contentMode: contentMode,
            options: options
        ) { [weak self] image, info in
            Task { @MainActor in
                guard let self else { return }
                if (info?[PHImageCancelledKey] as? Bool) == true { return }
                if let error = info?[PHImageErrorKey] as? Error {
                    self.finishImageRequest(
                        key: stringKey,
                        phase: .failed(error.localizedDescription)
                    )
                    return
                }
                guard let image else { return }
                let degraded = (info?[PHImageResultIsDegradedKey] as? Bool) == true
                if !degraded {
                    self.imageCache.setObject(image, forKey: cacheKey, cost: Self.imageCost(image))
                }
                self.publishImagePhase(
                    key: stringKey,
                    phase: .ready(image, degraded: degraded),
                    completesRequest: !degraded
                )
            }
        }
        if var pending = pendingImageRequests[stringKey] {
            pending.requestID = requestID
            pendingImageRequests[stringKey] = pending
        }
        return token
    }

    func cancelImageRequest(_ token: UUID?) {
        guard let token,
              let key = imageRequestKeysByToken.removeValue(forKey: token),
              var pending = pendingImageRequests[key] else { return }
        pending.callbacks[token] = nil
        if pending.callbacks.isEmpty {
            client.imageManager.cancelImageRequest(pending.requestID)
            pendingImageRequests[key] = nil
        } else {
            pendingImageRequests[key] = pending
        }
    }

    func preheat(assetIDs: [String], targetSize: CGSize, contentMode: PHImageContentMode) {
        let nextAssets = assetIDs.compactMap(client.asset(withID:))
        if !activeCacheAssets.isEmpty {
            client.imageManager.stopCachingImages(
                for: activeCacheAssets,
                targetSize: activeCacheSize,
                contentMode: contentMode,
                options: nil
            )
        }
        activeCacheAssets = nextAssets
        activeCacheSize = targetSize
        guard !nextAssets.isEmpty else { return }
        client.imageManager.startCachingImages(
            for: nextAssets,
            targetSize: targetSize,
            contentMode: contentMode,
            options: nil
        )
    }

    func stopPreheating(contentMode: PHImageContentMode = .aspectFill) {
        guard !activeCacheAssets.isEmpty else { return }
        client.imageManager.stopCachingImages(
            for: activeCacheAssets,
            targetSize: activeCacheSize,
            contentMode: contentMode,
            options: nil
        )
        activeCacheAssets = []
    }

    func requestPlayerItem(
        assetID: String,
        progress: @escaping @MainActor (Double?) -> Void
    ) async throws -> AVPlayerItem {
        guard let asset = client.asset(withID: assetID) else {
            throw NSError(domain: "MediaLIB.SystemPhotos", code: 404, userInfo: [
                NSLocalizedDescriptionKey: "录像已不可用"
            ])
        }
        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = true
        options.deliveryMode = .automatic
        options.progressHandler = { value, error, _, _ in
            Task { @MainActor in
                if error == nil { progress(value) }
            }
        }
        progress(nil)
        let manager = client.imageManager
        let box = SystemPhotoVideoRequestBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                box.requestID = manager.requestPlayerItem(forVideo: asset, options: options) { item, info in
                    guard !box.resumed else { return }
                    box.resumed = true
                    if (info?[PHImageCancelledKey] as? Bool) == true {
                        continuation.resume(throwing: CancellationError())
                    } else if let error = info?[PHImageErrorKey] as? Error {
                        continuation.resume(throwing: error)
                    } else if let item {
                        continuation.resume(returning: item)
                    } else {
                        continuation.resume(throwing: NSError(
                            domain: "MediaLIB.SystemPhotos",
                            code: 500,
                            userInfo: [NSLocalizedDescriptionKey: "无法读取录像"]
                        ))
                    }
                }
            }
        } onCancel: {
            manager.cancelImageRequest(box.requestID)
        }
    }

    func fullResolutionImage(assetID: String, targetSize: CGSize) async -> NSImage? {
        await withCheckedContinuation { continuation in
            var resumed = false
            _ = requestImage(
                assetID: assetID,
                targetSize: targetSize,
                contentMode: .aspectFit
            ) { phase in
                switch phase {
                case .ready(let image, let degraded) where !degraded:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: image)
                case .failed:
                    guard !resumed else { return }
                    resumed = true
                    continuation.resume(returning: nil)
                default:
                    break
                }
            }
        }
    }

    nonisolated func photoLibraryDidChange(_ changeInstance: PHChange) {
        Task { @MainActor [weak self] in
            guard let self, self.isAuthorized else { return }
            await self.reload()
        }
    }

    @objc private func applicationDidBecomeActive() {
        Task { await refreshAuthorizationAndReload() }
    }

    private static func imageCost(_ image: NSImage) -> Int {
        let pixels = max(image.size.width * image.size.height, 1)
        return Int(min(pixels * 4, CGFloat(Int.max)))
    }

    private func publishImagePhase(
        key: String,
        phase: SystemPhotoResourcePhase,
        completesRequest: Bool
    ) {
        guard let pending = pendingImageRequests[key] else { return }
        for callback in pending.callbacks.values {
            callback(phase)
        }
        if completesRequest {
            for token in pending.callbacks.keys {
                imageRequestKeysByToken[token] = nil
            }
            pendingImageRequests[key] = nil
        }
    }

    private func finishImageRequest(key: String, phase: SystemPhotoResourcePhase) {
        publishImagePhase(key: key, phase: phase, completesRequest: true)
    }

    private static func dayTitle(_ day: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(day) { return "今天" }
        if calendar.isDateInYesterday(day) { return "昨天" }
        let formatter = DateFormatter()
        formatter.dateFormat = calendar.isDate(day, equalTo: Date(), toGranularity: .year)
            ? "M月d日"
            : "yyyy年M月d日"
        return formatter.string(from: day)
    }
}
