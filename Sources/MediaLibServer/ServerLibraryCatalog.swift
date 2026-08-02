import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 服务端资料库读取边界。它在映射安全 DTO 或文件引用之前同时执行保险库排除、
/// 用户角色与逐资料库授权，路由层永远不会接触未授权的 `MediaItem` 或本地路径。
final class ServerLibraryCatalog {
    private let mediaRepository: MediaRepository
    private let sourceRepository: SourceRepository
    private let userMediaStateRepository: ServerUserMediaStateRepository
    private let userMediaPreferenceRepository: ServerUserMediaPreferenceRepository
    private let userQueueRepository: ServerUserQueueRepository

    init(database: DatabaseManager) {
        self.mediaRepository = MediaRepository(database: database)
        self.sourceRepository = SourceRepository(database: database)
        self.userMediaStateRepository = ServerUserMediaStateRepository(database: database)
        self.userMediaPreferenceRepository = ServerUserMediaPreferenceRepository(database: database)
        self.userQueueRepository = ServerUserQueueRepository(database: database)
    }

    func snapshot(for principal: ServerRequestPrincipal) throws -> ServerLibrarySnapshot {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerLibrarySnapshot(
                summary: ServerLibrarySummary(totalItemCount: 0, countsByType: [:]),
                items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
            )
        }
        let home = try mediaRepository.fetchServerLibraryHome(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        )
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: home.items.map(\.id))
        let preferences = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaIDs: home.items.map(\.id))
        let cards = home.items.map {
                ServerLibraryItem(
                    id: $0.id,
                    type: $0.type.rawValue,
                    title: $0.cardTitle,
                    year: $0.year,
                    artworkAvailable: $0.posterPath?.isEmpty == false,
                    isSeries: Self.isSeriesContainer($0),
                    userState: states[$0.id].map(Self.protocolState),
                    userPreference: preferences[$0.id].map(Self.protocolPreference) ?? .empty
                )
            }
        return ServerLibrarySnapshot(
            summary: ServerLibrarySummary(
                totalItemCount: home.totalItemCount,
                countsByType: home.countsByType
            ),
            items: ServerLibraryItemsResponse(totalItemCount: cards.count, items: cards)
        )
    }

    func categories(for principal: ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse {
        guard principal.permissions.contains(.viewMedia) else { return ServerLibraryCategoriesResponse(categories: []) }
        let summary = try mediaRepository.fetchServerLibraryHome(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            cardLimit: 1
        )
        let categories = MediaType.allCases.compactMap { type -> ServerLibraryCategory? in
            guard type != .privateCollection,
                  type != .auto,
                  let count = summary.countsByType[type.rawValue],
                  count > 0
            else { return nil }
            return ServerLibraryCategory(id: type.rawValue, title: type.displayName, itemCount: count)
        }
        return ServerLibraryCategoriesResponse(categories: categories)
    }

    func browse(_ query: ServerLibraryQuery, for principal: ServerRequestPrincipal) throws -> ServerLibraryItemsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
        }
        let type = query.type.flatMap(MediaType.init(rawValue:))
        let playbackFilter: ServerLibraryUserStateFilter? = switch query.playbackFilter {
        case .inProgress: .inProgress
        case .watched: .watched
        case .unwatched: .unwatched
        case .history: .history
        case nil: nil
        }
        let preferenceFilter: ServerLibraryUserPreferenceFilter? = switch query.preferenceFilter {
        case .favorite: .favorite
        case .watchlist: .watchlist
        case .rated: .rated
        case nil: nil
        }
        // 只有 history 查询连接当前用户状态表，才允许按该表的最近播放时间排序；
        // 其他受限请求即使携带该安全枚举也降级为资料更新时间，避免引用不存在的 SQL 别名。
        let sort: ServerLibraryDatabaseSort = query.playbackFilter == .history && query.sort == .lastPlayedDescending
            ? .lastPlayedDescending
            : databaseSort(query.sort)
        let databasePage = try mediaRepository.fetchServerLibraryPage(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            type: type,
            topLevelOnly: type == nil && playbackFilter == nil && preferenceFilter == nil,
            searchText: query.searchText,
            offset: query.offset,
            limit: query.limit,
            sort: sort,
            userID: principal.userID,
            playbackFilter: playbackFilter,
            preferenceFilter: preferenceFilter
        )
        let pageItems = databasePage.items
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: pageItems.map(\.id))
        let preferences = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaIDs: pageItems.map(\.id))
        let cards = pageItems.map { item in
            ServerLibraryItem(
                id: item.id,
                type: item.type.rawValue,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体",
                year: item.year,
                artworkAvailable: item.posterPath?.isEmpty == false,
                isSeries: Self.isSeriesContainer(item),
                userState: states[item.id].map(Self.protocolState),
                userPreference: preferences[item.id].map(Self.protocolPreference) ?? .empty
            )
        }
        return ServerLibraryItemsPage(
            totalItemCount: databasePage.totalItemCount,
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
        let canDirectPlay = hasReadableAsset && isPlayable
        let episodeNavigation = try authorizedEpisodeNavigation(for: item, principal: principal)
        let userState = try userMediaStateRepository.fetch(userID: principal.userID, mediaID: item.id)
        let userPreference = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaID: item.id)
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
            canTranscode: false,
            previousEpisode: episodeNavigation.previous,
            nextEpisode: episodeNavigation.next,
            userState: userState.map(Self.protocolState),
            userPreference: userPreference.map(Self.protocolPreference) ?? .empty
        )
    }

    func seriesDetail(id: String, for principal: ServerRequestPrincipal) throws -> ServerSeriesDetail? {
        guard principal.permissions.contains(.viewMedia),
              let overview = try mediaRepository.fetchServerSeriesOverview(
                allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
                seriesID: id,
                userID: principal.userID
              )
        else { return nil }
        let item = overview.series
        let preference = try userMediaPreferenceRepository.fetch(userID: principal.userID, mediaID: item.id)
        let seasons = overview.seasons.map { season in
            let title: String
            let seasonID: String
            if let number = season.seasonNumber {
                title = number == 0 ? "特别篇" : "第 \(number) 季"
                seasonID = "season-\(number)"
            } else {
                title = "未分季"
                seasonID = "unspecified"
            }
            return ServerSeriesSeason(
                id: seasonID,
                seasonNumber: season.seasonNumber,
                title: title,
                episodeCount: season.episodeCount,
                watchedCount: season.watchedCount,
                inProgressCount: season.inProgressCount
            )
        }
        return ServerSeriesDetail(
            id: item.id,
            type: item.type.rawValue,
            title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名系列",
            originalTitle: Self.boundedText(item.originalTitle, maximumLength: 512),
            year: item.year,
            overview: Self.boundedText(item.overview, maximumLength: 8_000),
            genres: Self.genres(item.genre),
            communityRating: item.rating,
            artworkAvailable: item.posterPath?.isEmpty == false,
            backdropAvailable: item.backdropPath?.isEmpty == false,
            totalEpisodeCount: overview.totalEpisodeCount,
            seasons: seasons,
            userPreference: preference.map(Self.protocolPreference) ?? .empty
        )
    }

    func seriesEpisodes(
        id: String,
        season: ServerSeriesSeasonSelector,
        offset: Int,
        limit: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerSeriesEpisodesPage? {
        guard principal.permissions.contains(.viewMedia) else { return nil }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        guard
              try mediaRepository.fetchServerSeriesOverview(
                allowedSourcePaths: allowedSourcePaths,
                seriesID: id,
                userID: principal.userID
              ) != nil
        else { return nil }
        let page = try mediaRepository.fetchServerSeriesEpisodePage(
            allowedSourcePaths: allowedSourcePaths,
            seriesID: id,
            season: season,
            offset: offset,
            limit: limit
        )
        let states = try userMediaStateRepository.fetch(userID: principal.userID, mediaIDs: page.items.map(\.id))
        let items = page.items.map { item in
            let runtimeSeconds: Double? = {
                if let duration = item.duration, duration.isFinite, duration >= 0 { return duration }
                if let runtime = item.runtime, runtime >= 0 { return Double(runtime) * 60 }
                return nil
            }()
            return ServerSeriesEpisode(
                id: item.id,
                title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名剧集",
                seasonNumber: item.seasonNumber,
                episodeNumber: item.episodeNumber,
                runtimeSeconds: runtimeSeconds,
                artworkAvailable: item.posterPath?.isEmpty == false,
                userState: states[item.id].map(Self.protocolState)
            )
        }
        return ServerSeriesEpisodesPage(
            totalItemCount: page.totalItemCount,
            offset: offset,
            limit: min(max(limit, 1), 100),
            items: items
        )
    }

    func people(searchText: String?, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerPeoplePage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let page = try mediaRepository.fetchServerPeoplePage(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            searchText: searchText,
            offset: offset,
            limit: limit
        )
        return ServerPeoplePage(
            totalItemCount: page.totalItemCount,
            offset: offset,
            limit: min(max(limit, 1), 100),
            items: page.items.map {
                ServerPersonCard(
                    id: $0.id,
                    name: Self.boundedText($0.name, maximumLength: 512) ?? "未命名人物",
                    department: Self.boundedText($0.department, maximumLength: 128),
                    mediaCount: $0.mediaCount
                )
            }
        )
    }

    func personDetail(id: String, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerPersonDetail? {
        guard principal.permissions.contains(.viewMedia) else { return nil }
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: .viewMedia)
        guard let profile = try mediaRepository.fetchServerPersonProfile(
            allowedSourcePaths: allowedSourcePaths,
            personID: id
        ) else { return nil }
        let credits = try mediaRepository.fetchServerPersonCreditsPage(
            allowedSourcePaths: allowedSourcePaths,
            personID: id,
            offset: offset,
            limit: limit
        )
        return ServerPersonDetail(
            id: profile.id,
            name: Self.boundedText(profile.name, maximumLength: 512) ?? "未命名人物",
            biography: Self.boundedText(profile.biography, maximumLength: 8_000),
            birthday: Self.boundedText(profile.birthday, maximumLength: 64),
            deathday: Self.boundedText(profile.deathday, maximumLength: 64),
            placeOfBirth: Self.boundedText(profile.placeOfBirth, maximumLength: 256),
            department: Self.boundedText(profile.department, maximumLength: 128),
            credits: ServerPeopleCreditsPage(
                totalItemCount: credits.totalItemCount,
                offset: offset,
                limit: min(max(limit, 1), 100),
                items: credits.items.map { credit in
                    ServerPersonCredit(
                        id: credit.media.id,
                        type: credit.media.type.rawValue,
                        title: Self.boundedText(credit.media.cardTitle, maximumLength: 512) ?? "未命名媒体",
                        year: credit.media.year,
                        artworkAvailable: credit.media.posterPath?.isEmpty == false,
                        isSeries: Self.isSeriesContainer(credit.media),
                        category: Self.boundedText(credit.category, maximumLength: 64) ?? "cast",
                        role: Self.boundedText(credit.role, maximumLength: 256)
                    )
                }
            )
        )
    }

    func collections(offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerCollectionsPage {
        guard principal.permissions.contains(.viewMedia) else {
            return ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: [])
        }
        let page = try mediaRepository.fetchServerManualCollectionsPage(
            allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
            offset: offset, limit: limit
        )
        return ServerCollectionsPage(
            totalItemCount: page.totalItemCount, offset: offset, limit: min(max(limit, 1), 100),
            items: page.items.map {
                ServerCollectionCard(id: $0.id, name: Self.boundedText($0.name, maximumLength: 512) ?? "未命名合集", mediaCount: $0.mediaCount)
            }
        )
    }

    func collectionDetail(id: String, offset: Int, limit: Int, for principal: ServerRequestPrincipal) throws -> ServerCollectionDetail? {
        guard principal.permissions.contains(.viewMedia),
              let detail = try mediaRepository.fetchServerManualCollectionDetail(
                allowedSourcePaths: try allowedPublicSourcePaths(for: principal, requiring: .viewMedia),
                collectionID: id, offset: offset, limit: limit
              ) else { return nil }
        return ServerCollectionDetail(
            id: detail.id, name: Self.boundedText(detail.name, maximumLength: 512) ?? "未命名合集",
            items: ServerCollectionItemsPage(
                totalItemCount: detail.totalItemCount, offset: offset, limit: min(max(limit, 1), 100),
                items: detail.items.map {
                    ServerCollectionMedia(
                        id: $0.id, type: $0.type.rawValue,
                        title: Self.boundedText($0.cardTitle, maximumLength: 512) ?? "未命名媒体",
                        year: $0.year, artworkAvailable: $0.posterPath?.isEmpty == false,
                        isSeries: Self.isSeriesContainer($0)
                    )
                }
            )
        )
    }

    func queue(for principal: ServerRequestPrincipal) throws -> ServerQueueResponse {
        guard principal.permissions.contains(.viewMedia) else { return ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) }
        let snapshot = try userQueueRepository.fetch(userID: principal.userID)
        let authorized = try publicItems(for: principal, requiring: .viewMedia)
        let byID = Dictionary(uniqueKeysWithValues: authorized.map { ($0.id, $0) })
        let items = snapshot.itemIDs.compactMap { id -> ServerQueueItem? in
            guard let item = byID[id] else { return nil }
            return ServerQueueItem(id: item.id, type: item.type.rawValue, title: Self.boundedText(item.cardTitle, maximumLength: 512) ?? "未命名媒体", year: item.year, artworkAvailable: item.posterPath?.isEmpty == false, isSeries: Self.isSeriesContainer(item))
        }
        return ServerQueueResponse(repeatMode: snapshot.repeatMode.rawValue, shuffleEnabled: snapshot.shuffleEnabled, currentPosition: min(snapshot.currentPosition, max(items.count - 1, 0)), items: items)
    }

    func mutateQueue(request: ServerQueueMutationRequest, for principal: ServerRequestPrincipal) throws -> ServerQueueResponse? {
        guard request.isValid, principal.permissions.contains(.viewMedia), let action = ServerQueueMutationAction(rawValue: request.action) else { return nil }
        if action == .add {
            guard let mediaID = request.mediaID,
                  try publicItems(for: principal, requiring: .playMedia).contains(where: { $0.id == mediaID }) else { return nil }
        }
        let repeatMode = request.repeatMode.flatMap(ServerQueueRepeatMode.init(rawValue:))
        guard request.repeatMode == nil || repeatMode != nil else { return nil }
        _ = try userQueueRepository.mutate(userID: principal.userID, action: action, mediaID: request.mediaID, fromIndex: request.fromIndex, toIndex: request.toIndex, repeatMode: repeatMode, shuffleEnabled: request.shuffleEnabled, currentPosition: request.currentPosition)
        return try queue(for: principal)
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

    func updatePreference(
        id: String,
        preference: ServerUserMediaPreferenceUpdate,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaUserPreference? {
        guard try publicItems(for: principal, requiring: .viewMedia).contains(where: { $0.id == id }) else {
            return nil
        }
        let record = try userMediaPreferenceRepository.update(
            userID: principal.userID,
            mediaID: id,
            preference: preference
        )
        return Self.protocolPreference(record)
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

    /// 浏览器原生字幕只交付同目录、同基名的外挂 WebVTT。这里不转换 SRT/ASS，
    /// 也不让调用方提供文件名或路径，避免字幕入口退化为任意文件读取。
    func webVTTSubtitleTracks(
        id: String,
        for principal: ServerRequestPrincipal
    ) throws -> [ServerWebVTTSubtitleTrack]? {
        guard let asset = try publicAsset(id: id, for: principal, requiring: .playMedia) else {
            return nil
        }
        return try Self.webVTTSubtitleAssets(for: asset).enumerated().map {
            ServerWebVTTSubtitleTrack(id: $0.offset, label: "字幕 \($0.offset + 1)")
        }
    }

    func publicWebVTTSubtitleAsset(
        id: String,
        trackID: Int,
        for principal: ServerRequestPrincipal
    ) throws -> ServerMediaAsset? {
        guard (0..<ServerWebVTTSubtitleTrack.maximumTrackCount).contains(trackID),
              let asset = try publicAsset(id: id, for: principal, requiring: .playMedia)
        else {
            return nil
        }
        let tracks = try Self.webVTTSubtitleAssets(for: asset)
        guard tracks.indices.contains(trackID) else { return nil }
        return tracks[trackID]
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
        let allowedSourcePaths = try allowedPublicSourcePaths(for: principal, requiring: permission)
        return try mediaRepository.fetchAll().filter { item in
            guard item.type != .privateCollection,
                  let sourcePath = item.sourcePath,
                  !sourcePath.isEmpty
            else {
                return false
            }
            return allowedSourcePaths.contains(sourcePath)
        }
    }

    private func allowedPublicSourcePaths(
        for principal: ServerRequestPrincipal,
        requiring permission: ServerPermission
    ) throws -> Set<String> {
        guard principal.permissions.contains(permission) else { return [] }
        let publicSources = try sourceRepository.fetchAll().filter { $0.mediaType != .privateCollection }
        if principal.canManageServer {
            return Set(publicSources.map(\.path).filter { !$0.isEmpty })
        }
        return Set(publicSources.compactMap { source in
            principal.allows(permission, libraryID: source.id) && !source.path.isEmpty ? source.path : nil
        })
    }

    private func authorizedEpisodeNavigation(
        for item: MediaItem,
        principal: ServerRequestPrincipal
    ) throws -> (previous: ServerEpisodeNavigation?, next: ServerEpisodeNavigation?) {
        guard item.type == .episode, let parentID = item.parentID, !parentID.isEmpty else {
            return (nil, nil)
        }
        let episodes = try publicItems(for: principal, requiring: .playMedia)
            .filter {
                $0.type == .episode &&
                    $0.parentID == parentID &&
                    $0.filePath.flatMap(Self.localReadableFileURL(from:)) != nil
            }
            .sorted {
                let leftSeason = $0.seasonNumber ?? Int.min
                let rightSeason = $1.seasonNumber ?? Int.min
                if leftSeason != rightSeason { return leftSeason < rightSeason }
                let leftEpisode = $0.episodeNumber ?? Int.min
                let rightEpisode = $1.episodeNumber ?? Int.min
                if leftEpisode != rightEpisode { return leftEpisode < rightEpisode }
                let titleOrder = $0.title.localizedCaseInsensitiveCompare($1.title)
                if titleOrder != .orderedSame { return titleOrder == .orderedAscending }
                return $0.id < $1.id
            }
        guard let index = episodes.firstIndex(where: { $0.id == item.id }) else { return (nil, nil) }
        func navigation(_ episode: MediaItem?) -> ServerEpisodeNavigation? {
            guard let episode else { return nil }
            return ServerEpisodeNavigation(
                id: episode.id,
                title: Self.boundedText(episode.cardTitle, maximumLength: 512) ?? "未命名剧集"
            )
        }
        return (
            navigation(index > episodes.startIndex ? episodes[index - 1] : nil),
            navigation(index + 1 < episodes.endIndex ? episodes[index + 1] : nil)
        )
    }

    private func databaseSort(_ sort: ServerLibrarySort) -> ServerLibraryDatabaseSort {
        switch sort {
        case .updatedDescending: return .updatedDescending
        case .titleAscending: return .titleAscending
        case .yearDescending: return .yearDescending
        case .lastPlayedDescending: return .updatedDescending
        }
    }

    private static func isSeriesContainer(_ item: MediaItem) -> Bool {
        switch item.type {
        case .tvShow, .anime, .variety:
            return true
        case .documentary:
            return item.filePath?.isEmpty != false
        default:
            return false
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

    private static func webVTTSubtitleAssets(for asset: ServerMediaAsset) throws -> [ServerMediaAsset] {
        let fileManager = FileManager.default
        let resolvedMediaURL = asset.fileURL.resolvingSymlinksInPath().standardizedFileURL
        let directory = resolvedMediaURL.deletingLastPathComponent()
        let stem = resolvedMediaURL.deletingPathExtension().lastPathComponent
        guard !stem.isEmpty else { return [] }
        let candidates = try fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        )
        return try candidates.compactMap { candidate -> ServerMediaAsset? in
            guard candidate.pathExtension.lowercased() == "vtt" else { return nil }
            let resolvedCandidate = candidate.resolvingSymlinksInPath().standardizedFileURL
            guard resolvedCandidate.deletingLastPathComponent() == directory else { return nil }
            let candidateStem = resolvedCandidate.deletingPathExtension().lastPathComponent
            guard candidateStem == stem || candidateStem.hasPrefix(stem + ".") else { return nil }
            let values = try resolvedCandidate.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0,
                  size <= ServerWebVTTSubtitleTrack.maximumByteLength
            else { return nil }
            return ServerMediaAsset(id: asset.id, fileURL: resolvedCandidate, byteLength: Int64(size))
        }
        .sorted { $0.fileURL.lastPathComponent.localizedStandardCompare($1.fileURL.lastPathComponent) == .orderedAscending }
        .prefix(ServerWebVTTSubtitleTrack.maximumTrackCount)
        .map { $0 }
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

    private static func protocolPreference(_ preference: ServerUserMediaPreferenceRecord) -> ServerMediaUserPreference {
        ServerMediaUserPreference(
            isFavorite: preference.isFavorite,
            isWatchlist: preference.isWatchlist,
            rating: preference.userRating
        )
    }
}

struct ServerLibrarySnapshot {
    let summary: ServerLibrarySummary
    let items: ServerLibraryItemsResponse
}

/// Web 专用的外挂字幕引用。ID 只是稳定排序后的有界序号，绝不携带文件名或路径。
struct ServerWebVTTSubtitleTrack: Codable, Equatable {
    static let maximumTrackCount = 16
    static let maximumByteLength = 8 * 1024 * 1024

    let id: Int
    let label: String
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
        case "vtt": return "text/vtt; charset=utf-8"
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
