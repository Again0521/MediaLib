import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Authenticated library summary, browsing, facets and item-detail JSON routes.
///
/// The outer router owns authentication and the `apiRead` bucket. This handler owns exact route
/// and query contracts so catalog providers never see malformed or ambiguous browser input.
struct ServerLibraryHTTPHandler {
    private let snapshotProvider: (ServerRequestPrincipal) throws -> ServerLibrarySnapshot
    private let browseProvider: (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage
    private let categoriesProvider: (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse
    private let facetsProvider: (String?, ServerLibraryMediaGroup?, ServerRequestPrincipal) throws -> ServerLibraryFacetsResponse
    private let detailProvider: (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?

    init(
        snapshotProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibrarySnapshot,
        browseProvider: @escaping (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage,
        categoriesProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse,
        facetsProvider: @escaping (String?, ServerLibraryMediaGroup?, ServerRequestPrincipal) throws -> ServerLibraryFacetsResponse,
        detailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?
    ) {
        self.snapshotProvider = snapshotProvider
        self.browseProvider = browseProvider
        self.categoriesProvider = categoriesProvider
        self.facetsProvider = facetsProvider
        self.detailProvider = detailProvider
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

        switch path {
        case "/api/v1/library/summary":
            guard target == path else { return .badRequest() }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            return snapshotResponse(\.summary, principal: principal, omitBody: omitBody)
        case "/api/v1/library/items":
            guard target == path else { return .badRequest() }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            return snapshotResponse(\.items, principal: principal, omitBody: omitBody)
        case "/api/v1/library/categories":
            guard target == path else { return .badRequest() }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            return encodedResponse(omitBody: omitBody) {
                try categoriesProvider(principal)
            }
        case "/api/v1/library/facets":
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let scope = facetsScope(from: target) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try facetsProvider(scope.type, scope.group, principal)
            }
        case "/api/v1/library/browse":
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let query = libraryQuery(from: target) else { return .badRequest() }
            return encodedResponse(omitBody: omitBody) {
                try browseProvider(query, principal)
            }
        default:
            guard target == path,
                  let itemID = decodedIdentifier(path: path, prefix: "/api/v1/items/")
            else { return target == path ? .notFound() : .badRequest() }
            do {
                guard let detail = try detailProvider(itemID, principal) else { return .notFound() }
                guard let encoded = ServerCommandOutput.jsonData(detail) else {
                    return .serviceUnavailable()
                }
                return .ok(body: encoded, omitBody: omitBody)
            } catch { return .serviceUnavailable() }
        }
    }

    private func recognizes(path: String) -> Bool {
        path == "/api/v1/library/summary" ||
            path == "/api/v1/library/items" ||
            path == "/api/v1/library/categories" ||
            path == "/api/v1/library/facets" ||
            path == "/api/v1/library/browse" ||
            path.hasPrefix("/api/v1/items/")
    }

    private func snapshotResponse<Value: Encodable>(
        _ value: (ServerLibrarySnapshot) -> Value,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        encodedResponse(omitBody: omitBody) {
            value(try snapshotProvider(principal))
        }
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

    /// Accept only the bounded browse vocabulary. Repeated, unknown and malformed values fail.
    private func libraryQuery(from target: String) -> ServerLibraryQuery? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/api/v1/library/browse" else { return nil }
        var values: [String: String] = [:]
        if pieces.count == 2, !pieces[1].isEmpty {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                guard !pair.isEmpty else { return nil }
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2,
                      let key = decodeQueryComponent(String(keyValue[0])),
                      let value = decodeQueryComponent(String(keyValue[1])),
                      [
                        "q", "type", "group", "offset", "limit", "sort", "order", "genre",
                        "state", "preference", "remoteScope", "vault"
                      ].contains(key),
                      values[key] == nil
                else { return nil }
                values[key] = value
            }
        }
        guard values.values.allSatisfy({ value in
            value.utf8.count <= 512 &&
                !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }) else { return nil }

        let searchText = values["q"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(128))
        }
        if let rawSearch = values["q"], rawSearch.count > 128 { return nil }
        let type = values["type"].flatMap { $0.isEmpty ? nil : $0 }
        if let type {
            guard let mediaType = MediaType(rawValue: type),
                  mediaType != .privateCollection, mediaType != .auto
            else { return nil }
        }

        let mediaGroup: ServerLibraryMediaGroup?
        if let rawGroup = values["group"], !rawGroup.isEmpty {
            guard type == nil, let parsed = ServerLibraryMediaGroup(rawValue: rawGroup) else {
                return nil
            }
            mediaGroup = parsed
        } else {
            mediaGroup = nil
        }
        let playbackFilter: ServerLibraryPlaybackFilter?
        if let rawState = values["state"], !rawState.isEmpty {
            guard let parsed = ServerLibraryPlaybackFilter(rawValue: rawState) else { return nil }
            playbackFilter = parsed
        } else {
            playbackFilter = nil
        }
        let preferenceFilter: ServerLibraryPreferenceFilter?
        if let rawPreference = values["preference"], !rawPreference.isEmpty {
            guard let parsed = ServerLibraryPreferenceFilter(rawValue: rawPreference) else {
                return nil
            }
            preferenceFilter = parsed
        } else {
            preferenceFilter = nil
        }

        let rawSort = values["sort"] ?? ServerLibrarySort.recentlyUpdated.rawValue
        let sort: ServerLibrarySort
        let sortOrder: ServerLibrarySortOrder
        if let legacy = ServerLibrarySort.legacy(rawSort) {
            guard values["order"] == nil else { return nil }
            (sort, sortOrder) = legacy
        } else {
            guard let parsedSort = ServerLibrarySort(rawValue: rawSort) else { return nil }
            sort = parsedSort
            if let rawOrder = values["order"] {
                guard let parsedOrder = ServerLibrarySortOrder(rawValue: rawOrder) else { return nil }
                sortOrder = parsedOrder
            } else {
                sortOrder = .primary
            }
        }

        let genre: String?
        if let rawGenre = values["genre"] {
            let trimmed = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
            genre = trimmed
        } else {
            genre = nil
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"),
              offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "48"),
              (1...100).contains(limit)
        else { return nil }

        let vaultScope: Bool
        if let rawVault = values["vault"] {
            guard rawVault == "1", values["remoteScope"] == nil else { return nil }
            vaultScope = true
        } else {
            vaultScope = false
        }
        let remoteScopeID: String?
        if let rawScope = values["remoteScope"], !rawScope.isEmpty {
            guard rawScope.count <= 64, rawScope.allSatisfy(\.isHexDigit) else { return nil }
            remoteScopeID = rawScope
        } else {
            remoteScopeID = nil
        }
        return ServerLibraryQuery(
            searchText: searchText, type: type, offset: offset, limit: limit,
            sort: sort, sortOrder: sortOrder, genre: genre,
            playbackFilter: playbackFilter, preferenceFilter: preferenceFilter,
            mediaGroup: mediaGroup, remoteScopeID: remoteScopeID, vaultScope: vaultScope
        )
    }

    private func facetsScope(
        from target: String
    ) -> (type: String?, group: ServerLibraryMediaGroup?)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/api/v1/library/facets" else { return nil }
        var values: [String: String] = [:]
        if pieces.count == 2, !pieces[1].isEmpty {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                guard !pair.isEmpty else { return nil }
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2,
                      let key = decodeQueryComponent(String(keyValue[0])),
                      let value = decodeQueryComponent(String(keyValue[1])),
                      ["type", "group"].contains(key), values[key] == nil
                else { return nil }
                values[key] = value
            }
        }
        let type = values["type"].flatMap { $0.isEmpty ? nil : $0 }
        if let type {
            guard let mediaType = MediaType(rawValue: type),
                  mediaType != .privateCollection, mediaType != .auto
            else { return nil }
        }
        let group: ServerLibraryMediaGroup?
        if let rawGroup = values["group"], !rawGroup.isEmpty {
            guard type == nil, let parsed = ServerLibraryMediaGroup(rawValue: rawGroup) else {
                return nil
            }
            group = parsed
        } else {
            group = nil
        }
        return (type, group)
    }

    private func decodedIdentifier(path: String, prefix: String) -> String? {
        let encodedID = String(path.dropFirst(prefix.count))
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
