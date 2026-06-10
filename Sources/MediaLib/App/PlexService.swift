import Foundation
import MediaLibCore

struct PlexSession {
    var serverURL: URL
    var accessToken: String
    var machineIdentifier: String?
    var serverName: String?
}

enum PlexServiceError: LocalizedError {
    case authenticationExpired
    case requestFailed(statusCode: Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .authenticationExpired:
            return "Plex Token 已失效，请重新连接 Plex。"
        case .requestFailed(let statusCode):
            return "Plex 请求失败（HTTP \(statusCode)），请检查服务器状态和网络连接。"
        case .invalidResponse:
            return "Plex 返回内容无法识别，请确认服务器地址和 Token。"
        }
    }
}

struct PlexService {
    private let clientName = "MediaLIB"
    private let version = "1.0.0"
    private let pageSize = 300

    func isAuthenticationFailure(_ error: Error) -> Bool {
        guard let error = error as? PlexServiceError else { return false }
        if case .authenticationExpired = error { return true }
        return false
    }

    func authenticate(serverURL: URL, token: String) async throws -> PlexSession {
        let baseURL = normalizedServerURL(serverURL)
        let provisional = PlexSession(serverURL: baseURL, accessToken: token)
        let root = try await fetchXML(session: provisional, pathComponents: ["identity"])
        let machineID = root.attributes["machineIdentifier"]
        let serverName = root.attributes["friendlyName"] ?? root.attributes["name"]
        return PlexSession(
            serverURL: baseURL,
            accessToken: token,
            machineIdentifier: machineID,
            serverName: serverName
        )
    }

    func validateSession(_ session: PlexSession) async throws {
        _ = try await fetchXML(session: session, pathComponents: ["identity"])
    }

    func fetchLibraries(session: PlexSession, sourceID: String, sourceName: String) async throws -> [EmbyLibrarySummary] {
        let root = try await fetchXML(session: session, pathComponents: ["library", "sections"])
        return root.children(named: "Directory").compactMap { node in
            guard let key = node.attributes["key"], !key.isEmpty else { return nil }
            let type = node.attributes["type"]
            return EmbyLibrarySummary(
                id: key,
                sourceID: sourceID,
                viewID: key,
                name: node.attributes["title"] ?? "Plex 媒体库",
                collectionType: collectionType(for: type),
                sourceName: sourceName
            )
        }
    }

    func fetchItems(
        session: PlexSession,
        sourceID: String,
        sourcePath: String,
        selectedLibraryIDs: Set<String> = []
    ) async throws -> [MediaItem] {
        let libraries = try await fetchLibraries(
            session: session,
            sourceID: sourceID,
            sourceName: session.serverName ?? session.serverURL.host ?? "Plex"
        )
        let syncLibraries = selectedLibraryIDs.isEmpty
            ? libraries
            : libraries.filter { selectedLibraryIDs.contains($0.viewID) || selectedLibraryIDs.contains($0.id) }
        guard !syncLibraries.isEmpty else { return [] }

        var imported: [MediaItem] = []
        var seen = Set<String>()
        var syntheticSeriesCandidates: [String: PlexXMLNode] = [:]

        for library in syncLibraries {
            let libraryPath = EmbyService.librarySourcePath(base: sourcePath, library: library)
            let metadataNodes = try await fetchMetadataNodes(session: session, library: library)
            for node in metadataNodes {
                if let item = mediaItem(from: node, session: session, sourceID: sourceID, sourcePath: libraryPath),
                   seen.insert(item.id).inserted {
                    imported.append(item)
                }
                if node.plexType == "episode",
                   let seriesID = node.attributes["grandparentRatingKey"] ?? node.attributes["parentRatingKey"],
                   !seriesID.isEmpty {
                    syntheticSeriesCandidates[seriesID] = node
                }
            }
        }

        for item in syntheticSeriesParents(
            from: syntheticSeriesCandidates,
            existingIDs: &seen,
            sourceID: sourceID,
            sourcePathByLibraryID: Dictionary(uniqueKeysWithValues: syncLibraries.map {
                ($0.viewID, EmbyService.librarySourcePath(base: sourcePath, library: $0))
            }),
            session: session
        ) {
            imported.append(item)
        }

        return imported
    }

    func refreshedResourceURLString(_ value: String?, session: PlexSession) -> String? {
        guard let value,
              var components = URLComponents(string: value),
              components.url?.host == session.serverURL.host else { return value }
        var queryItems = components.queryItems ?? []
        queryItems.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
        queryItems.append(URLQueryItem(name: "X-Plex-Token", value: session.accessToken))
        components.queryItems = queryItems
        return components.string ?? value
    }

    func reportPlayback(session: PlexSession, itemID: String, phase: EmbyPlaybackPhase, position: Double, isPaused: Bool) async throws {
        let state: String
        switch phase {
        case .started:
            state = "playing"
        case .progress:
            state = isPaused ? "paused" : "playing"
        case .stopped:
            state = "stopped"
        }
        try await sendPlexCommand(
            session: session,
            pathComponents: [":", "progress"],
            queryItems: [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library"),
                URLQueryItem(name: "time", value: "\(max(Int(position * 1000), 0))"),
                URLQueryItem(name: "state", value: state)
            ]
        )
    }

    func setPlayed(session: PlexSession, itemID: String, played: Bool) async throws {
        try await sendPlexCommand(
            session: session,
            pathComponents: [":", played ? "scrobble" : "unscrobble"],
            queryItems: [
                URLQueryItem(name: "key", value: itemID),
                URLQueryItem(name: "identifier", value: "com.plexapp.plugins.library")
            ]
        )
    }

    private func fetchMetadataNodes(session: PlexSession, library: EmbyLibrarySummary) async throws -> [PlexXMLNode] {
        switch library.collectionType?.lowercased() {
        case "movies":
            return try await fetchAllMetadataPages(session: session, libraryKey: library.viewID, typeCode: 1)
        case "tvshows":
            let shows = try await fetchAllMetadataPages(session: session, libraryKey: library.viewID, typeCode: 2)
            let episodes = try await fetchAllMetadataPages(session: session, libraryKey: library.viewID, typeCode: 4)
            return shows + episodes
        case "music":
            return try await fetchAllMetadataPages(session: session, libraryKey: library.viewID, typeCode: 10)
        default:
            return try await fetchAllMetadataPages(session: session, libraryKey: library.viewID, typeCode: nil)
        }
    }

    private func fetchAllMetadataPages(session: PlexSession, libraryKey: String, typeCode: Int?) async throws -> [PlexXMLNode] {
        var start = 0
        var nodes: [PlexXMLNode] = []
        while true {
            let page = try await fetchMetadataPage(session: session, libraryKey: libraryKey, typeCode: typeCode, start: start)
            nodes.append(contentsOf: page.nodes)
            guard page.count > 0 else { break }
            start += page.count
            if let total = page.totalSize, start >= total { break }
            if page.count < pageSize { break }
        }
        return nodes
    }

    private func fetchMetadataPage(
        session: PlexSession,
        libraryKey: String,
        typeCode: Int?,
        start: Int
    ) async throws -> (nodes: [PlexXMLNode], count: Int, totalSize: Int?) {
        var queryItems: [URLQueryItem] = []
        if let typeCode {
            queryItems.append(URLQueryItem(name: "type", value: "\(typeCode)"))
        }
        let root = try await fetchXML(
            session: session,
            pathComponents: ["library", "sections", libraryKey, "all"],
            queryItems: queryItems,
            rangeStart: start,
            rangeSize: pageSize
        )
        let nodes = root.children.filter { $0.name == "Video" || $0.name == "Directory" || $0.name == "Track" }
        let totalSize = root.attributes["totalSize"].flatMap(Int.init)
        return (nodes, nodes.count, totalSize)
    }

    private func mediaItem(from node: PlexXMLNode, session: PlexSession, sourceID: String, sourcePath: String) -> MediaItem? {
        guard let type = mediaType(for: node) else { return nil }
        guard let ratingKey = node.attributes["ratingKey"], !ratingKey.isEmpty else { return nil }

        let id = StableID.make(prefix: "plex", value: "\(sourceID)-\(ratingKey)")
        let parentRatingKey = node.attributes["grandparentRatingKey"] ?? node.attributes["parentRatingKey"]
        let parentID = parentRatingKey.map { StableID.make(prefix: "plex", value: "\(sourceID)-\($0)") }
        let duration = Self.durationSeconds(from: node)
        let position = Self.milliseconds(node.attributes["viewOffset"]).map { Double($0) / 1000.0 } ?? 0
        let progress = duration.map { $0 > 0 ? min(max(position / $0, 0), 1) : 0 } ?? 0
        let media = node.firstChild(named: "Media")
        let part = media?.firstChild(named: "Part")
        let width = Self.int(media?.attributes["width"])
        let height = Self.int(media?.attributes["height"])
        let resolution = (width.flatMap { width in height.map { "\(width)x\($0)" } })
        let streamURL = part?.attributes["key"].flatMap { mediaURL(relativeOrAbsolutePath: $0, session: session) }
        let rating = Self.double(node.attributes["audienceRating"]) ?? Self.double(node.attributes["rating"])
        let userRating = Self.double(node.attributes["userRating"]).map { min(max($0 / 2.0, 0), 5) }
            ?? Self.seedUserRating(from: rating)

        return MediaItem(
            id: id,
            type: type,
            title: node.attributes["title"] ?? node.attributes["grandparentTitle"] ?? "Plex 媒体",
            artist: node.attributes["grandparentTitle"] ?? node.attributes["originalTitle"],
            album: node.attributes["parentTitle"],
            trackNumber: Self.int(node.attributes["index"]),
            year: Self.int(node.attributes["year"]) ?? Self.year(from: node.attributes["originallyAvailableAt"]),
            overview: node.attributes["summary"],
            posterPath: posterURLString(for: node, session: session),
            rating: rating,
            userRating: userRating,
            runtime: duration.map { Int($0 / 60.0) },
            sourcePath: sourcePath,
            parentID: type == .episode ? parentID : nil,
            seasonNumber: Self.int(node.attributes["parentIndex"]),
            episodeNumber: type == .episode ? Self.int(node.attributes["index"]) : nil,
            filePath: streamURL,
            fileSize: Self.int64(part?.attributes["size"]),
            videoCodec: media?.attributes["videoCodec"],
            audioCodec: media?.attributes["audioCodec"],
            resolution: resolution,
            videoBitrate: Self.int64(media?.attributes["bitrate"]).map { $0 * 1000 },
            duration: duration,
            playPosition: position,
            playProgress: progress,
            watched: (Self.int(node.attributes["viewCount"]) ?? 0) > 0,
            favorite: false,
            externalID: ratingKey,
            metadataProvider: "Plex",
            lastPlayedAt: Self.date(fromUnixSeconds: node.attributes["lastViewedAt"]),
            genre: node.children(named: "Genre").compactMap { $0.attributes["tag"] }.joined(separator: ", ").nilIfEmpty
        )
    }

    private func syntheticSeriesParents(
        from seriesByID: [String: PlexXMLNode],
        existingIDs: inout Set<String>,
        sourceID: String,
        sourcePathByLibraryID: [String: String],
        session: PlexSession
    ) -> [MediaItem] {
        seriesByID.compactMap { seriesID, episode in
            let id = StableID.make(prefix: "plex", value: "\(sourceID)-\(seriesID)")
            guard existingIDs.insert(id).inserted else { return nil }
            let libraryID = episode.attributes["librarySectionID"] ?? episode.attributes["librarySectionKey"] ?? ""
            let sourcePath = sourcePathByLibraryID[libraryID] ?? sourcePathByLibraryID.values.first ?? "plex://unknown/\(sourceID)"
            let rating = Self.double(episode.attributes["audienceRating"]) ?? Self.double(episode.attributes["rating"])
            return MediaItem(
                id: id,
                type: .tvShow,
                title: episode.attributes["grandparentTitle"] ?? episode.attributes["title"] ?? "Plex 剧集",
                year: Self.int(episode.attributes["year"]) ?? Self.year(from: episode.attributes["originallyAvailableAt"]),
                overview: nil,
                posterPath: (episode.attributes["grandparentThumb"] ?? episode.attributes["thumb"]).flatMap {
                    mediaURL(relativeOrAbsolutePath: $0, session: session)
                },
                rating: rating,
                userRating: Self.seedUserRating(from: rating),
                sourcePath: sourcePath,
                externalID: seriesID,
                metadataProvider: "Plex",
                genre: episode.children(named: "Genre").compactMap { $0.attributes["tag"] }.joined(separator: ", ").nilIfEmpty
            )
        }
        .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    private func fetchXML(
        session: PlexSession,
        pathComponents: [String],
        queryItems: [URLQueryItem] = [],
        rangeStart: Int? = nil,
        rangeSize: Int? = nil
    ) async throws -> PlexXMLNode {
        let url = try requestURL(session: session, pathComponents: pathComponents, queryItems: queryItems)
        var request = URLRequest(url: url)
        addHeaders(to: &request, session: session)
        if let rangeStart {
            request.setValue("\(rangeStart)", forHTTPHeaderField: "X-Plex-Container-Start")
        }
        if let rangeSize {
            request.setValue("\(rangeSize)", forHTTPHeaderField: "X-Plex-Container-Size")
        }
        let (data, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
        return try PlexXMLTreeParser.parse(data: data)
    }

    private func sendPlexCommand(session: PlexSession, pathComponents: [String], queryItems: [URLQueryItem]) async throws {
        let url = try requestURL(session: session, pathComponents: pathComponents, queryItems: queryItems)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        addHeaders(to: &request, session: session)
        let (_, response) = try await URLSession.shared.data(for: request)
        try validate(response: response)
    }

    private func requestURL(session: PlexSession, pathComponents: [String], queryItems: [URLQueryItem]) throws -> URL {
        var url = session.serverURL
        for component in pathComponents {
            url.appendPathComponent(component)
        }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        var query = components?.queryItems ?? []
        query.append(contentsOf: queryItems)
        query.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
        query.append(URLQueryItem(name: "X-Plex-Token", value: session.accessToken))
        components?.queryItems = query
        guard let requestURL = components?.url else { throw URLError(.badURL) }
        return requestURL
    }

    private func addHeaders(to request: inout URLRequest, session: PlexSession) {
        request.setValue(clientName, forHTTPHeaderField: "X-Plex-Product")
        request.setValue(version, forHTTPHeaderField: "X-Plex-Version")
        request.setValue("macOS", forHTTPHeaderField: "X-Plex-Platform")
        request.setValue(deviceIdentifier(), forHTTPHeaderField: "X-Plex-Client-Identifier")
        request.setValue(session.accessToken, forHTTPHeaderField: "X-Plex-Token")
    }

    private func deviceIdentifier() -> String {
        if let existing = UserDefaults.standard.string(forKey: "MediaLib.plex.deviceID") {
            return existing
        }
        let generated = UUID().uuidString
        UserDefaults.standard.set(generated, forKey: "MediaLib.plex.deviceID")
        return generated
    }

    private func validate(response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw PlexServiceError.authenticationExpired
        }
        guard (200..<300).contains(http.statusCode) else {
            throw PlexServiceError.requestFailed(statusCode: http.statusCode)
        }
    }

    private func normalizedServerURL(_ url: URL) -> URL {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let trimmedPath = components?.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) ?? ""
        components?.path = trimmedPath
        components?.query = nil
        components?.fragment = nil
        return components?.url ?? url
    }

    private func mediaURL(relativeOrAbsolutePath: String, session: PlexSession) -> String? {
        let url = URL(string: relativeOrAbsolutePath, relativeTo: session.serverURL)?.absoluteURL
        guard var components = url.flatMap({ URLComponents(url: $0, resolvingAgainstBaseURL: false) }) else { return nil }
        var query = components.queryItems ?? []
        query.removeAll { $0.name.caseInsensitiveCompare("X-Plex-Token") == .orderedSame }
        query.append(URLQueryItem(name: "X-Plex-Token", value: session.accessToken))
        components.queryItems = query
        return components.string
    }

    private func posterURLString(for node: PlexXMLNode, session: PlexSession) -> String? {
        let candidate = node.attributes["thumb"] ?? node.attributes["grandparentThumb"] ?? node.attributes["art"]
        return candidate.flatMap { mediaURL(relativeOrAbsolutePath: $0, session: session) }
    }

    private func mediaType(for node: PlexXMLNode) -> MediaType? {
        switch node.plexType {
        case "movie": return .movie
        case "show": return .tvShow
        case "episode": return .episode
        case "track": return .music
        default:
            if node.name == "Track" { return .music }
            return nil
        }
    }

    private func collectionType(for type: String?) -> String? {
        switch type?.lowercased() {
        case "movie": return "movies"
        case "show": return "tvshows"
        case "artist", "music": return "music"
        default: return type
        }
    }

    private static func durationSeconds(from node: PlexXMLNode) -> Double? {
        let milliseconds = Self.milliseconds(node.attributes["duration"]) ??
            node.firstChild(named: "Media").flatMap { Self.milliseconds($0.attributes["duration"]) }
        return milliseconds.map { Double($0) / 1000.0 }
    }

    private static func milliseconds(_ value: String?) -> Int64? {
        int64(value)
    }

    private static func int(_ value: String?) -> Int? {
        guard let value else { return nil }
        return Int(value)
    }

    private static func int64(_ value: String?) -> Int64? {
        guard let value else { return nil }
        return Int64(value)
    }

    private static func double(_ value: String?) -> Double? {
        guard let value else { return nil }
        return Double(value)
    }

    private static func year(from value: String?) -> Int? {
        guard let value, value.count >= 4 else { return nil }
        return Int(value.prefix(4))
    }

    private static func date(fromUnixSeconds value: String?) -> Date? {
        guard let seconds = value.flatMap(Double.init) else { return nil }
        return Date(timeIntervalSince1970: seconds)
    }

    private static func seedUserRating(from rating: Double?) -> Double? {
        guard let rating, rating > 0 else { return nil }
        return min(max((rating / 10.0) * 5.0, 0), 5)
    }
}

private final class PlexXMLNode {
    let name: String
    let attributes: [String: String]
    var children: [PlexXMLNode] = []

    init(name: String, attributes: [String: String]) {
        self.name = name
        self.attributes = attributes
    }

    var plexType: String? {
        attributes["type"]?.lowercased()
    }

    func children(named name: String) -> [PlexXMLNode] {
        children.filter { $0.name == name }
    }

    func firstChild(named name: String) -> PlexXMLNode? {
        children.first { $0.name == name }
    }
}

private final class PlexXMLTreeParser: NSObject, XMLParserDelegate {
    private var stack: [PlexXMLNode] = []
    private var root: PlexXMLNode?

    static func parse(data: Data) throws -> PlexXMLNode {
        let delegate = PlexXMLTreeParser()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse(), let root = delegate.root else {
            throw parser.parserError ?? PlexServiceError.invalidResponse
        }
        return root
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String] = [:]
    ) {
        let node = PlexXMLNode(name: elementName, attributes: attributeDict)
        if let parent = stack.last {
            parent.children.append(node)
        } else {
            root = node
        }
        stack.append(node)
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        _ = stack.popLast()
    }
}

private extension String {
    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }
}
