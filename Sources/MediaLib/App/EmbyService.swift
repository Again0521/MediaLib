import Foundation
import MediaLibCore

struct EmbySession {
    var serverURL: URL
    var username: String
    var userID: String
    var accessToken: String
    var provider: RemoteConnectorProvider = .emby
}

private extension EmbySession {
    var stableIDPrefix: String {
        switch provider {
        case .jellyfin:
            return "jellyfin"
        default:
            return "emby"
        }
    }
}

enum EmbyServiceError: LocalizedError {
    case authenticationExpired
    /// 服务器疑似限制第三方客户端接入（白名单 / 451 / 自定义 HTML 错误页 / 含关键字）。
    /// 不应自动重试或反复重新登录，应提示用户联系管理员加入白名单。
    case clientRestricted(statusCode: Int?, reason: String?)
    case requestFailed(statusCode: Int)

    var errorDescription: String? {
        // ★这套错误 Emby 与 Jellyfin 共用（都走 EmbyService），文案必须中性，
        // 不能写死"Emby"——否则 Jellyfin 源同步失败时任务/提示里会串出"Emby"字样。
        // 具体平台名由上层 `provider.displayName` 拼进任务标题，这里只描述现象。
        switch self {
        case .authenticationExpired:
            return "远程媒体库登录已失效，需要重新认证。"
        case .clientRestricted:
            return "该远程服务器可能限制第三方客户端接入。请联系管理员将 MediaLIB 加入白名单。"
        case .requestFailed(let statusCode):
            return "远程媒体库请求失败（HTTP \(statusCode)），请检查服务器状态和网络连接。"
        }
    }
}

/// MediaLIB 向 Emby 表明身份的客户端信息，受限服务器提示中可复制给管理员加入白名单。
struct EmbyClientIdentity: Equatable, Sendable {
    var client: String
    var device: String
    var deviceID: String
    var version: String
    var userAgent: String
}

enum EmbyPlaybackPhase {
    case started
    case progress
    case stopped
}

struct EmbyLibrarySummary: Identifiable, Hashable, Sendable {
    var id: String
    var sourceID: String
    var viewID: String
    var name: String
    var collectionType: String?
    var sourceName: String

    var displayName: String {
        name
    }

    var systemImage: String {
        switch collectionType?.lowercased() {
        case "movies": return "film"
        case "tvshows": return "tv"
        case "music": return "music.note"
        case "boxsets", "playlists": return "rectangle.stack"
        case "homevideos", "photos": return "photo.on.rectangle"
        case "livetv": return "dot.radiowaves.left.and.right"
        default: return "rectangle.stack"
        }
    }
}

struct EmbySubtitleStream: Identifiable, Hashable, Sendable {
    var itemID: String
    var mediaSourceID: String?
    var index: Int
    var language: String?
    var displayTitle: String?
    var fileExtension: String
    var deliveryURLString: String?

    var id: String {
        "\(itemID)-\(mediaSourceID ?? "default")-\(index)"
    }
}

/// Emby 条目详情扩展数据：演员 + 艺术照 + 外部 ID（用于相关链接与 TMDB 类似作品补全）。
struct EmbyDetailExtras {
    var cast: [TMDBPerson]
    var crew: [TMDBPerson]
    var images: [TMDBImage]
    var tmdbID: String?
    var tmdbKind: String?
    var imdbID: String?
}

struct EmbyService {
    private let clientName = "MediaLIB"
    private let deviceName = Host.current().localizedName ?? "Mac"
    private let version = AppVersion.current
    private let pageSize = 300
    private static let maxItemPageIterations = 10_000
    private let deviceIDDefaults: UserDefaults

    init(deviceIDDefaults: UserDefaults = .standard) {
        self.deviceIDDefaults = deviceIDDefaults
    }

    private var userAgent: String {
        "\(clientName)/\(version) (macOS)"
    }

    /// 当前发往 Emby 的客户端身份，受限服务器提示中展示给用户复制。
    func clientIdentity() -> EmbyClientIdentity {
        EmbyClientIdentity(
            client: clientName,
            device: deviceName,
            deviceID: deviceIdentifier(),
            version: version,
            userAgent: userAgent
        )
    }

    func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let serviceError = error as? EmbyServiceError else { return false }
        if case .authenticationExpired = serviceError {
            return true
        }
        return false
    }

    /// 是否为受限服务器（白名单）错误——调用方据此停止重试并提示用户。
    func isClientRestriction(_ error: Error) -> Bool {
        guard let serviceError = error as? EmbyServiceError else { return false }
        if case .clientRestricted = serviceError { return true }
        return false
    }

    func authenticate(
        serverURL: URL,
        username: String,
        password: String,
        provider: RemoteConnectorProvider = .emby
    ) async throws -> EmbySession {
        let baseURL = normalizedServerURL(serverURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(accessToken: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.httpBody = try JSONEncoder().encode(EmbyLoginRequest(Username: username, Pw: password))

        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(EmbyLoginResponse.self, from: data)
        return EmbySession(
            serverURL: baseURL,
            username: payload.User.Name ?? username,
            userID: payload.User.Id,
            accessToken: payload.AccessToken,
            provider: provider
        )
    }

    func fetchItems(
        session: EmbySession,
        sourceID: String,
        sourcePath: String,
        selectedLibraryIDs: Set<String> = []
    ) async throws -> [MediaItem] {
        let libraries = try await fetchLibraries(
            session: session,
            sourceID: sourceID,
            sourceName: session.serverURL.host ?? session.provider.displayName
        )
        guard !libraries.isEmpty else {
            guard selectedLibraryIDs.isEmpty else { return [] }
            return try await fetchItems(session: session, sourceID: sourceID, sourcePath: sourcePath, parentID: nil)
        }

        let syncLibraries = selectedLibraryIDs.isEmpty
            ? libraries
            : libraries.filter { selectedLibraryIDs.contains($0.viewID) || selectedLibraryIDs.contains($0.id) }
        guard !syncLibraries.isEmpty else { return [] }

        var imported: [MediaItem] = []
        var seen = Set<String>()
        for library in syncLibraries {
            let libraryPath = Self.librarySourcePath(base: sourcePath, library: library)
            let items = try await fetchItems(session: session, sourceID: sourceID, sourcePath: libraryPath, parentID: library.viewID)
            for item in items where seen.insert(item.id).inserted {
                imported.append(item)
            }
        }
        return imported
    }

    func fetchLibraries(session: EmbySession, sourceID: String, sourceName: String) async throws -> [EmbyLibrarySummary] {
        let viewsURL = session.serverURL
            .appendingPathComponent("Users")
            .appendingPathComponent(session.userID)
            .appendingPathComponent("Views")
        var components = URLComponents(url: viewsURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: session.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
        return payload.Items
            .filter { $0.CollectionType?.isEmpty == false || $0.type.lowercased() == "collectionfolder" }
            .map { dto in
                EmbyLibrarySummary(
                    id: dto.Id,
                    sourceID: sourceID,
                    viewID: dto.Id,
                    name: dto.Name,
                    collectionType: dto.CollectionType,
                    sourceName: sourceName
                )
            }
    }

    func reportPlayback(
        session: EmbySession,
        itemID: String,
        playSessionID: String,
        phase: EmbyPlaybackPhase,
        position: Double,
        duration: Double?,
        isPaused: Bool,
        filePath: String?
    ) async throws {
        let endpoint: String
        switch phase {
        case .started:
            endpoint = "Sessions/Playing"
        case .progress:
            endpoint = "Sessions/Playing/Progress"
        case .stopped:
            endpoint = "Sessions/Playing/Stopped"
        }
        let payload = EmbyPlaybackReportRequest(
            ItemId: itemID,
            MediaSourceId: Self.mediaSourceID(from: filePath),
            PlaySessionId: playSessionID,
            PositionTicks: Self.ticks(from: position),
            RunTimeTicks: duration.map(Self.ticks(from:)),
            IsPaused: isPaused,
            PlayMethod: "DirectStream"
        )
        try await sendAuthenticated(
            session: session,
            pathComponents: endpoint.split(separator: "/").map(String.init),
            method: "POST",
            body: try JSONEncoder().encode(payload)
        )
    }

    func setFavorite(session: EmbySession, itemID: String, favorite: Bool) async throws {
        try await sendAuthenticated(
            session: session,
            pathComponents: ["Users", session.userID, "FavoriteItems", itemID],
            method: favorite ? "POST" : "DELETE"
        )
    }

    func setPlayed(session: EmbySession, itemID: String, played: Bool) async throws {
        try await sendAuthenticated(
            session: session,
            pathComponents: ["Users", session.userID, "PlayedItems", itemID],
            method: played ? "POST" : "DELETE"
        )
    }

    func validateSession(_ session: EmbySession) async throws {
        try await sendAuthenticated(
            session: session,
            pathComponents: ["Users", session.userID],
            method: "GET"
        )
    }

    func subtitleStreams(session: EmbySession, itemID: String, mediaSourceID: String?) async throws -> [EmbySubtitleStream] {
        let item = try await fetchItemDetail(session: session, itemID: itemID)
        let mediaSource = mediaSourceID.flatMap { requestedID in
            item.MediaSources?.first { $0.Id == requestedID }
        } ?? item.MediaSources?.first
        guard let mediaSource else { return [] }

        return (mediaSource.MediaStreams ?? []).compactMap { stream in
            guard stream.streamType.caseInsensitiveCompare("Subtitle") == .orderedSame,
                  let index = stream.Index,
                  let fileExtension = Self.subtitleFileExtension(for: stream) else {
                return nil
            }
            return EmbySubtitleStream(
                itemID: itemID,
                mediaSourceID: mediaSource.Id,
                index: index,
                language: stream.Language,
                displayTitle: stream.DisplayTitle,
                fileExtension: fileExtension,
                deliveryURLString: stream.DeliveryUrl
            )
        }
    }

    func downloadSubtitle(session: EmbySession, stream: EmbySubtitleStream) async throws -> Data {
        guard let url = subtitleDownloadURL(session: session, stream: stream) else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: session.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
        return data
    }

    func refreshedResourceURLString(_ value: String?, session: EmbySession) -> String? {
        guard let value,
              var components = URLComponents(string: value),
              let resourceURL = components.url,
              RemoteResourceURLPolicy.isSameOrigin(resourceURL, session.serverURL) else { return value }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("api_key") == .orderedSame }
        queryItems.append(URLQueryItem(name: "api_key", value: session.accessToken))
        components.queryItems = queryItems
        return components.string ?? value
    }

    static func librarySourcePath(base: String, library: EmbyLibrarySummary) -> String {
        let encodedName = library.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? library.name
        let encodedType = (library.collectionType ?? "mixed").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "mixed"
        return "\(base)/library/\(library.viewID)/type/\(encodedType)/name/\(encodedName)"
    }

    static func sourceRootPath(from librarySourcePath: String) -> String? {
        guard isMediaServerSourcePath(librarySourcePath) else { return nil }
        guard let range = librarySourcePath.range(of: "/library/", options: .caseInsensitive) else {
            return librarySourcePath
        }
        return String(librarySourcePath[..<range.lowerBound])
    }

    static func libraryInfo(from sourcePath: String) -> (id: String, name: String?, collectionType: String?)? {
        guard isMediaServerSourcePath(sourcePath),
              let range = sourcePath.range(of: "/library/", options: .caseInsensitive) else { return nil }
        let remainder = sourcePath[range.upperBound...]
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 1, !parts[0].isEmpty {
            return (parts[0], nil, nil)
        }
        if !parts.isEmpty, !parts[0].isEmpty {
            var name: String?
            var collectionType: String?
            var index = 1
            while index + 1 < parts.count {
                let key = parts[index]
                let value = parts[index + 1]
                if key == "name" {
                    name = value.removingPercentEncoding ?? value
                } else if key == "type" {
                    collectionType = value.removingPercentEncoding ?? value
                }
                index += 2
            }
            if name != nil || collectionType != nil {
                return (parts[0], name, collectionType)
            }
        }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let name = parts[0].removingPercentEncoding ?? parts[0]
        return (parts[1], name, nil)
    }

    static func isMediaServerSourcePath(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("emby://") || lowercased.hasPrefix("jellyfin://") || lowercased.hasPrefix("plex://") || lowercased.hasPrefix("mlink://")
    }

    /// 是否为「Emby 兼容」远程源（Emby 或 Jellyfin）——两者播放上报、转码取流走完全相同的 Emby API，
    /// 应当被同等对待；Plex 用另一套 API（由各自的 PlexService 分支处理），不包含在内。
    static func isEmbyCompatibleSourcePath(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("emby://") || lowercased.hasPrefix("jellyfin://")
    }

    /// 按 `metadataProvider` 判断是否 Emby 兼容（Emby / Jellyfin）。转码取流走 Emby API 的判断用它更稳：
    /// 有些条目（如仅带流地址 filePath 的远程视频）不一定填了 emby:// 的 sourcePath，但 metadataProvider 一定准确。
    static func isEmbyCompatibleProvider(_ provider: String?) -> Bool {
        provider == "Emby" || provider == "Jellyfin"
    }

    static func shouldContinueItemPagination(
        pageItemCount: Int,
        addedUniqueItems: Int,
        totalRecordCount: Int?,
        nextStartIndex: Int,
        pageIndex: Int,
        maxPageIterations: Int
    ) -> Bool {
        guard pageItemCount > 0 else { return false }
        if addedUniqueItems <= 0, totalRecordCount == nil {
            return false
        }
        if let totalRecordCount, nextStartIndex >= totalRecordCount {
            return false
        }
        if pageIndex >= maxPageIterations {
            return false
        }
        return true
    }

    private func fetchItems(session: EmbySession, sourceID: String, sourcePath: String, parentID: String?) async throws -> [MediaItem] {
        var imported: [MediaItem] = []
        var existingIDs = Set<String>()
        var syntheticSeriesCandidates: [String: EmbyItemDTO] = [:]
        var startIndex = 0
        var totalRecordCount: Int?
        // 防御：若服务器忽略 StartIndex/Limit（每次返回相同非空页）且不返回 TotalRecordCount，
        // 原循环 pageCount>0 恒真会无限翻页。用「绝对页数上限」+「连续页无新增去重项即中止」双闸。
        var pageIndex = 0

        repeat {
            pageIndex += 1
            let importedCountBeforePage = imported.count
            let payload = try await fetchItemPage(
                session: session,
                parentID: parentID,
                startIndex: startIndex,
                limit: pageSize
            )
            totalRecordCount = payload.TotalRecordCount
            let mappedItems = payload.Items.compactMap { dto in
                mediaItem(from: dto, session: session, sourceID: sourceID, sourcePath: sourcePath)
            }
            for item in mappedItems where existingIDs.insert(item.id).inserted {
                imported.append(item)
            }
            collectSyntheticSeriesCandidates(from: payload.Items, into: &syntheticSeriesCandidates)

            let pageCount = payload.Items.count
            let nextStartIndex = startIndex + pageCount
            guard Self.shouldContinueItemPagination(
                pageItemCount: pageCount,
                addedUniqueItems: imported.count - importedCountBeforePage,
                totalRecordCount: totalRecordCount,
                nextStartIndex: nextStartIndex,
                pageIndex: pageIndex,
                maxPageIterations: Self.maxItemPageIterations
            ) else {
                break
            }
            startIndex = nextStartIndex
        } while true

        imported.append(contentsOf: syntheticSeriesParents(
            from: syntheticSeriesCandidates,
            existingIDs: &existingIDs,
            sourceID: sourceID,
            sourcePath: sourcePath,
            session: session
        ))
        return imported
    }

    private func fetchItemPage(
        session: EmbySession,
        parentID: String?,
        startIndex: Int,
        limit: Int
    ) async throws -> EmbyItemsResponse {
        let itemsURL = session.serverURL
            .appendingPathComponent("Users")
            .appendingPathComponent(session.userID)
            .appendingPathComponent("Items")
        var components = URLComponents(url: itemsURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "IncludeItemTypes", value: "Movie,Series,Episode,Audio"),
            URLQueryItem(name: "Fields", value: "OriginalTitle,Overview,ProductionYear,RunTimeTicks,ParentId,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,CommunityRating,UserData,ImageTags,BackdropImageTags,MediaSources,MediaStreams,Path,PremiereDate,ProviderIds,Genres"),
            URLQueryItem(name: "StartIndex", value: "\(startIndex)"),
            URLQueryItem(name: "Limit", value: "\(limit)"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        if let parentID {
            queryItems.append(URLQueryItem(name: "ParentId", value: parentID))
        }
        components?.queryItems = queryItems
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: session.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
    }

    private func mediaItem(from dto: EmbyItemDTO, session: EmbySession, sourceID: String, sourcePath: String) -> MediaItem? {
        guard let type = mediaType(for: dto.type) else { return nil }
        let id = StableID.make(prefix: session.stableIDPrefix, value: "\(sourceID)-\(dto.Id)")
        let episodeParent = dto.SeriesId ?? dto.ParentId
        let parentID = episodeParent.map { StableID.make(prefix: session.stableIDPrefix, value: "\(sourceID)-\($0)") }
        let duration = dto.RunTimeTicks.map { Double($0) / 10_000_000.0 }
        let position = dto.UserData?.PlaybackPositionTicks.map { Double($0) / 10_000_000.0 } ?? 0
        let progress: Double
        if let duration, duration > 0 {
            progress = min(max(position / duration, 0), 1)
        } else {
            progress = (dto.UserData?.PlayedPercentage ?? 0) / 100
        }
        let stream = streamURL(for: dto, session: session)
        let mediaSource = dto.MediaSources?.first
        let videoStream = mediaSource?.MediaStreams?.first { $0.streamType.caseInsensitiveCompare("Video") == .orderedSame }
        let audioStream = mediaSource?.MediaStreams?.first { $0.streamType.caseInsensitiveCompare("Audio") == .orderedSame }
        let resolution: String?
        if let width = videoStream?.Width, let height = videoStream?.Height, width > 0, height > 0 {
            resolution = "\(width)x\(height)"
        } else {
            resolution = nil
        }

        return MediaItem(
            id: id,
            type: type,
            title: dto.Name,
            originalTitle: dto.OriginalTitle,
            artist: dto.Artists?.first,
            album: dto.Album,
            trackNumber: dto.IndexNumber,
            year: dto.ProductionYear,
            overview: dto.Overview,
            posterPath: posterURL(for: dto, session: session)?.absoluteString,
            backdropPath: dto.BackdropImageTags?.isEmpty == false
                ? backdropImageURL(itemID: dto.Id, index: 0, maxWidth: 1280, session: session)?.absoluteString
                : nil,
            rating: Self.normalizedProviderRating(dto.CommunityRating),
            userRating: Self.seedUserRating(from: dto.CommunityRating),
            runtime: duration.map { Int($0 / 60) },
            sourcePath: sourcePath,
            parentID: type == .episode ? parentID : nil,
            seasonNumber: dto.ParentIndexNumber,
            episodeNumber: type == .episode ? dto.IndexNumber : nil,
            filePath: stream?.absoluteString,
            fileSize: mediaSource?.Size,
            videoCodec: videoStream?.Codec,
            audioCodec: audioStream?.Codec,
            resolution: resolution,
            videoBitrate: mediaSource?.Bitrate ?? videoStream?.BitRate ?? videoStream?.Bitrate,
            duration: duration,
            playPosition: position,
            playProgress: progress,
            watched: dto.UserData?.Played ?? false,
            favorite: dto.UserData?.IsFavorite ?? false,
            externalID: dto.Id,
            metadataProvider: session.provider.displayName,
            lastPlayedAt: dto.UserData?.LastPlayedDate.flatMap(Self.parseEmbyDate),
            genre: (dto.Genres?.isEmpty == false) ? dto.Genres?.joined(separator: ", ") : nil
        )
    }

    private func mediaType(for embyType: String) -> MediaType? {
        switch embyType.lowercased() {
        case "movie":
            return .movie
        case "series":
            return .tvShow
        case "episode":
            return .episode
        case "audio":
            return .music
        default:
            return nil
        }
    }

    private func collectSyntheticSeriesCandidates(
        from dtos: [EmbyItemDTO],
        into seriesByID: inout [String: EmbyItemDTO]
    ) {
        for dto in dtos where dto.type.lowercased() == "episode" {
            guard let seriesID = dto.SeriesId,
                  let seriesName = dto.SeriesName,
                  !seriesID.isEmpty,
                  !seriesName.isEmpty else { continue }
            seriesByID[seriesID] = dto
        }
    }

    private func syntheticSeriesParents(
        from seriesByID: [String: EmbyItemDTO],
        existingIDs: inout Set<String>,
        sourceID: String,
        sourcePath: String,
        session: EmbySession
    ) -> [MediaItem] {
        return seriesByID.compactMap { seriesID, episodeDTO in
            let parentID = StableID.make(prefix: session.stableIDPrefix, value: "\(sourceID)-\(seriesID)")
            guard existingIDs.insert(parentID).inserted else { return nil }
            return MediaItem(
                id: parentID,
                type: .tvShow,
                title: episodeDTO.SeriesName ?? episodeDTO.Name,
                year: episodeDTO.ProductionYear,
                overview: nil,
                posterPath: imageURL(itemID: seriesID, session: session)?.absoluteString,
                rating: Self.normalizedProviderRating(episodeDTO.CommunityRating),
                userRating: Self.seedUserRating(from: episodeDTO.CommunityRating),
                sourcePath: sourcePath,
                externalID: seriesID,
                metadataProvider: session.provider.displayName,
                genre: (episodeDTO.Genres?.isEmpty == false) ? episodeDTO.Genres?.joined(separator: ", ") : nil
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func streamURL(for item: EmbyItemDTO, session: EmbySession) -> URL? {
        guard item.type.lowercased() == "movie" || item.type.lowercased() == "episode" || item.type.lowercased() == "audio" else {
            return nil
        }
        let mediaSource = item.MediaSources?.first
        let container = mediaSource?.Container?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let streamPath = container?.isEmpty == false ? "stream.\(container ?? "")" : "stream"
        let streamURL = session.serverURL
            .appendingPathComponent(item.type.lowercased() == "audio" ? "Audio" : "Videos")
            .appendingPathComponent(item.Id)
            .appendingPathComponent(streamPath)
        var components = URLComponents(url: streamURL, resolvingAgainstBaseURL: false)
        var queryItems = [
            URLQueryItem(name: "Static", value: "true"),
            URLQueryItem(name: "DeviceId", value: deviceIdentifier()),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        if let mediaSourceID = mediaSource?.Id, !mediaSourceID.isEmpty {
            queryItems.append(URLQueryItem(name: "MediaSourceId", value: mediaSourceID))
        }
        components?.queryItems = queryItems
        return components?.url
    }

    private func posterURL(for item: EmbyItemDTO, session: EmbySession) -> URL? {
        guard item.ImageTags?.Primary != nil else { return nil }
        return imageURL(itemID: item.Id, session: session)
    }

    private func imageURL(itemID: String, session: EmbySession) -> URL? {
        let imageURL = session.serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
            .appendingPathComponent("Images")
            .appendingPathComponent("Primary")
        var components = URLComponents(url: imageURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "700"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return components?.url
    }

    private func fetchItemDetail(
        session: EmbySession,
        itemID: String,
        fields: String = "MediaSources,MediaStreams"
    ) async throws -> EmbyItemDTO {
        let itemURL = session.serverURL
            .appendingPathComponent("Users")
            .appendingPathComponent(session.userID)
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
        var components = URLComponents(url: itemURL, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "Fields", value: fields),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        guard let url = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: url)
        request.setValue(authorizationHeader(accessToken: session.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")

        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(EmbyItemDTO.self, from: data)
    }

    /// 拉取 Emby 条目的详情扩展：演员（People）、艺术照（Backdrop/Primary 图）、外部 ID（Tmdb/Imdb）。
    /// 演员/艺术照用 Emby 自有数据；若带 Tmdb ProviderId，调用方可再补 TMDB「类似作品」。
    func fetchExtras(session: EmbySession, itemID: String) async throws -> EmbyDetailExtras {
        let dto = try await fetchItemDetail(
            session: session,
            itemID: itemID,
            fields: "People,ProviderIds,Overview,Genres,BackdropImageTags"
        )

        let people: [TMDBPerson] = (dto.People ?? []).prefix(28).compactMap { person in
            guard let name = person.Name, !name.isEmpty else { return nil }
            let role = person.Role?.isEmpty == false ? person.Role! : Self.localizedPersonType(person.personType)
            return TMDBPerson(
                id: person.Id.flatMap { Int($0) } ?? name.hashValue,
                stableID: "\(session.stableIDPrefix)-person-\(person.Id ?? String(name.hashValue))",
                name: name,
                role: role,
                profileURL: personImageURL(personID: person.Id, tag: person.PrimaryImageTag, session: session)?.absoluteString,
                category: ["actor", "gueststar"].contains((person.personType ?? "Actor").lowercased()) ? "cast" : "crew",
                department: person.personType
            )
        }
        let castTypes = Set(["actor", "gueststar"])
        let cast = people.filter { person in
            guard let dtoPerson = dto.People?.first(where: { ($0.Name ?? "") == person.name }) else { return true }
            return castTypes.contains((dtoPerson.personType ?? "Actor").lowercased())
        }
        let crew = people.filter { person in !cast.contains(where: { $0.id == person.id }) }

        var images: [TMDBImage] = []
        let backdropCount = dto.BackdropImageTags?.count ?? 0
        for index in 0..<backdropCount {
            guard let thumb = backdropImageURL(itemID: dto.Id, index: index, maxWidth: 500, session: session),
                  let full = backdropImageURL(itemID: dto.Id, index: index, maxWidth: 1280, session: session) else { continue }
            images.append(TMDBImage(
                id: "\(session.stableIDPrefix)-\(dto.Id)-backdrop-\(index)",
                thumbURL: thumb.absoluteString,
                fullURL: full.absoluteString,
                aspectRatio: 1.78,
                kind: "backdrop"
            ))
        }
        if dto.ImageTags?.Primary != nil,
           let thumb = primaryImageURL(itemID: dto.Id, maxWidth: 500, session: session),
           let full = primaryImageURL(itemID: dto.Id, maxWidth: 1280, session: session) {
            images.append(TMDBImage(
                id: "\(session.stableIDPrefix)-\(dto.Id)-primary",
                thumbURL: thumb.absoluteString,
                fullURL: full.absoluteString,
                aspectRatio: 0.67,
                kind: "poster"
            ))
        }

        let tmdbID = dto.ProviderIds?["Tmdb"] ?? dto.ProviderIds?["TmdbId"]
        let imdbID = dto.ProviderIds?["Imdb"] ?? dto.ProviderIds?["IMDB"]
        let tmdbKind = (dto.type.lowercased() == "movie") ? "movie" : "tv"

        return EmbyDetailExtras(cast: cast, crew: crew, images: images, tmdbID: tmdbID, tmdbKind: tmdbKind, imdbID: imdbID)
    }

    private func personImageURL(personID: String?, tag: String?, session: EmbySession) -> URL? {
        guard let personID, tag != nil else { return nil }
        let url = session.serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(personID)
            .appendingPathComponent("Images")
            .appendingPathComponent("Primary")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "185"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return components?.url
    }

    private func backdropImageURL(itemID: String, index: Int, maxWidth: Int, session: EmbySession) -> URL? {
        let url = session.serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
            .appendingPathComponent("Images")
            .appendingPathComponent("Backdrop")
            .appendingPathComponent("\(index)")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return components?.url
    }

    private func primaryImageURL(itemID: String, maxWidth: Int, session: EmbySession) -> URL? {
        let url = session.serverURL
            .appendingPathComponent("Items")
            .appendingPathComponent(itemID)
            .appendingPathComponent("Images")
            .appendingPathComponent("Primary")
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "maxWidth", value: "\(maxWidth)"),
            URLQueryItem(name: "quality", value: "90"),
            URLQueryItem(name: "api_key", value: session.accessToken)
        ]
        return components?.url
    }

    private static func localizedPersonType(_ type: String?) -> String {
        switch type {
        case "Actor": return "演员"
        case "Director": return "导演"
        case "Writer": return "编剧"
        case "Producer": return "制片"
        case "Composer", "GuestStar": return "演员"
        default: return type ?? "演员"
        }
    }

    private func sendAuthenticated(
        session: EmbySession,
        pathComponents: [String],
        method: String,
        body: Data? = nil
    ) async throws {
        var url = session.serverURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.queryItems = [URLQueryItem(name: "api_key", value: session.accessToken)]
        guard let requestURL = components?.url else {
            throw URLError(.badURL)
        }
        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.setValue(authorizationHeader(accessToken: session.accessToken), forHTTPHeaderField: "X-Emby-Authorization")
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if let body {
            request.httpBody = body
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, response) = try await HTTPClient.shared.data(for: request)
        try validate(response: response, data: data)
    }

    private func subtitleDownloadURL(session: EmbySession, stream: EmbySubtitleStream) -> URL? {
        if let deliveryURLString = stream.deliveryURLString,
           !deliveryURLString.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let url = URL(string: deliveryURLString, relativeTo: session.serverURL)?.absoluteURL
            return Self.urlByRefreshingAPIKey(url, baseURL: session.serverURL, accessToken: session.accessToken)
        }
        guard let mediaSourceID = stream.mediaSourceID else { return nil }
        let url = session.serverURL
            .appendingPathComponent("Videos")
            .appendingPathComponent(stream.itemID)
            .appendingPathComponent(mediaSourceID)
            .appendingPathComponent("Subtitles")
            .appendingPathComponent("\(stream.index)")
            .appendingPathComponent("Stream.\(stream.fileExtension)")
        return Self.urlByRefreshingAPIKey(url, baseURL: session.serverURL, accessToken: session.accessToken)
    }

    static func urlByRefreshingAPIKey(_ url: URL?, baseURL: URL, accessToken: String) -> URL? {
        RemoteResourceURLPolicy.authenticatedURL(
            url,
            baseURL: baseURL,
            tokenName: "api_key",
            tokenValue: accessToken
        )
    }

    static func mediaSourceID(from filePath: String?) -> String? {
        guard let filePath,
              let components = URLComponents(string: filePath) else { return nil }
        return components.queryItems?.first {
            $0.name.caseInsensitiveCompare("MediaSourceId") == .orderedSame
        }?.value
    }

    private static func subtitleFileExtension(for stream: EmbyMediaStreamDTO) -> String? {
        let deliveryExtension = stream.DeliveryUrl.flatMap { URL(string: $0)?.pathExtension.lowercased() }
        for value in [deliveryExtension, stream.Codec?.lowercased()] {
            switch value {
            case "srt", "subrip":
                return "srt"
            case "ass":
                return "ass"
            case "ssa":
                return "ssa"
            case "vtt", "webvtt":
                return "vtt"
            default:
                continue
            }
        }
        return stream.IsTextSubtitleStream == true ? "srt" : nil
    }

    static func ticks(from seconds: Double) -> Int64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return Int64((seconds * 10_000_000).rounded())
    }

    static func seedUserRating(from providerRating: Double?) -> Double? {
        guard let providerRating = normalizedProviderRating(providerRating) else { return nil }
        return min(max((providerRating / 2).rounded(), 1), 5)
    }

    static func normalizedProviderRating(_ providerRating: Double?) -> Double? {
        guard let providerRating, providerRating.isFinite, providerRating > 0, providerRating <= 10 else { return nil }
        return providerRating
    }

    private func normalizedServerURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if components?.scheme == nil {
            components?.scheme = "http"
        }
        if let path = components?.path, path.count > 1 {
            components?.path = path.hasSuffix("/") ? String(path.dropLast()) : path
        } else {
            components?.path = ""
        }
        return components?.url ?? url
    }

    private func authorizationHeader(accessToken: String?) -> String {
        var values = [
            #"Client="\#(clientName)""#,
            #"Device="\#(deviceName)""#,
            #"DeviceId="\#(deviceIdentifier())""#,
            #"Version="\#(version)""#
        ]
        if let accessToken {
            values.append(#"Token="\#(accessToken)""#)
        }
        return "MediaBrowser " + values.joined(separator: ", ")
    }

    func deviceIdentifier() -> String {
        if let existing = deviceIDDefaults.string(forKey: "MediaLib.emby.deviceID") {
            return existing
        }
        let generated = UUID().uuidString
        deviceIDDefaults.set(generated, forKey: "MediaLib.emby.deviceID")
        return generated
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            if let reason = Self.clientRestrictionReason(statusCode: http.statusCode, data: data, response: http) {
                throw EmbyServiceError.clientRestricted(statusCode: http.statusCode, reason: reason)
            }
            if http.statusCode == 401 || http.statusCode == 403 {
                throw EmbyServiceError.authenticationExpired
            }
            throw EmbyServiceError.requestFailed(statusCode: http.statusCode)
        }
    }

    /// 判定一次失败响应是否为「受限客户端」拒绝。返回非 nil 表示是，并附带可读原因。
    /// 命中条件：含白名单/禁止类关键字、HTTP 451、HTTP 403、或返回了 HTML 错误页。
    private static func clientRestrictionReason(statusCode: Int, data: Data, response: HTTPURLResponse) -> String? {
        let body = String(data: data.prefix(8192), encoding: .utf8)?.lowercased() ?? ""
        let keywords = [
            "whitelist", "not whitelisted", "client not allowed", "client is not allowed",
            "unsupported client", "unsupported device", "forbidden", "access denied",
            "not allowed", "client blocked", "blocked client"
        ]
        let matchedKeyword = keywords.first { body.contains($0) }
        let contentType = (response.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
        let looksLikeHTML = contentType.contains("text/html") || body.contains("<html")

        if statusCode == 451 {
            return matchedKeyword.map { "服务器返回 451 且包含关键字「\($0)」" }
                ?? "服务器返回 HTTP 451（通常表示访问被策略拦截）"
        }
        if statusCode == 403 {
            return matchedKeyword.map { "服务器返回 403 且包含关键字「\($0)」" }
                ?? "服务器返回 HTTP 403 Forbidden"
        }
        if let matchedKeyword {
            return "响应包含关键字「\(matchedKeyword)」（HTTP \(statusCode)）"
        }
        if looksLikeHTML {
            return "服务器返回了非标准的 HTML 错误页（HTTP \(statusCode)）"
        }
        return nil
    }

    private static func parseEmbyDate(_ value: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) {
            return date
        }
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: value)
    }
}

private struct EmbyPlaybackReportRequest: Encodable {
    let ItemId: String
    let MediaSourceId: String?
    let PlaySessionId: String
    let PositionTicks: Int64
    let RunTimeTicks: Int64?
    let IsPaused: Bool
    let PlayMethod: String
}

private struct EmbyLoginRequest: Encodable {
    let Username: String
    let Pw: String
}

private struct EmbyLoginResponse: Decodable {
    let User: EmbyUserDTO
    let AccessToken: String
}

private struct EmbyUserDTO: Decodable {
    let Id: String
    let Name: String?
}

private struct EmbyItemsResponse: Decodable {
    let Items: [EmbyItemDTO]
    let TotalRecordCount: Int?
}

private struct EmbyItemDTO: Decodable {
    let Id: String
    let Name: String
    let OriginalTitle: String?
    let type: String
    let Overview: String?
    let ProductionYear: Int?
    let RunTimeTicks: Int64?
    let ParentId: String?
    let SeriesId: String?
    let SeriesName: String?
    let IndexNumber: Int?
    let ParentIndexNumber: Int?
    let CommunityRating: Double?
    let UserData: EmbyUserDataDTO?
    let ImageTags: EmbyImageTagsDTO?
    let Artists: [String]?
    let Album: String?
    let CollectionType: String?
    let MediaSources: [EmbyMediaSourceDTO]?
    let Genres: [String]?
    let People: [EmbyPersonDTO]?
    let ProviderIds: [String: String]?
    let BackdropImageTags: [String]?

    private enum CodingKeys: String, CodingKey {
        case Id
        case Name
        case OriginalTitle
        case type = "Type"
        case Overview
        case ProductionYear
        case RunTimeTicks
        case ParentId
        case SeriesId
        case SeriesName
        case IndexNumber
        case ParentIndexNumber
        case CommunityRating
        case UserData
        case ImageTags
        case Artists
        case Album
        case CollectionType
        case MediaSources
        case Genres
        case People
        case ProviderIds
        case BackdropImageTags
    }
}

private struct EmbyPersonDTO: Decodable {
    let Id: String?
    let Name: String?
    let Role: String?
    let personType: String?
    let PrimaryImageTag: String?

    private enum CodingKeys: String, CodingKey {
        case Id, Name, Role
        case personType = "Type"
        case PrimaryImageTag
    }
}

private struct EmbyUserDataDTO: Decodable {
    let PlaybackPositionTicks: Int64?
    let PlayedPercentage: Double?
    let IsFavorite: Bool?
    let Played: Bool?
    let LastPlayedDate: String?
}

private struct EmbyImageTagsDTO: Decodable {
    let Primary: String?
}

private struct EmbyMediaSourceDTO: Decodable {
    let Id: String?
    let Container: String?
    let Size: Int64?
    let Bitrate: Int64?
    let MediaStreams: [EmbyMediaStreamDTO]?
}

private struct EmbyMediaStreamDTO: Decodable {
    let streamType: String
    let Index: Int?
    let Codec: String?
    let Width: Int?
    let Height: Int?
    let BitRate: Int64?
    let Bitrate: Int64?
    let Language: String?
    let DisplayTitle: String?
    let IsExternal: Bool?
    let IsTextSubtitleStream: Bool?
    let DeliveryUrl: String?
    let DeliveryMethod: String?

    private enum CodingKeys: String, CodingKey {
        case streamType = "Type"
        case Index
        case Codec
        case Width
        case Height
        case BitRate
        case Bitrate
        case Language
        case DisplayTitle
        case IsExternal
        case IsTextSubtitleStream
        case DeliveryUrl
        case DeliveryMethod
    }
}
