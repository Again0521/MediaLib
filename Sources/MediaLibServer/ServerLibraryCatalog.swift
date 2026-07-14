import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 服务端资料库读取边界。它在映射安全 DTO 或文件引用之前同时执行保险库排除、
/// 用户角色与逐资料库授权，路由层永远不会接触未授权的 `MediaItem` 或本地路径。
final class ServerLibraryCatalog {
    private let mediaRepository: MediaRepository
    private let sourceRepository: SourceRepository
    private let userMediaStateRepository: ServerUserMediaStateRepository

    init(database: DatabaseManager) {
        self.mediaRepository = MediaRepository(database: database)
        self.sourceRepository = SourceRepository(database: database)
        self.userMediaStateRepository = ServerUserMediaStateRepository(database: database)
    }

    func snapshot(for principal: ServerRequestPrincipal) throws -> ServerLibrarySnapshot {
        let visibleItems = try publicItems(for: principal, requiring: .viewMedia)
        let countsByType = visibleItems.reduce(into: [String: Int]()) { counts, item in
            counts[item.type.rawValue, default: 0] += 1
        }
        let cards = visibleItems
            .filter { $0.parentID == nil && $0.type != .episode }
            .sorted {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
            .prefix(60)
            .map {
                ServerLibraryItem(
                    id: $0.id,
                    type: $0.type.rawValue,
                    title: $0.cardTitle,
                    year: $0.year,
                    artworkAvailable: $0.posterPath?.isEmpty == false
                )
            }
        return ServerLibrarySnapshot(
            summary: ServerLibrarySummary(
                totalItemCount: visibleItems.count,
                countsByType: countsByType
            ),
            items: ServerLibraryItemsResponse(totalItemCount: cards.count, items: cards)
        )
    }

    func categories(for principal: ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse {
        let counts = try publicItems(for: principal, requiring: .viewMedia).reduce(into: [MediaType: Int]()) {
            $0[$1.type, default: 0] += 1
        }
        let categories = MediaType.allCases.compactMap { type -> ServerLibraryCategory? in
            guard type != .privateCollection, type != .auto, let count = counts[type], count > 0 else { return nil }
            return ServerLibraryCategory(id: type.rawValue, title: type.displayName, itemCount: count)
        }
        return ServerLibraryCategoriesResponse(categories: categories)
    }

    func browse(_ query: ServerLibraryQuery, for principal: ServerRequestPrincipal) throws -> ServerLibraryItemsPage {
        var items = try publicItems(for: principal, requiring: .viewMedia)
        if let type = query.type, let mediaType = MediaType(rawValue: type) {
            items = items.filter { $0.type == mediaType }
        } else {
            items = items.filter { $0.parentID == nil && $0.type != .episode }
        }
        if let searchText = query.searchText?.trimmingCharacters(in: .whitespacesAndNewlines), !searchText.isEmpty {
            let needle = searchText.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            items = items.filter { item in
                [item.cardTitle, item.originalTitle, item.artist, item.album, item.genre, item.year.map(String.init)]
                    .compactMap { $0 }
                    .contains { $0.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current).contains(needle) }
            }
        }
        switch query.sort {
        case .updatedDescending:
            items.sort {
                if $0.updatedAt != $1.updatedAt { return $0.updatedAt > $1.updatedAt }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        case .titleAscending:
            items.sort { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
        case .yearDescending:
            items.sort {
                if $0.year != $1.year { return ($0.year ?? Int.min) > ($1.year ?? Int.min) }
                return $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
            }
        }
        let total = items.count
        let pageItems = query.offset < total
            ? Array(items.dropFirst(query.offset).prefix(query.limit))
            : []
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: pageItems.map(\.id))
        let cards = pageItems.map { item in
            ServerLibraryItem(
                id: item.id,
                type: item.type.rawValue,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体",
                year: item.year,
                artworkAvailable: item.posterPath?.isEmpty == false,
                userState: states[item.id].map(Self.protocolState)
            )
        }
        return ServerLibraryItemsPage(
            totalItemCount: total,
            offset: query.offset,
            limit: query.limit,
            items: cards
        )
    }

    func publicDetail(id: String, for principal: ServerRequestPrincipal) throws -> ServerMediaItemDetail? {
        guard let item = try publicItems(for: principal, requiring: .viewMedia).first(where: { $0.id == id }) else {
            return nil
        }
        let hasReadableAsset = item.filePath.flatMap(Self.localReadableFileURL(from:)) != nil
        let isPlayable = try publicItems(for: principal, requiring: .playMedia)
            .contains(where: { $0.id == id })
        let isTranscodable = try publicItems(for: principal, requiring: .transcodePlayback)
            .contains(where: { $0.id == id })
        let canDirectPlay = hasReadableAsset && isPlayable
        let canTranscode = hasReadableAsset && isTranscodable
        let userState = try userMediaStateRepository.fetch(userID: principal.userID, mediaID: item.id)
        let runtimeSeconds: Double? = {
            if let duration = item.duration, duration.isFinite, duration >= 0 { return duration }
            if let runtime = item.runtime, runtime >= 0 { return Double(runtime) * 60 }
            return nil
        }()
        return ServerMediaItemDetail(
            id: item.id,
            type: item.type.rawValue,
            title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体",
            originalTitle: Self.boundedText(item.originalTitle, maximumLength: 512),
            year: item.year,
            overview: Self.boundedText(item.overview, maximumLength: 8_000),
            genres: Self.genres(item.genre),
            communityRating: item.rating,
            runtimeSeconds: runtimeSeconds,
            videoCodec: Self.boundedText(item.videoCodec, maximumLength: 64),
            audioCodec: Self.boundedText(item.audioCodec, maximumLength: 64),
            resolution: Self.boundedText(item.resolution, maximumLength: 64),
            artworkAvailable: item.posterPath?.isEmpty == false,
            backdropAvailable: item.backdropPath?.isEmpty == false,
            canDirectPlay: canDirectPlay,
            canTranscode: canTranscode,
            userState: userState.map(Self.protocolState)
        )
    }

    func updatePlaybackState(
        id: String,
        request: ServerPlaybackStateUpdateRequest,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaUserState? {
        guard request.isValid,
              try publicItems(for: principal, requiring: .playMedia).contains(where: { $0.id == id })
        else {
            return nil
        }
        let event: MediaLibCore.ServerPlaybackStateEvent
        switch request.event {
        case .started: event = .started
        case .progress: event = .progress
        case .stopped: event = .stopped
        case .completed: event = .completed
        case .reset: event = .reset
        }
        let state = try userMediaStateRepository.update(
            userID: principal.userID,
            mediaID: id,
            event: event,
            position: request.positionSeconds,
            duration: request.durationSeconds
        )
        return Self.protocolState(state)
    }

    /// 将媒体 ID 映射为可读取的本地文件，但绝不将这个路径交给 DTO 或路由以外的调用者。
    /// 调用前已经通过用户、资料库、能力和会话授权；未知与无权 ID 统一返回 nil。
    func publicAsset(
        id: String,
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission = .playMedia
    ) throws -> ServerMediaAsset? {
        guard let item = try publicItems(for: principal, requiring: permission).first(where: { $0.id == id }),
              let filePath = item.filePath,
              let url = Self.localReadableFileURL(from: filePath)
        else {
            return nil
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = (attributes[.size] as? NSNumber)?.int64Value,
              size >= 0
        else {
            return nil
        }
        return ServerMediaAsset(id: item.id, fileURL: url, byteLength: size)
    }

    /// 海报/背景图使用与详情相同的逐条目授权，不接受客户端路径。SVG 等可执行图片格式
    /// 和超大文件被排除，避免图片端点退化为任意文件读取或响应放大器。
    func publicArtwork(
        id: String,
        kind: ServerArtworkKind,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaAsset? {
        guard let item = try publicItems(for: principal, requiring: .viewMedia).first(where: { $0.id == id }) else {
            return nil
        }
        let rawPath: String?
        switch kind {
        case .poster: rawPath = item.posterPath
        case .backdrop: rawPath = item.backdropPath
        }
        guard let rawPath,
              let url = Self.localReadableFileURL(from: rawPath),
              ServerArtworkKind.allowedExtensions.contains(url.pathExtension.lowercased())
        else { return nil }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true,
              let size = values.fileSize,
              size > 0,
              size <= ServerArtworkKind.maximumByteLength
        else { return nil }
        return ServerMediaAsset(id: item.id, fileURL: url, byteLength: Int64(size))
    }

    private func publicItems(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> [MediaItem] {
        guard principal.permissions.contains(permission) else { return [] }
        let sources = try sourceRepository.fetchAll()
        let publicSources = sources.filter { $0.mediaType != .privateCollection }
        let publicSourcePaths = Set(publicSources.map(\.path))
        let allowedSourcePaths: Set<String>
        if principal.canManageServer {
            allowedSourcePaths = publicSourcePaths
        } else {
            allowedSourcePaths = Set(publicSources.compactMap { source in
                principal.allows(permission, libraryID: source.id) ? source.path : nil
            })
        }
        return try mediaRepository.fetchAll().filter { item in
            guard item.type != .privateCollection,
                  let sourcePath = item.sourcePath,
                  publicSourcePaths.contains(sourcePath)
            else {
                return false
            }
            return allowedSourcePaths.contains(sourcePath)
        }
    }

    private static func localReadableFileURL(from rawPath: String) -> URL? {
        let url: URL
        if let parsedURL = URL(string: rawPath), parsedURL.scheme != nil {
            guard parsedURL.isFileURL else { return nil }
            url = parsedURL
        } else {
            url = URL(fileURLWithPath: rawPath)
        }
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return url
    }

    private static func boundedText(_ value: String?, maximumLength: Int) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maximumLength))
    }

    private static func genres(_ value: String?) -> [String] {
        guard let value else { return [] }
        return value
            .replacingOccurrences(of: "，", with: ",")
            .split(separator: ",", omittingEmptySubsequences: true)
            .compactMap { boundedText(String($0), maximumLength: 128) }
            .prefix(24)
            .map { $0 }
    }

    private static func protocolState(_ state: ServerUserMediaStateRecord) -> ServerMediaUserState {
        ServerMediaUserState(
            itemID: state.mediaID,
            positionSeconds: state.playPosition,
            progress: state.playProgress,
            isWatched: state.isWatched,
            playCount: state.playCount,
            lastPlayedAt: state.lastPlayedAt,
            updatedAt: state.updatedAt
        )
    }
}

struct ServerLibrarySnapshot {
    let summary: ServerLibrarySummary
    let items: ServerLibraryItemsResponse
}

/// 保持在 Server target 内部的已授权媒体文件引用。任何协议响应都只携带媒体 ID，
/// 从不包含 `fileURL` 或文件大小以外的本地文件信息。
struct ServerMediaAsset {
    let id: String
    let fileURL: URL
    let byteLength: Int64

    var contentType: String {
        switch fileURL.pathExtension.lowercased() {
        case "mp4", "m4v": return "video/mp4"
        case "mkv": return "video/x-matroska"
        case "webm": return "video/webm"
        case "mov": return "video/quicktime"
        case "avi": return "video/x-msvideo"
        case "mp3": return "audio/mpeg"
        case "m4a": return "audio/mp4"
        case "aac": return "audio/aac"
        case "flac": return "audio/flac"
        case "wav": return "audio/wav"
        case "jpg", "jpeg", "jfif": return "image/jpeg"
        case "png": return "image/png"
        case "webp": return "image/webp"
        case "gif": return "image/gif"
        case "avif": return "image/avif"
        default: return "application/octet-stream"
        }
    }
}

enum ServerArtworkKind: String, Sendable {
    case poster
    case backdrop

    static let maximumByteLength = 32 * 1024 * 1024
    static let allowedExtensions: Set<String> = ["jpg", "jpeg", "jfif", "png", "webp", "gif", "avif"]
}
