import Foundation

/// 卡片来源于哪一类已连接的远程媒体服务，仅用于显示来源角标。
///
/// 它不携带服务地址、媒体路径、来源名称或 token——只有一个固定枚举值。
/// 之所以要有它：此前网页把任何"有远程可播放地址"的条目一律标成 `Mlink`，
/// 而 Mlink 是 MediaLIB 自己的服务端协议，其条目恰恰**没有**媒体 URL。
/// 于是 Emby/Jellyfin/Plex 的条目被贴上了 Mlink 的标，真正的 Mlink 条目反而没标。
public enum ServerRemoteSourceKind: String, Codable, Equatable, Sendable, CaseIterable {
    case emby
    case jellyfin
    case plex
    case mlink

    /// 由来源路径的 scheme 判定。与是否存在可播放地址无关，因此 Mlink 也能被正确标注。
    public init?(sourcePath: String?) {
        guard let sourcePath else { return nil }
        let lowercased = sourcePath.lowercased()
        guard let match = Self.allCases.first(where: { lowercased.hasPrefix("\($0.rawValue)://") }) else {
            return nil
        }
        self = match
    }

    public var displayName: String {
        switch self {
        case .emby: return "Emby"
        case .jellyfin: return "Jellyfin"
        case .plex: return "Plex"
        case .mlink: return "Mlink"
        }
    }
}

/// 上游播放地址所携带凭据的作用域。这是"能否让浏览器直连远程媒体服务器"
/// 的唯一决定性判据：只有短时、单媒体、单设备的票据才允许离开本进程。
public enum ServerUpstreamCredentialScope: String, Codable, Equatable, Sendable, CaseIterable {
    /// 地址里没有任何凭据（例如完全开放的上游）。
    case none
    /// 账号级长期令牌：Emby/Jellyfin 的 `api_key`、Plex 的 `X-Plex-Token`。
    /// 它们能读取该账号的整个媒体库，且不会随单次播放过期。
    case accountScopedLongLived
    /// 短时、单媒体、单设备的播放票据。当前受支持的连接器都不签发此类凭据，
    /// 该分支为将来真正提供票据的上游预留。
    case perMediaShortLived
}

/// 一次已认证的网页播放请求最终走哪条数据通路。
public enum ServerMediaTransportDecision: Equatable, Sendable {
    /// MediaLIB 同源代理。这是默认且唯一已发布的通路。
    case sameOriginProxy(reason: ServerMediaTransportReason)
    /// 浏览器直接向上游取流。仅在所有门禁同时满足时才可能出现。
    case verifiedLanDirect(upstream: URL)
}

/// 选择同源代理的可解释原因。它只描述策略判定，不含路径、URL、token 或标题。
public enum ServerMediaTransportReason: String, Codable, Equatable, Sendable, CaseIterable {
    /// 本地或网络挂载文件，本来就没有可直连的上游。
    case sourceIsLocalAsset
    /// 管理员没有显式开启"已验证局域网直连"。
    case lanDirectPlayDisabled
    /// 缺少 HTTPS 公开 Origin 或可信反代，直连没有可信的传输边界。
    case transportBoundaryNotTrusted
    /// 请求方不是经可信反代转发的私有网段客户端。
    case clientNotOnVerifiedLan
    /// 上游不是 HTTPS。HTTPS 页面加载 http:// 媒体会被浏览器按混合内容拦截。
    case upstreamNotSecure
    /// 上游凭据是账号级长期令牌，直连等于把整个媒体服务器账号交给浏览器。
    case upstreamCredentialAccountScoped
    /// 上游没有可用于直连的短时单媒体票据（包括完全无凭据的上游）。
    case upstreamProvidesNoPlaybackTicket
}

/// 面向管理员的局域网开放就绪度自检。逐项说明"现在把 iPhone/iPad/电视接进来"
/// 还缺什么，避免把开放远程访问变成改一个开关的动作。
public struct ServerLanAccessReadiness: Codable, Equatable, Sendable {
    /// 已配置无路径的 HTTPS 公开 Origin。
    public let hasHTTPSPublicOrigin: Bool
    /// 已显式列出可信反向代理地址。
    public let hasTrustedReverseProxy: Bool
    /// 监听地址仍限制在回环，远程流量只能经反代进入。
    public let listenerIsLoopbackOnly: Bool
    /// 会话 Cookie 为 HttpOnly + Secure + SameSite=Strict。
    public let sessionCookiesAreHardened: Bool
    /// 管理员可以逐会话吊销已登录设备。
    public let supportsSessionRevocation: Bool
    /// 代理链路已通过并发压测（见 `ServerRemoteProxyStressTests`）。
    public let proxyStressTestCovered: Bool
    /// 管理员是否开启了可选的局域网直连策略。
    public let lanDirectPlayEnabled: Bool
    /// 配置层面阻止直连的第一个原因；为 nil 表示配置已放行，是否直连仍取决于
    /// 逐请求的客户端网段与逐条目的上游凭据作用域。
    public let lanDirectPlayBlockedBy: ServerMediaTransportReason?
    /// 当前受支持的连接器是否签发短时、单媒体、单设备的播放票据。
    /// Emby/Jellyfin 的 `api_key` 与 Plex 的 `X-Plex-Token` 都是账号级长期令牌，
    /// 因此该值为 false，远程媒体始终经同源代理。
    public let supportedUpstreamsIssueScopedTickets: Bool

    /// 只有全部前置项满足时才认为可以对外开放；直连开关不影响该结论。
    public var isReadyForLanAccess: Bool {
        hasHTTPSPublicOrigin && hasTrustedReverseProxy && listenerIsLoopbackOnly &&
            sessionCookiesAreHardened && supportsSessionRevocation && proxyStressTestCovered
    }

    public init(
        hasHTTPSPublicOrigin: Bool,
        hasTrustedReverseProxy: Bool,
        listenerIsLoopbackOnly: Bool,
        sessionCookiesAreHardened: Bool,
        supportsSessionRevocation: Bool,
        proxyStressTestCovered: Bool,
        lanDirectPlayEnabled: Bool,
        lanDirectPlayBlockedBy: ServerMediaTransportReason?,
        supportedUpstreamsIssueScopedTickets: Bool
    ) {
        self.hasHTTPSPublicOrigin = hasHTTPSPublicOrigin
        self.hasTrustedReverseProxy = hasTrustedReverseProxy
        self.listenerIsLoopbackOnly = listenerIsLoopbackOnly
        self.sessionCookiesAreHardened = sessionCookiesAreHardened
        self.supportsSessionRevocation = supportsSessionRevocation
        self.proxyStressTestCovered = proxyStressTestCovered
        self.lanDirectPlayEnabled = lanDirectPlayEnabled
        self.lanDirectPlayBlockedBy = lanDirectPlayBlockedBy
        self.supportedUpstreamsIssueScopedTickets = supportedUpstreamsIssueScopedTickets
    }

    private enum CodingKeys: String, CodingKey {
        case hasHTTPSPublicOrigin, hasTrustedReverseProxy, listenerIsLoopbackOnly
        case sessionCookiesAreHardened, supportsSessionRevocation, proxyStressTestCovered
        case lanDirectPlayEnabled, lanDirectPlayBlockedBy, supportedUpstreamsIssueScopedTickets
        case isReadyForLanAccess
    }

    /// `isReadyForLanAccess` 是派生结论，只出现在编码结果里；解码时重新计算，
    /// 避免旧客户端或被篡改的响应把"未就绪"读成"已就绪"。
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            hasHTTPSPublicOrigin: try values.decode(Bool.self, forKey: .hasHTTPSPublicOrigin),
            hasTrustedReverseProxy: try values.decode(Bool.self, forKey: .hasTrustedReverseProxy),
            listenerIsLoopbackOnly: try values.decode(Bool.self, forKey: .listenerIsLoopbackOnly),
            sessionCookiesAreHardened: try values.decode(Bool.self, forKey: .sessionCookiesAreHardened),
            supportsSessionRevocation: try values.decode(Bool.self, forKey: .supportsSessionRevocation),
            proxyStressTestCovered: try values.decode(Bool.self, forKey: .proxyStressTestCovered),
            lanDirectPlayEnabled: try values.decode(Bool.self, forKey: .lanDirectPlayEnabled),
            lanDirectPlayBlockedBy: try values.decodeIfPresent(
                ServerMediaTransportReason.self, forKey: .lanDirectPlayBlockedBy
            ),
            supportedUpstreamsIssueScopedTickets: try values.decode(
                Bool.self, forKey: .supportedUpstreamsIssueScopedTickets
            )
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hasHTTPSPublicOrigin, forKey: .hasHTTPSPublicOrigin)
        try container.encode(hasTrustedReverseProxy, forKey: .hasTrustedReverseProxy)
        try container.encode(listenerIsLoopbackOnly, forKey: .listenerIsLoopbackOnly)
        try container.encode(sessionCookiesAreHardened, forKey: .sessionCookiesAreHardened)
        try container.encode(supportsSessionRevocation, forKey: .supportsSessionRevocation)
        try container.encode(proxyStressTestCovered, forKey: .proxyStressTestCovered)
        try container.encode(lanDirectPlayEnabled, forKey: .lanDirectPlayEnabled)
        try container.encodeIfPresent(lanDirectPlayBlockedBy, forKey: .lanDirectPlayBlockedBy)
        try container.encode(
            supportedUpstreamsIssueScopedTickets, forKey: .supportedUpstreamsIssueScopedTickets
        )
        try container.encode(isReadyForLanAccess, forKey: .isReadyForLanAccess)
    }
}

/// 远程服务器下的一个资料库入口，镜像客户端远程分组里的 `EmbyLibrarySummary` 行。
public struct ServerRemoteLibraryEntry: Codable, Equatable, Sendable, Identifiable {
    /// 不透明 ID。绝不能直接用 `source_path`：它含主机名与百分号编码的库名。
    public let id: String
    public let title: String
    public let itemCount: Int

    public init(id: String, title: String, itemCount: Int) {
        self.id = id
        self.title = title
        self.itemCount = itemCount
    }
}

/// 一台已连接的远程媒体服务器及其资料库。
///
/// 客户端把每台远程服务器放在自己的侧栏分组里，绝不并进电影／剧集／音乐这些
/// 一级目录；网页按同一结构呈现，因此两端的"一级分类"含义完全一致。
public struct ServerRemoteSourceGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: String
    public let title: String
    public let kind: ServerRemoteSourceKind
    public let itemCount: Int
    public let libraries: [ServerRemoteLibraryEntry]

    public init(
        id: String,
        title: String,
        kind: ServerRemoteSourceKind,
        itemCount: Int,
        libraries: [ServerRemoteLibraryEntry]
    ) {
        self.id = id
        self.title = title
        self.kind = kind
        self.itemCount = itemCount
        self.libraries = libraries
    }
}
