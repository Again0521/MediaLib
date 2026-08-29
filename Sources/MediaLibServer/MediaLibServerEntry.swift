import Foundation
import MediaLibCore
import MediaLibServerProtocol

@main
struct MediaLibServer {
    static func main() async throws {
        let configuration = try ServerLaunchConfiguration.load()
        let arguments = Array(CommandLine.arguments.dropFirst())

        switch arguments.first {
        case "--health":
            try ServerCommandOutput.write(
                ServerHealth(
                    serverID: configuration.serverID,
                    serverName: configuration.serverName
                )
            )
        case "--describe":
            try ServerCommandOutput.write(
                MlinkServerDescriptor(
                    serverID: configuration.serverID,
                    serverName: configuration.serverName,
                    capabilities: ServerCommandOutput.capabilities
                )
            )
        case "--serve":
            let defaultDirectories = try FileAccessService.appDirectories()
            let dataDirectories = try ServerDataDirectories.fromEnvironment() ?? ServerDataDirectories(
                root: defaultDirectories.applicationSupport,
                database: defaultDirectories.database,
                databaseBackups: defaultDirectories.databaseBackups
            )
            let database = try DatabaseManager(
                url: dataDirectories.database,
                backupDirectory: dataDirectories.databaseBackups
            )
            let experienceRepository = ServerExperienceRepository(database: database)
            let operationalSettings = (try? experienceRepository.operationalSettings().value)
                ?? ServerOperationalSettings()
            // 保险库解锁状态由这台机器上的桌面 App 发布到同一个应用支持目录里，
            // 服务端只读它，而且每次请求都重新读一次：App 一上锁（或者会话过期），
            // 下一个请求就回到锁定。这里不做缓存——保险库的可见性不值得为几微秒
            // 冒"读到的是旧状态"的险。
            let vaultUnlockStore = VaultUnlockSessionStore(directory: dataDirectories.root)
            // 首页推荐名单同样由桌面 App 发布到这个目录，服务端只读、每次请求重读。
            // 它每天会换一份，缓存省不下什么，却会让网页比 App 慢一整天。
            let homeRecommendationStore = HomeRecommendationSnapshotStore(directory: dataDirectories.root)
            // 探测结果与上游读取器都只此一份：网页问轨道、导出内嵌字幕、决定要不要
            // 重封装、去 Emby 取字幕——这几件事必须看到同一份事实，否则同一部片子
            // 会在不同入口得到不同的答案。
            let mediaTrackCatalog = ServerMediaTrackCatalog()
            let remoteAssetFetcher = ServerRemoteAssetFetcher()
            let hlsPlaybackSessions = ServerHLSPlaybackSessionManager(
                remoteAssetFetcher: remoteAssetFetcher,
                maximumConcurrentSessions: operationalSettings.maximumTranscodeSessions,
                defaultRemoteBitrateMbps: operationalSettings.defaultRemoteBitrateMbps,
                operationalSettingsProvider: {
                    (try? experienceRepository.operationalSettings().value) ?? operationalSettings
                }
            )
            let catalog = ServerLibraryCatalog(
                database: database,
                vaultUnlockProvider: { vaultUnlockStore.isUnlocked() },
                homeRecommendationProvider: { homeRecommendationStore.current() },
                trackCatalog: mediaTrackCatalog,
                remoteAssetFetcher: remoteAssetFetcher
            )
            let administrationCatalog = ServerAdministrationCatalog(database: database)
            let identityRepository = ServerIdentityRepository(database: database)
            let authentication = try ServerAuthenticationService(database: database)
            let maintenanceService = ServerMaintenanceService(
                database: database,
                experienceRepository: experienceRepository,
                backupDirectory: dataDirectories.databaseBackups,
                transcodeCacheCleanup: { hlsPlaybackSessions.clearAllSessionsAndCache() }
            )
            let hostControlClient = ServerHostControlClient()
            let runtimeDiagnostics = ServerRuntimeDiagnostics(
                databaseURL: dataDirectories.database,
                volumeURL: dataDirectories.root,
                listenerMode: configuration.networkAccessMode,
                configuredPort: configuration.port,
                publicOrigin: configuration.publicOrigin?.absoluteString,
                trustedProxyAddresses: Array(configuration.trustedProxyAddresses),
                hostControlAvailable: { hostControlClient?.isAvailable == true }
            )
            // 首屏海报会同时抵达多条 320px 缩略图请求，冷启动时它们全要 decode +
            // JPEG 编码。上游取图有 8 个槽位，派生这一侧按可用核数取值（封顶 8），
            // 免得八路取回来的图排在四路解码后面；轻量服务仍只保留一路，以不牺牲
            // 媒体分发为前提压低本机瞬时 CPU 与磁盘占用。
            let isLightweightServer = ProcessInfo.processInfo.environment["MEDIALIB_SERVER_LIGHTWEIGHT"] == "1"
            let artworkThumbnailer = ServerArtworkThumbnailer(
                cacheDirectory: dataDirectories.root.appendingPathComponent(
                    "web-artwork-thumbnails",
                    isDirectory: true
                ),
                maximumConcurrentGenerations: isLightweightServer
                    ? 1
                    : max(4, ProcessInfo.processInfo.activeProcessorCount / 2)
            )
            let server = try LocalLoopbackHTTPServer(
                configuration: configuration,
                remoteSourceGroupsProvider: { try catalog.remoteSourceGroups(for: $0) },
                librarySnapshotProvider: { try catalog.snapshot(for: $0) },
                libraryBrowseProvider: { try catalog.browse($0, for: $1) },
                libraryCategoriesProvider: { try catalog.categories(for: $0) },
                navigationRevisionProvider: { try catalog.navigationRevision(for: $0) },
                homeRecommendationsProvider: { try catalog.homeRecommendations(for: $0) },
                libraryFacetsProvider: { try catalog.facets(type: $0, group: $1, for: $2) },
                mediaDetailProvider: { try catalog.publicDetail(id: $0, for: $1) },
                seriesDetailProvider: { try catalog.seriesDetail(id: $0, for: $1) },
                seriesEpisodesProvider: { try catalog.seriesEpisodes(id: $0, season: $1, offset: $2, limit: $3, for: $4) },
                peopleProvider: { try catalog.people(searchText: $0, offset: $1, limit: $2, for: $3) },
                personDetailProvider: { try catalog.personDetail(id: $0, offset: $1, limit: $2, for: $3) },
                collectionsProvider: { try catalog.collections(offset: $0, limit: $1, for: $2) },
                collectionDetailProvider: { try catalog.collectionDetail(id: $0, offset: $1, limit: $2, for: $3) },
                smartCollectionsProvider: { try catalog.smartCollections(offset: $0, limit: $1, for: $2) },
                smartCollectionDetailProvider: { try catalog.smartCollectionDetail(id: $0, offset: $1, limit: $2, for: $3) },
                musicPlaylistsProvider: { try catalog.musicPlaylists(offset: $0, limit: $1, for: $2) },
                musicPlaylistDetailProvider: { try catalog.musicPlaylistDetail(id: $0, offset: $1, limit: $2, for: $3) },
                musicItemsProvider: { try catalog.musicItems(for: $0) },
                queueProvider: { try catalog.queue(for: $0) },
                queueMutationProvider: { try catalog.mutateQueue(request: $0, for: $1) },
                mediaPlaybackStateUpdater: { try catalog.updatePlaybackState(id: $0, request: $1, for: $2) },
                mediaPreferenceUpdater: { try catalog.updatePreference(id: $0, preference: $1, for: $2) },
                mediaAssetProvider: { try catalog.publicAsset(id: $0, for: $1, requiring: $2) },
                webVTTSubtitleTracksProvider: { try catalog.webVTTSubtitleTracks(id: $0, for: $1) },
                subtitleTrackProvider: { try catalog.subtitleTrack(id: $0, trackID: $1, for: $2) },
                playbackTracksProvider: { try catalog.playbackTracks(id: $0, for: $1) },
                audioRemuxProvider: {
                    try catalog.audioRemuxStream(id: $0, audioTrackID: $1, startSeconds: $2, for: $3)
                },
                remuxStartProvider: { try catalog.remuxStartSeconds(id: $0, at: $1, for: $2) },
                hlsSessionProvider: { itemID, request, principal in
                    let policy = try experienceRepository.userPolicy(userID: principal.userID).value
                    guard policy.playbackAllowed else { return nil }
                    guard var asset = try catalog.publicAsset(
                        id: itemID,
                        for: principal,
                        requiring: .playMedia
                    ) else { return nil }
                    if let remoteURL = asset.remoteURL, asset.byteLength <= 0 {
                        guard let length = remoteAssetFetcher.mediaByteLength(url: remoteURL), length > 0 else {
                            return nil
                        }
                        asset = ServerMediaAsset(
                            id: asset.id,
                            remoteURL: remoteURL,
                            byteLength: length,
                            contentType: asset.contentType
                        )
                    }
                    let probe = mediaTrackCatalog.probe(asset: asset)
                    let videoCodec = probe?.video.first?.codec
                    let videoHeight = probe?.video.first?.height
                    let sourceIsHDR = probe?.video.first?.isHDR == true
                    let selectedAudioID = request.audioTrackID ?? 0
                    let audioCodec = probe?.audio.first(where: { $0.typeOrdinal == selectedAudioID })?.codec
                    let burnInSubtitleStreamIndex: Int? = {
                        guard let subtitleTrackID = request.subtitleTrackID,
                              let reference = try? catalog.subtitleTrack(
                                id: itemID,
                                trackID: subtitleTrackID,
                                for: principal
                              ),
                              reference.renderingMode == .burnIn,
                              case let .embedded(_, streamIndex) = reference.source
                        else { return nil }
                        return streamIndex
                    }()
                    guard request.subtitleTrackID == nil || burnInSubtitleStreamIndex != nil else { return nil }
                    let requestedStart = request.startSeconds ?? 0
                    let actualStart = videoCodec?.lowercased() == "h264"
                        ? (try catalog.remuxStartSeconds(id: itemID, at: requestedStart, for: principal) ?? requestedStart)
                        : requestedStart
                    let normalizedRequest = ServerHLSPlaybackRequest(
                        audioTrackID: request.audioTrackID,
                        subtitleTrackID: request.subtitleTrackID,
                        startSeconds: request.startSeconds,
                        durationSeconds: probe?.durationSeconds ?? request.durationSeconds,
                        capabilities: request.capabilities,
                        quality: request.quality,
                        maximumBitrateMbps: request.maximumBitrateMbps
                    )
                    return hlsPlaybackSessions.create(
                        asset: asset,
                        request: normalizedRequest,
                        actualStartSeconds: actualStart,
                        videoCodec: videoCodec,
                        videoHeight: videoHeight,
                        sourceIsHDR: sourceIsHDR,
                        audioCodec: audioCodec,
                        burnInSubtitleStreamIndex: burnInSubtitleStreamIndex,
                        principal: principal,
                        policy: policy
                    )
                },
                hlsStatusProvider: {
                    hlsPlaybackSessions.status(sessionID: $0, principal: $1)
                },
                hlsResourceProvider: {
                    hlsPlaybackSessions.resource(sessionID: $0, fileName: $1, principal: $2)
                },
                hlsCancellationProvider: {
                    hlsPlaybackSessions.cancel(sessionID: $0, principal: $1)
                },
                adminHLSSessionsProvider: {
                    hlsPlaybackSessions.administrativeSessions()
                },
                adminHLSCancellationProvider: { sessionID, principal in
                    guard hlsPlaybackSessions.administrativelyCancel(sessionID: sessionID) else { return false }
                    try? identityRepository.appendSecurityEvent(ServerSecurityEvent(
                        category: .session,
                        action: "playback.session.terminated",
                        outcome: .success,
                        actorUserID: principal.userID,
                        sessionID: principal.sessionID,
                        deviceID: principal.deviceID,
                        detailCode: "administrator"
                    ))
                    return true
                },
                artworkAssetProvider: { try catalog.publicArtwork(id: $0, kind: $1, for: $2) },
                detailImageProvider: { try catalog.detailImageAsset(itemID: $0, kind: $1, index: $2, for: $3) },
                vaultAccessProvider: { try catalog.vaultAccess(for: $0) },
                artworkThumbnailer: artworkThumbnailer,
                remoteAssetFetcher: remoteAssetFetcher,
                mediaTrackCatalog: mediaTrackCatalog,
                playbackInfoProvider: { itemID, principal in
                    guard let asset = try catalog.publicAsset(
                        id: itemID,
                        for: principal,
                        requiring: ServerPermission.playMedia
                    ), asset.remoteURL == nil else { return nil }
                    return mediaTrackCatalog.playbackInfo(for: asset)
                },
                currentUserProfileProvider: { try authentication.currentUserProfile(for: $0) },
                administrationCatalog: administrationCatalog,
                experienceRepository: experienceRepository,
                maintenanceService: maintenanceService,
                runtimeDiagnosticsProvider: { runtimeDiagnostics.snapshot() },
                runtimeConfigurationApplyProvider: { request in
                    guard let hostControlClient else { return false }
                    let normalized = ServerModeConfiguration(
                        serverName: request.serverName,
                        port: request.port,
                        networkAccessMode: request.networkAccessMode,
                        publicOrigin: request.publicOrigin,
                        trustedProxyAddresses: request.trustedProxyAddresses
                    )
                    let response = try hostControlClient.apply(ServerHostRuntimeConfiguration(
                        serverName: normalized.serverName,
                        port: normalized.port,
                        networkAccessMode: normalized.networkAccessMode.rawValue,
                        publicOrigin: normalized.publicOrigin,
                        trustedProxyAddresses: normalized.trustedProxyAddresses
                    ))
                    return response.status == .accepted
                },
                authenticationService: authentication,
                authenticationProvider: { try authentication.principal(forRequestHead: $0) }
            )
            switch configuration.networkAccessMode {
            case .loopbackOnly:
                print("MediaLibServer 正在监听 http://\(configuration.host):\(configuration.port)")
                try server.run()
            case .lanHTTPS:
                guard #available(macOS 14.0, *) else {
                    throw ServerConfigurationError.lanHTTPSRequiresMacOS14
                }
                let lanServer = try LANHTTPSServer(
                    configuration: configuration,
                    dataDirectory: dataDirectories.root,
                    requestHandler: server
                )
                print("MediaLibServer 正在监听 \(configuration.publicOrigin?.absoluteString ?? "https://0.0.0.0:\(configuration.port)")")
                try await lanServer.run()
            }
        case "--help", "-h":
            print(ServerCommandOutput.usage)
        default:
            throw ServerConfigurationError.runtimeNotInstalled(
                host: configuration.host,
                port: configuration.port
            )
        }
    }
}

/// Docker/服务进程的数据根目录适配层。当前服务仍只监听回环；该目录注入只为让
/// 数据库与备份不再强制依赖 macOS Application Support，为后续纯服务端拆分预留稳定边界。
struct ServerDataDirectories: Equatable {
    let root: URL
    let database: URL
    let databaseBackups: URL

    static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) throws -> Self? {
        guard let rawValue = environment["MEDIALIB_SERVER_DATA_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !rawValue.isEmpty else {
            return nil
        }
        guard rawValue.hasPrefix("/") else {
            throw ServerDataDirectoryError.notAbsolute(rawValue)
        }
        let root = URL(fileURLWithPath: rawValue, isDirectory: true).standardizedFileURL
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw ServerDataDirectoryError.notDirectory(root.path)
        }
        let backups = root.appendingPathComponent("backups", isDirectory: true)
        try fileManager.createDirectory(
            at: backups,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        return Self(
            root: root,
            database: root.appendingPathComponent("medialib.sqlite", isDirectory: false),
            databaseBackups: backups
        )
    }
}

enum ServerDataDirectoryError: LocalizedError, Equatable {
    case notAbsolute(String)
    case notDirectory(String)

    var errorDescription: String? {
        switch self {
        case let .notAbsolute(path): return "MEDIALIB_SERVER_DATA_DIR 必须是绝对路径：\(path)。"
        case let .notDirectory(path): return "MEDIALIB_SERVER_DATA_DIR 不是可用目录：\(path)。"
        }
    }
}

enum ServerCommandOutput {
    static let capabilities = [
        "administration-read",
        "authenticated-library",
        "categorized-library-browse",
        "download-media",
        "protected-artwork",
        "health",
        "loopback-range-streaming",
        "media-detail",
        "media-probe",
        "per-user-playback-state",
        "per-user-playback-queue",
        "server-discovery",
        "web-playback"
    ]

    static let usage = """
    MediaLibServer 安全 Web 服务
      --health   输出不含敏感信息的服务器健康 JSON
      --describe 输出 Mlink 服务描述 JSON
      --serve    按 loopback 或 lan-https 模式启动认证 Web/媒体服务

    当前具备登录/刷新/注销、桌面多用户与逐资料库授权、安全审计、
    Web 列表/详情/浏览器原生播放、逐用户续播/已看、只读管理、播放探测、HTTP Range 与分级限速。限速参数压测、
    告警聚合与公网部署尚未完成。lan-https 需要 macOS 14+、私有 IPv4 HTTPS Origin，
    使用内建 TLS 监听；loopback 也可由显式配置的本机 HTTPS 反向代理安全转发。
    两种方式都不会开放明文局域网或公网监听。

    远程媒体始终经本服务同源代理。MEDIALIB_SERVER_LAN_DIRECT_PLAY 默认关闭，只解除
    「已验证局域网直连」的配置层门禁；Emby/Jellyfin/Plex 的播放地址携带账号级长期令牌，
    不满足单媒体短时票据要求，因此仍会走代理。管理员可用 /api/v1/admin/lan-readiness 自检。
    """

    static func write<T: Encodable>(_ value: T) throws {
        let data = try jsonDataOrThrow(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    static func jsonData<T: Encodable>(_ value: T) -> Data? {
        try? jsonDataOrThrow(value)
    }

    private static func jsonDataOrThrow<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return try encoder.encode(value)
    }
}

struct ServerLaunchConfiguration: Sendable {
    let host: String
    let port: Int
    let networkAccessMode: ServerNetworkAccessMode
    let serverID: String
    let serverName: String
    let publicOrigin: URL?
    let trustedProxyAddresses: Set<String>
    /// 可选的"已验证局域网直连"策略开关，默认关闭。开启只是解除配置层门禁，
    /// 逐请求的网段与上游凭据作用域仍要各自通过，见 `ServerRemoteAccessPolicy`。
    let lanDirectPlayEnabled: Bool

    static func load(environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Self {
        let host = environment["MEDIALIB_SERVER_HOST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalizedHost = host?.isEmpty == false ? host! : "127.0.0.1"
        guard ["127.0.0.1", "localhost"].contains(normalizedHost.lowercased()) else {
            throw ServerConfigurationError.nonLoopbackHost(normalizedHost)
        }

        let portValue = environment["MEDIALIB_SERVER_PORT"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let port = portValue.flatMap(Int.init) ?? 8098
        guard (1...65_535).contains(port) else {
            throw ServerConfigurationError.invalidPort(portValue ?? "")
        }

        let networkAccessModeValue = environment["MEDIALIB_SERVER_NETWORK_ACCESS_MODE"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let networkAccessMode: ServerNetworkAccessMode
        switch networkAccessModeValue.lowercased() {
        case "", ServerNetworkAccessMode.loopbackOnly.rawValue:
            networkAccessMode = .loopbackOnly
        case ServerNetworkAccessMode.lanHTTPS.rawValue:
            networkAccessMode = .lanHTTPS
        default:
            throw ServerConfigurationError.invalidNetworkAccessMode(networkAccessModeValue)
        }

        let serverID = environment["MEDIALIB_SERVER_ID"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let serverName = environment["MEDIALIB_SERVER_NAME"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicOriginValue = environment["MEDIALIB_SERVER_PUBLIC_ORIGIN"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        let publicOrigin: URL?
        if let publicOriginValue, !publicOriginValue.isEmpty {
            guard let url = URL(string: publicOriginValue),
                  let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
                  components.scheme?.lowercased() == "https",
                  components.host?.isEmpty == false,
                  components.user == nil,
                  components.password == nil,
                  (components.path.isEmpty || components.path == "/"),
                  components.query == nil,
                  components.fragment == nil,
                  components.port == nil || (1...65_535).contains(components.port ?? 0)
            else {
                throw ServerConfigurationError.invalidPublicOrigin(publicOriginValue)
            }
            publicOrigin = url
        } else {
            publicOrigin = nil
        }

        let proxyValues = (environment["MEDIALIB_SERVER_TRUSTED_PROXIES"] ?? "")
            .split(separator: ",", omittingEmptySubsequences: true)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let trustedProxyAddresses = Set(proxyValues)
        guard proxyValues.allSatisfy(Self.isIPv4Address),
              trustedProxyAddresses.isEmpty || publicOrigin != nil
        else {
            throw ServerConfigurationError.invalidTrustedProxyConfiguration
        }

        let lanDirectPlayValue = environment["MEDIALIB_SERVER_LAN_DIRECT_PLAY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let lanDirectPlayEnabled: Bool
        switch lanDirectPlayValue.lowercased() {
        case "", "0", "false", "no": lanDirectPlayEnabled = false
        case "1", "true", "yes": lanDirectPlayEnabled = true
        default: throw ServerConfigurationError.invalidLanDirectPlayConfiguration
        }
        // 直连必须建立在可信传输边界之上；没有 HTTPS 公开 Origin 与可信反代时
        // 开这个开关只会制造"以为已经生效"的错觉，因此直接拒绝启动。
        guard !lanDirectPlayEnabled || (publicOrigin != nil && !trustedProxyAddresses.isEmpty) else {
            throw ServerConfigurationError.invalidLanDirectPlayConfiguration
        }
        return Self(
            host: normalizedHost,
            port: port,
            networkAccessMode: networkAccessMode,
            // App/容器必须注入持久化 ID；默认值只用于开发命令和本机健康探测。
            serverID: serverID?.isEmpty == false ? serverID! : "medialib-development",
            serverName: serverName?.isEmpty == false ? serverName! : "MediaLIB Server",
            publicOrigin: publicOrigin,
            trustedProxyAddresses: trustedProxyAddresses,
            lanDirectPlayEnabled: lanDirectPlayEnabled
        )
    }

    private static func isIPv4Address(_ value: String) -> Bool {
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        return parts.allSatisfy { part in
            !part.isEmpty && part.count <= 3 && part.allSatisfy(\.isNumber) &&
                Int(part).map { (0...255).contains($0) } == true
        }
    }
}

enum ServerConfigurationError: LocalizedError, Equatable {
    case invalidPort(String)
    case invalidNetworkAccessMode(String)
    case nonLoopbackHost(String)
    case invalidPublicOrigin(String)
    case invalidTrustedProxyConfiguration
    case invalidLanDirectPlayConfiguration
    case lanHTTPSRuntimeUnavailable
    case lanHTTPSRequiresMacOS14
    case runtimeNotInstalled(host: String, port: Int)

    var errorDescription: String? {
        switch self {
        case let .invalidPort(value):
            return "MEDIALIB_SERVER_PORT 无效：\(value)。端口必须在 1 到 65535 之间。"
        case let .invalidNetworkAccessMode(value):
            return "MEDIALIB_SERVER_NETWORK_ACCESS_MODE 无效：\(value)。只接受 loopback 或 lan-https。"
        case let .nonLoopbackHost(host):
            return "当前安全门槛下服务端只允许监听本机回环地址，不能使用：\(host)。"
        case let .invalidPublicOrigin(origin):
            return "MEDIALIB_SERVER_PUBLIC_ORIGIN 必须是无路径的 HTTPS 地址：\(origin)。"
        case .invalidTrustedProxyConfiguration:
            return "MEDIALIB_SERVER_TRUSTED_PROXIES 必须是 IPv4 地址列表，并且只能与 HTTPS 公开 Origin 一起使用。"
        case .invalidLanDirectPlayConfiguration:
            return "MEDIALIB_SERVER_LAN_DIRECT_PLAY 只接受 0/1，并且必须同时配置 HTTPS 公开 Origin 与可信反向代理。"
        case .lanHTTPSRuntimeUnavailable:
            return "局域网 HTTPS 配置已保存，但当前运行时尚未接入 TLS 监听；服务已保持关闭，未退化为明文连接。"
        case .lanHTTPSRequiresMacOS14:
            return "内建局域网 HTTPS 服务需要 macOS 14 或更高版本。"
        case let .runtimeNotInstalled(host, port):
            return "MediaLibServer 未选择运行命令，尚未监听 \(host):\(port)。使用 --health、--describe、--serve 或 --help。"
        }
    }
}
