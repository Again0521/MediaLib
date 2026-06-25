import Foundation

/// 远程请求的统一传输层：集中处理超时兜底、429 限流退避（含 `Retry-After`）、5xx 有限重试。
///
/// 设计动机（R1-NET-001）：此前各远程服务（Emby/Plex/Trakt/Last.fm/Subtitle）各写一套
/// `URLSession.shared.data(for:)` + 状态判断，**只有 TMDB 处理 429/5xx 重试**，其余瞬时
/// 限流/服务端错误会直接整批失败。本客户端把「传输 + 重试」统一，**不接管响应语义**：
/// 仍返回 `(Data, URLResponse)`（含非 2xx），由各服务沿用原有的状态码解释与解码逻辑，
/// 因此是 `URLSession.shared.data(for:)` 的**drop-in 替换**，迁移零语义变化。
///
/// 安全：**仅对幂等方法（GET/HEAD）自动重试**，避免重试 POST（如 scrobble）导致重复提交。
public final class HTTPClient: @unchecked Sendable {
    public static let shared = HTTPClient()

    private let session: URLSession
    private let maxRetries: Int
    private let defaultTimeout: TimeInterval
    /// 重试等待秒数的计算器；默认按 `Retry-After` 或指数退避，测试可注入 0 以加速。
    private let retryDelay: @Sendable (HTTPURLResponse, Int) -> Double

    public init(
        session: URLSession = .shared,
        maxRetries: Int = 2,
        defaultTimeout: TimeInterval = 20,
        retryDelay: @escaping @Sendable (HTTPURLResponse, Int) -> Double = HTTPClient.defaultRetryDelay
    ) {
        self.session = session
        self.maxRetries = max(maxRetries, 0)
        self.defaultTimeout = defaultTimeout
        self.retryDelay = retryDelay
    }

    /// 与 `URLSession.data(for:)` 同签名的 drop-in 替换：附加超时兜底与幂等请求的限流/5xx 重试。
    public func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        var request = request
        // 仅在调用方未自定义超时（URLRequest 框架默认 60s）时套用更紧的默认超时；
        // 不缩短调用方已显式设置的超时。
        if request.timeoutInterval == 60 {
            request.timeoutInterval = defaultTimeout
        }

        let method = (request.httpMethod ?? "GET").uppercased()
        let isIdempotent = (method == "GET" || method == "HEAD")
        let maxAttempts = isIdempotent ? maxRetries + 1 : 1

        var attempt = 0
        while true {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return (data, response)
            }
            let isTransient = (http.statusCode == 429 || (500...599).contains(http.statusCode))
            if isTransient, attempt + 1 < maxAttempts {
                let seconds = max(retryDelay(http, attempt), 0)
                if seconds > 0 {
                    try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                }
                attempt += 1
                continue
            }
            return (data, response)
        }
    }

    /// 默认退避：优先 `Retry-After`（秒，封顶 30s），否则指数退避 1/2/4…（封顶 8s）。
    public static func defaultRetryDelay(_ response: HTTPURLResponse, attempt: Int) -> Double {
        if let header = response.value(forHTTPHeaderField: "Retry-After"), let seconds = Double(header) {
            return min(max(seconds, 0), 30)
        }
        return min(pow(2.0, Double(attempt)), 8)
    }
}
