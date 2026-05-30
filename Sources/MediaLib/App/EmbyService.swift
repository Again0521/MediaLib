import Foundation
import MediaLibCore

struct EmbySession {
    var serverURL: URL
    var username: String
    var userID: String
    var accessToken: String
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

struct EmbyService {
    private let clientName = "MediaLIB"
    private let deviceName = Host.current().localizedName ?? "Mac"
    private let version = "1.0.0"
    private let pageSize = 300

    func authenticate(serverURL: URL, username: String, password: String) async throws -> EmbySession {
        let baseURL = normalizedServerURL(serverURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("Users/AuthenticateByName"))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(authorizationHeader(accessToken: nil), forHTTPHeaderField: "X-Emby-Authorization")
        request.httpBody = try JSONEncoder().encode(EmbyLoginRequest(Username: username, Pw: password))

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        let payload = try JSONDecoder().decode(EmbyLoginResponse.self, from: data)
        return EmbySession(
            serverURL: baseURL,
            username: payload.User.Name ?? username,
            userID: payload.User.Id,
            accessToken: payload.AccessToken
        )
    }

    func fetchItems(session: EmbySession, sourceID: String, sourcePath: String) async throws -> [MediaItem] {
        let libraries = try await fetchLibraries(session: session, sourceID: sourceID, sourceName: session.serverURL.host ?? "Emby")
        guard !libraries.isEmpty else {
            return try await fetchItems(session: session, sourceID: sourceID, sourcePath: sourcePath, parentID: nil)
        }

        var imported: [MediaItem] = []
        var seen = Set<String>()
        for library in libraries {
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

        let (data, response) = try await URLSession.shared.data(for: request)
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

    static func librarySourcePath(base: String, library: EmbyLibrarySummary) -> String {
        let encodedName = library.name.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? library.name
        let encodedType = (library.collectionType ?? "mixed").addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? "mixed"
        return "\(base)/library/\(library.viewID)/type/\(encodedType)/name/\(encodedName)"
    }

    static func sourceRootPath(from librarySourcePath: String) -> String? {
        guard let range = librarySourcePath.range(of: "/library/") else {
            return librarySourcePath.hasPrefix("emby://") ? librarySourcePath : nil
        }
        return String(librarySourcePath[..<range.lowerBound])
    }

    static func libraryInfo(from sourcePath: String) -> (id: String, name: String?, collectionType: String?)? {
        guard sourcePath.hasPrefix("emby://"),
              let range = sourcePath.range(of: "/library/") else { return nil }
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

    private func fetchItems(session: EmbySession, sourceID: String, sourcePath: String, parentID: String?) async throws -> [MediaItem] {
        var imported: [MediaItem] = []
        var existingIDs = Set<String>()
        var syntheticSeriesCandidates: [String: EmbyItemDTO] = [:]
        var startIndex = 0
        var totalRecordCount: Int?

        repeat {
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
            guard pageCount > 0 else { break }
            startIndex += pageCount
            if let totalRecordCount, startIndex >= totalRecordCount {
                break
            }
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
            URLQueryItem(name: "Fields", value: "Overview,ProductionYear,RunTimeTicks,ParentId,SeriesId,SeriesName,IndexNumber,ParentIndexNumber,CommunityRating,UserData,ImageTags,MediaSources,MediaStreams,Path,PremiereDate,ProviderIds,Genres"),
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

        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response, data: data)
        return try JSONDecoder().decode(EmbyItemsResponse.self, from: data)
    }

    private func mediaItem(from dto: EmbyItemDTO, session: EmbySession, sourceID: String, sourcePath: String) -> MediaItem? {
        guard let type = mediaType(for: dto.type) else { return nil }
        let id = StableID.make(prefix: "emby", value: "\(sourceID)-\(dto.Id)")
        let episodeParent = dto.SeriesId ?? dto.ParentId
        let parentID = episodeParent.map { StableID.make(prefix: "emby", value: "\(sourceID)-\($0)") }
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
            artist: dto.Artists?.first,
            album: dto.Album,
            trackNumber: dto.IndexNumber,
            year: dto.ProductionYear,
            overview: dto.Overview,
            posterPath: posterURL(for: dto, session: session)?.absoluteString,
            rating: dto.CommunityRating,
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
            metadataProvider: "Emby",
            lastPlayedAt: dto.UserData?.LastPlayedDate.flatMap(Self.parseEmbyDate)
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
            let parentID = StableID.make(prefix: "emby", value: "\(sourceID)-\(seriesID)")
            guard existingIDs.insert(parentID).inserted else { return nil }
            return MediaItem(
                id: parentID,
                type: .tvShow,
                title: episodeDTO.SeriesName ?? episodeDTO.Name,
                year: episodeDTO.ProductionYear,
                overview: nil,
                posterPath: imageURL(itemID: seriesID, session: session)?.absoluteString,
                sourcePath: sourcePath,
                externalID: seriesID,
                metadataProvider: "Emby"
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
        let streamURL = session.serverURL
            .appendingPathComponent(item.type.lowercased() == "audio" ? "Audio" : "Videos")
            .appendingPathComponent(item.Id)
            .appendingPathComponent(container?.isEmpty == false ? "stream.\(container!)" : "stream")
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

    private func deviceIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: "MediaLib.emby.deviceID") {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: "MediaLib.emby.deviceID")
        return generated
    }

    private func validate(response: URLResponse, data: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(http.statusCode) else {
            throw NSError(
                domain: "MediaLib.Emby",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Emby 请求失败（HTTP \(http.statusCode)），请检查服务器地址和登录信息。"]
            )
        }
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

    private enum CodingKeys: String, CodingKey {
        case Id
        case Name
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
    let Codec: String?
    let Width: Int?
    let Height: Int?
    let BitRate: Int64?
    let Bitrate: Int64?

    private enum CodingKeys: String, CodingKey {
        case streamType = "Type"
        case Codec
        case Width
        case Height
        case BitRate
        case Bitrate
    }
}
