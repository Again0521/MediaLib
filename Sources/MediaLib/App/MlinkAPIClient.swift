import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// Mlink 原生客户端的最小网络契约。所有受保护请求必须显式使用 Bearer，
/// 不依赖浏览器 Cookie，也不把令牌拼入 URL、日志或媒体来源路径。
struct MlinkAPIClient: Sendable {
    typealias Transport = @Sendable (URLRequest) async throws -> (Data, URLResponse)

    enum Error: LocalizedError, Equatable {
        case invalidServerURL
        case insecureTransport
        case untrustedResponse
        case unsupportedVersion(String)
        case requestFailed(Int)
        case invalidTokens

        var errorDescription: String? {
            switch self {
            case .invalidServerURL: return "Mlink 服务器地址必须是 HTTP 或 HTTPS 地址，且不能包含账号信息。"
            case .insecureTransport: return "非回环 Mlink 服务必须使用 HTTPS。"
            case .untrustedResponse: return "Mlink 服务响应无效或包含不安全字段。"
            case .unsupportedVersion(let version): return "该 Mlink 服务版本（\(version)）暂不受支持。"
            case .requestFailed(let status): return "Mlink 服务请求失败（HTTP \(status)）。"
            case .invalidTokens: return "Mlink 服务返回了无效的会话令牌。"
            }
        }
    }

    struct SessionTokens: Codable, Equatable, Sendable {
        let accessToken: String
        let refreshToken: String
        let tokenType: String
        let accessExpiresAt: Date
        let refreshExpiresAt: Date
        let sessionID: String
        let deviceID: String

        var isValid: Bool {
            tokenType.caseInsensitiveCompare("Bearer") == .orderedSame &&
                (32...1_024).contains(accessToken.utf8.count) &&
                (32...1_024).contains(refreshToken.utf8.count) &&
                !sessionID.isEmpty && sessionID.utf8.count <= 128 &&
                !deviceID.isEmpty && deviceID.utf8.count <= 128 &&
                accessExpiresAt < refreshExpiresAt
        }
    }

    /// 原生客户端一次只写入一个逐用户偏好字段，与网页端相同；不包含用户 ID、
    /// 媒体路径或任何播放 URL。
    enum MediaPreferenceUpdate: Equatable, Sendable {
        case favorite(Bool)
        case watchlist(Bool)
        case rating(Double?)
    }

    enum PlaybackStateEvent: String, Equatable, Sendable {
        case started
        case progress
        case stopped
        case completed
        case reset
    }

    private struct LoginRequest: Encodable {
        let username: String
        let password: String
        let deviceName: String
        let platform: String
        let delivery = "token"
    }

    private struct RefreshRequest: Encodable {
        let refreshToken: String
        let delivery = "token"
    }

    private struct MediaPreferenceRequest: Encodable {
        let favorite: Bool?
        let watchlist: Bool?
        let rating: Double?

        enum CodingKeys: String, CodingKey { case favorite, watchlist, rating }

        init(_ update: MediaPreferenceUpdate) {
            switch update {
            case .favorite(let value):
                favorite = value; watchlist = nil; rating = nil
            case .watchlist(let value):
                favorite = nil; watchlist = value; rating = nil
            case .rating(let value):
                favorite = nil; watchlist = nil; rating = value ?? 0
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            if let favorite { try container.encode(favorite, forKey: .favorite) }
            if let watchlist { try container.encode(watchlist, forKey: .watchlist) }
            if let rating { try container.encode(rating, forKey: .rating) }
        }
    }

    private struct PlaybackStateRequest: Encodable {
        let event: String
        let positionSeconds: Double
        let durationSeconds: Double?
    }

    private let transport: Transport

    init(transport: @escaping Transport = { try await HTTPClient.shared.data(for: $0) }) {
        self.transport = transport
    }

    func discover(serverURL: URL) async throws -> MlinkServerDescriptor {
        let baseURL = try normalizedBaseURL(serverURL)
        var request = URLRequest(url: baseURL.appendingPathComponent(".well-known/mlink"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let descriptor = try decoder.decode(MlinkServerDescriptor.self, from: data)
        guard descriptor.apiVersion == MlinkProtocol.currentAPIVersion else {
            throw Error.unsupportedVersion(descriptor.apiVersion)
        }
        guard descriptor.serverID.utf8.count <= 128, !descriptor.serverID.isEmpty,
              descriptor.serverName.utf8.count <= 256, !descriptor.serverName.isEmpty,
              descriptor.capabilities.count <= 128,
              descriptor.capabilities.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 128 })
        else { throw Error.untrustedResponse }
        return descriptor
    }

    func login(
        serverURL: URL,
        username: String,
        password: String,
        deviceName: String,
        platform: String = "macOS"
    ) async throws -> SessionTokens {
        let baseURL = try normalizedBaseURL(serverURL)
        let normalizedUsername = username.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedUsername.isEmpty, normalizedUsername.utf8.count <= 128,
              !password.isEmpty, password.utf8.count <= 1_024,
              !deviceName.isEmpty, deviceName.utf8.count <= 128,
              !platform.isEmpty, platform.utf8.count <= 128
        else { throw Error.untrustedResponse }
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/login"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mlink-native/1", forHTTPHeaderField: "X-MediaLIB-Client")
        request.httpBody = try JSONEncoder().encode(LoginRequest(
            username: normalizedUsername, password: password, deviceName: deviceName, platform: platform
        ))
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let tokens = try decoder.decode(SessionTokens.self, from: data)
        guard tokens.isValid else { throw Error.invalidTokens }
        return tokens
    }

    func categories(serverURL: URL, accessToken: String) async throws -> ServerLibraryCategoriesResponse {
        guard (32...1_024).contains(accessToken.utf8.count) else { throw Error.invalidTokens }
        let baseURL = try normalizedBaseURL(serverURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/library/categories"))
        request.httpMethod = "GET"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let result = try decoder.decode(ServerLibraryCategoriesResponse.self, from: data)
        guard result.categories.count <= 256,
              result.categories.allSatisfy({ !$0.id.isEmpty && $0.id.utf8.count <= 128 && $0.title.utf8.count <= 256 })
        else { throw Error.untrustedResponse }
        return result
    }

    /// Refresh token 只用于 JSON 请求体，响应中的新 token 会立即替换本地 0600 凭据文件中的旧值。
    func refresh(serverURL: URL, refreshToken: String) async throws -> SessionTokens {
        guard (32...1_024).contains(refreshToken.utf8.count) else { throw Error.invalidTokens }
        let baseURL = try normalizedBaseURL(serverURL)
        var request = URLRequest(url: baseURL.appendingPathComponent("api/v1/auth/refresh"))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("mlink-native/1", forHTTPHeaderField: "X-MediaLIB-Client")
        request.httpBody = try JSONEncoder().encode(RefreshRequest(refreshToken: refreshToken))
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let tokens = try decoder.decode(SessionTokens.self, from: data)
        guard tokens.isValid else { throw Error.invalidTokens }
        return tokens
    }

    /// 以服务端白名单字段分页浏览资料库。查询参数使用 URLComponents 编码，令牌始终只放在 Authorization。
    func browse(
        serverURL: URL,
        accessToken: String,
        type: String? = nil,
        offset: Int = 0,
        limit: Int = 100,
        sort: ServerLibrarySort = .recentlyUpdated
    ) async throws -> ServerLibraryItemsPage {
        guard (32...1_024).contains(accessToken.utf8.count),
              offset >= 0, offset <= 1_000_000,
              (1...100).contains(limit),
              type.map({ MediaType(rawValue: $0) != nil && $0 != MediaType.auto.rawValue && $0 != MediaType.privateCollection.rawValue }) ?? true
        else { throw Error.untrustedResponse }
        let baseURL = try normalizedBaseURL(serverURL)
        guard var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/library/browse"), resolvingAgainstBaseURL: false) else {
            throw Error.invalidServerURL
        }
        var query = [
            URLQueryItem(name: "offset", value: String(offset)),
            URLQueryItem(name: "limit", value: String(limit)),
            URLQueryItem(name: "sort", value: sort.rawValue)
        ]
        if let type { query.append(URLQueryItem(name: "type", value: type)) }
        components.queryItems = query
        guard let url = components.url else { throw Error.invalidServerURL }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let page = try decoder.decode(ServerLibraryItemsPage.self, from: data)
        guard page.offset == offset, page.limit == limit,
              page.totalItemCount >= 0, page.totalItemCount <= 10_000_000,
              page.items.count <= limit,
              page.items.allSatisfy(isTrustedLibraryItem)
        else { throw Error.untrustedResponse }
        return page
    }

    /// 将当前 Mlink 登录用户的单项偏好写回服务端。Bearer 令牌只在 Authorization
    /// 头中发送；原生请求带固定标记以走服务端专用的无 Cookie/无 Origin 防护分支。
    func updatePreference(
        serverURL: URL,
        accessToken: String,
        itemID: String,
        update: MediaPreferenceUpdate
    ) async throws -> ServerMediaUserPreference {
        guard (32...1_024).contains(accessToken.utf8.count), Self.isSafeWebItemIdentifier(itemID) else {
            throw Error.untrustedResponse
        }
        if case .rating(let rating) = update,
           let rating,
           (!rating.isFinite || rating <= 0 || rating > 5) {
            throw Error.untrustedResponse
        }
        let baseURL = try normalizedBaseURL(serverURL)
        var request = URLRequest(url: baseURL
            .appendingPathComponent("api/v1/user-media/preferences", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: false))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mlink-native/1", forHTTPHeaderField: "X-MediaLIB-Client")
        request.httpBody = try JSONEncoder().encode(MediaPreferenceRequest(update))
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let preference = try decoder.decode(ServerMediaUserPreference.self, from: data)
        guard isTrustedPreference(preference) else { throw Error.untrustedResponse }
        return preference
    }

    /// Mlink 客户端仅同步用户状态，绝不请求媒体 URL 或在桌面端解码。网页播放会
    /// 自己上报进度；此入口只用于桌面目录中的显式“已看/未看”操作。
    func updatePlaybackState(
        serverURL: URL,
        accessToken: String,
        itemID: String,
        event: PlaybackStateEvent,
        positionSeconds: Double,
        durationSeconds: Double? = nil
    ) async throws -> ServerMediaUserState {
        guard (32...1_024).contains(accessToken.utf8.count),
              Self.isSafeWebItemIdentifier(itemID),
              positionSeconds.isFinite, positionSeconds >= 0, positionSeconds <= 31_536_000,
              durationSeconds == nil || (
                durationSeconds!.isFinite && durationSeconds! > 0 && durationSeconds! <= 31_536_000 &&
                    positionSeconds <= durationSeconds! + 300
              )
        else { throw Error.untrustedResponse }
        let baseURL = try normalizedBaseURL(serverURL)
        var request = URLRequest(url: baseURL
            .appendingPathComponent("api/v1/playback/state", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: false))
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue("mlink-native/1", forHTTPHeaderField: "X-MediaLIB-Client")
        request.httpBody = try JSONEncoder().encode(PlaybackStateRequest(
            event: event.rawValue, positionSeconds: positionSeconds, durationSeconds: durationSeconds
        ))
        let (data, response) = try await transport(request)
        try requireSuccess(response)
        let state = try decoder.decode(ServerMediaUserState.self, from: data)
        guard state.itemID == itemID,
              state.positionSeconds.isFinite, state.positionSeconds >= 0,
              state.progress.isFinite, (0...1).contains(state.progress), state.playCount >= 0
        else { throw Error.untrustedResponse }
        return state
    }

    /// 构造仅供浏览器打开的详情页地址。这里不携带任何会话令牌：浏览器会使用自身的
    /// HttpOnly 会话 Cookie 完成认证，媒体请求也由网页端发起和解码。
    func webItemURL(serverURL: URL, itemID: String, isSeries: Bool = false) throws -> URL {
        let baseURL = try normalizedBaseURL(serverURL)
        guard Self.isSafeWebItemIdentifier(itemID) else { throw Error.untrustedResponse }
        return baseURL
            .appendingPathComponent(isSeries ? "series" : "item", isDirectory: true)
            .appendingPathComponent(itemID, isDirectory: false)
    }

    static func isSafeWebItemIdentifier(_ itemID: String) -> Bool {
        guard !itemID.isEmpty, itemID.utf8.count <= 512,
              itemID != ".", itemID != "..",
              !itemID.contains("/"), !itemID.contains("\\")
        else { return false }
        return !itemID.unicodeScalars.contains { scalar in
            CharacterSet.controlCharacters.contains(scalar)
        }
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    private func requireSuccess(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw Error.untrustedResponse }
        guard http.statusCode == 200 else { throw Error.requestFailed(http.statusCode) }
    }

    private func isTrustedLibraryItem(_ item: ServerLibraryItem) -> Bool {
        Self.isSafeWebItemIdentifier(item.id) &&
            MediaType(rawValue: item.type).map { $0 != .auto && $0 != .privateCollection } == true &&
            !item.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && item.title.utf8.count <= 1_024 &&
            (item.year == nil || (1800...3000).contains(item.year!)) &&
            isTrustedPreference(item.userPreference) &&
            (item.userState.map { state in
                state.itemID == item.id && state.positionSeconds.isFinite && state.positionSeconds >= 0 &&
                    state.progress.isFinite && (0...1).contains(state.progress) && state.playCount >= 0
            } ?? true)
    }

    private func isTrustedPreference(_ preference: ServerMediaUserPreference) -> Bool {
        preference.rating == nil || (preference.rating!.isFinite && preference.rating! > 0 && preference.rating! <= 5)
    }

    private func normalizedBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = components.host?.lowercased(), !host.isEmpty,
              components.user == nil, components.password == nil
        else { throw Error.invalidServerURL }
        let loopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard scheme == "https" || loopback else { throw Error.insecureTransport }
        components.path = ""
        components.query = nil
        components.fragment = nil
        guard let baseURL = components.url else { throw Error.invalidServerURL }
        return baseURL
    }
}
