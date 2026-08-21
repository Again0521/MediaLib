import Foundation
import MediaLibServerProtocol

/// P4 的最终取舍点：一个已认证的浏览器要播放远程媒体时，字节到底从
/// MediaLIB 同源代理来，还是允许浏览器直接向 Emby/Jellyfin/Plex 取。
///
/// 默认永远是代理。直连是可选策略，必须**同时**满足下面每一项才成立，
/// 任何一项缺失都退回代理并给出可解释原因，绝不静默降级：
///
/// 1. 管理员显式开启 `MEDIALIB_SERVER_LAN_DIRECT_PLAY`；
/// 2. 已配置 HTTPS 公开 Origin 与可信反向代理（传输边界可信）；
/// 3. 请求经该可信反代转发，且原始客户端位于私有网段（同网）；
/// 4. 上游本身是 HTTPS（否则 HTTPS 页面会被混合内容拦截）；
/// 5. 上游凭据是短时、单媒体、单设备的票据。
///
/// 第 5 条是当前的决定性约束：Emby/Jellyfin 的播放地址带 `api_key`、Plex 带
/// `X-Plex-Token`，两者都是账号级长期令牌（见 `EmbyService`/`PlexService` 的
/// 地址构造），把它交给浏览器等于交出整个媒体服务器账号。受支持的连接器都
/// 不签发单媒体票据，因此本策略在当前产品阶段总是判定为代理——这是结论，
/// 不是暂缺实现：省下的那一跳不值得用 token 泄露去换。
struct ServerRemoteAccessPolicy: Sendable {
    let publicOrigin: URL?
    let trustedProxyAddresses: Set<String>
    let listenerIsLoopbackOnly: Bool
    let lanDirectPlayEnabled: Bool

    static let loopbackOnly = ServerRemoteAccessPolicy(
        publicOrigin: nil,
        trustedProxyAddresses: [],
        listenerIsLoopbackOnly: true,
        lanDirectPlayEnabled: false
    )

    init(
        publicOrigin: URL?,
        trustedProxyAddresses: Set<String>,
        listenerIsLoopbackOnly: Bool = true,
        lanDirectPlayEnabled: Bool
    ) {
        self.publicOrigin = publicOrigin
        self.trustedProxyAddresses = trustedProxyAddresses
        self.listenerIsLoopbackOnly = listenerIsLoopbackOnly
        self.lanDirectPlayEnabled = lanDirectPlayEnabled
    }

    /// 传输边界是否可信：HTTPS 公开 Origin 加显式可信反代，缺一不可。
    var hasTrustedTransportBoundary: Bool {
        publicOrigin != nil && !trustedProxyAddresses.isEmpty
    }

    /// 决定一次远程媒体读取的通路。`upstream` 为 nil 表示本地资产。
    func transportDecision(
        upstream: URL?,
        forwardedClientAddress: String?
    ) -> ServerMediaTransportDecision {
        guard let upstream else { return .sameOriginProxy(reason: .sourceIsLocalAsset) }
        guard lanDirectPlayEnabled else { return .sameOriginProxy(reason: .lanDirectPlayDisabled) }
        guard hasTrustedTransportBoundary else {
            return .sameOriginProxy(reason: .transportBoundaryNotTrusted)
        }
        guard let forwardedClientAddress,
              Self.isPrivateIPv4Address(forwardedClientAddress)
        else {
            return .sameOriginProxy(reason: .clientNotOnVerifiedLan)
        }
        guard upstream.scheme?.lowercased() == "https" else {
            return .sameOriginProxy(reason: .upstreamNotSecure)
        }
        switch Self.credentialScope(of: upstream) {
        case .perMediaShortLived:
            return .verifiedLanDirect(upstream: upstream)
        case .accountScopedLongLived:
            return .sameOriginProxy(reason: .upstreamCredentialAccountScoped)
        case .none:
            return .sameOriginProxy(reason: .upstreamProvidesNoPlaybackTicket)
        }
    }

    /// 供遥测记录使用的原因。它评估配置门禁与上游侧门禁；逐请求的客户端网段
    /// 在代理写出路径上拿不到，因此当前面各项都放行时报告客户端一侧。
    ///
    /// 默认配置下第一项即短路返回，不会解析 URL，因此对每个 Range 的热路径
    /// 只增加两次布尔判断。
    func transportDecisionReason(upstream: URL) -> ServerMediaTransportReason {
        if let blocker = lanDirectPlayConfigurationBlocker() { return blocker }
        guard upstream.scheme?.lowercased() == "https" else { return .upstreamNotSecure }
        switch Self.credentialScope(of: upstream) {
        case .accountScopedLongLived: return .upstreamCredentialAccountScoped
        case .none: return .upstreamProvidesNoPlaybackTicket
        case .perMediaShortLived: return .clientNotOnVerifiedLan
        }
    }

    /// 配置层面阻止直连的第一个原因；nil 表示配置已放行。逐请求的客户端网段
    /// 与逐条目的上游凭据作用域仍在 `transportDecision` 中单独判定。
    func lanDirectPlayConfigurationBlocker() -> ServerMediaTransportReason? {
        guard lanDirectPlayEnabled else { return .lanDirectPlayDisabled }
        guard hasTrustedTransportBoundary else { return .transportBoundaryNotTrusted }
        return nil
    }

    /// 管理员自检：把"能否把 iPhone/iPad/电视接进来"拆成逐项可核对的事实，
    /// 而不是一个含糊的开关。任何一项为假都不应对外开放。
    func lanAccessReadiness() -> ServerLanAccessReadiness {
        ServerLanAccessReadiness(
            hasHTTPSPublicOrigin: publicOrigin != nil,
            hasTrustedReverseProxy: !trustedProxyAddresses.isEmpty,
            listenerIsLoopbackOnly: listenerIsLoopbackOnly,
            // 这两项由本仓库的实现保证：登录响应固定发 HttpOnly + Secure +
            // SameSite=Strict，管理端固定提供逐会话吊销。
            sessionCookiesAreHardened: true,
            supportsSessionRevocation: true,
            proxyStressTestCovered: true,
            lanDirectPlayEnabled: lanDirectPlayEnabled,
            lanDirectPlayBlockedBy: lanDirectPlayConfigurationBlocker(),
            // Emby/Jellyfin/Plex 都只有账号级长期令牌，没有单媒体短时票据。
            supportedUpstreamsIssueScopedTickets: false
        )
    }

    /// 判断上游地址携带的凭据作用域。
    ///
    /// 这里只认**已知的**账号级凭据参数名；未知参数不被乐观地当成短时票据，
    /// 默认落到账号级一侧，因为误判的代价是把长期 token 交给浏览器。
    static func credentialScope(of url: URL) -> ServerUpstreamCredentialScope {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems, !queryItems.isEmpty
        else {
            return .none
        }
        let names = Set(queryItems.map { $0.name.lowercased() })
        if names.contains(where: { accountScopedCredentialParameters.contains($0) }) {
            return .accountScopedLongLived
        }
        // 带查询串但不含已知凭据参数：仍可能是某种未识别的授权形式，保守归入
        // 账号级，绝不因为"没认出来"就允许外发。
        return .accountScopedLongLived
    }

    /// Emby/Jellyfin 使用 `api_key`（亦见 `X-Emby-Token` 头），Plex 使用
    /// `X-Plex-Token`。三者都是账号级、长期有效、可读取整库的令牌。
    private static let accountScopedCredentialParameters: Set<String> = [
        "api_key", "apikey", "x-emby-token", "x-plex-token", "plextoken", "token", "access_token"
    ]

    static func isPrivateIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        let octets = parts.compactMap { part -> Int? in
            guard !part.isEmpty, part.count <= 3, part.allSatisfy(\.isNumber),
                  let number = Int(part), (0...255).contains(number)
            else { return nil }
            return number
        }
        guard octets.count == 4 else { return false }
        switch (octets[0], octets[1]) {
        case (10, _): return true
        case (192, 168): return true
        case (172, 16...31): return true
        default: return false
        }
    }
}
