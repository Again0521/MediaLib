import CryptoKit
import Foundation

/// Last.fm 会话（授权成功后获得，用于后续打卡请求）。
struct LastfmSession: Equatable {
    let sessionKey: String
    let username: String
}

enum LastfmScrobbleError: LocalizedError {
    case missingCredentials
    case notAuthorized
    case requestFailed(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .missingCredentials:
            return "请先在设置中填写 Last.fm API Key 与 Shared Secret。"
        case .notAuthorized:
            return "用户尚未在浏览器中完成授权，请先点击「授权」。"
        case .requestFailed(let message):
            return "Last.fm 请求失败：\(message)"
        case .invalidResponse:
            return "Last.fm 返回了无法解析的响应。"
        }
    }
}

/// Last.fm 听歌打卡（Scrobbling）服务：基于 API Key + Shared Secret 的桌面授权流程，
/// 以及 track.updateNowPlaying / track.scrobble 提交。所有签名请求按官方规则做 md5 api_sig。
struct LastfmScrobbleService {
    let apiKey: String
    let sharedSecret: String

    private let endpoint = URL(string: "https://ws.audioscrobbler.com/2.0/")!

    private var hasCredentials: Bool {
        !apiKey.trimmingCharacters(in: .whitespaces).isEmpty &&
        !sharedSecret.trimmingCharacters(in: .whitespaces).isEmpty
    }

    // MARK: - 授权流程

    /// 第一步：获取 request token。
    func fetchToken() async throws -> String {
        guard hasCredentials else { throw LastfmScrobbleError.missingCredentials }
        let params = ["method": "auth.getToken", "api_key": apiKey]
        let data = try await get(signing: params)
        let decoded = try decode(TokenResponse.self, from: data)
        return decoded.token
    }

    /// 第二步：把 token 拼成浏览器授权 URL，让用户在 Last.fm 网站点“允许”。
    func authorizationURL(token: String) -> URL? {
        var components = URLComponents(string: "https://www.last.fm/api/auth/")
        components?.queryItems = [
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "token", value: token)
        ]
        return components?.url
    }

    /// 第三步：用户授权后，用 token 换取长期 session key 与用户名。
    func fetchSession(token: String) async throws -> LastfmSession {
        guard hasCredentials else { throw LastfmScrobbleError.missingCredentials }
        let params = ["method": "auth.getSession", "api_key": apiKey, "token": token]
        let data = try await get(signing: params)
        let decoded = try decode(SessionResponse.self, from: data)
        return LastfmSession(sessionKey: decoded.session.key, username: decoded.session.name)
    }

    // MARK: - 打卡

    func updateNowPlaying(
        artist: String,
        track: String,
        album: String?,
        durationSeconds: Int?,
        sessionKey: String
    ) async throws {
        guard hasCredentials else { throw LastfmScrobbleError.missingCredentials }
        var params: [String: String] = [
            "method": "track.updateNowPlaying",
            "api_key": apiKey,
            "sk": sessionKey,
            "artist": artist,
            "track": track
        ]
        if let album, !album.isEmpty { params["album"] = album }
        if let durationSeconds, durationSeconds > 0 { params["duration"] = String(durationSeconds) }
        _ = try await post(signing: params)
    }

    func scrobble(
        artist: String,
        track: String,
        album: String?,
        timestamp: Int,
        durationSeconds: Int?,
        sessionKey: String
    ) async throws {
        guard hasCredentials else { throw LastfmScrobbleError.missingCredentials }
        var params: [String: String] = [
            "method": "track.scrobble",
            "api_key": apiKey,
            "sk": sessionKey,
            "artist": artist,
            "track": track,
            "timestamp": String(timestamp)
        ]
        if let album, !album.isEmpty { params["album"] = album }
        if let durationSeconds, durationSeconds > 0 { params["duration"] = String(durationSeconds) }
        _ = try await post(signing: params)
    }

    // MARK: - 底层请求

    /// 按 Last.fm 规则计算 api_sig：参数名升序拼接 name+value，末尾追加 shared secret，取 md5。
    private func apiSignature(for params: [String: String]) -> String {
        let concatenated = params.keys.sorted()
            .map { "\($0)\(params[$0] ?? "")" }
            .joined()
        let raw = concatenated + sharedSecret
        let digest = Insecure.MD5.hash(data: Data(raw.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private func signedItems(_ params: [String: String]) -> [URLQueryItem] {
        var signed = params
        signed["api_sig"] = apiSignature(for: params)
        signed["format"] = "json"
        return signed.map { URLQueryItem(name: $0.key, value: $0.value) }
    }

    private func get(signing params: [String: String]) async throws -> Data {
        var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false)
        components?.queryItems = signedItems(params)
        guard let url = components?.url else { throw LastfmScrobbleError.invalidResponse }
        var request = URLRequest(url: url)
        request.timeoutInterval = 12
        return try await perform(request)
    }

    private func post(signing params: [String: String]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 12
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        var body = URLComponents()
        body.queryItems = signedItems(params)
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)
        return try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw LastfmScrobbleError.invalidResponse }
        if let error = try? JSONDecoder().decode(LastfmErrorResponse.self, from: data), error.error != nil {
            throw LastfmScrobbleError.requestFailed(error.message ?? "error \(error.error ?? -1)")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw LastfmScrobbleError.requestFailed("HTTP \(http.statusCode)")
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch {
            throw LastfmScrobbleError.invalidResponse
        }
    }
}

// MARK: - 响应解码

private struct TokenResponse: Decodable {
    let token: String
}

private struct SessionResponse: Decodable {
    struct Session: Decodable {
        let name: String
        let key: String
    }
    let session: Session
}

private struct LastfmErrorResponse: Decodable {
    let error: Int?
    let message: String?
}
