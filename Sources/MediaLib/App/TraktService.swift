import Foundation
import MediaLibCore

struct TraktRemoteState: Equatable {
    var watchedMovies: Set<Int> = []
    var watchedEpisodes: Set<TraktEpisodeKey> = []
    var watchlistMovies: Set<Int> = []
    var watchlistShows: Set<Int> = []
}

struct TraktDeviceCode {
    let deviceCode: String
    let userCode: String
    let verificationURL: String
    let interval: Int
    let expiresIn: Int
}

struct TraktTokens: Equatable {
    let accessToken: String
    let refreshToken: String
}

enum TraktError: LocalizedError {
    case missingCredentials
    case notConnected
    case authorizationPending
    case authorizationExpired
    case authorizationDenied
    case requestFailed(Int)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials: return "请先在设置中填写 Trakt Client ID 与 Client Secret。"
        case .notConnected: return "尚未连接 Trakt 账号。"
        case .authorizationPending: return "等待用户在浏览器中授权…"
        case .authorizationExpired: return "授权码已过期，请重新开始连接。"
        case .authorizationDenied: return "用户拒绝了授权。"
        case .requestFailed(let code): return "Trakt 请求失败（HTTP \(code)）。"
        case .invalidResponse: return "Trakt 返回了无法解析的响应。"
        }
    }
}

/// Trakt 同步服务：设备码授权流程、状态推送，以及历史/想看清单拉取。
struct TraktService {
    let clientID: String
    let clientSecret: String
    private let base = "https://api.trakt.tv"

    private var hasCredentials: Bool {
        !clientID.trimmingCharacters(in: .whitespaces).isEmpty &&
        !clientSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 设备码授权

    func requestDeviceCode() async throws -> TraktDeviceCode {
        guard hasCredentials else { throw TraktError.missingCredentials }
        let data = try await post(path: "/oauth/device/code", body: ["client_id": clientID], accessToken: nil, expecting: [200])
        let dto = try decode(DeviceCodeResponse.self, from: data)
        return TraktDeviceCode(
            deviceCode: dto.device_code,
            userCode: dto.user_code,
            verificationURL: dto.verification_url,
            interval: dto.interval,
            expiresIn: dto.expires_in
        )
    }

    /// 轮询一次。返回 tokens 表示成功；抛 `.authorizationPending` 表示继续轮询；其余为终止错误。
    func pollOnce(deviceCode: String) async throws -> TraktTokens {
        guard hasCredentials else { throw TraktError.missingCredentials }
        let body = ["code": deviceCode, "client_id": clientID, "client_secret": clientSecret]
        let (data, status) = try await rawPost(path: "/oauth/device/token", body: body, accessToken: nil)
        switch status {
        case 200:
            let dto = try decode(TokenResponse.self, from: data)
            return TraktTokens(accessToken: dto.access_token, refreshToken: dto.refresh_token)
        case 400: throw TraktError.authorizationPending
        case 410: throw TraktError.authorizationExpired
        case 418: throw TraktError.authorizationDenied
        case 409: throw TraktError.requestFailed(409) // already used
        default: throw TraktError.requestFailed(status)
        }
    }

    func refreshTokens(_ refreshToken: String) async throws -> TraktTokens {
        guard hasCredentials else { throw TraktError.missingCredentials }
        let body: [String: String] = [
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret,
            "redirect_uri": "urn:ietf:wg:oauth:2.0:oob",
            "grant_type": "refresh_token"
        ]
        let data = try await post(path: "/oauth/token", body: body, accessToken: nil, expecting: [200])
        let dto = try decode(TokenResponse.self, from: data)
        return TraktTokens(accessToken: dto.access_token, refreshToken: dto.refresh_token)
    }

    // MARK: - 同步

    func addToHistory(_ refs: [TraktMediaRef], accessToken: String) async throws {
        try await sync(path: "/sync/history", refs: refs, accessToken: accessToken)
    }

    func removeFromHistory(_ refs: [TraktMediaRef], accessToken: String) async throws {
        try await sync(path: "/sync/history/remove", refs: refs, accessToken: accessToken)
    }

    func addToWatchlist(_ refs: [TraktMediaRef], accessToken: String) async throws {
        try await sync(path: "/sync/watchlist", refs: refs, accessToken: accessToken)
    }

    func removeFromWatchlist(_ refs: [TraktMediaRef], accessToken: String) async throws {
        try await sync(path: "/sync/watchlist/remove", refs: refs, accessToken: accessToken)
    }

    func fetchRemoteState(accessToken: String) async throws -> TraktRemoteState {
        async let watchedMovies = fetchWatchedMovies(accessToken: accessToken)
        async let watchedShows = fetchWatchedShows(accessToken: accessToken)
        async let watchlistItems = fetchWatchlist(accessToken: accessToken)

        var state = TraktRemoteState()
        state.watchedMovies = try await watchedMovies
        state.watchedEpisodes = try await watchedShows
        let watchlist = try await watchlistItems
        state.watchlistMovies = watchlist.movies
        state.watchlistShows = watchlist.shows
        return state
    }

    private func sync(path: String, refs: [TraktMediaRef], accessToken: String) async throws {
        guard !refs.isEmpty else { return }
        let payload = TraktSyncPayloadBuilder.buildPayload(from: refs)
        let bodyData = try JSONSerialization.data(withJSONObject: payload)
        _ = try await postData(path: path, bodyData: bodyData, accessToken: accessToken, expecting: [200, 201])
    }

    private func fetchWatchedMovies(accessToken: String) async throws -> Set<Int> {
        let data = try await get(path: "/sync/watched/movies", accessToken: accessToken, queryItems: [URLQueryItem(name: "extended", value: "min")])
        return Set(try decode([WatchedMovieItem].self, from: data).compactMap { $0.movie.ids.tmdb })
    }

    private func fetchWatchedShows(accessToken: String) async throws -> Set<TraktEpisodeKey> {
        let data = try await get(path: "/sync/watched/shows", accessToken: accessToken, queryItems: [URLQueryItem(name: "extended", value: "min")])
        let shows = try decode([WatchedShowItem].self, from: data)
        var keys: Set<TraktEpisodeKey> = []
        for show in shows {
            guard let showTmdbID = show.show.ids.tmdb else { continue }
            for season in show.seasons {
                for episode in season.episodes {
                    keys.insert(TraktEpisodeKey(showTmdbID: showTmdbID, season: season.number, episode: episode.number))
                }
            }
        }
        return keys
    }

    private func fetchWatchlist(accessToken: String) async throws -> (movies: Set<Int>, shows: Set<Int>) {
        let data = try await get(path: "/sync/watchlist", accessToken: accessToken, queryItems: [URLQueryItem(name: "extended", value: "min")])
        let items = try decode([WatchlistItem].self, from: data)
        var movies: Set<Int> = []
        var shows: Set<Int> = []
        for item in items {
            switch item.type {
            case "movie":
                if let tmdbID = item.movie?.ids.tmdb { movies.insert(tmdbID) }
            case "show":
                if let tmdbID = item.show?.ids.tmdb { shows.insert(tmdbID) }
            default:
                continue
            }
        }
        return (movies, shows)
    }

    // MARK: - 底层请求

    private func headers(accessToken: String?) -> [String: String] {
        var headers = [
            "Content-Type": "application/json",
            "trakt-api-version": "2",
            "trakt-api-key": clientID
        ]
        if let accessToken { headers["Authorization"] = "Bearer \(accessToken)" }
        return headers
    }

    private func post(path: String, body: [String: String], accessToken: String?, expecting: [Int]) async throws -> Data {
        let bodyData = try JSONSerialization.data(withJSONObject: body)
        return try await postData(path: path, bodyData: bodyData, accessToken: accessToken, expecting: expecting)
    }

    private func rawPost(path: String, body: [String: String], accessToken: String?) async throws -> (Data, Int) {
        guard let url = URL(string: base + path) else { throw TraktError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (key, value) in headers(accessToken: accessToken) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        return (data, status)
    }

    private func postData(path: String, bodyData: Data, accessToken: String?, expecting: [Int]) async throws -> Data {
        guard let url = URL(string: base + path) else { throw TraktError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        for (key, value) in headers(accessToken: accessToken) { request.setValue(value, forHTTPHeaderField: key) }
        request.httpBody = bodyData
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard expecting.contains(status) else { throw TraktError.requestFailed(status) }
        return data
    }

    private func get(path: String, accessToken: String, queryItems: [URLQueryItem] = []) async throws -> Data {
        guard var components = URLComponents(string: base + path) else { throw TraktError.invalidResponse }
        components.queryItems = queryItems.isEmpty ? nil : queryItems
        guard let url = components.url else { throw TraktError.invalidResponse }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        for (key, value) in headers(accessToken: accessToken) { request.setValue(value, forHTTPHeaderField: key) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw TraktError.requestFailed(status) }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw TraktError.invalidResponse }
    }
}

// MARK: - 解码

private struct DeviceCodeResponse: Decodable {
    let device_code: String
    let user_code: String
    let verification_url: String
    let expires_in: Int
    let interval: Int
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String
}

private struct TraktIDs: Decodable {
    let tmdb: Int?
}

private struct TraktMovieObject: Decodable {
    let ids: TraktIDs
}

private struct TraktShowObject: Decodable {
    let ids: TraktIDs
}

private struct WatchedMovieItem: Decodable {
    let movie: TraktMovieObject
}

private struct WatchedShowEpisode: Decodable {
    let number: Int
}

private struct WatchedShowSeason: Decodable {
    let number: Int
    let episodes: [WatchedShowEpisode]
}

private struct WatchedShowItem: Decodable {
    let show: TraktShowObject
    let seasons: [WatchedShowSeason]
}

private struct WatchlistItem: Decodable {
    let type: String
    let movie: TraktMovieObject?
    let show: TraktShowObject?
}
