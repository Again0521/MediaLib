import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authenticated discovery APIs for series, people, photos and user-visible groupings.
///
/// The outer router owns authentication and the `apiRead` bucket. This handler keeps the related
/// pagination and opaque-identifier rules together, and checks `viewMedia` before any provider.
struct ServerDiscoveryHTTPHandler {
    private struct ExactRoute {
        let query: String?
    }

    private let seriesEpisodesProvider: (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage?
    private let peopleProvider: (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage
    private let personDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail?
    private let collectionsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage
    private let collectionDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail?
    private let smartCollectionsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionsPage
    private let smartCollectionDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionDetail?
    private let musicPlaylistsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage
    private let musicPlaylistDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistDetail?
    private let libraryBrowseProvider: (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage

    init(
        seriesEpisodesProvider: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage?,
        peopleProvider: @escaping (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage,
        personDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail?,
        collectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage,
        collectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail?,
        smartCollectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionsPage,
        smartCollectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionDetail?,
        musicPlaylistsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage,
        musicPlaylistDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistDetail?,
        libraryBrowseProvider: @escaping (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage
    ) {
        self.seriesEpisodesProvider = seriesEpisodesProvider
        self.peopleProvider = peopleProvider
        self.personDetailProvider = personDetailProvider
        self.collectionsProvider = collectionsProvider
        self.collectionDetailProvider = collectionDetailProvider
        self.smartCollectionsProvider = smartCollectionsProvider
        self.smartCollectionDetailProvider = smartCollectionDetailProvider
        self.musicPlaylistsProvider = musicPlaylistsProvider
        self.musicPlaylistDetailProvider = musicPlaylistDetailProvider
        self.libraryBrowseProvider = libraryBrowseProvider
    }

    func response(
        method: String,
        path: String,
        target: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool,
        rateLimitResponse: () -> LocalHTTPResponse?
    ) -> LocalHTTPResponse? {
        guard recognizes(path: path) else { return nil }
        guard method == "GET" || method == "HEAD" else { return .methodNotAllowed() }
        if let limited = rateLimitResponse() { return limited }
        guard principal.permissions.contains(.viewMedia) else { return .forbidden() }

        switch path {
        case let value where value.hasPrefix("/api/v1/series/"):
            guard let request = seriesEpisodeQuery(from: target) else { return .badRequest() }
            return optionalResponse(omitBody: omitBody) {
                try seriesEpisodesProvider(
                    request.id, request.season, request.offset, request.limit, principal
                )
            }
        case "/api/v1/people":
            guard let query = peopleQuery(from: target) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try peopleProvider(query.searchText, query.offset, query.limit, principal)
            }
        case let value where value.hasPrefix("/api/v1/people/"):
            guard let request = personCreditsQuery(from: target) else { return .badRequest() }
            do {
                guard let detail = try personDetailProvider(
                    request.id, request.offset, request.limit, principal
                ), let encoded = ServerCommandOutput.jsonData(detail.credits)
                else { return .notFound() }
                return .ok(body: encoded, omitBody: omitBody)
            } catch { return .serviceUnavailable() }
        case "/api/v1/collections":
            guard let query = pagingQuery(from: target, path: path) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try collectionsProvider(query.offset, query.limit, principal)
            }
        case "/api/v1/photos":
            guard let query = pagingQuery(from: target, path: path) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try libraryBrowseProvider(
                    ServerLibraryQuery(type: "photo", offset: query.offset, limit: query.limit),
                    principal
                )
            }
        case let value where value.hasPrefix("/api/v1/collections/"):
            guard let request = identifiedPagingQuery(
                from: target,
                prefix: "/api/v1/collections/"
            ) else { return .badRequest() }
            do {
                guard let detail = try collectionDetailProvider(
                    request.id, request.offset, request.limit, principal
                ), let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                return .ok(body: encoded, omitBody: omitBody)
            } catch { return .serviceUnavailable() }
        case "/api/v1/smart-collections":
            guard let query = pagingQuery(from: target, path: path) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try smartCollectionsProvider(query.offset, query.limit, principal)
            }
        case let value where value.hasPrefix("/api/v1/smart-collections/"):
            guard let request = identifiedPagingQuery(
                from: target,
                prefix: "/api/v1/smart-collections/"
            ) else { return .badRequest() }
            do {
                guard let detail = try smartCollectionDetailProvider(
                    request.id, request.offset, request.limit, principal
                ), let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                return .ok(body: encoded, omitBody: omitBody)
            } catch { return .serviceUnavailable() }
        case "/api/v1/music/playlists":
            guard let query = pagingQuery(from: target, path: path) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try musicPlaylistsProvider(query.offset, query.limit, principal)
            }
        default:
            guard let request = identifiedPagingQuery(
                from: target,
                prefix: "/api/v1/music/playlists/"
            ) else { return .badRequest() }
            do {
                guard let detail = try musicPlaylistDetailProvider(
                    request.id, request.offset, request.limit, principal
                ), let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                return .ok(body: encoded, omitBody: omitBody)
            } catch { return .serviceUnavailable() }
        }
    }

    private func recognizes(path: String) -> Bool {
        path.hasPrefix("/api/v1/series/") ||
            path == "/api/v1/people" || path.hasPrefix("/api/v1/people/") ||
            path == "/api/v1/collections" || path.hasPrefix("/api/v1/collections/") ||
            path == "/api/v1/photos" ||
            path == "/api/v1/smart-collections" ||
            path.hasPrefix("/api/v1/smart-collections/") ||
            path == "/api/v1/music/playlists" ||
            path.hasPrefix("/api/v1/music/playlists/")
    }

    private func encodedResponse<Value: Encodable>(
        omitBody: Bool,
        value: () throws -> Value
    ) -> LocalHTTPResponse {
        do {
            guard let encoded = ServerCommandOutput.jsonData(try value()) else {
                return .serviceUnavailable()
            }
            return .ok(body: encoded, omitBody: omitBody)
        } catch { return .serviceUnavailable() }
    }

    private func optionalResponse<Value: Encodable>(
        omitBody: Bool,
        value: () throws -> Value?
    ) -> LocalHTTPResponse {
        do {
            guard let result = try value() else { return .notFound() }
            guard let encoded = ServerCommandOutput.jsonData(result) else {
                return .serviceUnavailable()
            }
            return .ok(body: encoded, omitBody: omitBody)
        } catch { return .serviceUnavailable() }
    }

    private func seriesEpisodeQuery(
        from target: String
    ) -> (id: String, season: ServerSeriesSeasonSelector, offset: Int, limit: Int)? {
        guard let route = identifiedRoute(
            from: target,
            prefix: "/api/v1/series/",
            suffix: "/episodes"
        ), let values = queryValues(
            from: route.query,
            allowedKeys: ["season", "offset", "limit"],
            maximumValueBytes: 64,
            requireNonemptyQuery: true
        ) else { return nil }
        let season: ServerSeriesSeasonSelector
        if values["season"] == "unspecified" {
            season = .unspecified
        } else {
            guard let rawSeason = values["season"],
                  let number = strictNonnegativeInteger(rawSeason), number <= 10_000
            else { return nil }
            season = .numbered(number)
        }
        guard let page = boundedPage(values, defaultLimit: 50) else { return nil }
        return (route.id, season, page.offset, page.limit)
    }

    private func peopleQuery(
        from target: String
    ) -> (searchText: String?, offset: Int, limit: Int)? {
        guard let route = exactRoute(from: target, path: "/api/v1/people"),
              let values = queryValues(
                from: route.query,
                allowedKeys: ["q", "offset", "limit"],
                maximumValueBytes: 512
              ), let page = boundedPage(values, defaultLimit: 24)
        else { return nil }
        let search = values["q"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(128))
        }
        guard values["q"]?.count ?? 0 <= 128 else { return nil }
        return (search, page.offset, page.limit)
    }

    private func personCreditsQuery(
        from target: String
    ) -> (id: String, offset: Int, limit: Int)? {
        guard let route = identifiedRoute(
            from: target,
            prefix: "/api/v1/people/",
            suffix: "/credits"
        ), let values = queryValues(
            from: route.query,
            allowedKeys: ["offset", "limit"],
            maximumValueBytes: 32,
            requireNonemptyQuery: true
        ), let page = boundedPage(values, defaultLimit: 24)
        else { return nil }
        return (route.id, page.offset, page.limit)
    }

    private func pagingQuery(
        from target: String,
        path: String
    ) -> (offset: Int, limit: Int)? {
        guard let route = exactRoute(from: target, path: path),
              let values = queryValues(
                from: route.query,
                allowedKeys: ["offset", "limit"],
                maximumValueBytes: 32
              )
        else { return nil }
        return boundedPage(values, defaultLimit: 24)
    }

    private func identifiedPagingQuery(
        from target: String,
        prefix: String
    ) -> (id: String, offset: Int, limit: Int)? {
        guard let route = identifiedRoute(
            from: target,
            prefix: prefix,
            suffix: "/items"
        ), let values = queryValues(
            from: route.query,
            allowedKeys: ["offset", "limit"],
            maximumValueBytes: 32,
            requireNonemptyQuery: true
        ), let page = boundedPage(values, defaultLimit: 24)
        else { return nil }
        return (route.id, page.offset, page.limit)
    }

    private func exactRoute(from target: String, path: String) -> ExactRoute? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == path else { return nil }
        return ExactRoute(query: pieces.count == 2 ? String(pieces[1]) : nil)
    }

    private func identifiedRoute(
        from target: String,
        prefix: String,
        suffix: String
    ) -> (id: String, query: String?)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        let path = String(pieces[0])
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let id = decodedIdentifier(encodedID) else { return nil }
        return (id, pieces.count == 2 ? String(pieces[1]) : nil)
    }

    private func queryValues(
        from query: String?,
        allowedKeys: Set<String>,
        maximumValueBytes: Int,
        requireNonemptyQuery: Bool = false
    ) -> [String: String]? {
        if requireNonemptyQuery, query?.isEmpty != false { return nil }
        guard let query, !query.isEmpty else { return [:] }
        var values: [String: String] = [:]
        for pair in query.split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  allowedKeys.contains(key), values[key] == nil,
                  value.utf8.count <= maximumValueBytes,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            values[key] = value
        }
        return values
    }

    private func boundedPage(
        _ values: [String: String],
        defaultLimit: Int
    ) -> (offset: Int, limit: Int)? {
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"),
              offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? String(defaultLimit)),
              (1...100).contains(limit)
        else { return nil }
        return (offset, limit)
    }

    private func decodedIdentifier(_ encodedID: String) -> String? {
        guard !encodedID.isEmpty,
              let identifier = encodedID.removingPercentEncoding,
              !identifier.isEmpty,
              !identifier.contains("/"), !identifier.contains("\\"),
              !identifier.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              identifier.utf8.count <= 512
        else { return nil }
        return identifier
    }

    private func decodeQueryComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }
}
