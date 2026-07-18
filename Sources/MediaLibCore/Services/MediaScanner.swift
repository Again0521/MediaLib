import Foundation
#if os(macOS)
import ImageIO
#endif

public struct ScanProgress: Equatable {
    public var sourceID: String
    public var status: String
    public var totalFiles: Int
    public var processedFiles: Int
    public var currentPath: String?
    public var errorMessage: String?

    public var fraction: Double {
        guard totalFiles > 0 else { return 0 }
        return min(max(Double(processedFiles) / Double(totalFiles), 0), 1)
    }
}

public struct ScanSummary: Equatable {
    public var scannedFiles: Int
    public var importedItems: Int
    public var skippedFiles: Int
    public var errors: [String]
}

#if os(macOS)

enum MediaScannerPathKind: Sendable, Equatable {
    case missing
    case file
    case directory
}

struct MediaScannerFileCatalog: @unchecked Sendable {
    var mediaFilesInSource: @Sendable (MediaSource) -> [URL]
    var mediaFilesAtRoot: @Sendable (URL, MediaSource, Bool) -> [URL]
    var pathKind: @Sendable (String) -> MediaScannerPathKind
    var fileSize: @Sendable (URL) throws -> Int64
    var photoMetadata: @Sendable (URL, Bool) -> MediaScannerPhotoMetadata

    static func fileSystem(parser: FilenameParser, fileManager: FileManager) -> MediaScannerFileCatalog {
        let catalog = FileSystemMediaScannerFileCatalog(parser: parser, fileManager: fileManager)
        return MediaScannerFileCatalog(
            mediaFilesInSource: { catalog.mediaFiles(in: $0) },
            mediaFilesAtRoot: { catalog.mediaFiles(at: $0, source: $1, recursive: $2) },
            pathKind: { catalog.pathKind(at: $0) },
            fileSize: { try catalog.fileSize(for: $0) },
            photoMetadata: { catalog.photoMetadata(for: $0, isImage: $1) }
        )
    }
}

struct MediaScannerPhotoMetadata: Sendable, Equatable {
    var capturedDate: Date
    var imagePixelSize: String?
}

private final class FileSystemMediaScannerFileCatalog: @unchecked Sendable {
    private let parser: FilenameParser
    private let fileManager: FileManager

    init(parser: FilenameParser, fileManager: FileManager) {
        self.parser = parser
        self.fileManager = fileManager
    }

    func mediaFiles(in source: MediaSource) -> [URL] {
        mediaFiles(at: URL(fileURLWithPath: source.path, isDirectory: true), source: source, recursive: source.recursive)
    }

    func mediaFiles(at root: URL, source: MediaSource, recursive: Bool) -> [URL] {
        var results: [URL] = []
        var seenPaths = Set<String>()

        func appendIfMediaFile(_ url: URL) {
            guard parser.isMediaFile(url, preferredType: source.mediaType) else { return }
            let canonicalURL = canonicalMediaURL(url)
            guard let values = try? canonicalURL.resourceValues(forKeys: [.isRegularFileKey]),
                  values.isRegularFile == true else { return }
            guard seenPaths.insert(canonicalURL.path).inserted else { return }
            results.append(canonicalURL)
        }

        if recursive {
            guard let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .fileSizeKey],
                options: source.ignoreHiddenFiles ? [.skipsHiddenFiles] : []
            ) else {
                return []
            }
            for case let url as URL in enumerator {
                appendIfMediaFile(url)
            }
        } else if let urls = try? fileManager.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isHiddenKey, .fileSizeKey],
            options: source.ignoreHiddenFiles ? [.skipsHiddenFiles] : []
        ) {
            urls.forEach(appendIfMediaFile)
        }

        return results.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }

    func pathKind(at path: String) -> MediaScannerPathKind {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else {
            return .missing
        }
        return isDirectory.boolValue ? .directory : .file
    }

    func fileSize(for url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    func photoMetadata(for url: URL, isImage: Bool) -> MediaScannerPhotoMetadata {
        MediaScannerPhotoMetadata(
            capturedDate: fileCaptureDate(for: url, isImage: isImage),
            imagePixelSize: isImage ? imagePixelSize(for: url) : nil
        )
    }

    private func canonicalMediaURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func fileCaptureDate(for fileURL: URL, isImage: Bool) -> Date {
        // 照片优先用 EXIF 拍摄时间（更贴合「相册按拍摄日期分组」），回落到文件创建/修改日期。
        if isImage, let exifDate = exifCaptureDate(for: fileURL) {
            return exifDate
        }
        let values = try? fileURL.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate ?? Date()
    }

    private func imagePixelSize(for url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width > 0, height > 0 else {
            return nil
        }
        return "\(width)x\(height)"
    }

    private func exifCaptureDate(for url: URL) -> Date? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return nil
        }
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any]
        let dateString = (exif?[kCGImagePropertyExifDateTimeOriginal] as? String)
            ?? (exif?[kCGImagePropertyExifDateTimeDigitized] as? String)
            ?? (tiff?[kCGImagePropertyTIFFDateTime] as? String)
        guard let dateString else { return nil }
        return Self.exifDateFormatter.date(from: dateString)
    }

    private static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()
}

public final class MediaScanner {
    private let parser: FilenameParser
    private let localMetadataService: LocalMetadataService
    private let audioMetadataReader: AudioMetadataReader
    private let thumbnailGenerator: ThumbnailGenerator?
    private let mediaRepository: MediaRepository
    private let logger: LoggingService?
    private let fileCatalog: MediaScannerFileCatalog

    public init(
        parser: FilenameParser = FilenameParser(),
        localMetadataService: LocalMetadataService = LocalMetadataService(),
        audioMetadataReader: AudioMetadataReader = AudioMetadataReader(),
        thumbnailGenerator: ThumbnailGenerator?,
        mediaRepository: MediaRepository,
        logger: LoggingService? = nil,
        fileManager: FileManager = .default
    ) {
        self.parser = parser
        self.localMetadataService = localMetadataService
        self.audioMetadataReader = audioMetadataReader
        self.thumbnailGenerator = thumbnailGenerator
        self.mediaRepository = mediaRepository
        self.logger = logger
        self.fileCatalog = .fileSystem(parser: parser, fileManager: fileManager)
    }

    init(
        parser: FilenameParser = FilenameParser(),
        localMetadataService: LocalMetadataService = LocalMetadataService(),
        audioMetadataReader: AudioMetadataReader = AudioMetadataReader(),
        thumbnailGenerator: ThumbnailGenerator?,
        mediaRepository: MediaRepository,
        logger: LoggingService? = nil,
        fileCatalog: MediaScannerFileCatalog
    ) {
        self.parser = parser
        self.localMetadataService = localMetadataService
        self.audioMetadataReader = audioMetadataReader
        self.thumbnailGenerator = thumbnailGenerator
        self.mediaRepository = mediaRepository
        self.logger = logger
        self.fileCatalog = fileCatalog
    }

    public func scan(
        source: MediaSource,
        settings: AppSettings,
        progress: @escaping (ScanProgress) -> Void,
        onImportedIDs: @escaping (Set<String>) -> Void = { _ in }
    ) async -> ScanSummary {
        guard await FileAccessService.isReachableDirectoryAsync(source.path) else {
            let message = inaccessibleSourceMessage(source, incremental: false)
            logger?.log(message, level: .warning)
            progress(ScanProgress(sourceID: source.id, status: "failed", totalFiles: 0, processedFiles: 0, currentPath: nil, errorMessage: message))
            return ScanSummary(scannedFiles: 0, importedItems: 0, skippedFiles: 0, errors: [message])
        }

        let files = await catalogMediaFiles(in: source)
        progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: files.count, processedFiles: 0, currentPath: nil, errorMessage: nil))

        var imported = 0
        var skipped = 0
        var errors: [String] = []
        var importedIDs = Set<String>()

        for (index, fileURL) in files.enumerated() {
            if Task.isCancelled { break }
            progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: files.count, processedFiles: index, currentPath: source.mediaType == .privateCollection ? nil : fileURL.path, errorMessage: nil))
            do {
                let fileSize = try await catalogFileSize(for: fileURL)
                guard fileSize >= minimumFileSize(for: fileURL, source: source) else {
                    skipped += 1
                    continue
                }
                let ids = try await importFile(fileURL, fileSize: fileSize, source: source, settings: settings)
                importedIDs.formUnion(ids)
                imported += 1
                onImportedIDs(ids)
            } catch {
                let message = source.mediaType == .privateCollection
                    ? "隐私媒体源中有文件扫描失败。"
                    : "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                errors.append(message)
                logger?.log(message, level: .error)
            }
        }

        if !Task.isCancelled && errors.isEmpty {
            do {
                try mediaRepository.deleteItems(sourcePath: source.path, excludingIDs: importedIDs)
            } catch {
                let message = "清理已移除媒体索引失败：\(error.localizedDescription)"
                errors.append(message)
                logger?.log(message, level: .warning)
            }
        } else if !errors.isEmpty {
            logger?.log("扫描存在错误，保留旧索引以避免误删。", level: .warning)
        }

        progress(ScanProgress(sourceID: source.id, status: "finished", totalFiles: files.count, processedFiles: files.count, currentPath: nil, errorMessage: errors.first))
        return ScanSummary(scannedFiles: files.count, importedItems: imported, skippedFiles: skipped, errors: errors)
    }

    public func scanChanges(
        source: MediaSource,
        changedPaths: [String],
        settings: AppSettings,
        progress: @escaping (ScanProgress) -> Void,
        onImportedIDs: @escaping (Set<String>) -> Void = { _ in }
    ) async -> ScanSummary {
        guard await FileAccessService.isReachableDirectoryAsync(source.path) else {
            let message = inaccessibleSourceMessage(source, incremental: true)
            logger?.log(message, level: .warning)
            progress(ScanProgress(sourceID: source.id, status: "failed", totalFiles: 0, processedFiles: 0, currentPath: nil, errorMessage: message))
            return ScanSummary(scannedFiles: 0, importedItems: 0, skippedFiles: 0, errors: [message])
        }

        let sourceRoot = URL(fileURLWithPath: source.path, isDirectory: true).standardizedFileURL.path
        let normalizedPaths = Set(changedPaths.compactMap { path -> String? in
            let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
            guard normalized == sourceRoot || normalized.hasPrefix("\(sourceRoot)/") else { return nil }
            return normalized
        })

        var importURLs = Set<URL>()
        var deletedFilePaths = Set<String>()
        var deletedDirectoryPaths = Set<String>()
        for path in normalizedPaths {
            let url = URL(fileURLWithPath: path)
            switch await catalogPathKind(at: path) {
            case .directory:
                let discovered = await catalogMediaFiles(at: url, source: source, recursive: source.recursive)
                discovered.forEach { importURLs.insert($0) }
            case .file:
                if parser.isMediaFile(url, preferredType: source.mediaType) {
                    importURLs.insert(canonicalMediaURL(url))
                } else if isMetadataSidecar(url) {
                    let discovered = await catalogMediaFiles(
                        at: url.deletingLastPathComponent(),
                        source: source,
                        recursive: false
                    )
                    discovered.forEach { importURLs.insert($0) }
                }
            case .missing:
                if parser.isMediaFile(url, preferredType: source.mediaType) {
                    deletedFilePaths.insert(path)
                    deletedFilePaths.insert(canonicalMediaURL(url).path)
                } else if isMetadataSidecar(url) {
                    let discovered = await catalogMediaFiles(
                        at: url.deletingLastPathComponent(),
                        source: source,
                        recursive: false
                    )
                    discovered.forEach { importURLs.insert($0) }
                } else {
                    deletedDirectoryPaths.insert(path)
                }
            }
        }

        let files = importURLs.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
        let totalWork = files.count + deletedFilePaths.count + deletedDirectoryPaths.count
        progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: totalWork, processedFiles: 0, currentPath: nil, errorMessage: nil))

        var imported = 0
        var skipped = 0
        var processed = 0
        var errors: [String] = []

        for path in deletedFilePaths {
            if Task.isCancelled { break }
            do {
                try mediaRepository.deleteItems(filePath: path)
            } catch {
                errors.append("移除失效文件索引失败：\(error.localizedDescription)")
            }
            processed += 1
            progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: totalWork, processedFiles: processed, currentPath: source.mediaType == .privateCollection ? nil : path, errorMessage: errors.first))
        }

        for path in deletedDirectoryPaths {
            if Task.isCancelled { break }
            do {
                try mediaRepository.deleteItems(filePathPrefix: path, sourcePath: source.path)
            } catch {
                errors.append("移除失效目录索引失败：\(error.localizedDescription)")
            }
            processed += 1
            progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: totalWork, processedFiles: processed, currentPath: source.mediaType == .privateCollection ? nil : path, errorMessage: errors.first))
        }

        for fileURL in files {
            if Task.isCancelled { break }
            do {
                let fileSize = try await catalogFileSize(for: fileURL)
                guard fileSize >= minimumFileSize(for: fileURL, source: source) else {
                    skipped += 1
                    processed += 1
                    progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: totalWork, processedFiles: processed, currentPath: source.mediaType == .privateCollection ? nil : fileURL.path, errorMessage: errors.first))
                    continue
                }
                let ids = try await importFile(fileURL, fileSize: fileSize, source: source, settings: settings)
                imported += 1
                onImportedIDs(ids)
            } catch {
                let message = source.mediaType == .privateCollection
                    ? "隐私媒体源中有文件增量更新失败。"
                    : "\(fileURL.lastPathComponent): \(error.localizedDescription)"
                errors.append(message)
                logger?.log(message, level: .error)
            }
            processed += 1
            progress(ScanProgress(sourceID: source.id, status: "running", totalFiles: totalWork, processedFiles: processed, currentPath: source.mediaType == .privateCollection ? nil : fileURL.path, errorMessage: errors.first))
        }

        if !Task.isCancelled {
            do {
                try mediaRepository.deleteOrphanParents(sourcePath: source.path)
            } catch {
                errors.append("清理空剧集索引失败：\(error.localizedDescription)")
            }
        }

        progress(ScanProgress(sourceID: source.id, status: "finished", totalFiles: totalWork, processedFiles: processed, currentPath: nil, errorMessage: errors.first))
        return ScanSummary(scannedFiles: files.count, importedItems: imported, skippedFiles: skipped, errors: errors)
    }

    private func importFile(_ fileURL: URL, fileSize: Int64, source: MediaSource, settings: AppSettings) async throws -> Set<String> {
        // 相册源：图片→.photo，视频→.homeVideo（归属由源决定，独立于视频库），不做剧集/电影解析。
        if source.mediaType == .photo {
            return try await importAlbumFile(fileURL, fileSize: fileSize, source: source, settings: settings)
        }

        let parsed = parser.parse(url: fileURL, preferredType: source.mediaType, sourcePath: source.path)
        let isMusicFile = source.mediaType == .music || (source.mediaType == .auto && parser.isAudioFile(fileURL))
        let localMetadata = isMusicFile
            ? LocalMetadata()
            : await localMetadataService.metadataAsync(for: fileURL, readNFO: source.readNFO, preferLocalArtwork: source.preferLocalArtwork)
        let mediaInfo = await thumbnailGenerator?.mediaInfo(for: fileURL)

        if isMusicFile {
            let canonicalFileURL = canonicalMediaURL(fileURL)
            let id = StableID.make(prefix: "music", value: canonicalFileURL.path)
            let audioMetadata = await audioMetadataReader.metadata(
                for: canonicalFileURL,
                artworkDirectory: thumbnailGenerator?.outputDirectoryURL,
                mediaID: id
            )
            let title = audioMetadata.title ?? musicTitle(for: canonicalFileURL)
            let album = audioMetadata.album
            var poster = audioMetadata.artworkPath
            if poster == nil {
                poster = await fallbackPoster(
                    for: canonicalFileURL,
                    mediaID: id,
                    title: title,
                    mediaType: .music,
                    source: source,
                    settings: settings,
                    mediaInfo: mediaInfo
                )
            }
            let item = MediaItem(
                id: id,
                type: .music,
                title: title,
                artist: audioMetadata.artist,
                album: album,
                trackNumber: audioMetadata.trackNumber,
                year: audioMetadata.year,
                posterPath: poster,
                sourcePath: source.path,
                filePath: canonicalFileURL.path,
                fileSize: fileSize,
                duration: audioMetadata.duration ?? mediaInfo?.duration,
                loudnessTrackGainDB: audioMetadata.loudnessTrackGainDB,
                loudnessAlbumGainDB: audioMetadata.loudnessAlbumGainDB,
                loudnessTrackPeak: audioMetadata.loudnessTrackPeak,
                loudnessAlbumPeak: audioMetadata.loudnessAlbumPeak,
                metadataProvider: audioMetadata.hasEmbeddedMetadata ? "Embedded" : nil,
                genre: audioMetadata.genre
            )
            try mediaRepository.deleteItems(filePath: canonicalFileURL.path, excludingID: id)
            try mediaRepository.upsert(item)
            return [id]
        }

        switch parsed.kind {
        case .movie:
            let id = StableID.make(prefix: "movie", value: fileURL.path)
            let itemType = resolvedMovieType(for: source)
            let title = localMetadata.title ?? parsed.title
            var poster = localMetadata.posterPath
            if poster == nil {
                poster = await fallbackPoster(
                    for: fileURL,
                    mediaID: id,
                    title: title,
                    mediaType: itemType,
                    source: source,
                    settings: settings,
                    mediaInfo: mediaInfo
                )
            }
            let item = MediaItem(
                id: id,
                type: itemType,
                title: title,
                originalTitle: localMetadata.originalTitle,
                year: localMetadata.year ?? parsed.year,
                overview: localMetadata.overview,
                posterPath: poster,
                backdropPath: localMetadata.backdropPath,
                sourcePath: source.path,
                filePath: fileURL.path,
                fileSize: fileSize,
                resolution: mediaInfo?.resolution,
                duration: mediaInfo?.duration
            )
            try mediaRepository.upsert(item)
            return [id]

        case .episode:
            let seriesDirectory = parsed.seriesDirectoryPath.map { URL(fileURLWithPath: $0, isDirectory: true) }
            let seriesMetadata: LocalMetadata
            if let seriesDirectory {
                seriesMetadata = await localMetadataService.metadataAsync(
                    forDirectory: seriesDirectory,
                    readNFO: source.readNFO,
                    preferLocalArtwork: source.preferLocalArtwork
                )
            } else {
                seriesMetadata = LocalMetadata()
            }
            let showTitle = seriesMetadata.title ?? parsed.title
            let showIDSource = parsed.seriesDirectoryPath ?? "\(source.path)/\(showTitle)"
            let showID = StableID.make(prefix: "show", value: showIDSource)

            let episodeID = StableID.make(prefix: "episode", value: fileURL.path)
            var episodePoster = localMetadata.posterPath
            if episodePoster == nil {
                episodePoster = await fallbackPoster(
                    for: fileURL,
                    mediaID: episodeID,
                    title: "\(showTitle) \(parsed.episodeNumber.map { "E\($0)" } ?? "")",
                    mediaType: .episode,
                    source: source,
                    settings: settings,
                    mediaInfo: mediaInfo
                )
            }

            let show = MediaItem(
                id: showID,
                type: resolvedSeriesType(for: source),
                title: showTitle,
                originalTitle: seriesMetadata.originalTitle,
                year: seriesMetadata.year,
                overview: seriesMetadata.overview,
                posterPath: seriesMetadata.posterPath ?? episodePoster,
                backdropPath: seriesMetadata.backdropPath,
                sourcePath: source.path
            )
            try mediaRepository.upsert(show)

            let episode = MediaItem(
                id: episodeID,
                type: .episode,
                title: showTitle,
                posterPath: episodePoster,
                sourcePath: source.path,
                parentID: showID,
                seasonNumber: parsed.seasonNumber,
                episodeNumber: parsed.episodeNumber,
                filePath: fileURL.path,
                fileSize: fileSize,
                resolution: mediaInfo?.resolution,
                duration: mediaInfo?.duration
            )
            try mediaRepository.upsert(episode)
            return [showID, episodeID]
        }
    }

    /// 相册条目导入：单文件即一个顶层条目。图片用原图作缩略图来源，视频生成缩略图；
    /// 拍摄日期取文件创建/修改日期（EXIF 留待后续轮），用于相册按时间排序。
    private func importAlbumFile(_ fileURL: URL, fileSize: Int64, source: MediaSource, settings: AppSettings) async throws -> Set<String> {
        let canonicalURL = canonicalMediaURL(fileURL)
        let isImage = parser.isImageFile(canonicalURL)
        let id = StableID.make(prefix: isImage ? "photo" : "albumvideo", value: canonicalURL.path)
        let title = canonicalURL.deletingPathExtension().lastPathComponent
        let photoMetadata = await catalogPhotoMetadata(for: canonicalURL, isImage: isImage)
        let capturedDate = photoMetadata.capturedDate

        var poster: String?
        var resolution: String?
        var duration: Double?
        if isImage {
            poster = canonicalURL.path
            // 记录像素尺寸（W×H），相册网格用它做保留宽高比的瀑布式排版。
            resolution = photoMetadata.imagePixelSize
        } else {
            let mediaInfo = await thumbnailGenerator?.mediaInfo(for: canonicalURL)
            resolution = mediaInfo?.resolution
            duration = mediaInfo?.duration
            poster = await fallbackPoster(
                for: canonicalURL,
                mediaID: id,
                title: title,
                mediaType: .homeVideo,
                source: source,
                settings: settings,
                mediaInfo: mediaInfo
            )
        }

        let item = MediaItem(
            id: id,
            type: isImage ? .photo : .homeVideo,
            title: title,
            posterPath: poster,
            sourcePath: source.path,
            filePath: canonicalURL.path,
            fileSize: fileSize,
            resolution: resolution,
            duration: duration,
            createdAt: capturedDate,
            updatedAt: capturedDate
        )
        try mediaRepository.deleteItems(filePath: canonicalURL.path, excludingID: id)
        try mediaRepository.upsert(item)
        return [id]
    }

    private func fallbackPoster(
        for fileURL: URL,
        mediaID: String,
        title: String,
        mediaType: MediaType,
        source: MediaSource,
        settings: AppSettings,
        mediaInfo: (duration: Double?, resolution: String?)?
    ) async -> String? {
        guard source.screenshotFallbackEnabled, settings.enableThumbnailFallback else {
            return nil
        }

        switch settings.artworkFallbackMode {
        case .videoFrame:
            if mediaType == .music {
                return await thumbnailGenerator?.generateDefaultArtwork(
                    mediaID: mediaID,
                    title: title,
                    mediaType: mediaType,
                    aspectRatio: 1.0
                )?.path
            }
            return await thumbnailGenerator?.generateThumbnail(
                for: fileURL,
                mediaID: mediaID,
                ratio: settings.thumbnailCaptureRatio,
                avoidBlackFrames: settings.avoidBlackFrames
            )?.path
        case .generatedDefault:
            return await thumbnailGenerator?.generateDefaultArtwork(
                mediaID: mediaID,
                title: title,
                mediaType: mediaType,
                aspectRatio: aspectRatio(from: mediaInfo?.resolution)
            )?.path
        case .none:
            return nil
        }
    }

    private func aspectRatio(from resolution: String?) -> Double? {
        guard let resolution else { return nil }
        let parts = resolution.lowercased().split(separator: "x")
        guard parts.count == 2,
              let width = Double(parts[0]),
              let height = Double(parts[1]),
              width > 0,
              height > 0 else {
            return nil
        }
        return width / height
    }

    private func catalogMediaFiles(in source: MediaSource) async -> [URL] {
        await BlockingIOExecutor.run {
            self.fileCatalog.mediaFilesInSource(source)
        }
    }

    private func catalogMediaFiles(at root: URL, source: MediaSource, recursive: Bool) async -> [URL] {
        await BlockingIOExecutor.run {
            self.fileCatalog.mediaFilesAtRoot(root, source, recursive)
        }
    }

    private func catalogPathKind(at path: String) async -> MediaScannerPathKind {
        await BlockingIOExecutor.run {
            self.fileCatalog.pathKind(path)
        }
    }

    private func catalogFileSize(for url: URL) async throws -> Int64 {
        try await BlockingIOExecutor.run {
            try self.fileCatalog.fileSize(url)
        }
    }

    private func catalogPhotoMetadata(for url: URL, isImage: Bool) async -> MediaScannerPhotoMetadata {
        await BlockingIOExecutor.run {
            self.fileCatalog.photoMetadata(url, isImage)
        }
    }

    private func isMetadataSidecar(_ url: URL) -> Bool {
        parser.isSidecarMetadataFile(url)
    }

    private func canonicalMediaURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    private func minimumFileSize(for fileURL: URL, source: MediaSource) -> Int64 {
        // 相册源不设体积下限：照片常常远小于视频的 50MB 默认阈值。
        if source.mediaType == .photo {
            return 0
        }
        guard parser.isAudioFile(fileURL) else {
            return source.minimumFileSize
        }
        return min(source.minimumFileSize, 512 * 1024)
    }

    /// 保险库扫描错误不能暴露来源路径；普通来源保留路径便于用户排查挂载问题。
    private func inaccessibleSourceMessage(_ source: MediaSource, incremental: Bool) -> String {
        if source.mediaType == .privateCollection {
            return incremental ? "保险库媒体源不可访问，已跳过增量更新。" : "保险库媒体源不可访问。"
        }
        return incremental ? "媒体源不可访问，已跳过增量更新：\(source.path)" : "媒体源不可访问：\(source.path)"
    }

    private func musicTitle(for fileURL: URL) -> String {
        let filename = fileURL.deletingPathExtension().lastPathComponent
        let cleaned = filename
            .replacingOccurrences(of: #"^\d{1,3}\s*[-_.]\s*"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "_", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? filename : cleaned
    }

    private func resolvedMovieType(for source: MediaSource) -> MediaType {
        switch source.mediaType {
        case .movie, .anime, .documentary, .variety, .homeVideo, .music, .other, .privateCollection:
            return source.mediaType
        case .auto, .tvShow, .episode, .photo:
            return .movie
        }
    }

    private func resolvedSeriesType(for source: MediaSource) -> MediaType {
        switch source.mediaType {
        case .anime, .documentary, .variety, .homeVideo, .music, .other, .privateCollection:
            return source.mediaType
        case .auto, .movie, .tvShow, .episode, .photo:
            return .tvShow
        }
    }
}
#endif
