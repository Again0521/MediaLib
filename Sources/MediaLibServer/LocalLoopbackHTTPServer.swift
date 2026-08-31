import Foundation
import MediaLibCore
import MediaLibServerProtocol

#if os(Linux)
import Glibc
private func streamSocketType() -> Int32 { Int32(SOCK_STREAM.rawValue) }
#else
import Darwin
private func streamSocketType() -> Int32 { SOCK_STREAM }
#endif

/// 当前认证回环 HTTP 适配层。它承担严格请求解析、静态 Web、API 与流式媒体，
/// 但仍不承担 TLS、可信代理或公网访问；开放远程前会由生产 HTTP 框架替换。
final class LocalLoopbackHTTPServer: @unchecked Sendable {
    private static let maximumConcurrentConnections = 32
    private static let maximumRequestsPerConnection = 64
    private static let requestDeadline: TimeInterval = 10
    private static let connectionLifetime: TimeInterval = 60

    private let configuration: ServerLaunchConfiguration
    private let router: LocalHTTPRouter
    private let requestSecurityPolicy: HTTPRequestSecurityPolicy
    private let clientQueue = DispatchQueue(
        label: "MediaLibServer.HTTPClients",
        qos: .userInitiated,
        attributes: .concurrent
    )
    private let connectionSlots = DispatchSemaphore(value: maximumConcurrentConnections)

    init(
        configuration: ServerLaunchConfiguration,
        remoteSourceGroupsProvider: @escaping (ServerRequestPrincipal) throws -> [ServerRemoteSourceGroup] = { _ in [] },
        librarySnapshotProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibrarySnapshot = { _ in
            ServerLibrarySnapshot(
                summary: ServerLibrarySummary(totalItemCount: 0, countsByType: [:]),
                items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
            )
        },
        libraryBrowseProvider: @escaping (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage = { query, _ in
            ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
        },
        libraryCategoriesProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse = { _ in
            ServerLibraryCategoriesResponse(categories: [])
        },
        navigationRevisionProvider: @escaping (ServerRequestPrincipal) throws -> String = { _ in UUID().uuidString },
        // 首页推荐名单由客户端算好发布，服务端只按请求者的授权把它查出来。
        // 默认空 = 没有客户端（测试、纯服务端部署），首页回落到服务端自己的推导。
        homeRecommendationsProvider: @escaping (ServerRequestPrincipal) throws -> ServerHomeRecommendations = { _ in .empty },
        libraryFacetsProvider: @escaping (String?, ServerLibraryMediaGroup?, ServerRequestPrincipal) throws -> ServerLibraryFacetsResponse = { _, _, _ in
            ServerLibraryFacetsResponse(genres: [], availableSorts: [])
        },
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail? = { _, _ in nil },
        seriesDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerSeriesDetail? = { _, _ in nil },
        seriesEpisodesProvider: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage? = { _, _, _, _, _ in nil },
        peopleProvider: @escaping (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage = { _, offset, limit, _ in ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        personDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail? = { _, _, _, _ in nil },
        collectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage = { offset, limit, _ in ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        collectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail? = { _, _, _, _ in nil },
        // 每个新 provider 都给一个"返回空"的默认值：现有的二十多个测试文件不必为了
        // 编译而各加一行。
        smartCollectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionsPage = { offset, limit, _ in ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        smartCollectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionDetail? = { _, _, _, _ in nil },
        musicPlaylistsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage = { offset, limit, _ in ServerMusicPlaylistsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        musicPlaylistDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistDetail? = { _, _, _, _ in nil },
        musicItemsProvider: @escaping (ServerRequestPrincipal) throws -> [ServerLibraryItem] = { _ in [] },
        queueProvider: @escaping (ServerRequestPrincipal) throws -> ServerQueueResponse = { _ in ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) },
        queueMutationProvider: @escaping (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse? = { _, _ in nil },
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaPreferenceUpdater: @escaping (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        webVTTSubtitleTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]? = { _, _ in nil },
        subtitleTrackProvider: @escaping (String, Int, ServerRequestPrincipal) throws -> ServerSubtitleTrackReference? = { _, _, _ in nil },
        playbackTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerWebPlaybackTrackSet? = { _, _ in nil },
        audioRemuxProvider: @escaping (String, Int, Double, ServerRequestPrincipal) throws -> ServerAudioRemuxStream? = { _, _, _, _ in nil },
        remuxStartProvider: @escaping (String, Double, ServerRequestPrincipal) throws -> Double? = { _, _, _ in nil },
        hlsSessionProvider: @escaping (String, ServerHLSPlaybackRequest, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor? = { _, _, _ in nil },
        hlsStatusProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor? = { _, _ in nil },
        hlsResourceProvider: @escaping (String, String, ServerRequestPrincipal) throws -> ServerHLSResource? = { _, _, _ in nil },
        hlsCancellationProvider: @escaping (String, ServerRequestPrincipal) -> Void = { _, _ in },
        adminHLSSessionsProvider: @escaping () -> [ServerAdminHLSPlaybackSession] = { [] },
        adminHLSCancellationProvider: @escaping (String, ServerRequestPrincipal) -> Bool = { _, _ in false },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        detailImageProvider: @escaping (String, ServerDetailImageKind, Int, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _, _ in nil },
        /// 保险库对这个账号的可见性。默认 `.locked`——没有显式接线的调用方拿不到
        /// 保险库内容，这是这一整条链路的"失败即锁定"起点。
        vaultAccessProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibraryCatalog.VaultAccess = { _ in .locked },
        artworkThumbnailer: ServerArtworkThumbnailer = ServerArtworkThumbnailer(),
        remoteAssetFetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher(),
        /// 内嵌字幕导出与音轨探测共用的 ffprobe 结果缓存。把同一个实例也交给
        /// `ServerLibraryCatalog`，一次探测两处都算数。
        mediaTrackCatalog: ServerMediaTrackCatalog = ServerMediaTrackCatalog(),
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        currentUserProfileProvider: @escaping (ServerRequestPrincipal) throws -> ServerCurrentUserProfile? = { _ in nil },
        administrationCatalog: ServerAdministrationCatalog? = nil,
        experienceRepository: ServerExperienceRepository? = nil,
        maintenanceService: ServerMaintenanceService? = nil,
        runtimeDiagnosticsProvider: @escaping () -> ServerRuntimeDiagnosticsSnapshot? = { nil },
        runtimeConfigurationApplyProvider: @escaping (ServerRuntimeConfigurationMutationRequest) throws -> Bool = { _ in false },
        authenticationService: ServerAuthenticationService? = nil,
        authenticationProvider: @escaping (String) throws -> ServerRequestPrincipal? = { _ in nil },
        rateLimiter: ServerRequestRateLimiter = ServerRequestRateLimiter(),
        csrfToken: String = ServerRequestSecurityToken.generate()
    ) throws {
        guard ["127.0.0.1", "localhost"].contains(configuration.host.lowercased()) else {
            throw ServerConfigurationError.nonLoopbackHost(configuration.host)
        }
        var allowedHosts: Set<String> = ["127.0.0.1", "localhost"]
        if configuration.networkAccessMode == .lanHTTPS,
           let publicHost = configuration.publicOrigin?.host?.lowercased() {
            allowedHosts.insert(publicHost)
        }
        self.configuration = configuration
        self.requestSecurityPolicy = HTTPRequestSecurityPolicy(
            allowedHosts: allowedHosts,
            allowedPort: configuration.port,
            csrfToken: csrfToken,
            trustedProxyAddresses: configuration.trustedProxyAddresses,
            publicOrigin: configuration.publicOrigin
        )
        self.router = LocalHTTPRouter(
            serverID: configuration.serverID,
            serverName: configuration.serverName,
            remoteAccessPolicy: ServerRemoteAccessPolicy(
                publicOrigin: configuration.publicOrigin,
                trustedProxyAddresses: configuration.trustedProxyAddresses,
                lanDirectPlayEnabled: configuration.lanDirectPlayEnabled
            ),
            remoteSourceGroupsProvider: remoteSourceGroupsProvider,
            librarySnapshotProvider: librarySnapshotProvider,
            libraryBrowseProvider: libraryBrowseProvider,
            libraryCategoriesProvider: libraryCategoriesProvider,
            navigationRevisionProvider: navigationRevisionProvider,
            homeRecommendationsProvider: homeRecommendationsProvider,
            libraryFacetsProvider: libraryFacetsProvider,
            mediaDetailProvider: mediaDetailProvider,
            seriesDetailProvider: seriesDetailProvider,
            seriesEpisodesProvider: seriesEpisodesProvider,
            peopleProvider: peopleProvider,
            personDetailProvider: personDetailProvider,
            collectionsProvider: collectionsProvider,
            collectionDetailProvider: collectionDetailProvider,
            smartCollectionsProvider: smartCollectionsProvider,
            smartCollectionDetailProvider: smartCollectionDetailProvider,
            musicPlaylistsProvider: musicPlaylistsProvider,
            musicPlaylistDetailProvider: musicPlaylistDetailProvider,
            musicItemsProvider: musicItemsProvider,
            queueProvider: queueProvider,
            queueMutationProvider: queueMutationProvider,
            mediaPlaybackStateUpdater: mediaPlaybackStateUpdater,
            mediaPreferenceUpdater: mediaPreferenceUpdater,
            mediaAssetProvider: mediaAssetProvider,
            webVTTSubtitleTracksProvider: webVTTSubtitleTracksProvider,
            subtitleTrackProvider: subtitleTrackProvider,
            playbackTracksProvider: playbackTracksProvider,
            audioRemuxProvider: audioRemuxProvider,
            remuxStartProvider: remuxStartProvider,
            hlsSessionProvider: hlsSessionProvider,
            hlsStatusProvider: hlsStatusProvider,
            hlsResourceProvider: hlsResourceProvider,
            hlsCancellationProvider: hlsCancellationProvider,
            adminHLSSessionsProvider: adminHLSSessionsProvider,
            adminHLSCancellationProvider: adminHLSCancellationProvider,
            artworkAssetProvider: artworkAssetProvider,
            detailImageProvider: detailImageProvider,
            vaultAccessProvider: vaultAccessProvider,
            artworkThumbnailer: artworkThumbnailer,
            remoteAssetFetcher: remoteAssetFetcher,
            mediaTrackCatalog: mediaTrackCatalog,
            playbackInfoProvider: playbackInfoProvider,
            currentUserProfileProvider: currentUserProfileProvider,
            administrationCatalog: administrationCatalog,
            experienceRepository: experienceRepository,
            maintenanceService: maintenanceService,
            runtimeDiagnosticsProvider: runtimeDiagnosticsProvider,
            runtimeConfigurationApplyProvider: runtimeConfigurationApplyProvider,
            authenticationService: authenticationService,
            authenticationProvider: authenticationProvider,
            rateLimiter: rateLimiter,
            csrfToken: csrfToken
        )
    }

    func run() throws {
        guard configuration.networkAccessMode == .loopbackOnly else {
            throw ServerConfigurationError.lanHTTPSRuntimeUnavailable
        }
        let listener = try makeListener()
        defer { _ = close(listener) }

        while true {
            var peerAddress = sockaddr_in()
            var peerAddressLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let client = withUnsafeMutablePointer(to: &peerAddress) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    accept(listener, $0, &peerAddressLength)
                }
            }
            if client < 0 {
                if errno == EINTR { continue }
                throw LocalHTTPServerError.acceptFailed(errno: errno)
            }
            guard configureTimeouts(for: client) else {
                _ = close(client)
                continue
            }
            guard connectionSlots.wait(timeout: .now()) == .success else {
                write(response: .tooManyRequests(retryAfter: 1), to: client)
                _ = close(client)
                continue
            }
            let clientAddressKey = Self.clientAddressKey(peerAddress)
            clientQueue.async { [self] in
                defer { connectionSlots.signal() }
                handle(client: client, clientAddressKey: clientAddressKey)
            }
        }
    }

    private func makeListener() throws -> Int32 {
        let descriptor = socket(AF_INET, streamSocketType(), 0)
        guard descriptor >= 0 else {
            throw LocalHTTPServerError.socketCreationFailed(errno: errno)
        }

        var reuseAddress: Int32 = 1
        guard setsockopt(
            descriptor,
            SOL_SOCKET,
            SO_REUSEADDR,
            &reuseAddress,
            socklen_t(MemoryLayout<Int32>.size)
        ) == 0 else {
            let error = errno
            _ = close(descriptor)
            throw LocalHTTPServerError.socketOptionFailed(errno: error)
        }

        var address = sockaddr_in()
        #if !os(Linux)
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        #endif
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(configuration.port).bigEndian)
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            _ = close(descriptor)
            throw LocalHTTPServerError.loopbackAddressCreationFailed
        }

        let bindResult = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bindResult == 0 else {
            let error = errno
            _ = close(descriptor)
            throw LocalHTTPServerError.bindFailed(port: configuration.port, errno: error)
        }
        guard listen(descriptor, SOMAXCONN) == 0 else {
            let error = errno
            _ = close(descriptor)
            throw LocalHTTPServerError.listenFailed(errno: error)
        }
        return descriptor
    }

    private func handle(client: Int32, clientAddressKey: String) {
        defer { _ = close(client) }
        let connectionDeadline = ProcessInfo.processInfo.systemUptime + Self.connectionLifetime
        for requestIndex in 0..<Self.maximumRequestsPerConnection {
            guard ProcessInfo.processInfo.systemUptime <= connectionDeadline,
                  let received = receiveRequest(from: client)
            else { return }
            let request: LocalHTTPRequest
            switch received {
            case let .request(value): request = value
            case let .rejected(rejection):
                write(response: response(for: rejection), to: client)
                return
            }
            let response = response(
                for: request.head,
                body: request.body,
                clientAddressKey: clientAddressKey
            )
            let keepAlive = requestIndex + 1 < Self.maximumRequestsPerConnection &&
                ProcessInfo.processInfo.systemUptime <= connectionDeadline &&
                Self.supportsPersistentConnection(request.head)
            // 实际是否复用由写出方决定：长度未知的响应（重封装流）只能以关闭连接
            // 结束，这里不能再回去等下一个请求——那会让连接一直挂到超时。
            let reused = write(
                response: response,
                to: client,
                keepAlive: keepAlive
            )
            if !reused { return }
        }
    }

    /// Shared request boundary used by both the legacy loopback socket and the
    /// maintained Hummingbird TLS listener. Keeping validation here prevents the
    /// LAN transport from silently bypassing Host, Origin, CSRF or rate-limit keys.
    func response(
        for requestHead: String,
        body: Data,
        clientAddressKey: String,
        isDirectTLS: Bool = false
    ) -> LocalHTTPResponse {
        if let rejection = requestSecurityPolicy.validate(
            requestHead,
            bodyLength: body.count,
            clientAddressKey: clientAddressKey,
            isDirectTLS: isDirectTLS
        ) {
            return response(for: rejection)
        }
        return router.response(
            for: requestHead,
            body: body,
            clientAddressKey: requestSecurityPolicy.effectiveClientAddressKey(
                for: requestHead,
                connectedAddressKey: clientAddressKey
            )
        )
    }

    private func response(for rejection: HTTPRequestSecurityPolicy.Rejection) -> LocalHTTPResponse {
        switch rejection {
        case .badRequest: return .badRequest()
        case .forbidden: return .forbidden()
        case .payloadTooLarge: return .payloadTooLarge()
        }
    }

    private func receiveRequest(from client: Int32) -> LocalHTTPRequestReceiveResult? {
        let headerTerminator = Data([13, 10, 13, 10])
        let deadline = ProcessInfo.processInfo.systemUptime + Self.requestDeadline
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)

        while request.range(of: headerTerminator) == nil {
            guard ProcessInfo.processInfo.systemUptime <= deadline else {
                return .rejected(.badRequest)
            }
            guard request.count < 16_384 else { return .rejected(.payloadTooLarge) }
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return nil }
            request.append(contentsOf: buffer.prefix(Int(count)))
        }
        guard let separator = request.range(of: headerTerminator) else { return .rejected(.badRequest) }
        let headData = request[..<separator.upperBound]
        guard headData.count <= 16_384,
              let head = String(data: headData, encoding: .utf8),
              let declaredLength = Self.declaredContentLength(in: head)
        else {
            return .rejected(.badRequest)
        }
        guard declaredLength <= 4_096 else { return .rejected(.payloadTooLarge) }
        var body = Data(request[separator.upperBound...])
        guard body.count <= declaredLength else { return .rejected(.badRequest) }
        while body.count < declaredLength {
            guard ProcessInfo.processInfo.systemUptime <= deadline else {
                return .rejected(.badRequest)
            }
            let remaining = min(buffer.count, declaredLength - body.count)
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(client, bytes.baseAddress, remaining, 0)
            }
            guard count > 0 else { return .rejected(.badRequest) }
            body.append(contentsOf: buffer.prefix(Int(count)))
        }
        return .request(LocalHTTPRequest(head: head, body: body))
    }

    private func configureTimeouts(for client: Int32) -> Bool {
        var timeout = timeval(tv_sec: Int(Self.requestDeadline), tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        // 往一条**对端已经关掉**的 socket 上 `send()` 会触发 SIGPIPE，而它的默认
        // 处置是终止进程——整台服务器跟着一个离开的浏览器一起死。
        //
        // 这不是理论风险：读者拖动进度条、换音轨、关掉标签页，浏览器都会中止
        // 正在传输的媒体响应。此前它一直藏着，是因为直放的每个 Range 都很短、
        // 客户端多半读完才走；实时重封装流会一直写到片尾，中止发生在它写的正中间，
        // 于是每一次跳转都是一次必然的进程终止（真实验收里一次就复现）。
        //
        // `SO_NOSIGPIPE` 让写失败表现为 `EPIPE` 返回值，正是写出路径已经在处理的
        // 那种失败。它是逐 socket 的，比全局忽略信号更精确。
        var noSignalPipe: Int32 = 1
        return setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0 &&
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0 &&
            setsockopt(
                client, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size)
            ) == 0
    }

    private static func declaredContentLength(in head: String) -> Int? {
        let values = head.components(separatedBy: "\r\n").dropFirst().compactMap { line -> String? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == "content-length"
            else { return nil }
            return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard values.count <= 1 else { return nil }
        guard let value = values.first else { return 0 }
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let length = Int(value), length >= 0 else { return nil }
        return length
    }

    /// HTTP/1.1 reuses a connection unless the client explicitly closes it. HTTP/1.0
    /// remains close-by-default and must explicitly opt in. Request validation handles
    /// duplicate/ambiguous headers before this policy is used for a response.
    static func supportsPersistentConnection(_ head: String) -> Bool {
        let lines = head.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return false }
        let requestParts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard requestParts.count == 3 else { return false }
        let version = requestParts[2].uppercased()
        let connectionTokens = lines.dropFirst().compactMap { line -> [String]? in
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].trimmingCharacters(in: .whitespaces).lowercased() == "connection"
            else { return nil }
            return line[line.index(after: colon)...]
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
        }.flatMap { $0 }
        if connectionTokens.contains("close") { return false }
        if version == "HTTP/1.1" { return true }
        return version == "HTTP/1.0" && connectionTokens.contains("keep-alive")
    }

    private static func clientAddressKey(_ address: sockaddr_in) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = withUnsafePointer(to: &address.sin_addr) { pointer in
            inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else { return "unresolved-client" }
        return String(cString: buffer)
    }

    /// - Returns: 这条连接写完之后是否还能复用。
    @discardableResult
    private func write(response: LocalHTTPResponse, to client: Int32, keepAlive: Bool = false) -> Bool {
        // 没有 `Content-Length` 的响应无法在同一条连接上界定边界，所以它一定
        // 关连接，不管调用方本来打算不打算复用。
        let effectiveKeepAlive = keepAlive && response.declaredContentLength >= 0
        // A client that has already gone away must not trigger an upstream NAS
        // read just because the router prepared a lazy remote Range payload.
        guard write(data: response.serializedHeaders(keepAlive: effectiveKeepAlive), to: client) else { return false }
        switch response.payload {
        case let .data(body):
            write(data: body, to: client)
        case let .fileRange(range):
            write(fileRange: range, to: client)
        case let .remoteRange(range):
            write(remoteRange: range, to: client)
        case let .remoteFull(full):
            _ = full.stream { [weak self] chunk in
                guard let self else { return false }
                return self.write(data: chunk, to: client)
            }
        case let .remuxStream(stream):
            stream.stream { [weak self] chunk in
                guard let self else { return false }
                return self.write(data: chunk, to: client)
            }
        }
        return effectiveKeepAlive
    }

    @discardableResult
    private func write(data: Data, to client: Int32) -> Bool {
        // Never peel bytes from the front of `Data`: each partial socket write
        // can otherwise trigger another slice/copy of a large remote Range
        // response. Keep one immutable buffer and advance only an integer
        // cursor, which matters for browser seeks that arrive as many partial
        // writes in quick succession.
        var offset = 0
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return false }
            while offset < bytes.count {
                let count = send(
                    client,
                    baseAddress.advanced(by: offset),
                    bytes.count - offset,
                    0
                )
                guard count > 0 else { return false }
                offset += Int(count)
            }
            return true
        }
    }

    private func write(fileRange: LocalHTTPFileRange, to client: Int32) {
        // 本地/网络挂载直放也要计量：NAS 挂载卷的分块读取一样会成为首帧瓶颈，
        // 只量远程上游会让"慢在磁盘还是慢在上游"这个问题无从回答。
        let telemetry = ServerPlaybackTelemetry.shared
        let startedAt = Date()
        var delivered: Int64 = 0
        var disconnected = false
        telemetry.rangeBegan()
        defer { telemetry.rangeEnded() }
        var readFailed = false
        do {
            try streamFileRange(fileRange) { [weak self] chunk in
                guard let self else { return false }
                telemetry.acquiredBuffer(chunk.count)
                defer { telemetry.releasedBuffer(chunk.count) }
                guard self.write(data: chunk, to: client) else {
                    disconnected = true
                    return false
                }
                delivered += Int64(chunk.count)
                return true
            }
        } catch {
            readFailed = true
        }
        let outcome: ServerRangeOutcome
        if readFailed { outcome = .transportFailed }
        else if disconnected { outcome = .clientDisconnected }
        else { outcome = delivered == fileRange.length ? .completed : .transportFailed }
        telemetry.recordRange(
            source: .localFile,
            requestedByteLength: fileRange.length,
            deliveredByteLength: delivered,
            outcome: outcome,
            upstreamTimeToFirstByte: nil,
            totalDuration: Date().timeIntervalSince(startedAt)
        )
    }

    private func write(remoteRange: LocalHTTPRemoteRange, to client: Int32) {
        _ = remoteRange.stream { [weak self] chunk in
            guard let self else { return false }
            return self.write(data: chunk, to: client)
        }
    }

}

private struct LocalHTTPRequest {
    let head: String
    let body: Data
}

/// Web 管理成员创建的严格正文。未知字段、缺字段、重复权限表达或异常值一律拒绝，
/// 避免由宽松 JSON 解码把未来字段静默扩展成权限接口。
private struct ServerAdministrationMemberCreateRequest: Decodable {
    let username: String
    let displayName: String
    let password: String
    let libraryIDs: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case username, displayName, password, libraryIDs
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unexpected fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        username = try values.decode(String.self, forKey: .username)
        displayName = try values.decode(String.self, forKey: .displayName)
        password = try values.decode(String.self, forKey: .password)
        libraryIDs = try values.decode([String].self, forKey: .libraryIDs)
    }
}

/// 普通成员编辑只允许显示名和资料库不透明 ID；权限位、角色、路径和用户身份
/// 均由服务端固定/认证 principal 派生，不能由网页任意提交。
private struct ServerAdministrationMemberAccessRequest: Decodable {
    let displayName: String
    let libraryIDs: [String]

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case displayName, libraryIDs
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unexpected fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        displayName = try values.decode(String.self, forKey: .displayName)
        libraryIDs = try values.decode([String].self, forKey: .libraryIDs)
    }
}

/// 管理员重置成员密码时正文只含新口令；不能指定 userID、角色、会话或恢复票据。
private struct ServerAdministrationPasswordResetRequest: Decodable {
    let password: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case password
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unexpected fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        password = try values.decode(String.self, forKey: .password)
        guard (12...1_024).contains(password.utf8.count) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid password length"))
        }
    }
}

/// 仅允许当前会话主体提交自己的当前密码和新密码。正文不含 userID、设备、会话或
/// 恢复票据，字段不精确匹配即拒绝。
private struct ServerPasswordChangeRequest: Decodable {
    let currentPassword: String
    let newPassword: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case currentPassword, newPassword
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unexpected fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentPassword = try values.decode(String.self, forKey: .currentPassword)
        newPassword = try values.decode(String.self, forKey: .newPassword)
        guard (1...1_024).contains(currentPassword.utf8.count),
              (12...1_024).contains(newPassword.utf8.count)
        else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid password lengths"))
        }
    }
}

/// 数据库恢复只接受当前会话账号的密码。备份 ID 来自路径中的不透明服务端 ID，
/// 正文不能夹带文件名、路径、用户或其它恢复参数。
private struct ServerBackupRestoreRequest: Decodable {
    let currentPassword: String

    private enum CodingKeys: String, CodingKey, CaseIterable {
        case currentPassword
    }

    init(from decoder: Decoder) throws {
        let dynamic = try decoder.container(keyedBy: DynamicCodingKey.self)
        guard Set(dynamic.allKeys.map(\.stringValue)) == Set(CodingKeys.allCases.map(\.rawValue)) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "unexpected fields"))
        }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        currentPassword = try values.decode(String.self, forKey: .currentPassword)
        guard (1...1_024).contains(currentPassword.utf8.count) else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "invalid password length"))
        }
    }
}

private struct DynamicCodingKey: CodingKey {
    let stringValue: String
    let intValue: Int?

    init?(stringValue: String) {
        self.stringValue = stringValue
        intValue = nil
    }

    init?(intValue: Int) {
        stringValue = String(intValue)
        self.intValue = intValue
    }
}

private enum LocalHTTPRequestReceiveResult {
    case request(LocalHTTPRequest)
    case rejected(HTTPRequestSecurityPolicy.Rejection)
}

private enum ArtworkRequest {
    case original
    case thumbnail(Int)
}

private final class ServerNavigationSnapshotCache: @unchecked Sendable {
    private struct Entry {
        let value: ServerWebSidebarExtras
        let createdAt: Date
    }

    private let condition = NSCondition()
    private var entries: [String: Entry] = [:]
    private var inFlightKeys: Set<String> = []
    private static let maximumEntries = 32

    func value(for key: String, create: () -> ServerWebSidebarExtras) -> ServerWebSidebarExtras {
        condition.lock()
        while true {
            if let cached = entries[key]?.value {
                condition.unlock()
                return cached
            }
            if !inFlightKeys.contains(key) {
                inFlightKeys.insert(key)
                condition.unlock()
                break
            }
            condition.wait()
        }

        let value = create()
        condition.lock()
        entries[key] = Entry(value: value, createdAt: Date())
        if entries.count > Self.maximumEntries,
           let oldest = entries.min(by: { $0.value.createdAt < $1.value.createdAt })?.key {
            entries.removeValue(forKey: oldest)
        }
        inFlightKeys.remove(key)
        condition.broadcast()
        condition.unlock()
        return value
    }
}

struct LocalHTTPRouter {
    /// One entry per browser-facing stylesheet or script.
    ///
    /// This replaces thirty-five near-identical `if path == …` branches.  A table
    /// makes it obvious at a glance what the browser can fetch, and adding a
    /// design-system layer no longer means appending another branch to a chain
    /// that had already grown past a hundred lines.
    ///
    /// Contents are produced lazily so a request for one asset does not build the
    /// strings for the other thirty-four.
    struct StaticWebAsset {
        enum Kind { case stylesheet, javascript }
        let kind: Kind
        let contents: () -> String
    }

    static let staticWebAssets: [String: StaticWebAsset] = [
        // Design system: loaded by every page, in cascade-layer order.
        "/assets/tokens.css": .init(kind: .stylesheet) { ServerWebDesignTokens.css },
        "/assets/base.css": .init(kind: .stylesheet) { ServerWebBaseStyle.css },
        "/assets/primitives.css": .init(kind: .stylesheet) { ServerWebPrimitives.css },
        "/assets/app-shell.css": .init(kind: .stylesheet) { ServerWebShellStyle.css },
        "/assets/appearance.js": .init(kind: .javascript) { ServerWebAppearanceScript.script },
        "/assets/app-shell.js": .init(kind: .javascript) { ServerWebShellScript.script },
        "/assets/overlays.js": .init(kind: .javascript) { ServerWebOverlayScript.script },

        // Per-page layout.
        "/assets/home.css": .init(kind: .stylesheet) { ServerWebHomePage.style },
        "/assets/home.js": .init(kind: .javascript) { ServerWebHomePage.script },
        "/assets/library.css": .init(kind: .stylesheet) { ServerWebLibraryPage.style },
        "/assets/library.js": .init(kind: .javascript) { ServerWebLibraryPage.script },
        "/assets/music.css": .init(kind: .stylesheet) { ServerWebMusicPage.style },
        "/assets/music.js": .init(kind: .javascript) { ServerWebMusicPage.script },
        "/assets/player.css": .init(kind: .stylesheet) { ServerWebMediaDetailPage.style },
        "/assets/player.js": .init(kind: .javascript) { ServerWebMediaDetailPage.script },
        "/assets/people.css": .init(kind: .stylesheet) { ServerWebPeoplePage.style },
        "/assets/people.js": .init(kind: .javascript) { ServerWebPeoplePage.script },
        "/assets/collections.css": .init(kind: .stylesheet) { ServerWebCollectionsPage.style },
        "/assets/collections.js": .init(kind: .javascript) { ServerWebCollectionsPage.script },
        "/assets/photos.css": .init(kind: .stylesheet) { ServerWebPhotosPage.style },
        "/assets/photos.js": .init(kind: .javascript) { ServerWebPhotosPage.script },
        "/assets/queue.css": .init(kind: .stylesheet) { ServerWebQueuePage.style },
        "/assets/queue.js": .init(kind: .javascript) { ServerWebQueuePage.script },
        "/assets/status.css": .init(kind: .stylesheet) { ServerWebStatusPage.style },
        "/assets/status.js": .init(kind: .javascript) { ServerWebStatusPage.script },
        "/assets/sources.css": .init(kind: .stylesheet) { ServerWebSourcesPage.style },
        "/assets/sources.js": .init(kind: .javascript) { ServerWebSourcesPage.script },
        "/assets/admin.css": .init(kind: .stylesheet) { ServerWebAdministrationPage.style },
        "/assets/admin.js": .init(kind: .javascript) { ServerWebAdministrationPage.script },
        "/assets/operations.css": .init(kind: .stylesheet) { ServerWebOperationsPage.style },
        "/assets/operations.js": .init(kind: .javascript) { ServerWebOperationsPage.script },
        "/assets/account.css": .init(kind: .stylesheet) { ServerWebAccountPage.style },
        "/assets/account.js": .init(kind: .javascript) { ServerWebAccountPage.script },
        "/assets/vault.css": .init(kind: .stylesheet) { ServerWebVaultPage.style },
        "/assets/login.css": .init(kind: .stylesheet) { ServerWebLoginPage.style },
        "/assets/login.js": .init(kind: .javascript) { ServerWebLoginPage.script }
    ]

    private let serverID: String
    private let serverName: String
    private let remoteAccessPolicy: ServerRemoteAccessPolicy
    private let remoteSourceGroupsProvider: (ServerRequestPrincipal) throws -> [ServerRemoteSourceGroup]
    private let playbackTelemetry: ServerPlaybackTelemetry
    private let librarySnapshotProvider: (ServerRequestPrincipal) throws -> ServerLibrarySnapshot
    private let libraryBrowseProvider: (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage
    private let libraryCategoriesProvider: (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse
    private let navigationRevisionProvider: (ServerRequestPrincipal) throws -> String
    private let homeRecommendationsProvider: (ServerRequestPrincipal) throws -> ServerHomeRecommendations
    private let libraryFacetsProvider: (String?, ServerLibraryMediaGroup?, ServerRequestPrincipal) throws -> ServerLibraryFacetsResponse
    private let mediaDetailProvider: (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?
    private let seriesDetailProvider: (String, ServerRequestPrincipal) throws -> ServerSeriesDetail?
    private let seriesEpisodesProvider: (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage?
    private let peopleProvider: (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage
    private let personDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail?
    private let collectionsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage
    private let collectionDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail?
    private let smartCollectionsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionsPage
    private let smartCollectionDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionDetail?
    private let musicPlaylistsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage
    private let musicPlaylistDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistDetail?
    private let musicItemsProvider: (ServerRequestPrincipal) throws -> [ServerLibraryItem]
    private let queueProvider: (ServerRequestPrincipal) throws -> ServerQueueResponse
    private let queueMutationProvider: (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse?
    private let mediaPlaybackStateUpdater: (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState?
    private let mediaPreferenceUpdater: (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference?
    private let mediaAssetProvider: (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset?
    private let webVTTSubtitleTracksProvider: (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]?
    private let subtitleTrackProvider: (String, Int, ServerRequestPrincipal) throws -> ServerSubtitleTrackReference?
    private let playbackTracksProvider: (String, ServerRequestPrincipal) throws -> ServerWebPlaybackTrackSet?
    private let audioRemuxProvider: (String, Int, Double, ServerRequestPrincipal) throws -> ServerAudioRemuxStream?
    private let remuxStartProvider: (String, Double, ServerRequestPrincipal) throws -> Double?
    private let hlsSessionProvider: (String, ServerHLSPlaybackRequest, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?
    private let hlsStatusProvider: (String, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor?
    private let hlsResourceProvider: (String, String, ServerRequestPrincipal) throws -> ServerHLSResource?
    private let hlsCancellationProvider: (String, ServerRequestPrincipal) -> Void
    private let adminHLSSessionsProvider: () -> [ServerAdminHLSPlaybackSession]
    private let adminHLSCancellationProvider: (String, ServerRequestPrincipal) -> Bool
    private let artworkAssetProvider: (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let detailImageProvider: (String, ServerDetailImageKind, Int, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let vaultAccessProvider: (ServerRequestPrincipal) throws -> ServerLibraryCatalog.VaultAccess
    private let artworkThumbnailer: ServerArtworkThumbnailer
    private let remoteAssetFetcher: ServerRemoteAssetFetcher
    private let remoteSubtitleBodyCatalog: ServerRemoteSubtitleBodyCatalog
    private let mediaTrackCatalog: ServerMediaTrackCatalog
    private let playbackInfoProvider: (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo?
    private let currentUserProfileProvider: (ServerRequestPrincipal) throws -> ServerCurrentUserProfile?
    private let administrationCatalog: ServerAdministrationCatalog?
    private let experienceRepository: ServerExperienceRepository?
    private let maintenanceService: ServerMaintenanceService?
    private let runtimeDiagnosticsProvider: () -> ServerRuntimeDiagnosticsSnapshot?
    private let runtimeConfigurationApplyProvider: (ServerRuntimeConfigurationMutationRequest) throws -> Bool
    private let authenticationService: ServerAuthenticationService?
    private let authenticationProvider: (String) throws -> ServerRequestPrincipal?
    private let rateLimiter: ServerRequestRateLimiter
    private let csrfToken: String
    private let navigationCache = ServerNavigationSnapshotCache()

    init(
        serverID: String,
        serverName: String,
        remoteAccessPolicy: ServerRemoteAccessPolicy = .loopbackOnly,
        remoteSourceGroupsProvider: @escaping (ServerRequestPrincipal) throws -> [ServerRemoteSourceGroup] = { _ in [] },
        playbackTelemetry: ServerPlaybackTelemetry = .shared,
        librarySnapshotProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibrarySnapshot = { _ in
            ServerLibrarySnapshot(
                summary: ServerLibrarySummary(totalItemCount: 0, countsByType: [:]),
                items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
            )
        },
        libraryBrowseProvider: @escaping (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage = { query, _ in
            ServerLibraryItemsPage(totalItemCount: 0, offset: query.offset, limit: query.limit, items: [])
        },
        libraryCategoriesProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse = { _ in
            ServerLibraryCategoriesResponse(categories: [])
        },
        navigationRevisionProvider: @escaping (ServerRequestPrincipal) throws -> String = { _ in UUID().uuidString },
        // 首页推荐名单由客户端算好发布，服务端只按请求者的授权把它查出来。
        // 默认空 = 没有客户端（测试、纯服务端部署），首页回落到服务端自己的推导。
        homeRecommendationsProvider: @escaping (ServerRequestPrincipal) throws -> ServerHomeRecommendations = { _ in .empty },
        libraryFacetsProvider: @escaping (String?, ServerLibraryMediaGroup?, ServerRequestPrincipal) throws -> ServerLibraryFacetsResponse = { _, _, _ in
            ServerLibraryFacetsResponse(genres: [], availableSorts: [])
        },
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail? = { _, _ in nil },
        seriesDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerSeriesDetail? = { _, _ in nil },
        seriesEpisodesProvider: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage? = { _, _, _, _, _ in nil },
        peopleProvider: @escaping (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage = { _, offset, limit, _ in ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        personDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail? = { _, _, _, _ in nil },
        collectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage = { offset, limit, _ in ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        collectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail? = { _, _, _, _ in nil },
        // 每个新 provider 都给一个"返回空"的默认值：现有的二十多个测试文件不必为了
        // 编译而各加一行。
        smartCollectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionsPage = { offset, limit, _ in ServerSmartCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        smartCollectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerSmartCollectionDetail? = { _, _, _, _ in nil },
        musicPlaylistsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistsPage = { offset, limit, _ in ServerMusicPlaylistsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        musicPlaylistDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerMusicPlaylistDetail? = { _, _, _, _ in nil },
        musicItemsProvider: @escaping (ServerRequestPrincipal) throws -> [ServerLibraryItem] = { _ in [] },
        queueProvider: @escaping (ServerRequestPrincipal) throws -> ServerQueueResponse = { _ in ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) },
        queueMutationProvider: @escaping (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse? = { _, _ in nil },
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaPreferenceUpdater: @escaping (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        webVTTSubtitleTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]? = { _, _ in nil },
        subtitleTrackProvider: @escaping (String, Int, ServerRequestPrincipal) throws -> ServerSubtitleTrackReference? = { _, _, _ in nil },
        playbackTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerWebPlaybackTrackSet? = { _, _ in nil },
        audioRemuxProvider: @escaping (String, Int, Double, ServerRequestPrincipal) throws -> ServerAudioRemuxStream? = { _, _, _, _ in nil },
        remuxStartProvider: @escaping (String, Double, ServerRequestPrincipal) throws -> Double? = { _, _, _ in nil },
        hlsSessionProvider: @escaping (String, ServerHLSPlaybackRequest, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor? = { _, _, _ in nil },
        hlsStatusProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerHLSPlaybackDescriptor? = { _, _ in nil },
        hlsResourceProvider: @escaping (String, String, ServerRequestPrincipal) throws -> ServerHLSResource? = { _, _, _ in nil },
        hlsCancellationProvider: @escaping (String, ServerRequestPrincipal) -> Void = { _, _ in },
        adminHLSSessionsProvider: @escaping () -> [ServerAdminHLSPlaybackSession] = { [] },
        adminHLSCancellationProvider: @escaping (String, ServerRequestPrincipal) -> Bool = { _, _ in false },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        detailImageProvider: @escaping (String, ServerDetailImageKind, Int, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _, _ in nil },
        /// 保险库对这个账号的可见性。默认 `.locked`——没有显式接线的调用方拿不到
        /// 保险库内容，这是这一整条链路的"失败即锁定"起点。
        vaultAccessProvider: @escaping (ServerRequestPrincipal) throws -> ServerLibraryCatalog.VaultAccess = { _ in .locked },
        artworkThumbnailer: ServerArtworkThumbnailer = ServerArtworkThumbnailer(),
        remoteAssetFetcher: ServerRemoteAssetFetcher = ServerRemoteAssetFetcher(),
        remoteSubtitleBodyCatalog: ServerRemoteSubtitleBodyCatalog? = nil,
        mediaTrackCatalog: ServerMediaTrackCatalog = ServerMediaTrackCatalog(),
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        currentUserProfileProvider: @escaping (ServerRequestPrincipal) throws -> ServerCurrentUserProfile? = { _ in nil },
        administrationCatalog: ServerAdministrationCatalog? = nil,
        experienceRepository: ServerExperienceRepository? = nil,
        maintenanceService: ServerMaintenanceService? = nil,
        runtimeDiagnosticsProvider: @escaping () -> ServerRuntimeDiagnosticsSnapshot? = { nil },
        runtimeConfigurationApplyProvider: @escaping (ServerRuntimeConfigurationMutationRequest) throws -> Bool = { _ in false },
        authenticationService: ServerAuthenticationService? = nil,
        authenticationProvider: @escaping (String) throws -> ServerRequestPrincipal? = { _ in nil },
        rateLimiter: ServerRequestRateLimiter = ServerRequestRateLimiter(),
        csrfToken: String = "test-csrf-token"
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.remoteAccessPolicy = remoteAccessPolicy
        self.remoteSourceGroupsProvider = remoteSourceGroupsProvider
        self.playbackTelemetry = playbackTelemetry
        self.librarySnapshotProvider = librarySnapshotProvider
        self.libraryBrowseProvider = libraryBrowseProvider
        self.libraryCategoriesProvider = libraryCategoriesProvider
        self.navigationRevisionProvider = navigationRevisionProvider
        self.homeRecommendationsProvider = homeRecommendationsProvider
        self.libraryFacetsProvider = libraryFacetsProvider
        self.mediaDetailProvider = mediaDetailProvider
        self.seriesDetailProvider = seriesDetailProvider
        self.seriesEpisodesProvider = seriesEpisodesProvider
        self.peopleProvider = peopleProvider
        self.personDetailProvider = personDetailProvider
        self.collectionsProvider = collectionsProvider
        self.smartCollectionsProvider = smartCollectionsProvider
        self.smartCollectionDetailProvider = smartCollectionDetailProvider
        self.musicPlaylistsProvider = musicPlaylistsProvider
        self.musicPlaylistDetailProvider = musicPlaylistDetailProvider
        self.collectionDetailProvider = collectionDetailProvider
        self.musicItemsProvider = musicItemsProvider
        self.queueProvider = queueProvider
        self.queueMutationProvider = queueMutationProvider
        self.mediaPlaybackStateUpdater = mediaPlaybackStateUpdater
        self.mediaPreferenceUpdater = mediaPreferenceUpdater
        self.mediaAssetProvider = mediaAssetProvider
        self.webVTTSubtitleTracksProvider = webVTTSubtitleTracksProvider
        self.subtitleTrackProvider = subtitleTrackProvider
        self.playbackTracksProvider = playbackTracksProvider
        self.audioRemuxProvider = audioRemuxProvider
        self.remuxStartProvider = remuxStartProvider
        self.hlsSessionProvider = hlsSessionProvider
        self.hlsStatusProvider = hlsStatusProvider
        self.hlsResourceProvider = hlsResourceProvider
        self.hlsCancellationProvider = hlsCancellationProvider
        self.adminHLSSessionsProvider = adminHLSSessionsProvider
        self.adminHLSCancellationProvider = adminHLSCancellationProvider
        self.artworkAssetProvider = artworkAssetProvider
        self.detailImageProvider = detailImageProvider
        self.vaultAccessProvider = vaultAccessProvider
        self.artworkThumbnailer = artworkThumbnailer
        self.remoteAssetFetcher = remoteAssetFetcher
        self.remoteSubtitleBodyCatalog = remoteSubtitleBodyCatalog
            ?? ServerRemoteSubtitleBodyCatalog(fetcher: remoteAssetFetcher)
        self.mediaTrackCatalog = mediaTrackCatalog
        self.playbackInfoProvider = playbackInfoProvider
        self.currentUserProfileProvider = currentUserProfileProvider
        self.administrationCatalog = administrationCatalog
        self.experienceRepository = experienceRepository
        self.maintenanceService = maintenanceService
        self.runtimeDiagnosticsProvider = runtimeDiagnosticsProvider
        self.runtimeConfigurationApplyProvider = runtimeConfigurationApplyProvider
        self.authenticationService = authenticationService
        self.authenticationProvider = authenticationProvider
        self.rateLimiter = rateLimiter
        self.csrfToken = csrfToken
    }

    func response(
        for requestHead: String,
        body: Data = Data(),
        clientAddressKey: String = "loopback-test-client"
    ) -> LocalHTTPResponse {
        guard let requestLine = requestHead.split(separator: "\r\n", maxSplits: 1).first else {
            return .badRequest()
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .badRequest() }

        let method = String(parts[0]).uppercased()
        let target = String(parts[1])
        let path = String(target.split(separator: "?", maxSplits: 1).first ?? "")
        let isHeadRequest = method == "HEAD"
        if (method == "GET" || isHeadRequest), path == "/health" || path == "/.well-known/mlink" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return publicProbeResponse(path: path, omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/login" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .html(
                body: Data(ServerWebLoginPage.render(
                    serverName: serverName,
                    csrfToken: csrfToken,
                    returnState: loginReturnState(from: target)
                ).utf8),
                omitBody: isHeadRequest
            )
        }
        if method == "GET" || isHeadRequest {
            if path == "/assets/vendor/hls-1.7.1.min.js",
               let url = Bundle.module.url(forResource: "hls.min", withExtension: "js"),
               let data = try? Data(contentsOf: url) {
                return .javascript(body: data, omitBody: isHeadRequest)
            }
            if path == "/assets/vendor/hls.js-LICENSE.txt",
               let url = Bundle.module.url(forResource: "LICENSE", withExtension: nil),
               let data = try? Data(contentsOf: url) {
                return .asset(
                    body: data, contentType: "text/plain; charset=utf-8", omitBody: isHeadRequest
                )
            }
            if let asset = LocalHTTPRouter.staticWebAssets[path] {
                switch asset.kind {
                case .stylesheet:
                    return .stylesheet(body: Data(asset.contents().utf8), omitBody: isHeadRequest)
                case .javascript:
                    return .javascript(body: Data(asset.contents().utf8), omitBody: isHeadRequest)
                }
            }
        }
        if method == "POST", path == "/api/v1/auth/login" {
            return loginResponse(requestHead: requestHead, body: body, clientAddressKey: clientAddressKey)
        }
        if method == "POST", path == "/login" {
            return webFormLoginResponse(
                requestHead: requestHead,
                target: target,
                body: body,
                clientAddressKey: clientAddressKey
            )
        }
        if method == "POST", path == "/api/v1/auth/refresh" {
            return refreshResponse(requestHead: requestHead, body: body, clientAddressKey: clientAddressKey)
        }
        guard let principal = try? authenticationProvider(requestHead) else {
            if let limited = limitedResponse(
                scope: .unauthenticated,
                identityComponents: [clientAddressKey]
            ) { return limited }
            if (method == "GET" || isHeadRequest), path == "/" || path == "/index.html" {
                return .seeOther(location: "/login", omitBody: isHeadRequest)
            }
            if (method == "GET" || isHeadRequest), acceptsHTMLNavigation(requestHead) {
                return .seeOther(location: loginLocation(for: target), omitBody: isHeadRequest)
            }
            return .unauthorized()
        }
        if method == "PATCH", path == "/api/v1/me/preferences" {
            if let limited = limitedResponse(
                scope: .authenticatedMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let expectedVersion = ifMatchVersion(in: requestHead) else { return .preconditionRequired() }
            guard let value: ServerUserExperiencePreferences = strictlyDecode(
                    ServerUserExperiencePreferences.self,
                    from: body,
                    allowedKeys: [
                        "schemaVersion", "interfaceLanguage", "appearance", "defaultLandingPath",
                        "homeSectionOrder", "hiddenHomeSections", "contentDensity", "motion",
                        "autoplayNext", "resumePlayback", "defaultQuality", "remoteBitrateMbps",
                        "preferredAudioLanguage", "preferredSubtitleLanguage", "subtitleMode",
                        "subtitleSDHPreference", "rememberTrackSelections", "subtitleStyle"
                    ],
                    nestedAllowedKeys: ["subtitleStyle": [
                        "fontFamily", "fontScalePercent", "fontWeight", "textColor",
                        "backgroundOpacityPercent", "edgeStyle", "verticalPositionPercent"
                    ]]
                  ),
                  value.isValid, let experienceRepository
            else { return .badRequest() }
            do {
                let saved = try experienceRepository.saveUserPreferences(
                    userID: principal.userID, value: value, expectedVersion: expectedVersion
                )
                guard let encoded = ServerCommandOutput.jsonData(saved) else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"])
            } catch { return experienceMutationErrorResponse(error) }
        }
        if method == "PATCH", path == "/api/v1/me/preferences/device" {
            if let limited = limitedResponse(
                scope: .authenticatedMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let expectedVersion = ifMatchVersion(in: requestHead) else { return .preconditionRequired() }
            guard let value: ServerDeviceExperienceOverrides = strictlyDecode(
                    ServerDeviceExperienceOverrides.self,
                    from: body,
                    allowedKeys: [
                        "schemaVersion", "appearance", "contentDensity", "motion",
                        "defaultQuality", "remoteBitrateMbps"
                    ]
                  ),
                  value.isValid, let experienceRepository
            else { return .badRequest() }
            do {
                let saved = try experienceRepository.saveDevicePreferences(
                    userID: principal.userID, deviceID: principal.deviceID,
                    value: value, expectedVersion: expectedVersion
                )
                guard let encoded = ServerCommandOutput.jsonData(saved) else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"])
            } catch { return experienceMutationErrorResponse(error) }
        }
        if method == "DELETE", path == "/api/v1/me/preferences/device" {
            if let limited = limitedResponse(
                scope: .authenticatedMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let expectedVersion = ifMatchVersion(in: requestHead) else { return .preconditionRequired() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                try experienceRepository.deleteDevicePreferences(
                    userID: principal.userID, deviceID: principal.deviceID, expectedVersion: expectedVersion
                )
                return .noContent()
            } catch { return experienceMutationErrorResponse(error) }
        }
        if method == "PATCH", path == "/api/v1/admin/settings" {
            if let limited = limitedResponse(
                scope: .managementMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let expectedVersion = ifMatchVersion(in: requestHead) else { return .preconditionRequired() }
            guard let value: ServerOperationalSettings = strictlyDecode(
                    ServerOperationalSettings.self,
                    from: body,
                    allowedKeys: [
                        "schemaVersion", "transcodeEngine", "maximumTranscodeSessions",
                        "defaultRemoteBitrateMbps", "temporaryStorageLimitGB", "minimumFreeDiskGB",
                        "sessionIdleMinutes", "telemetryRetentionHours"
                    ]
                  ),
                  value.isValid, let experienceRepository
            else { return .badRequest() }
            do {
                let saved = try experienceRepository.saveOperationalSettings(value, expectedVersion: expectedVersion)
                guard let encoded = ServerCommandOutput.jsonData(saved) else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"])
            } catch { return experienceMutationErrorResponse(error) }
        }
        if method == "PATCH", let userID = administrationUserPolicyID(path) {
            if let limited = limitedResponse(
                scope: .managementMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let expectedVersion = ifMatchVersion(in: requestHead) else { return .preconditionRequired() }
            guard let administrationCatalog,
                  (try? administrationCatalog.containsUser(id: userID)) == true
            else { return .notFound() }
            guard let value: ServerUserPolicy = strictlyDecode(
                ServerUserPolicy.self,
                from: body,
                allowedKeys: [
                    "schemaVersion", "playbackAllowed", "remoteAccessAllowed", "directPlayAllowed",
                    "remuxAllowed", "transcodeAllowed", "downloadAllowed", "maximumConcurrentStreams",
                    "remoteBitrateLimitMbps", "accessStartMinute", "accessEndMinute", "maximumContentRating"
                ]
            ), value.isValid, let experienceRepository else { return .badRequest() }
            do {
                let saved = try experienceRepository.saveUserPolicy(
                    userID: userID, value: value, expectedVersion: expectedVersion
                )
                try administrationCatalog.recordPolicyUpdate(userID: userID, actor: principal)
                guard let encoded = ServerCommandOutput.jsonData(saved) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    additionalHeaders: [etagHeader(saved.version), "Cache-Control: no-store"]
                )
            } catch { return experienceMutationErrorResponse(error) }
        }
        if method == "PUT" || method == "DELETE",
           let route = playbackOverrideRoute(path) {
            if let limited = limitedResponse(
                scope: .authenticatedMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let experienceRepository else { return .serviceUnavailable() }
            if method == "DELETE" {
                do {
                    try experienceRepository.deleteTrackOverride(
                        userID: principal.userID, scope: route.scope, scopeID: route.id
                    )
                    return .noContent()
                } catch { return .serviceUnavailable() }
            }
            guard let request: ServerTrackOverrideMutation = strictlyDecode(
                ServerTrackOverrideMutation.self,
                from: body,
                allowedKeys: ["audioFingerprint", "subtitleFingerprint", "subtitleDisabled"]
            ) else {
                return .badRequest()
            }
            let value = ServerTrackSelectionOverride(
                scope: route.scope,
                scopeID: route.id,
                audioFingerprint: request.audioFingerprint,
                subtitleFingerprint: request.subtitleFingerprint,
                subtitleDisabled: request.subtitleDisabled
            )
            guard value.isValid else { return .badRequest() }
            do {
                let saved = try experienceRepository.saveTrackOverride(userID: principal.userID, value: value)
                guard let encoded = ServerCommandOutput.jsonData(saved) else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
            } catch { return .serviceUnavailable() }
        }
        if method == "DELETE", path.hasPrefix("/api/v1/playback/sessions/") {
            if let limited = limitedResponse(
                scope: .authenticatedMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let raw = String(path.dropFirst("/api/v1/playback/sessions/".count))
            guard !raw.isEmpty, !raw.contains("/") else { return .notFound() }
            hlsCancellationProvider(raw, principal)
            return .noContent()
        }
        if method == "DELETE", path.hasPrefix("/api/v1/admin/playback-sessions/") {
            if let limited = limitedResponse(
                scope: .managementMutation, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            let raw = String(path.dropFirst("/api/v1/admin/playback-sessions/".count))
            guard !raw.isEmpty, !raw.contains("/"), body.isEmpty else { return .notFound() }
            guard adminHLSCancellationProvider(raw, principal) else { return .notFound() }
            return .noContent()
        }
        if method == "DELETE", path == "/api/v1/admin/storage/transcode-cache" {
            if let limited = limitedResponse(
                scope: .managementMutation,
                principal: principal,
                clientAddressKey: clientAddressKey,
                cost: 3
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard body.isEmpty, let maintenanceService else { return .badRequest() }
            do {
                let job = try maintenanceService.enqueueTranscodeCacheCleanup(requestedBy: principal)
                guard let encoded = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
                return .accepted(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
            } catch { return .serviceUnavailable() }
        }
        if method == "POST" {
            if path == "/api/v1/playback/sessions" {
                if let limited = limitedResponse(
                    scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
                ) { return limited }
                guard let creation: ServerHLSPlaybackSessionCreationRequest = strictlyDecode(
                    ServerHLSPlaybackSessionCreationRequest.self,
                    from: body,
                    allowedKeys: ["itemID", "audioTrackID", "subtitleTrackID", "startSeconds", "durationSeconds", "capabilities", "quality", "maximumBitrateMbps"],
                    nestedAllowedKeys: ["capabilities": [
                        "nativeHLS", "mediaSource", "videoCodecs", "audioCodecs",
                        "screenWidth", "screenHeight", "hdrDisplay", "measuredDownlinkMbps"
                    ]]
                ), creation.isValid else { return .badRequest() }
                guard let policy = experiencePolicy(for: principal),
                      policyAllowsPlayback(policy, clientAddressKey: clientAddressKey),
                      policyAllowsItem(policy, itemID: creation.itemID, principal: principal),
                      policy.remuxAllowed || policy.transcodeAllowed else {
                    return .forbidden()
                }
                guard let descriptor = try? hlsSessionProvider(
                    creation.itemID, creation.playbackRequest, principal
                ), let encoded = ServerCommandOutput.jsonData(descriptor)
                else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
            }
            if path.hasPrefix("/api/v1/playback/sessions/") {
                if let limited = limitedResponse(
                    scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
                ) { return limited }
                if path.hasSuffix("/cancel") {
                    let raw = String(
                        path.dropFirst("/api/v1/playback/sessions/".count).dropLast("/cancel".count)
                    )
                    guard !raw.isEmpty, !raw.contains("/") else { return .notFound() }
                    hlsCancellationProvider(raw, principal)
                    return .noContent()
                }
                guard let itemID = decodedPathIdentifier(path, prefix: "/api/v1/playback/sessions/"),
                      let request: ServerHLSPlaybackRequest = strictlyDecode(
                        ServerHLSPlaybackRequest.self,
                        from: body,
                        allowedKeys: ["audioTrackID", "subtitleTrackID", "startSeconds", "durationSeconds", "capabilities", "quality", "maximumBitrateMbps"],
                        nestedAllowedKeys: ["capabilities": [
                            "nativeHLS", "mediaSource", "videoCodecs", "audioCodecs",
                            "screenWidth", "screenHeight", "hdrDisplay", "measuredDownlinkMbps"
                        ]]
                      ), request.isValid else { return .badRequest() }
                guard let policy = experiencePolicy(for: principal),
                      policyAllowsPlayback(policy, clientAddressKey: clientAddressKey),
                      policyAllowsItem(policy, itemID: itemID, principal: principal),
                      policy.remuxAllowed || policy.transcodeAllowed else {
                    return .forbidden()
                }
                guard let descriptor = try? hlsSessionProvider(itemID, request, principal),
                      let encoded = ServerCommandOutput.jsonData(descriptor)
                else { return .serviceUnavailable() }
                return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
            }
            if path == "/api/v1/auth/password" {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                return passwordChangeResponse(body: body, principal: principal)
            }
            if path == "/api/v1/auth/logout" {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                return logoutResponse(principal: principal)
            }
            if path == "/api/v1/queue" {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                return mutateQueueResponse(body: body, principal: principal)
            }
            if path.hasPrefix("/api/v1/playback/state/") {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                return updatePlaybackStateResponse(
                    path: path,
                    body: body,
                    principal: principal
                )
            }
            if path.hasPrefix("/api/v1/user-media/preferences/") {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                return updateMediaPreferenceResponse(path: path, body: body, principal: principal)
            }
            if path == "/api/v1/admin/runtime/validate" || path == "/api/v1/admin/runtime/apply" {
                guard method == "POST" else { return .methodNotAllowed() }
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey,
                    cost: path.hasSuffix("/apply") ? 3 : 1
                ) { return limited }
                guard principal.permissions.contains(.manageServer) else { return .forbidden() }
                guard let request: ServerRuntimeConfigurationMutationRequest = strictlyDecode(
                    ServerRuntimeConfigurationMutationRequest.self,
                    from: body,
                    allowedKeys: [
                        "currentPassword", "serverName", "port", "networkAccessMode",
                        "publicOrigin", "trustedProxyAddresses"
                    ]
                ) else { return .badRequest() }
                let hostControlAvailable = runtimeDiagnosticsProvider()?.hostControlAvailable == true
                let validation = ServerRuntimeConfigurationValidator.validate(
                    request,
                    hostControlAvailable: hostControlAvailable
                )
                guard validation.valid else {
                    guard let encoded = ServerCommandOutput.jsonData(validation) else {
                        return .serviceUnavailable()
                    }
                    return .jsonError(
                        statusCode: 400,
                        reason: "Bad Request",
                        body: encoded,
                        additionalHeaders: ["Cache-Control: no-store"]
                    )
                }
                if path.hasSuffix("/apply") {
                    guard hostControlAvailable else { return .serviceUnavailable() }
                    guard let authenticationService,
                          let password = request.currentPassword,
                          (try? authenticationService.verifyCurrentPassword(
                            for: principal,
                            password: password,
                            purpose: "runtime.apply"
                          )) == true
                    else { return .forbidden() }
                    do {
                        let accepted = try runtimeConfigurationApplyProvider(request)
                        try administrationCatalog?.recordRuntimeConfigurationApply(
                            accepted: accepted,
                            actor: principal,
                            detailCode: accepted ? "host.accepted" : "host.rejected"
                        )
                        guard accepted,
                              let encoded = ServerCommandOutput.jsonData(validation)
                        else { return .serviceUnavailable() }
                        return .accepted(
                            body: encoded,
                            additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
                        )
                    } catch {
                        try? administrationCatalog?.recordRuntimeConfigurationApply(
                            accepted: false,
                            actor: principal,
                            detailCode: "host.transport-failed"
                        )
                        return .serviceUnavailable()
                    }
                }
                guard let encoded = ServerCommandOutput.jsonData(validation) else {
                    return .serviceUnavailable()
                }
                return .json(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
            }
            if path == "/api/v1/admin/jobs" {
                guard method == "POST" else { return .methodNotAllowed() }
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
                guard let request: ServerJobCreationRequest = strictlyDecode(
                        ServerJobCreationRequest.self, from: body, allowedKeys: ["kind"]
                      ),
                      request.isValid,
                      let maintenanceService
                else { return .badRequest() }
                do {
                    let job = try maintenanceService.enqueueLibraryJob(
                        kind: request.kind,
                        requestedBy: principal
                    )
                    guard let encoded = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
                    return .created(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
                } catch { return .serviceUnavailable() }
            }
            if path == "/api/v1/admin/backups" {
                guard method == "POST" else { return .methodNotAllowed() }
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey,
                    cost: 3
                ) { return limited }
                guard principal.permissions.contains(.manageServer) else { return .forbidden() }
                guard body.isEmpty, let maintenanceService else { return .badRequest() }
                do {
                    let job = try maintenanceService.enqueueBackup(requestedBy: principal)
                    guard let encoded = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
                    return .created(body: encoded, additionalHeaders: ["Cache-Control: no-store"])
                } catch { return .serviceUnavailable() }
            }
            if path.hasPrefix("/api/v1/admin/backups/"), path.hasSuffix("/restore") {
                guard method == "POST" else { return .methodNotAllowed() }
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey,
                    cost: 4
                ) { return limited }
                guard principal.permissions.contains(.manageServer) else { return .forbidden() }
                let backupID = String(
                    path.dropFirst("/api/v1/admin/backups/".count).dropLast("/restore".count)
                )
                guard !backupID.isEmpty, !backupID.contains("/"),
                      let request: ServerBackupRestoreRequest = strictlyDecode(
                        ServerBackupRestoreRequest.self,
                        from: body,
                        allowedKeys: ["currentPassword"]
                      )
                else { return .badRequest() }
                guard let authenticationService,
                      (try? authenticationService.verifyCurrentPassword(
                        for: principal,
                        password: request.currentPassword,
                        purpose: "backup.restore"
                      )) == true
                else { return .forbidden() }
                guard let maintenanceService else { return .serviceUnavailable() }
                do {
                    let job = try maintenanceService.enqueueRestore(
                        backupID: backupID,
                        requestedBy: principal
                    )
                    guard let encoded = ServerCommandOutput.jsonData(job) else { return .serviceUnavailable() }
                    return .accepted(body: encoded, additionalHeaders: [
                        "Cache-Control: no-store",
                        "Clear-Site-Data: \"cache\""
                    ])
                } catch ServerMaintenanceError.backupNotFound {
                    return .notFound()
                } catch ServerMaintenanceError.invalidBackup {
                    return .conflict()
                } catch {
                    return .serviceUnavailable()
                }
            }
            if path == "/api/v1/admin/users" {
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
                return createAdministrationMemberResponse(body: body, principal: principal)
            }
            if path.hasPrefix("/api/v1/admin/sessions/") {
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
                return revokeAdministrationSessionResponse(path: path, principal: principal)
            }
            if path.hasPrefix("/api/v1/admin/users/") {
                if let limited = limitedResponse(
                    scope: .managementMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
                if path.hasSuffix("/access") {
                    guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
                    return updateAdministrationMemberAccessResponse(path: path, body: body, principal: principal)
                }
                if path.hasSuffix("/password") {
                    return resetAdministrationMemberPasswordResponse(path: path, body: body, principal: principal)
                }
                return updateAdministrationUserAvailabilityResponse(path: path, principal: principal)
            }
            return .methodNotAllowed()
        }
        guard method == "GET" || isHeadRequest else {
            return .methodNotAllowed()
        }

        if path.hasPrefix("/api/v1/playback/sessions/") {
            // This endpoint only reads the in-memory HLS state machine. It is
            // polled while ffmpeg prepares the first segment and must not spend
            // the deliberately scarce ffprobe budget (`mediaProbe`), otherwise
            // a normal long-GOP stream exhausts that bucket before becoming
            // ready. Playlist, segment and session-state traffic share the
            // bounded playback bucket; actual media inspection stays isolated.
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let raw = String(path.dropFirst("/api/v1/playback/sessions/".count))
            guard !raw.isEmpty, !raw.contains("/"),
                  let descriptor = try? hlsStatusProvider(raw, principal),
                  let encoded = ServerCommandOutput.jsonData(descriptor)
            else { return .notFound() }
            return .json(body: encoded, omitBody: isHeadRequest, additionalHeaders: ["Cache-Control: no-store"])
        }

        if path == "/api/v1/admin/playback-sessions" ||
            path.hasPrefix("/api/v1/admin/playback-sessions/") {
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            let sessions = adminHLSSessionsProvider()
            let encoded: Data?
            if path == "/api/v1/admin/playback-sessions" {
                encoded = ServerCommandOutput.jsonData(sessions)
            } else {
                let raw = String(path.dropFirst("/api/v1/admin/playback-sessions/".count))
                guard !raw.isEmpty, !raw.contains("/"),
                      let session = sessions.first(where: { $0.sessionID == raw })
                else { return .notFound() }
                encoded = ServerCommandOutput.jsonData(session)
            }
            guard let encoded else { return .serviceUnavailable() }
            return .json(body: encoded, omitBody: isHeadRequest, additionalHeaders: ["Cache-Control: no-store"])
        }

        if let userID = administrationUserPolicyID(path) {
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let administrationCatalog,
                  (try? administrationCatalog.containsUser(id: userID)) == true
            else { return .notFound() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let policy = try experienceRepository.userPolicy(userID: userID)
                guard let encoded = ServerCommandOutput.jsonData(policy) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: [etagHeader(policy.version), "Cache-Control: no-store"]
                )
            } catch { return .serviceUnavailable() }
        }

        if path.hasPrefix("/api/v1/playback/hls/") {
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let remainder = String(path.dropFirst("/api/v1/playback/hls/".count))
            let pieces = remainder.split(separator: "/", omittingEmptySubsequences: false)
            guard pieces.count == 2,
                  let resource = try? hlsResourceProvider(String(pieces[0]), String(pieces[1]), principal)
            else { return .notFound() }
            switch resource.storage {
            case let .data(data):
                return LocalHTTPResponse(
                    statusCode: 200,
                    reason: "OK",
                    contentType: resource.contentType,
                    payload: .data(isHeadRequest ? Data() : data),
                    declaredContentLength: data.count,
                    additionalHeaders: ["Cache-Control: no-store"]
                )
            case let .file(url, byteLength):
                return .file(
                    url: url,
                    byteLength: byteLength,
                    contentType: resource.contentType,
                    omitBody: isHeadRequest,
                    additionalHeaders: ["Cache-Control: no-store"]
                )
            }
        }

        if path == "/api/v1/admin/backups" {
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let query = administrationBackupsQuery(from: target) else { return .badRequest() }
            guard let maintenanceService else { return .serviceUnavailable() }
            do {
                let page = try maintenanceService.managedBackups(
                    limit: query.limit,
                    offset: query.offset,
                    kind: query.kind
                )
                guard let encoded = ServerCommandOutput.jsonData(page.backups) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: administrationPaginationHeaders(
                        totalCount: page.totalCount,
                        offset: query.offset,
                        itemCount: page.backups.count
                    )
                )
            } catch { return .serviceUnavailable() }
        }
        if path == "/api/v1/admin/diagnostics" {
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey, cost: 2
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let administrationCatalog,
                  let experienceRepository,
                  let runtime = runtimeDiagnosticsProvider()
            else { return .serviceUnavailable() }
            do {
                try administrationCatalog.recordDiagnosticExport(actor: principal)
                let users = try administrationCatalog.users(limit: 1)
                let sessions = try administrationCatalog.activeSessions()
                let sources = try administrationCatalog.sources()
                let security = try administrationCatalog.securityEvents()
                let export = ServerRedactedDiagnosticExport(
                    runtime: runtime,
                    userCount: users.totalCount,
                    activeDeviceCount: sessions.devices.count,
                    activeSessionCount: sessions.sessions.count,
                    managedSourceCount: sources?.totalCount ?? 0,
                    jobs: try experienceRepository.jobs(limit: 25),
                    securityEvents: security.events
                )
                guard let encoded = ServerCommandOutput.jsonData(export) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: [
                        "Cache-Control: no-store",
                        "Content-Disposition: attachment; filename=\"MediaLIB-diagnostics.json\""
                    ]
                )
            } catch { return .serviceUnavailable() }
        }
        if path.hasPrefix("/api/v1/admin/backups/"), path.hasSuffix("/download") {
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            let id = String(path.dropFirst("/api/v1/admin/backups/".count).dropLast("/download".count))
            guard !id.contains("/"),
                  let maintenanceService,
                  let backup = try? maintenanceService.backupFile(id: id)
            else { return .notFound() }
            return .file(
                url: backup.url,
                byteLength: backup.byteLength,
                contentType: "application/vnd.sqlite3",
                omitBody: isHeadRequest,
                additionalHeaders: [
                    "Cache-Control: no-store",
                    "Content-Disposition: attachment; filename=\"MediaLib-backup.sqlite\""
                ]
            )
        }

        let body: Data
        switch path {
        case "/", "/index.html":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let snapshot = try? librarySnapshotProvider(principal) else {
                return .serviceUnavailable()
            }
            // 推荐栏目（banner、剧集推荐、最近添加剧集、高分精选、音乐推荐、照片墙）
            // 的**顺序**来自客户端首页：同一个资料库不该在 App 和网页上给出两份不同
            // 的片单，也不该为此把同一套排序在两个进程里各算一遍。条目仍由服务端按
            // 这个账号的授权查出，痕迹仍是这个账号自己的。
            let recommendations = (try? homeRecommendationsProvider(principal)) ?? .empty
            // 客户端名单缺席时的回落（App 没运行、名单过期、纯服务端部署）。
            //
            // 「最近添加」和「高分精选」要的是**排序**，而首页快照只有一种顺序，
            // 所以这两条各要一次有界查询；取不到就让那一栏不出现，而不是整页 503。
            // `includesRemoteSources` 与首页快照同口径：首页看板是本地 + 远程，
            // 而一级分类页仍然只有本地。少了它，同一个首页上"继续观看"里有 Emby
            // 的剧、"最近添加"里却一部都没有。
            //
            // 名单在时这两次查询根本不发出去——那正是"避免重复计算"的那一半。
            let recentlyAdded = recommendations.recentSeries.isEmpty
                ? (try? libraryBrowseProvider(
                    ServerLibraryQuery(
                        limit: 12, sort: .dateAdded, mediaGroup: .video, includesRemoteSources: true
                    ), principal
                ))?.items ?? []
                : recommendations.recentSeries
            let highRated = recommendations.highRated.isEmpty
                ? (try? libraryBrowseProvider(
                    ServerLibraryQuery(
                        limit: 12, sort: .score, mediaGroup: .video, includesRemoteSources: true
                    ), principal
                ))?.items ?? []
                : recommendations.highRated
            return .html(
                body: Data(
                    ServerWebHomePage.render(
                        serverName: serverName,
                        snapshot: snapshot,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        recentlyAdded: recentlyAdded,
                        highRated: highRated,
                        recommendations: recommendations,
                        categories: (try? libraryCategoriesProvider(principal))?.categories ?? [],
                        sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebStatusPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: true,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin/users":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebAdministrationPage.render(
                        section: .users,
                        serverName: serverName,
                        csrfToken: csrfToken,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin/sessions":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebAdministrationPage.render(
                        section: .sessions,
                        serverName: serverName,
                        csrfToken: csrfToken,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin/libraries":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebSourcesPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin/playback", "/admin/network", "/admin/tasks", "/admin/storage", "/admin/security", "/admin/logs":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let requiredPermission: ServerPermission = path == "/admin/tasks" ? .manageLibraries : .manageServer
            guard principal.permissions.contains(requiredPermission) else { return .forbidden() }
            let section: ServerWebOperationsPage.Section = switch path {
            case "/admin/playback": .playback
            case "/admin/network": .network
            case "/admin/tasks": .tasks
            case "/admin/storage": .storage
            case "/admin/security": .security
            default: .logs
            }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebOperationsPage.render(
                        section: section,
                        serverName: serverName,
                        csrfToken: csrfToken,
                        categories: categories,
                        sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/sources":
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            return .seeOther(location: "/admin/libraries", omitBody: isHeadRequest)
        case "/status":
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            return .seeOther(location: "/admin", omitBody: isHeadRequest)
        case "/account":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebAccountPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/vault":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            // Every other authenticated page gates on `.viewMedia`; the vault
            // lock screen was the one that did not, so a principal without media
            // access could reach it.
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            // 解锁状态由这台机器上的 App 发布，授权是逐库的——两者都成立时保险库
            // 就是一个普通的资料库页面，与电影、剧集共用同一套渲染、筛选和授权。
            // 取不到状态时按锁定处理：失败即锁定。
            let vaultAccess = (try? vaultAccessProvider(principal)) ?? .locked
            switch vaultAccess {
            case .unlocked:
                return .html(
                    body: Data(
                        ServerWebLibraryPage.render(
                            serverName: serverName,
                            csrfToken: csrfToken,
                            showAdministration: principal.canManageServer,
                            page: .vault,
                            categories: categories, sidebarExtras: sidebarExtras(for: principal),
                            scope: ServerWebLibraryPage.Scope(vaultTitle: "保险库"),
                            // 题材下拉刻意不给：`libraryFacets` 算的是**公开**来源的
                            // 题材，挂在保险库页面上就是一个选中即空网格的控件。
                            // 保险库的题材要单独统计，那是另一件事，不是这一页的默认。
                            facets: ServerLibraryFacetsResponse(genres: [], availableSorts: [])
                        ).utf8
                    ),
                    omitBody: isHeadRequest
                )
            case .locked, .notGranted:
                return .html(
                    body: Data(
                        ServerWebVaultPage.render(
                            serverName: serverName,
                            showAdministration: principal.canManageServer,
                            reason: vaultAccess == .notGranted ? .notGranted : .locked,
                            categories: categories, sidebarExtras: sidebarExtras(for: principal)
                        ).utf8
                    ),
                    omitBody: isHeadRequest
                )
            }
        // Browsing is always scoped.  There is no "everything" list: a grid that
        // mixed every episode, track and photo together was nobody's destination,
        // and it was where `返回` used to strand people.  Each browse destination
        // names its scope in its own path — a category id, or the reserved
        // `video` group.
        // 远程来源浏览页。作用域 ID 是来源路径的不透明哈希，解析只在**已授权**
        // 集合内做匹配，因此未知或越权的 ID 落到 404 而不是一个未加作用域的页面。
        case let remotePath where remotePath.hasPrefix("/remote/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            let rawScope = String(remotePath.dropFirst("/remote/".count))
            guard !rawScope.isEmpty, !rawScope.contains("/"),
                  rawScope.count <= 64,
                  rawScope.allSatisfy({ $0.isHexDigit })
            else { return .notFound() }
            let groups = (try? remoteSourceGroupsProvider(principal)) ?? []
            let matched: (id: String, title: String)? = groups.compactMap { group -> (String, String)? in
                if group.id == rawScope { return (group.id, group.title) }
                if let library = group.libraries.first(where: { $0.id == rawScope }) {
                    return (library.id, "\(group.title) · \(library.title)")
                }
                return nil
            }.first
            guard let matched else { return .notFound() }
            let remoteCategories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: remoteCategories,
                        sidebarExtras: sidebarExtras(for: principal, activeRemoteScopeID: matched.id),
                        selectedCategoryID: nil,
                        scope: ServerWebLibraryPage.Scope(
                            remoteScopeID: matched.id, title: matched.title
                        ),
                        facets: ServerLibraryFacetsResponse(genres: [], availableSorts: [])
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case let categoryPath where categoryPath.hasPrefix("/category/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            guard let scope = ServerWebLibraryPage.Scope(
                path: categoryPath,
                allowedCategories: categories.categories
            ) else { return .notFound() }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        selectedCategoryID: scope.categoryID,
                        scope: scope,
                        facets: libraryFacets(
                            type: scope.categoryID,
                            group: scope.categoryID == nil ? .video : nil,
                            for: principal
                        )
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/music/songs", "/music/albums", "/music/artists", "/music/playlists", "/music/recent":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page: ServerWebMusicPage.Page = switch path {
                case "/music/albums": .albums
                case "/music/artists": .artists
                case "/music/playlists": .playlists
                case "/music/recent": .recent
                default: .songs
                }
                let tracks = try musicItemsProvider(principal)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                let playlists = (try? musicPlaylistsProvider(0, 100, principal))?.items ?? []
                return .html(
                    body: Data(ServerWebMusicPage.render(
                        page: page,
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal),
                        tracks: tracks,
                        playlists: playlists
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case "/people":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                // 人物页的搜索框现在是一个真表单（`GET /people?q=`）。不解析这个键的话，
                // 脚本没到时按回车看起来就像什么都没发生。
                let searchText = boundedQueryText(from: target, key: "q", maximumLength: 128)
                let page = try peopleProvider(searchText, 0, 24, principal)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(
                    body: Data(ServerWebPeoplePage.directory(
                        serverName: serverName, page: page, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        query: searchText ?? "",
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case "/collections":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page = try collectionsProvider(0, 24, principal)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(
                    body: Data(ServerWebCollectionsPage.directory(
                        serverName: serverName, page: page, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal)
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case let smartCollectionPath where smartCollectionPath.hasPrefix("/smart-collections/"):
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let id = decodedPathIdentifier(smartCollectionPath, prefix: "/smart-collections/") else { return .notFound() }
            do {
                guard let detail = try smartCollectionDetailProvider(id, 0, 100, principal) else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                var extras = sidebarExtras(for: principal)
                // 当前正在看的那一条要在侧栏里标出来。
                extras = ServerWebSidebarExtras(
                    smartCollections: extras.smartCollections, smartPlaylists: extras.smartPlaylists,
                    activeCollectionID: id
                )
                return .html(body: Data(ServerWebCollectionsPage.smartDetail(
                    serverName: serverName, detail: detail, csrfToken: csrfToken,
                    showAdministration: principal.canManageServer, categories: categories, sidebarExtras: extras,
                    back: ServerWebBackNavigation.target(
                        requestHead: requestHead, fallback: .init(label: "返回首页", href: "/")
                    )
                ).utf8), omitBody: isHeadRequest)
            } catch { return .serviceUnavailable() }
        case let playlistPath where playlistPath.hasPrefix("/music/playlists/"):
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let id = decodedPathIdentifier(playlistPath, prefix: "/music/playlists/") else { return .notFound() }
            do {
                guard let detail = try musicPlaylistDetailProvider(id, 0, 100, principal) else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                var extras = sidebarExtras(for: principal)
                extras = ServerWebSidebarExtras(
                    smartCollections: extras.smartCollections, smartPlaylists: extras.smartPlaylists,
                    activePlaylistID: detail.isSmart ? id : nil
                )
                return .html(body: Data(ServerWebMusicPage.playlistDetail(
                    serverName: serverName, detail: detail, csrfToken: csrfToken,
                    showAdministration: principal.canManageServer, categories: categories, sidebarExtras: extras,
                    back: ServerWebBackNavigation.target(
                        requestHead: requestHead, fallback: .init(label: "返回歌单", href: "/music/playlists")
                    )
                ).utf8), omitBody: isHeadRequest)
            } catch { return .serviceUnavailable() }
        case "/albums":
            // 客户端「相册 · 全部」是照片与录像合在一起。网页从前只有一个纯照片
            // 页，录像得绕到「其他视频」分类里去找。
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page = try libraryBrowseProvider(ServerLibraryQuery(offset: 0, limit: 24, mediaGroup: .album), principal)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(body: Data(ServerWebPhotosPage.gallery(serverName: serverName, page: page, csrfToken: csrfToken, showAdministration: principal.canManageServer, categories: categories, sidebarExtras: sidebarExtras(for: principal), scope: .album).utf8), omitBody: isHeadRequest)
            } catch { return .serviceUnavailable() }
        case "/photos":
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page = try libraryBrowseProvider(ServerLibraryQuery(type: "photo", offset: 0, limit: 24), principal)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(body: Data(ServerWebPhotosPage.gallery(serverName: serverName, page: page, csrfToken: csrfToken, showAdministration: principal.canManageServer, categories: categories, sidebarExtras: sidebarExtras(for: principal)).utf8), omitBody: isHeadRequest)
            } catch { return .serviceUnavailable() }
        case "/search":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .search,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        // 服务端渲染搜索框的初值，于是刷新结果页、分享链接、
                        // 以及脚本未到达时都保留着关键词。
                        searchQuery: boundedQueryText(from: target, key: "q", maximumLength: 128) ?? "",
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/queue":
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let queue = try? queueProvider(principal) else { return .serviceUnavailable() }
            let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
            return .html(
                body: Data(ServerWebQueuePage.render(serverName: serverName, queue: queue, csrfToken: csrfToken, showAdministration: principal.canManageServer, categories: categories, sidebarExtras: sidebarExtras(for: principal)).utf8),
                omitBody: isHeadRequest
            )
        case "/watching":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .continuing,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/history":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .history,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/favorites":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .favorites,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/watchlist":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .watchlist,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/watched":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .watched,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/ratings":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .ratings,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/unwatched":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        page: .unwatched,
                        categories: categories.categories,
                        sidebarExtras: sidebarExtras(for: principal),
                        facets: libraryFacets(type: nil, group: nil, for: principal)
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case let itemPagePath where itemPagePath.hasPrefix("/item/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(itemPagePath, prefix: "/item/") else {
                return .notFound()
            }
            do {
                guard let detail = try mediaDetailProvider(itemID, principal) else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(
                    body: Data(
                        ServerWebMediaDetailPage.render(
                            serverName: serverName,
                            detail: detail,
                            csrfToken: csrfToken,
                            showAdministration: principal.canManageServer,
                            categories: categories, sidebarExtras: sidebarExtras(for: principal),
                            back: ServerWebBackNavigation.target(
                                requestHead: requestHead,
                                fallback: .init(label: "返回首页", href: "/")
                            )
                        ).utf8
                    ),
                    omitBody: isHeadRequest
                )
            } catch {
                return .serviceUnavailable()
            }
        case let videoPlayerPath where videoPlayerPath.hasPrefix("/play/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(videoPlayerPath, prefix: "/play/") else {
                return .notFound()
            }
            do {
                guard let detail = try mediaDetailProvider(itemID, principal) else { return .notFound() }
                // Both media kinds resolve to the same detail shell, which is the
                // single source of truth for layout modes, selection state and
                // client-style metadata.  Video keeps `#play` in the URL and
                // auto-starts the embedded player; music hands playback to the
                // persistent bottom dock.  (These were previously two branches
                // constructing byte-identical pages.)
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                let page = ServerWebMediaDetailPage.render(
                    serverName: serverName,
                    detail: detail,
                    csrfToken: csrfToken,
                    showAdministration: principal.canManageServer,
                    categories: categories, sidebarExtras: sidebarExtras(for: principal),
                    back: ServerWebBackNavigation.target(
                        requestHead: requestHead,
                        fallback: .init(label: "返回首页", href: "/")
                    )
                )
                return .html(
                    body: Data(page.utf8),
                    omitBody: isHeadRequest
                )
            } catch {
                return .serviceUnavailable()
            }
        case let seriesPlayPath where seriesPlayPath.hasPrefix("/series/") && seriesPlayPath.hasSuffix("/play"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let seriesID = decodedSeriesPlayIdentifier(seriesPlayPath) else { return .notFound() }
            do {
                // A poster is an intent to watch, not an intermediate selection
                // screen. Resolve only through the existing authorised series
                // providers and redirect to an actual episode detail/player.
                guard let detail = try seriesDetailProvider(seriesID, principal) else { return .notFound() }
                var fallback: ServerSeriesEpisode?
                let selectors = detail.seasons.isEmpty
                    ? [.unspecified]
                    : detail.seasons.map { $0.seasonNumber.map(ServerSeriesSeasonSelector.numbered) ?? .unspecified }
                for selector in selectors {
                    guard let page = try seriesEpisodesProvider(seriesID, selector, 0, 100, principal) else { continue }
                    if let resumable = page.items.first(where: {
                        guard let state = $0.userState else { return false }
                        return state.progress > 0 && !state.isWatched
                    }) {
                        guard let episodeID = ServerWebURL.pathSegment(resumable.id) else { return .notFound() }
                        return .seeOther(location: "/item/\(episodeID)#play", omitBody: isHeadRequest)
                    }
                    fallback = fallback ?? page.items.first
                }
                guard let episode = fallback, let episodeID = ServerWebURL.pathSegment(episode.id) else { return .notFound() }
                return .seeOther(location: "/item/\(episodeID)#play", omitBody: isHeadRequest)
            } catch {
                return .serviceUnavailable()
            }
        case let personPagePath where personPagePath.hasPrefix("/people/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let personID = decodedPathIdentifier(personPagePath, prefix: "/people/") else {
                return .notFound()
            }
            do {
                guard let detail = try personDetailProvider(personID, 0, 24, principal) else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(
                    body: Data(ServerWebPeoplePage.detail(
                        serverName: serverName, detail: detail, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal),
                        back: ServerWebBackNavigation.target(
                            requestHead: requestHead, fallback: .init(label: "返回人物", href: "/people")
                        )
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case let collectionPagePath where collectionPagePath.hasPrefix("/collections/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let collectionID = decodedPathIdentifier(collectionPagePath, prefix: "/collections/") else {
                return .notFound()
            }
            do {
                guard let detail = try collectionDetailProvider(collectionID, 0, 24, principal) else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(
                    body: Data(ServerWebCollectionsPage.detail(
                        serverName: serverName, detail: detail, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories, sidebarExtras: sidebarExtras(for: principal),
                        back: ServerWebBackNavigation.target(
                            requestHead: requestHead, fallback: .init(label: "返回合集", href: "/collections")
                        )
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case let photoPagePath where photoPagePath.hasPrefix("/photo/"):
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard let itemID = decodedPathIdentifier(photoPagePath, prefix: "/photo/") else { return .notFound() }
            do {
                guard let detail = try mediaDetailProvider(itemID, principal), detail.type == "photo" else { return .notFound() }
                let categories = (try? libraryCategoriesProvider(principal))?.categories ?? []
                return .html(body: Data(ServerWebPhotosPage.detail(
                    serverName: serverName, item: detail, csrfToken: csrfToken,
                    showAdministration: principal.canManageServer, categories: categories,
                    sidebarExtras: sidebarExtras(for: principal),
                    back: ServerWebBackNavigation.target(
                        requestHead: requestHead, fallback: .init(label: "返回照片", href: "/photos")
                    )
                ).utf8), omitBody: isHeadRequest)
            } catch { return .serviceUnavailable() }
        case "/api/v1/library/summary":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let encoded = encodedLibraryResponse(\.summary, principal: principal) else {
                return .serviceUnavailable()
            }
            body = encoded
        case "/api/v1/library/items":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let encoded = encodedLibraryResponse(\.items, principal: principal) else {
                return .serviceUnavailable()
            }
            body = encoded
        case "/api/v1/library/categories":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try libraryCategoriesProvider(principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch {
                return .serviceUnavailable()
            }
        case "/api/v1/library/facets":
            // 网页用它决定该给出哪些排序键和哪些题材。没有这个端点，筛选栏只能
            // 渲染一串固定选项，其中一部分在当前资料库里永远匹配不到内容。
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let scope = libraryFacetsScope(from: target) else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(
                    try libraryFacetsProvider(scope.type, scope.group, principal)
                ) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch {
                return .serviceUnavailable()
            }
        case "/api/v1/library/browse":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let query = libraryQuery(from: target) else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try libraryBrowseProvider(query, principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch {
                return .serviceUnavailable()
            }
        case "/api/v1/queue":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try queueProvider(principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let itemDetailPath where itemDetailPath.hasPrefix("/api/v1/items/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(itemDetailPath, prefix: "/api/v1/items/") else {
                return .notFound()
            }
            do {
                guard let detail = try mediaDetailProvider(itemID, principal) else { return .notFound() }
                guard let encoded = ServerCommandOutput.jsonData(detail) else { return .serviceUnavailable() }
                body = encoded
            } catch {
                return .serviceUnavailable()
            }
        case let seriesEpisodesPath where seriesEpisodesPath.hasPrefix("/api/v1/series/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let request = seriesEpisodeQuery(from: target) else { return .badRequest() }
            do {
                guard let page = try seriesEpisodesProvider(
                    request.id, request.season, request.offset, request.limit, principal
                ) else { return .notFound() }
                guard let encoded = ServerCommandOutput.jsonData(page) else { return .serviceUnavailable() }
                body = encoded
            } catch {
                return .serviceUnavailable()
            }
        case "/api/v1/people":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let query = peopleQuery(from: target) else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try peopleProvider(query.searchText, query.offset, query.limit, principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let personCreditsPath where personCreditsPath.hasPrefix("/api/v1/people/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let request = personCreditsQuery(from: target) else { return .badRequest() }
            do {
                guard let detail = try personDetailProvider(request.id, request.offset, request.limit, principal),
                      let encoded = ServerCommandOutput.jsonData(detail.credits)
                else { return .notFound() }
                body = encoded
            } catch { return .serviceUnavailable() }
        case "/api/v1/collections":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let query = collectionsQuery(from: target) else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try collectionsProvider(query.offset, query.limit, principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch { return .serviceUnavailable() }
        case "/api/v1/photos":
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard let query = photosQuery(from: target) else { return .badRequest() }
            do {
                let page = try libraryBrowseProvider(ServerLibraryQuery(type: "photo", offset: query.offset, limit: query.limit), principal)
                guard let encoded = ServerCommandOutput.jsonData(page) else { return .serviceUnavailable() }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let collectionItemsPath where collectionItemsPath.hasPrefix("/api/v1/collections/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let request = collectionItemsQuery(from: target) else { return .badRequest() }
            do {
                guard let detail = try collectionDetailProvider(request.id, request.offset, request.limit, principal),
                      let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                body = encoded
            } catch { return .serviceUnavailable() }
        case "/api/v1/smart-collections":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let query = pagingQuery(from: target, path: "/api/v1/smart-collections") else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try smartCollectionsProvider(query.offset, query.limit, principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let smartItemsPath where smartItemsPath.hasPrefix("/api/v1/smart-collections/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let request = identifiedPagingQuery(
                from: target, prefix: "/api/v1/smart-collections/", identifierNamespace: "smart-collections"
            ) else { return .badRequest() }
            do {
                guard let detail = try smartCollectionDetailProvider(request.id, request.offset, request.limit, principal),
                      let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                body = encoded
            } catch { return .serviceUnavailable() }
        case "/api/v1/music/playlists":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let query = pagingQuery(from: target, path: "/api/v1/music/playlists") else { return .badRequest() }
            do {
                guard let encoded = ServerCommandOutput.jsonData(try musicPlaylistsProvider(query.offset, query.limit, principal)) else {
                    return .serviceUnavailable()
                }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let playlistItemsPath where playlistItemsPath.hasPrefix("/api/v1/music/playlists/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let request = identifiedPagingQuery(
                from: target, prefix: "/api/v1/music/playlists/", identifierNamespace: "playlists"
            ) else { return .badRequest() }
            do {
                guard let detail = try musicPlaylistDetailProvider(request.id, request.offset, request.limit, principal),
                      let encoded = ServerCommandOutput.jsonData(detail.items)
                else { return .notFound() }
                body = encoded
            } catch { return .serviceUnavailable() }
        case let imagePath where imagePath.hasPrefix("/api/v1/images/"):
            if let limited = limitedResponse(
                scope: .artworkRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let remainder = imagePath.dropFirst("/api/v1/images/".count)
            let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
            guard let artworkRequest = artworkRequest(from: target) else { return .badRequest() }
            let asset: ServerMediaAsset?
            switch segments.count {
            case 2:
                guard let kind = ServerArtworkKind(rawValue: String(segments[1])),
                      let itemID = decodedPathIdentifier("/image/\(segments[0])", prefix: "/image/")
                else { return .notFound() }
                asset = try? artworkAssetProvider(itemID, kind, principal)
            case 3:
                // 详情页的剧照、推荐海报与人物头像。序号是浏览器拿到的全部信息：
                // 上游地址在服务端解析，浏览器从不直接联系元数据提供方。
                guard let kind = ServerDetailImageKind(rawValue: String(segments[1])),
                      let index = strictNonnegativeInteger(String(segments[2])), index < 64,
                      let itemID = decodedPathIdentifier("/image/\(segments[0])", prefix: "/image/")
                else { return .notFound() }
                asset = try? detailImageProvider(itemID, kind, index, principal)
            default:
                return .notFound()
            }
            guard let asset else { return .notFound() }
            // 派生结果都是磁盘文件，实体标签由「尺寸 + 修改时间」得到；`If-None-Match`
            // 命中就退成一次 304，不再重传整张 JPEG，远程封面还顺带免掉一次上游取图。
            let ifNoneMatch = httpHeader(named: "If-None-Match", in: requestHead)
            func fileResponse(
                _ served: ServerMediaAsset, cacheControl: String, omitBody: Bool
            ) -> LocalHTTPResponse {
                guard let entityTag = Self.fileEntityTag(for: served.fileURL) else {
                    return .fullFile(asset: served, omitBody: omitBody, cacheControl: cacheControl)
                }
                if Self.entityTagMatches(entityTag, ifNoneMatch: ifNoneMatch) {
                    return .notModified(entityTag: entityTag, cacheControl: cacheControl)
                }
                return .fullFile(
                    asset: served, omitBody: omitBody, cacheControl: cacheControl, entityTag: entityTag
                )
            }
            if let remoteURL = asset.remoteURL {
                // 远程封面只经已授权条目的同源图片端点返回；原始 URL 与 token
                // 从不进入 HTML。请求缩略图时，服务端先受限读取再生成私有 JPEG，
                // 避免浏览器为海报墙反复下载并解码多 MB 原图。
                // 上游身份剥掉了会轮换的 token 与尺寸参数，因此磁盘上已派生的缩略图
                // 可以直接按路径命中——不必为了"找到它"而把原图重新下载一遍。
                let upstreamIdentity = ServerRemoteArtworkURL.stableIdentity(for: remoteURL)
                // 远程条目没有「原图」这一档。
                //
                // 不带 `?size=` 时它从前是把上游原图整份代理给浏览器：不落磁盘缓存、
                // 只有五分钟的内存缓存，于是每看一次就回源一整张图。照片详情页正是
                // 这一条路径。改为一律走最大的那个桶——1024 已经是本产品里"最大展示
                // 尺寸"（详情页剧照灯箱用的就是它），而且它有磁盘缓存与实体标签。
                let remoteMaximumPixel: Int
                if case let .thumbnail(requestedMaximumPixel) = artworkRequest {
                    remoteMaximumPixel = requestedMaximumPixel
                } else {
                    remoteMaximumPixel = ServerArtworkThumbnailer.supportedMaximumPixels.max() ?? 1_024
                }
                if let cached = artworkThumbnailer.cachedRemoteThumbnail(
                    id: asset.id, upstreamIdentity: upstreamIdentity, maximumPixel: remoteMaximumPixel
                ) {
                    return fileResponse(cached, cacheControl: "private, max-age=86400", omitBody: isHeadRequest)
                }
                // 只向上游要真正需要的尺寸：同步阶段写下的地址固定是 maxWidth=700，
                // 而海报墙要的多半是 320，等于每张卡都在下载四倍面积的图再丢掉。
                let fetchURL = ServerRemoteArtworkURL.sized(remoteURL, maximumPixel: remoteMaximumPixel)
                guard !isHeadRequest, let body = remoteAssetFetcher.artworkBytes(url: fetchURL) else {
                    return isHeadRequest ? .notFound() : .serviceUnavailable()
                }
                // 上游字节**从不**原样转发：一律派生成本地 JPEG 再发出。
                //
                // 这既是性能上的选择（浏览器不必为海报墙反复解码多 MB 原图），也是
                // 授权层敢于放宽"远程地址必须带图片扩展名"那条判断的前提——不能解码
                // 成图片的字节到不了浏览器。派生失败即 503，不留降级通道。
                guard let thumbnail = artworkThumbnailer.thumbnail(
                    forRemoteData: body,
                    id: asset.id,
                    upstreamIdentity: upstreamIdentity,
                    maximumPixel: remoteMaximumPixel
                ) else { return .serviceUnavailable() }
                return fileResponse(thumbnail, cacheControl: "private, max-age=86400", omitBody: false)
            }
            switch artworkRequest {
            case .thumbnail(let requestedMaximumPixel):
                guard let thumbnail = artworkThumbnailer.thumbnail(for: asset, maximumPixel: requestedMaximumPixel) else {
                    return .notFound()
                }
                // 本地缩略图的实体标签跟着源文件的 mtime 走（文件名里就含它），
                // 所以换封面立刻失配。有了复验，这里不必再靠五分钟的短过期兜底。
                return fileResponse(thumbnail, cacheControl: "private, max-age=86400", omitBody: isHeadRequest)
            case .original:
                return fileResponse(asset, cacheControl: "private, max-age=300", omitBody: isHeadRequest)
            }
        case "/api/v1/me/preferences":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let account = try experienceRepository.userPreferences(userID: principal.userID)
                let device = try experienceRepository.devicePreferences(
                    userID: principal.userID, deviceID: principal.deviceID
                )
                let response = ServerPreferencesResponse(
                    account: account,
                    device: device,
                    effective: effectivePreferences(account.value, device: device?.value)
                )
                guard let encoded = ServerCommandOutput.jsonData(response) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: [etagHeader(account.version), "Cache-Control: no-store"]
                )
            } catch { return .serviceUnavailable() }
        case "/api/v1/me/preferences/device":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                guard let device = try experienceRepository.devicePreferences(
                    userID: principal.userID, deviceID: principal.deviceID
                ) else { return .notFound() }
                guard let encoded = ServerCommandOutput.jsonData(device) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: [etagHeader(device.version), "Cache-Control: no-store"]
                )
            } catch { return .serviceUnavailable() }
        case "/api/v1/admin/dashboard":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let settings = try experienceRepository.operationalSettings()
                let jobCounts = try experienceRepository.jobStateCounts()
                let response = ServerAdminDashboardResponse(
                    serverName: serverName,
                    apiVersion: MlinkProtocol.currentAPIVersion,
                    settingsVersion: settings.version,
                    maximumTranscodeSessions: settings.value.maximumTranscodeSessions,
                    queuedJobCount: jobCounts[.queued, default: 0],
                    runningJobCount: jobCounts[.running, default: 0],
                    failedJobCount: jobCounts[.failed, default: 0],
                    recentSecurityEventCount: (try? administrationCatalog?.securityEvents().events.count) ?? 0,
                    playback: playbackTelemetry.snapshot(),
                    lan: remoteAccessPolicy.lanAccessReadiness(),
                    runtime: runtimeDiagnosticsProvider()
                )
                guard let encoded = ServerCommandOutput.jsonData(response) else { return .serviceUnavailable() }
                return .json(body: encoded, omitBody: isHeadRequest, additionalHeaders: ["Cache-Control: no-store"])
            } catch { return .serviceUnavailable() }
        case "/api/v1/admin/settings":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let experienceRepository else { return .serviceUnavailable() }
            do {
                let settings = try experienceRepository.operationalSettings()
                guard let encoded = ServerCommandOutput.jsonData(settings) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: [etagHeader(settings.version), "Cache-Control: no-store"]
                )
            } catch { return .serviceUnavailable() }
        case "/api/v1/admin/jobs":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageLibraries) ||
                    principal.permissions.contains(.manageServer)
            else { return .forbidden() }
            guard let query = administrationJobsQuery(from: target) else { return .badRequest() }
            guard let experienceRepository else { return .serviceUnavailable() }
            let libraryKinds: Set<String> = ["library.scan", "library.reindex", "metadata.refresh"]
            let serverKinds: Set<String> = ["database.backup", "database.restore", "transcode-cache.clear"]
            var allowedKinds: Set<String> = []
            if principal.permissions.contains(.manageLibraries) { allowedKinds.formUnion(libraryKinds) }
            if principal.permissions.contains(.manageServer) { allowedKinds.formUnion(serverKinds) }
            if query.scope == "library" { allowedKinds.formIntersection(libraryKinds) }
            if query.scope == "server" { allowedKinds.formIntersection(serverKinds) }
            guard query.kind.map({ allowedKinds.contains($0) }) ?? true else { return .forbidden() }
            do {
                let page = try experienceRepository.managedJobs(
                    limit: query.limit,
                    offset: query.offset,
                    state: query.state,
                    kind: query.kind,
                    searchText: query.searchText,
                    allowedKinds: allowedKinds
                )
                guard let encoded = ServerCommandOutput.jsonData(page.jobs) else { return .serviceUnavailable() }
                return .json(
                    body: encoded,
                    omitBody: isHeadRequest,
                    additionalHeaders: administrationPaginationHeaders(
                        totalCount: page.totalCount,
                        offset: query.offset,
                        itemCount: page.jobs.count
                    )
                )
            } catch { return .serviceUnavailable() }
        case "/api/v1/admin/users":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let query = pagingQuery(from: target, path: "/api/v1/admin/users") else {
                return .badRequest()
            }
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.users(limit: query.limit, offset: query.offset),
                  let data = ServerCommandOutput.jsonData(encoded)
            else {
                return .serviceUnavailable()
            }
            body = data
        case "/api/v1/auth/me":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            do {
                guard let profile = try currentUserProfileProvider(principal),
                      let data = ServerCommandOutput.jsonData(profile)
                else { return .unauthorized() }
                body = data
            } catch {
                return .serviceUnavailable()
            }
        case "/api/v1/admin/sessions":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
            guard let query = administrationSessionsQuery(from: target) else { return .badRequest() }
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.activeSessions(
                    limit: query.limit,
                    offset: query.offset,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(encoded)
            else {
                return .serviceUnavailable()
            }
            body = data
        case "/api/v1/admin/security-events", "/api/v1/admin/logs":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let query = administrationSecurityEventsQuery(from: target, path: path) else {
                return .badRequest()
            }
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.securityEvents(
                    limit: query.limit,
                    offset: query.offset,
                    category: query.category,
                    outcome: query.outcome,
                    searchText: query.searchText
                  ),
                  let data = ServerCommandOutput.jsonData(encoded)
            else {
                return .serviceUnavailable()
            }
            body = data
        case "/api/v1/admin/sources":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let administrationCatalog,
                  let sources = try? administrationCatalog.sources(),
                  let data = ServerCommandOutput.jsonData(sources)
            else {
                return .serviceUnavailable()
            }
            body = data
        // 局域网开放就绪度只回答策略事实：没有地址、端口、代理 IP、上游 URL 或
        // 媒体标题，未认证客户端也拿不到部署形态。
        case "/api/v1/admin/lan-readiness":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let data = ServerCommandOutput.jsonData(remoteAccessPolicy.lanAccessReadiness()) else {
                return .serviceUnavailable()
            }
            body = data
        // 播放遥测只回答"代理整体表现如何"：计数、分桶与分位数。它不含媒体 ID、
        // 标题、路径、上游 URL、token、用户、设备或客户端地址。
        case "/api/v1/admin/playback-telemetry":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let data = ServerCommandOutput.jsonData(playbackTelemetry.snapshot()) else {
                return .serviceUnavailable()
            }
            body = data
        case "/api/v1/admin/libraries":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageLibraries) else { return .forbidden() }
            guard let administrationCatalog,
                  let libraries = try? administrationCatalog.libraries(),
                  let data = ServerCommandOutput.jsonData(libraries)
            else {
                return .serviceUnavailable()
            }
            body = data
        case let infoPath where infoPath.hasPrefix("/api/v1/playback/info/"):
            if let limited = limitedResponse(
                scope: .mediaProbe, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let encodedID = String(infoPath.dropFirst("/api/v1/playback/info/".count))
            guard !encodedID.isEmpty,
                  let itemID = encodedID.removingPercentEncoding,
                  !itemID.contains("/")
            else {
                return .notFound()
            }
            return playbackInfoResponse(itemID: itemID, principal: principal, omitBody: isHeadRequest)
        case let subtitleListPath where subtitleListPath.hasPrefix("/api/v1/playback/subtitles/"):
            if let limited = limitedResponse(
                scope: .mediaProbe, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(subtitleListPath, prefix: "/api/v1/playback/subtitles/") else {
                return .notFound()
            }
            return webVTTSubtitleTracksResponse(itemID: itemID, principal: principal, omitBody: isHeadRequest)
        case let trackListPath where trackListPath.hasPrefix("/api/v1/playback/tracks/"):
            if let limited = limitedResponse(
                scope: .mediaProbe, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(trackListPath, prefix: "/api/v1/playback/tracks/") else {
                return .notFound()
            }
            let baseTracks: ServerWebPlaybackTrackSet
            do {
                guard let resolved = try playbackTracksProvider(itemID, principal) else {
                    return .notFound()
                }
                baseTracks = resolved
            } catch is ServerRemoteSubtitleTracksPending {
                return .accepted(
                    body: Data(),
                    additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
                )
            } catch {
                return .notFound()
            }
            var selectionOverride = try? experienceRepository?.trackOverride(
                userID: principal.userID,
                scope: .media,
                scopeID: itemID
            )
            if selectionOverride == nil,
               let detail = try? mediaDetailProvider(itemID, principal),
               let seriesID = detail.episodeContext?.seriesID {
                selectionOverride = try? experienceRepository?.trackOverride(
                    userID: principal.userID,
                    scope: .series,
                    scopeID: seriesID
                )
            }
            let tracks = baseTracks.applying(selectionOverride: selectionOverride ?? nil)
            guard let encoded = ServerCommandOutput.jsonData(tracks) else { return .serviceUnavailable() }
            return .ok(body: encoded, omitBody: isHeadRequest)
        case let keyframePath where keyframePath.hasPrefix("/api/v1/playback/keyframe/"):
            if let limited = limitedResponse(
                scope: .mediaProbe, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(keyframePath, prefix: "/api/v1/playback/keyframe/"),
                  let requested = keyframeQuery(from: target),
                  let resolved = try? remuxStartProvider(itemID, requested, principal)
            else { return .notFound() }
            let encoded = Data("{\"startSeconds\":\(String(format: "%.3f", resolved))}".utf8)
            return .ok(body: encoded, omitBody: isHeadRequest)
        case let subtitlePath where subtitlePath.hasPrefix("/api/v1/subtitles/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            return webVTTSubtitleResponse(path: subtitlePath, principal: principal, omitBody: isHeadRequest)
        case let remuxPath where remuxPath.hasPrefix("/api/v1/transcode/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(remuxPath, prefix: "/api/v1/transcode/"),
                  let request = audioRemuxRequest(from: target)
            else { return .notFound() }
            return audioRemuxResponse(
                itemID: itemID,
                audioTrackID: request.audioTrackID,
                startSeconds: request.startSeconds,
                principal: principal,
                clientAddressKey: clientAddressKey,
                omitBody: isHeadRequest
            )
        case let streamPath where streamPath.hasPrefix("/api/v1/stream/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let encodedID = String(streamPath.dropFirst("/api/v1/stream/".count))
            guard !encodedID.isEmpty,
                  let itemID = encodedID.removingPercentEncoding,
                  !itemID.contains("/")
            else {
                return .notFound()
            }
            return streamResponse(
                itemID: itemID,
                principal: principal,
                clientAddressKey: clientAddressKey,
                rangeHeader: httpHeader(named: "Range", in: requestHead),
                omitBody: isHeadRequest
            )
        case let downloadPath where downloadPath.hasPrefix("/api/v1/download/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let itemID = decodedPathIdentifier(downloadPath, prefix: "/api/v1/download/") else {
                return .notFound()
            }
            return downloadResponse(
                itemID: itemID,
                principal: principal,
                clientAddressKey: clientAddressKey,
                rangeHeader: httpHeader(named: "Range", in: requestHead),
                omitBody: isHeadRequest
            )
        default:
            return .notFound()
        }
        return .ok(body: body, omitBody: isHeadRequest)
    }

    private func encodedLibraryResponse<T: Encodable>(
        _ value: (ServerLibrarySnapshot) -> T,
        principal: ServerRequestPrincipal
    ) -> Data? {
        guard let snapshot = try? librarySnapshotProvider(principal) else { return nil }
        return ServerCommandOutput.jsonData(value(snapshot))
    }

    private func decodedPathIdentifier(_ path: String, prefix: String) -> String? {
        let encodedID = String(path.dropFirst(prefix.count))
        guard !encodedID.isEmpty,
              let itemID = encodedID.removingPercentEncoding,
              !itemID.isEmpty,
              !itemID.contains("/"),
              !itemID.contains("\\"),
              !itemID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              itemID.utf8.count <= 512
        else {
            return nil
        }
        return itemID
    }

    /// 只接受固定键和值域；重复键、未知键、控制字符和畸形百分号统一拒绝。
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
                      ["q", "type", "group", "offset", "limit", "sort", "order", "genre", "state", "preference", "remoteScope", "vault"].contains(key),
                      values[key] == nil
                else { return nil }
                values[key] = value
            }
        }
        guard values.values.allSatisfy({ value in
            value.utf8.count <= 512 && !value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
        }) else { return nil }
        let searchText = values["q"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(128))
        }
        if let rawSearch = values["q"], rawSearch.count > 128 { return nil }
        let type = values["type"].flatMap { $0.isEmpty ? nil : $0 }
        if let type {
            guard let mediaType = MediaType(rawValue: type), mediaType != .privateCollection, mediaType != .auto else {
                return nil
            }
        }
        let mediaGroup: ServerLibraryMediaGroup?
        if let rawGroup = values["group"], !rawGroup.isEmpty {
            guard type == nil, let parsed = ServerLibraryMediaGroup(rawValue: rawGroup) else { return nil }
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
            guard let parsed = ServerLibraryPreferenceFilter(rawValue: rawPreference) else { return nil }
            preferenceFilter = parsed
        } else {
            preferenceFilter = nil
        }
        // 排序键与方向。旧的四个 `sort` 值（`updatedDescending` 等）永远被接受——
        // 用户地址栏里已经存着它们——但它们各自只代表一个完整状态，所以与显式
        // `order` 同时出现会被拒绝：同一个状态不能有两种拼法。
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
        // 题材是自由文本（数据决定，不是固定枚举），所以它被裁剪而非白名单校验；
        // 仓储层把它当作绑定参数并转义 LIKE 元字符。空值是错误而不是"无筛选"：
        // 无筛选的写法是不带这个键。
        let genre: String?
        if let rawGenre = values["genre"] {
            let trimmed = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, trimmed.count <= 64 else { return nil }
            genre = trimmed
        } else {
            genre = nil
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "48"), (1...100).contains(limit)
        else { return nil }
        // 远程作用域只接受不透明十六进制 ID；解析仍在已授权集合内匹配，
        // 未知值得到空集合而不是一个未加作用域的结果。
        // 保险库作用域只认一个字面量 `1`。它不是"再加一个筛选"，而是把浏览范围
        // 整个换掉，所以它与远程作用域互斥——同时给出两个作用域是矛盾的请求，
        // 拒绝比挑一个执行更安全。
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
            playbackFilter: playbackFilter, preferenceFilter: preferenceFilter, mediaGroup: mediaGroup,
            remoteScopeID: remoteScopeID,
            vaultScope: vaultScope
        )
    }

    /// 从一个 HTML 页面路由的查询串里读一个受限文本键。
    ///
    /// 与 API 端点不同，页面路由对未知键宽容——用户会带着 utm 之类的参数落地，
    /// 那时应该正常渲染而不是 400。但取出来的值仍然被裁剪并剔除控制字符。
    private func boundedQueryText(from target: String, key: String, maximumLength: Int) -> String? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2, !pieces[1].isEmpty else { return nil }
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: true) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  decodeQueryComponent(String(keyValue[0])) == key,
                  let value = decodeQueryComponent(String(keyValue[1]))
            else { continue }
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty,
                  !trimmed.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            return String(trimmed.prefix(maximumLength))
        }
        return nil
    }

    /// 页面渲染时取筛选面。取不到就退回空集：筛选栏于是只给出永远成立的排序键，
    /// 而不是让整页 503——一个少了题材下拉的页面仍然可用。
    private func libraryFacets(
        type: String?,
        group: ServerLibraryMediaGroup?,
        for principal: ServerRequestPrincipal
    ) -> ServerLibraryFacetsResponse {
        (try? libraryFacetsProvider(type, group, principal))
            ?? ServerLibraryFacetsResponse(genres: [], availableSorts: [])
    }

    /// `/api/v1/library/facets` 的作用域。键白名单与 browse 同样严格——多一个未知键
    /// 就是 400，而不是被忽略。
    private func libraryFacetsScope(from target: String) -> (type: String?, group: ServerLibraryMediaGroup?)? {
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
                      ["type", "group"].contains(key),
                      values[key] == nil
                else { return nil }
                values[key] = value
            }
        }
        let type = values["type"].flatMap { $0.isEmpty ? nil : $0 }
        if let type {
            guard let mediaType = MediaType(rawValue: type), mediaType != .privateCollection, mediaType != .auto else {
                return nil
            }
        }
        let group: ServerLibraryMediaGroup?
        if let rawGroup = values["group"], !rawGroup.isEmpty {
            guard type == nil, let parsed = ServerLibraryMediaGroup(rawValue: rawGroup) else { return nil }
            group = parsed
        } else {
            group = nil
        }
        return (type, group)
    }

    private func decodeQueryComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    /// 图片接口只有显式的尺寸桶；它不接受未知键、重复键或空值，避免暴露任意图片
    /// 处理能力，也让缓存键保持可预测。
    /// 浏览器给失败的封面重试时挂上的序号。服务端只认识它、然后忽略它。
    static let artworkRetryQueryKey = "_retry"

    /// `/api/v1/transcode/<id>?audio=<序号>&start=<秒>` 的严格解析。
    ///
    /// 键白名单与封面端点同样严格：未知键、重复键、畸形百分号一律拒绝。`start` 只
    /// 认整数秒——分片流本来就只能在关键帧起播，把小数交给 ffmpeg 只会让"同一个
    /// 位置"变成一串互不相同的 URL，白白多起好几个进程。
    private func audioRemuxRequest(from target: String) -> (audioTrackID: Int, startSeconds: Double)? {
        guard let values = boundedQuery(from: target, allowedKeys: ["audio", "start"]) else { return nil }
        var audioTrackID = 0
        if let raw = values["audio"] {
            guard let parsed = strictNonnegativeInteger(raw),
                  parsed < ServerWebAudioTrackSet.maximumTrackCount
            else { return nil }
            audioTrackID = parsed
        }
        var startSeconds: Double = 0
        if let raw = values["start"] {
            guard let parsed = Self.boundedSeconds(raw) else { return nil }
            startSeconds = parsed
        }
        return (audioTrackID, startSeconds)
    }

    /// `/api/v1/playback/keyframe/<id>?at=<秒>`。
    private func keyframeQuery(from target: String) -> Double? {
        guard let values = boundedQuery(from: target, allowedKeys: ["at"]),
              let raw = values["at"]
        else { return nil }
        return Self.boundedSeconds(raw)
    }

    /// 键白名单式的查询串解析：未知键、重复键、畸形百分号一律拒绝。
    private func boundedQuery(from target: String, allowedKeys: Set<String>) -> [String: String]? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        guard pieces.count == 2 else { return [:] }
        guard !pieces[1].isEmpty else { return nil }
        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  allowedKeys.contains(key),
                  values[key] == nil
            else { return nil }
            values[key] = value
        }
        return values
    }

    /// 秒数：最多 5 位整数 + 最多 3 位小数，上限一天。小数是必需的——跳转落点要
    /// 对齐到关键帧的真实时间戳，那不是整数。
    private static func boundedSeconds(_ raw: String) -> Double? {
        guard !raw.isEmpty, raw.utf8.count <= 9 else { return nil }
        let parts = raw.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count <= 2,
              let whole = parts.first, !whole.isEmpty, whole.count <= 5, whole.allSatisfy(\.isNumber)
        else { return nil }
        if parts.count == 2 {
            let fraction = parts[1]
            guard !fraction.isEmpty, fraction.count <= 3, fraction.allSatisfy(\.isNumber) else { return nil }
        }
        guard let value = Double(raw), value.isFinite, value >= 0, value < 86_400 else { return nil }
        return value
    }

    private func artworkRequest(from target: String) -> ArtworkRequest? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2 else { return nil }
        guard pieces.count == 2 else { return .original }
        guard !pieces[1].isEmpty else { return nil }

        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  key == "size" || key == Self.artworkRetryQueryKey,
                  values[key] == nil,
                  !value.isEmpty,
                  value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                  value.utf8.count <= 4
            else { return nil }
            // 重试序号只是一个换 URL 的手段：浏览器不会为同一个地址再发一次请求，
            // 而失败的封面必须能真正重取。它不参与任何解析，1–3 位数字之外一律拒绝。
            if key == Self.artworkRetryQueryKey {
                guard value.utf8.count <= 3 else { return nil }
                // 记下来只为了让「同一个键出现两次」照旧被拒绝；读取时只认 `size`。
                values[key] = value
                continue
            }
            guard let maximumPixel = Int(value),
                  ServerArtworkThumbnailer.supportedMaximumPixels.contains(maximumPixel)
            else { return nil }
            values[key] = value
        }
        // 只带重试序号、没有 `size` 时仍然是"原图"那一档，与不带查询串一致。
        guard let value = values["size"] else { return .original }
        guard let maximumPixel = Int(value) else { return nil }
        return .thumbnail(maximumPixel)
    }

    /// 派生自「将要发出的那个文件」的实体标签。
    ///
    /// 用尺寸与修改时间，不读内容：缩略图的磁盘文件名本身已经是内容身份的摘要
    /// （本地是 `路径|大小|mtime`，远程是与凭据无关的上游身份），所以这两项一变
    /// 就一定是另一张图。为每次复验重新读一遍几十 KB 的 JPEG 去算哈希，代价正好
    /// 落在这个机制想省掉的地方。
    ///
    /// 弱标签（`W/`）：Range 请求不按它做条件取字节，海报也从不走 Range。
    private static func fileEntityTag(for url: URL) -> String? {
        guard let values = try? url.resourceValues(
            forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
        ), values.isRegularFile == true, let size = values.fileSize else { return nil }
        let modified = Int64((values.contentModificationDate ?? .distantPast).timeIntervalSince1970 * 1_000)
        return "W/\"\(size)-\(modified)\""
    }

    /// `If-None-Match` 是否覆盖这个标签。`*` 按 RFC 9110 匹配任何现存表示。
    private static func entityTagMatches(_ entityTag: String, ifNoneMatch header: String?) -> Bool {
        guard let header else { return false }
        let candidates = header.split(separator: ",").map {
            $0.trimmingCharacters(in: .whitespaces)
        }
        guard !candidates.isEmpty else { return false }
        if candidates.contains("*") { return true }
        // 弱比较：`W/"x"` 与 `"x"` 视为同一表示，这正是弱标签该有的语义。
        func normalized(_ value: String) -> String {
            value.hasPrefix("W/") ? String(value.dropFirst(2)) : value
        }
        let expected = normalized(entityTag)
        return candidates.contains { normalized($0) == expected }
    }

    private func seriesEpisodeQuery(
        from target: String
    ) -> (id: String, season: ServerSeriesSeasonSelector, offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let path = String(pieces[0])
        let prefix = "/api/v1/series/"
        let suffix = "/episodes"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encodedID.isEmpty,
              let id = decodedPathIdentifier("/series/\(encodedID)", prefix: "/series/")
        else { return nil }
        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  ["season", "offset", "limit"].contains(key),
                  values[key] == nil,
                  value.utf8.count <= 64,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            values[key] = value
        }
        let season: ServerSeriesSeasonSelector
        if values["season"] == "unspecified" {
            season = .unspecified
        } else {
            guard let rawSeason = values["season"],
                  let number = strictNonnegativeInteger(rawSeason), number <= 10_000
            else { return nil }
            season = .numbered(number)
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "50"), (1...100).contains(limit)
        else { return nil }
        return (id, season, offset, limit)
    }

    private func decodedSeriesPlayIdentifier(_ path: String) -> String? {
        let prefix = "/series/"
        let suffix = "/play"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encodedID.isEmpty else { return nil }
        return decodedPathIdentifier("/series/\(encodedID)", prefix: prefix)
    }

    /// 人物目录只接受固定搜索键和有界分页。搜索语句最终是 SQLite 绑定参数，且这里
    /// 先拒绝重复键、控制字符、畸形百分号和超长输入，避免把目录接口变成枚举入口。
    private func peopleQuery(from target: String) -> (searchText: String?, offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/api/v1/people" else { return nil }
        var values: [String: String] = [:]
        if pieces.count == 2, !pieces[1].isEmpty {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2,
                      let key = decodeQueryComponent(String(keyValue[0])),
                      let value = decodeQueryComponent(String(keyValue[1])),
                      ["q", "offset", "limit"].contains(key), values[key] == nil,
                      value.utf8.count <= 512,
                      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
                else { return nil }
                values[key] = value
            }
        }
        let search = values["q"].flatMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : String(trimmed.prefix(128))
        }
        if let raw = values["q"], raw.count > 128 { return nil }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "24"), (1...100).contains(limit)
        else { return nil }
        return (search, offset, limit)
    }

    private func personCreditsQuery(from target: String) -> (id: String, offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let path = String(pieces[0])
        let prefix = "/api/v1/people/"
        let suffix = "/credits"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let id = decodedPathIdentifier("/people/\(encodedID)", prefix: "/people/") else { return nil }
        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  ["offset", "limit"].contains(key), values[key] == nil,
                  value.utf8.count <= 32,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            values[key] = value
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "24"), (1...100).contains(limit)
        else { return nil }
        return (id, offset, limit)
    }

    /// 合集仅接受分页参数。合集 ID 经过同一套路径段解码与控制字符检查，查询键
    /// 不能携带账号、资料库或任意排序字段，从路由边界阻断横向枚举。
    /// 侧栏那两串由数据决定的条目。
    ///
    /// 智能集合与智能歌单必须在**每一个**页面上都出现，否则它们会在展开「视频」或
    /// 「音乐」时忽隐忽现——比从不显示更让人困惑。取不到就给空，侧栏少两行，不会
    /// 让页面渲染失败。
    private func sidebarExtras(
        for principal: ServerRequestPrincipal,
        activeRemoteScopeID: String? = nil
    ) -> ServerWebSidebarExtras {
        let revision = (try? navigationRevisionProvider(principal)) ?? UUID().uuidString
        let permissionKey = principal.permissions.map(\.rawValue).sorted().joined(separator: ",")
        let grantKey = principal.libraryGrants.values
            .sorted { $0.libraryID < $1.libraryID }
            .map {
                "\($0.libraryID):\($0.canView ? 1 : 0):\($0.canPlay ? 1 : 0):\($0.canDownload ? 1 : 0)"
            }
            .joined(separator: ",")
        let key = "\(revision)|\(permissionKey)|\(grantKey)"
        let resolved = navigationCache.value(for: key) {
            ServerWebSidebarExtras(
                smartCollections: (try? smartCollectionsProvider(0, 24, principal))?.items ?? [],
                smartPlaylists: (try? musicPlaylistsProvider(0, 100, principal))?.items ?? [],
                remoteSources: (try? remoteSourceGroupsProvider(principal)) ?? [],
                videoGroupItemCount: (try? libraryCategoriesProvider(principal))?.videoGroupItemCount ?? 0
            )
        }
        return ServerWebSidebarExtras(
            smartCollections: resolved.smartCollections,
            smartPlaylists: resolved.smartPlaylists,
            // 远程分组和徽标同样只由数据库媒体/来源/授权生成，必须与其它导航内容
            // 共用修订快照；实际连接状态不在这个 DTO 中，不需要每页重新聚合。
            remoteSources: resolved.remoteSources,
            videoGroupItemCount: resolved.videoGroupItemCount,
            activeRemoteScopeID: activeRemoteScopeID
        )
    }

    private func collectionsQuery(from target: String) -> (offset: Int, limit: Int)? {
        pagingQuery(from: target, path: "/api/v1/collections")
    }

    private func administrationSessionsQuery(
        from target: String
    ) -> (offset: Int, limit: Int, searchText: String?)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == "/api/v1/admin/sessions",
              let values = boundedQuery(from: target, allowedKeys: ["offset", "limit", "q"]),
              let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "50"), (1...100).contains(limit)
        else { return nil }
        let trimmed = values["q"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.utf8.count ?? 0) <= 128,
              trimmed?.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) != true
        else { return nil }
        return (offset, limit, trimmed?.isEmpty == false ? trimmed : nil)
    }

    private func administrationSecurityEventsQuery(
        from target: String,
        path expectedPath: String
    ) -> (
        offset: Int,
        limit: Int,
        category: ServerSecurityEventCategory?,
        outcome: ServerSecurityEventOutcome?,
        searchText: String?
    )? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == expectedPath,
              let values = boundedQuery(
                from: target,
                allowedKeys: ["offset", "limit", "category", "outcome", "q"]
              ),
              let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "50"), (1...100).contains(limit)
        else { return nil }
        let category = values["category"].flatMap(ServerSecurityEventCategory.init(rawValue:))
        let outcome = values["outcome"].flatMap(ServerSecurityEventOutcome.init(rawValue:))
        guard values["category"] == nil || category != nil,
              values["outcome"] == nil || outcome != nil
        else { return nil }
        let trimmed = values["q"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.utf8.count ?? 0) <= 128,
              trimmed?.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) != true
        else { return nil }
        return (offset, limit, category, outcome, trimmed?.isEmpty == false ? trimmed : nil)
    }

    private func administrationJobsQuery(
        from target: String
    ) -> (
        offset: Int,
        limit: Int,
        state: ServerJobState?,
        kind: String?,
        scope: String?,
        searchText: String?
    )? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == "/api/v1/admin/jobs",
              let values = boundedQuery(
                from: target,
                allowedKeys: ["offset", "limit", "state", "kind", "scope", "q"]
              ),
              let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "50"), (1...100).contains(limit)
        else { return nil }
        let state = values["state"].flatMap(ServerJobState.init(rawValue:))
        let knownKinds: Set<String> = [
            "library.scan", "library.reindex", "metadata.refresh",
            "database.backup", "database.restore", "transcode-cache.clear"
        ]
        let kind = values["kind"]
        let scope = values["scope"]
        guard values["state"] == nil || state != nil,
              kind.map({ knownKinds.contains($0) }) ?? true,
              scope.map({ ["library", "server"].contains($0) }) ?? true
        else { return nil }
        let trimmed = values["q"]?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (trimmed?.utf8.count ?? 0) <= 128,
              trimmed?.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) != true
        else { return nil }
        return (offset, limit, state, kind, scope, trimmed?.isEmpty == false ? trimmed : nil)
    }

    private func administrationBackupsQuery(
        from target: String
    ) -> (offset: Int, limit: Int, kind: ServerBackupKind?)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == "/api/v1/admin/backups",
              let values = boundedQuery(from: target, allowedKeys: ["offset", "limit", "kind"]),
              let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "100"), (1...100).contains(limit)
        else { return nil }
        let kind = values["kind"].flatMap(ServerBackupKind.init(rawValue:))
        guard values["kind"] == nil || kind != nil else { return nil }
        return (offset, limit, kind)
    }

    private func administrationPaginationHeaders(
        totalCount: Int,
        offset: Int,
        itemCount: Int
    ) -> [String] {
        let boundedTotal = max(totalCount, 0)
        let boundedOffset = max(offset, 0)
        let boundedItemCount = max(itemCount, 0)
        return [
            "Cache-Control: no-store",
            "X-MediaLIB-Total-Count: \(boundedTotal)",
            "X-MediaLIB-Is-Truncated: \(boundedOffset + boundedItemCount < boundedTotal ? "true" : "false")"
        ]
    }

    private func pagingQuery(from target: String, path expectedPath: String) -> (offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first.map(String.init) == expectedPath else { return nil }
        var values: [String: String] = [:]
        if pieces.count == 2, !pieces[1].isEmpty {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2,
                      let key = decodeQueryComponent(String(keyValue[0])),
                      let value = decodeQueryComponent(String(keyValue[1])),
                      ["offset", "limit"].contains(key), values[key] == nil,
                      value.utf8.count <= 32,
                      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
                else { return nil }
                values[key] = value
            }
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "24"), (1...100).contains(limit)
        else { return nil }
        return (offset, limit)
    }

    private func collectionItemsQuery(from target: String) -> (id: String, offset: Int, limit: Int)? {
        identifiedPagingQuery(from: target, prefix: "/api/v1/collections/", identifierNamespace: "collections")
    }

    /// `/api/v1/<集合>/<id>/items?offset=&limit=` 的解析。
    ///
    /// 智能集合和歌单的 items 路由与合集逐字同形，所以共用这一份而不是各抄一遍：
    /// 抄一遍就是多一处可以漏掉 `decodedPathIdentifier`、漏掉上界检查的地方。
    private func identifiedPagingQuery(
        from target: String,
        prefix: String,
        identifierNamespace: String
    ) -> (id: String, offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let path = String(pieces[0])
        let suffix = "/items"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let id = decodedPathIdentifier("/\(identifierNamespace)/\(encodedID)", prefix: "/\(identifierNamespace)/") else { return nil }
        var values: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1])),
                  ["offset", "limit"].contains(key), values[key] == nil,
                  value.utf8.count <= 32,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            values[key] = value
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "24"), (1...100).contains(limit)
        else { return nil }
        return (id, offset, limit)
    }

    private func photosQuery(from target: String) -> (offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/api/v1/photos" else { return nil }
        var values: [String: String] = [:]
        if pieces.count == 2, !pieces[1].isEmpty {
            for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
                let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                guard keyValue.count == 2,
                      let key = decodeQueryComponent(String(keyValue[0])),
                      let value = decodeQueryComponent(String(keyValue[1])),
                      ["offset", "limit"].contains(key), values[key] == nil,
                      value.utf8.count <= 32,
                      !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
                else { return nil }
                values[key] = value
            }
        }
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "24"), (1...100).contains(limit)
        else { return nil }
        return (offset, limit)
    }

    private func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    private func streamResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        rangeHeader: String?,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let policy = experiencePolicy(for: principal),
              policyAllowsPlayback(policy, clientAddressKey: clientAddressKey),
              policyAllowsItem(policy, itemID: itemID, principal: principal),
              policy.directPlayAllowed
        else { return .notFound() }
        guard let asset = try? mediaAssetProvider(itemID, principal, .playMedia) else {
            // 与不存在的条目统一返回 404，避免 ID 或资料库权限被枚举。
            return .notFound()
        }
        if let remoteURL = asset.remoteURL {
            guard let sizedAsset = remoteAssetWithResolvedLength(asset, remoteURL: remoteURL) else {
                return .serviceUnavailable()
            }
            return remoteStreamResponse(
                asset: sizedAsset,
                remoteURL: remoteURL,
                rangeHeader: rangeHeader,
                omitBody: omitBody
            )
        }

        guard asset.byteLength > 0 else { return .rangeNotSatisfiable(totalLength: asset.byteLength) }

        if let rangeHeader {
            guard let request = HTTPByteRangeRequest(headerValue: rangeHeader),
                  let range = request.resolve(totalLength: asset.byteLength)
            else {
                return .rangeNotSatisfiable(totalLength: asset.byteLength)
            }
            return .partialFile(asset: asset, range: range, omitBody: omitBody)
        }
        return .fullFile(asset: asset, omitBody: omitBody)
    }

    private func downloadResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        rangeHeader: String?,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let policy = experiencePolicy(for: principal),
              policyAllowsPlayback(policy, clientAddressKey: clientAddressKey),
              policyAllowsItem(policy, itemID: itemID, principal: principal),
              policy.downloadAllowed
        else { return .notFound() }
        guard let asset = try? mediaAssetProvider(itemID, principal, .downloadMedia) else {
            // 下载与播放使用同一条目隐藏策略；无权时不能通过状态码差异枚举媒体。
            return .notFound()
        }
        let headers = ["Content-Disposition: attachment; filename=\"\(safeDownloadFileName(for: asset))\""]
        if let remoteURL = asset.remoteURL {
            guard let sizedAsset = remoteAssetWithResolvedLength(asset, remoteURL: remoteURL) else {
                return .serviceUnavailable()
            }
            return remoteStreamResponse(
                asset: sizedAsset,
                remoteURL: remoteURL,
                rangeHeader: rangeHeader,
                omitBody: omitBody,
                additionalHeaders: headers
            )
        }
        guard asset.byteLength > 0 else { return .rangeNotSatisfiable(totalLength: asset.byteLength) }
        if let rangeHeader {
            guard let request = HTTPByteRangeRequest(headerValue: rangeHeader),
                  let range = request.resolve(totalLength: asset.byteLength)
            else {
                return .rangeNotSatisfiable(totalLength: asset.byteLength)
            }
            return .partialFile(asset: asset, range: range, omitBody: omitBody, additionalHeaders: headers)
        }
        return .fullFile(asset: asset, omitBody: omitBody, additionalHeaders: headers)
    }

    private func remoteAssetWithResolvedLength(_ asset: ServerMediaAsset, remoteURL: URL) -> ServerMediaAsset? {
        if asset.byteLength > 0 { return asset }
        guard let byteLength = remoteAssetFetcher.mediaByteLength(url: remoteURL), byteLength > 0 else { return nil }
        return ServerMediaAsset(
            id: asset.id,
            remoteURL: remoteURL,
            byteLength: byteLength,
            contentType: asset.declaredContentType ?? asset.contentType
        )
    }

    /// 对上游媒体始终做有界 Range 读取，但对浏览器保持标准 HTTP 语义：没有
    /// `Range` 的 GET 是完整 200，明确带 Range 的请求才是 206。完整响应仍按
    /// 16 MiB 上游窗口逐段转发，不会把整部影片缓进内存或磁盘。
    private func remoteStreamResponse(
        asset: ServerMediaAsset,
        remoteURL: URL,
        rangeHeader: String?,
        omitBody: Bool,
        additionalHeaders: [String] = []
    ) -> LocalHTTPResponse {
        // 记录"这次为什么走代理"。远程条目在此处必然是代理；把原因显式记下来，
        // 就不需要在事后从日志推断策略，也不会因为改了策略而无人察觉。
        ServerPlaybackTelemetry.shared.recordTransportReason(
            remoteAccessPolicy.transportDecisionReason(upstream: remoteURL)
        )
        if let rangeHeader {
            guard let request = HTTPByteRangeRequest(headerValue: rangeHeader),
                  let resolved = request.resolve(totalLength: asset.byteLength)
            else { return .rangeNotSatisfiable(totalLength: asset.byteLength) }
            // HTMLMediaElement 通常以 `bytes=0-` 发起首个探测；远程代理不能为
            // 该开放范围一次性缓冲整部影片。返回同一起点的有界 206 分段，让浏览器
            // 继续按需请求即可，同时保持服务进程内存上限。
            let length = min(resolved.length, Int64(ServerRemoteAssetFetcher.maximumMediaRangeByteLength))
            let range = ResolvedHTTPByteRange(
                lowerBound: resolved.lowerBound,
                upperBound: resolved.lowerBound + length - 1,
                totalLength: asset.byteLength
            )
            return LocalHTTPResponse(
                statusCode: 206,
                reason: "Partial Content",
                contentType: asset.contentType,
                payload: omitBody
                    ? .data(Data())
                    : .remoteRange(
                        LocalHTTPRemoteRange(
                            fetcher: remoteAssetFetcher,
                            url: remoteURL,
                            offset: range.lowerBound,
                            length: range.length
                        )
                    ),
                declaredContentLength: Int(range.length),
                additionalHeaders: [
                    "Accept-Ranges: bytes",
                    "Content-Range: \(range.contentRangeHeader)",
                    "Cache-Control: no-store"
                ] + additionalHeaders
            )
        }
        return LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: asset.contentType,
            payload: omitBody
                ? .data(Data())
                : .remoteFull(
                    LocalHTTPRemoteFull(
                        fetcher: remoteAssetFetcher,
                        url: remoteURL,
                        byteLength: asset.byteLength
                    )
                ),
            declaredContentLength: Int(asset.byteLength),
            additionalHeaders: [
                "Accept-Ranges: bytes",
                "Cache-Control: no-store"
            ] + additionalHeaders
        )
    }

    private func safeDownloadFileName(for asset: ServerMediaAsset) -> String {
        let ext = asset.fileURL.pathExtension.lowercased()
        guard ext.utf8.count <= 16,
              !ext.isEmpty,
              ext.unicodeScalars.allSatisfy({ scalar in
                  (scalar.value >= 48 && scalar.value <= 57) ||
                      (scalar.value >= 97 && scalar.value <= 122)
              })
        else {
            return "MediaLIB-download"
        }
        return "MediaLIB-download.\(ext)"
    }

    private func webVTTSubtitleTracksResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let tracks = try webVTTSubtitleTracksProvider(itemID, principal),
                  let body = ServerCommandOutput.jsonData(tracks)
            else { return .notFound() }
            return .ok(body: body, omitBody: omitBody)
        } catch is ServerRemoteSubtitleTracksPending {
            return .accepted(
                body: Data(),
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
            )
        } catch {
            return .notFound()
        }
    }

    private func webVTTSubtitleResponse(
        path: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        let prefix = "/api/v1/subtitles/"
        let remainder = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard remainder.count == 2,
              let itemID = String(remainder[0]).removingPercentEncoding,
              !itemID.isEmpty,
              !itemID.contains("/"),
              !itemID.contains("\\"),
              let trackID = strictNonnegativeInteger(String(remainder[1])),
              trackID < ServerWebVTTSubtitleTrack.maximumTrackCount
        else { return .notFound() }
        let track: ServerSubtitleTrackReference
        do {
            guard let resolved = try subtitleTrackProvider(itemID, trackID, principal) else {
                return .notFound()
            }
            track = resolved
        } catch is ServerRemoteSubtitleTracksPending {
            return .accepted(
                body: Data(),
                additionalHeaders: ["Cache-Control: no-store", "Retry-After: 2"]
            )
        } catch {
            return .notFound()
        }
        switch track.source {
        case let .sidecar(asset):
            let pathExtension = asset.fileURL.pathExtension.lowercased()
            // 已经是 VTT 的原样流式送出，保持"路由层不把文件复制进内存"的既有边界。
            guard pathExtension != "vtt" else {
                return .file(
                    url: asset.fileURL,
                    byteLength: asset.byteLength,
                    contentType: "text/vtt; charset=utf-8",
                    omitBody: omitBody
                )
            }
            // SRT 与 ASS 必须落到内存再转：`<track>` 只认 WebVTT，把原文交出去
            // 浏览器会静默丢掉整条轨道。转换要读完全文，而且中文资料库里的这两类
            // 文件常常不是 UTF-8，顺带统一编码。体积由 8 MiB 上限兜住。
            guard asset.byteLength <= Int64(ServerWebVTTSubtitleTrack.maximumByteLength),
                  let raw = try? Data(contentsOf: asset.fileURL),
                  let payload = ServerSubtitleSidecar.webVTTPayload(
                    from: raw, pathExtension: pathExtension
                  )
            else { return .notFound() }
            return Self.webVTTResponse(payload: payload, omitBody: omitBody)
        case let .embedded(asset, streamIndex):
            switch mediaTrackCatalog.embeddedSubtitleWebVTT(
                for: asset,
                streamIndex: streamIndex,
                startIfNeeded: !omitBody
            ) {
            case let .ready(payload):
                return Self.webVTTResponse(payload: payload, omitBody: omitBody)
            case .pending:
                return .accepted(
                    body: Data(),
                    additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
                )
            case .failed:
                return .notFound()
            }
        case let .remote(remoteTrack):
            guard !omitBody else {
                // HEAD 不该为了报一个长度就去 Emby 拉一份字幕回来。
                return Self.webVTTResponse(payload: Data(), omitBody: true)
            }
            switch remoteSubtitleBodyCatalog.webVTT(
                ownerID: "\(itemID)/\(trackID)",
                track: remoteTrack
            ) {
            case let .ready(payload):
                return Self.webVTTResponse(payload: payload, omitBody: false)
            case .pending:
                return .accepted(
                    body: Data(),
                    additionalHeaders: ["Cache-Control: no-store", "Retry-After: 1"]
                )
            case .failed:
                return .notFound()
            }
        }
    }

    private static func webVTTResponse(payload: Data, omitBody: Bool) -> LocalHTTPResponse {
        LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "text/vtt; charset=utf-8",
            payload: .data(omitBody ? Data() : payload),
            declaredContentLength: payload.count,
            additionalHeaders: ["Cache-Control: private, max-age=300"]
        )
    }

    /// 重新封装音轨的播放流。
    ///
    /// 它**没有** `Content-Length`，也不接受 Range：字节是 ffmpeg 边转边给的，长度
    /// 要等转完才知道。跳转由播放器改写 `start=` 重开一条流完成，页面上维持一条
    /// 虚拟时间轴（见详情页脚本里的 `remuxTimeOffset`）。
    private func audioRemuxResponse(
        itemID: String,
        audioTrackID: Int,
        startSeconds: Double,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let policy = experiencePolicy(for: principal),
              policyAllowsPlayback(policy, clientAddressKey: clientAddressKey),
              policyAllowsItem(policy, itemID: itemID, principal: principal),
              policy.transcodeAllowed
        else { return .notFound() }
        guard let stream = try? audioRemuxProvider(itemID, audioTrackID, startSeconds, principal) else {
            return .notFound()
        }
        guard !omitBody else {
            // HEAD 不能起一个 ffmpeg。它只需要确认"这条通路存在"。
            return LocalHTTPResponse(
                statusCode: 200,
                reason: "OK",
                contentType: "video/mp4",
                payload: .data(Data()),
                declaredContentLength: 0,
                additionalHeaders: ["Accept-Ranges: none"]
            )
        }
        return LocalHTTPResponse(
            statusCode: 200,
            reason: "OK",
            contentType: "video/mp4",
            payload: .remuxStream(stream),
            declaredContentLength: LocalHTTPResponse.unknownContentLength,
            additionalHeaders: ["Accept-Ranges: none"]
        )
    }

    private func mutateQueueResponse(body: Data, principal: ServerRequestPrincipal) -> LocalHTTPResponse {
        guard let object = try? JSONSerialization.jsonObject(with: body, options: [.fragmentsAllowed]),
              let dictionary = object as? [String: Any],
              !dictionary.isEmpty,
              Set(dictionary.keys).isSubset(of: ["action", "mediaID", "fromIndex", "toIndex", "repeatMode", "shuffleEnabled", "currentPosition"]),
              let action = dictionary["action"] as? String,
              ["add", "remove", "clear", "move", "settings"].contains(action),
              let request = try? JSONDecoder().decode(ServerQueueMutationRequest.self, from: body),
              request.isValid
        else { return .badRequest() }
        do {
            guard let queue = try queueMutationProvider(request, principal),
                  let encoded = ServerCommandOutput.jsonData(queue)
            else { return .notFound() }
            return .json(body: encoded)
        } catch is ServerUserQueueRepositoryError {
            return .badRequest()
        } catch {
            return .serviceUnavailable()
        }
    }

    private func updatePlaybackStateResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let itemID = decodedPathIdentifier(path, prefix: "/api/v1/playback/state/") else {
            return .notFound()
        }
        guard let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys).isSubset(of: ["event", "positionSeconds", "durationSeconds"]),
              dictionary["event"] != nil,
              dictionary["positionSeconds"] != nil,
              let request = try? JSONDecoder().decode(ServerPlaybackStateUpdateRequest.self, from: body),
              request.isValid
        else {
            return .badRequest()
        }
        do {
            guard let state = try mediaPlaybackStateUpdater(itemID, request, principal) else {
                return .notFound()
            }
            guard let encoded = ServerCommandOutput.jsonData(state) else { return .serviceUnavailable() }
            return .json(body: encoded)
        } catch {
            return .serviceUnavailable()
        }
    }

    /// 偏好请求只允许一次更新一个字段，避免浏览器可借构造型正文意外覆盖其他字段。
    /// 用户身份始终取 principal；评分 0 表示清除，1–5 表示星级。
    private func updateMediaPreferenceResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let itemID = decodedPathIdentifier(path, prefix: "/api/v1/user-media/preferences/"),
              let object = try? JSONSerialization.jsonObject(with: body),
              let dictionary = object as? [String: Any],
              dictionary.count == 1
        else { return .badRequest() }

        let preference: ServerUserMediaPreferenceUpdate
        if let value = dictionary["favorite"] as? Bool, Set(dictionary.keys) == Set(["favorite"]) {
            preference = .favorite(value)
        } else if let value = dictionary["watchlist"] as? Bool, Set(dictionary.keys) == Set(["watchlist"]) {
            preference = .watchlist(value)
        } else if let value = dictionary["rating"] as? NSNumber,
                  CFGetTypeID(value) != CFBooleanGetTypeID(),
                  value.doubleValue.isFinite,
                  (0...5).contains(value.doubleValue),
                  Set(dictionary.keys) == Set(["rating"]) {
            preference = .rating(value.doubleValue == 0 ? nil : value.doubleValue)
        } else {
            return .badRequest()
        }
        do {
            guard let updated = try mediaPreferenceUpdater(itemID, preference, principal),
                  let encoded = ServerCommandOutput.jsonData(updated)
            else { return .notFound() }
            return .json(body: encoded)
        } catch {
            // 未知/无权媒体和内部仓储细节均不能通过偏好写接口区分。
            return .notFound()
        }
    }

    private func revokeAdministrationSessionResponse(
        path: String,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        let prefix = "/api/v1/admin/sessions/"
        let suffix = "/revoke"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return .notFound() }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encodedID.isEmpty,
              let sessionID = encodedID.removingPercentEncoding,
              !sessionID.isEmpty,
              !sessionID.contains("/"),
              !sessionID.contains("\\"),
              !sessionID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              sessionID.utf8.count <= 512,
              let administrationCatalog
        else { return .notFound() }
        do {
            try administrationCatalog.revokeSession(id: sessionID, actorUserID: principal.userID)
            return .noContent()
        } catch {
            return .notFound()
        }
    }

    private func updateAdministrationUserAvailabilityResponse(
        path: String,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        let prefix = "/api/v1/admin/users/"
        let action: (suffix: String, disabled: Bool)
        if path.hasSuffix("/disable") {
            action = ("/disable", true)
        } else if path.hasSuffix("/enable") {
            action = ("/enable", false)
        } else {
            return .notFound()
        }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(action.suffix.count))
        guard !encodedID.isEmpty,
              let userID = encodedID.removingPercentEncoding,
              !userID.isEmpty,
              !userID.contains("/"),
              !userID.contains("\\"),
              !userID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              userID.utf8.count <= 512,
              let administrationCatalog
        else { return .notFound() }
        do {
            try administrationCatalog.setUserDisabled(
                id: userID,
                disabled: action.disabled,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch {
            return .notFound()
        }
    }

    private func updateAdministrationMemberAccessResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let userID = administrationUserID(path: path, suffix: "/access"),
              let request = try? JSONDecoder().decode(ServerAdministrationMemberAccessRequest.self, from: body),
              let administrationCatalog
        else { return .badRequest() }
        do {
            try administrationCatalog.updateMemberAccess(
                id: userID,
                displayName: request.displayName,
                libraryIDs: request.libraryIDs,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch {
            // 不区分成员是否存在、是否是内置管理员或资料库 ID 是否有效，避免管理接口
            // 形成账户/资料库枚举器；前端只显示通用失败提示。
            return .badRequest()
        }
    }

    private func resetAdministrationMemberPasswordResponse(
        path: String,
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let userID = administrationUserID(path: path, suffix: "/password"),
              let request = try? JSONDecoder().decode(ServerAdministrationPasswordResetRequest.self, from: body),
              let administrationCatalog
        else { return .badRequest() }
        do {
            try administrationCatalog.resetMemberPassword(
                id: userID,
                password: request.password,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch {
            return .badRequest()
        }
    }

    private func administrationUserID(path: String, suffix: String) -> String? {
        let prefix = "/api/v1/admin/users/"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard !encodedID.isEmpty,
              let userID = encodedID.removingPercentEncoding,
              !userID.isEmpty,
              !userID.contains("/"),
              !userID.contains("\\"),
              !userID.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }),
              userID.utf8.count <= 512
        else { return nil }
        return userID
    }

    private func createAdministrationMemberResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let request = try? JSONDecoder().decode(ServerAdministrationMemberCreateRequest.self, from: body),
              let administrationCatalog
        else { return .badRequest() }
        guard request.libraryIDs.isEmpty || principal.permissions.contains(.manageLibraries) else {
            return .forbidden()
        }
        do {
            try administrationCatalog.createMember(
                username: request.username,
                displayName: request.displayName,
                password: request.password,
                libraryIDs: request.libraryIDs,
                actorUserID: principal.userID
            )
            return .noContent()
        } catch ServerAdministrationCatalogError.unavailable {
            return .serviceUnavailable()
        } catch {
            // 此处不把重复用户名、来源存在性或口令细节回显给浏览器，避免成员枚举与
            // 内部资料库信息泄漏；前端只给出通用的输入/创建失败提示。
            return .badRequest()
        }
    }

    private func playbackInfoResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        do {
            guard let info = try playbackInfoProvider(itemID, principal) else { return .notFound() }
            guard let body = ServerCommandOutput.jsonData(info) else { return .serviceUnavailable() }
            return .ok(body: body, omitBody: omitBody)
        } catch {
            // ffprobe 的原始错误可能包含路径或损坏文件的内容摘要，不可作为 HTTP 响应返回。
            return .serviceUnavailable()
        }
    }

    /// 浏览器直接打开受保护页面时返回登录页，而 API、播放器字节流和脚本请求仍保持
    /// 401，防止非 HTML 客户端把重定向误当成成功响应。
    private func acceptsHTMLNavigation(_ requestHead: String) -> Bool {
        guard let accept = httpHeader(named: "Accept", in: requestHead)?.lowercased() else {
            return false
        }
        return accept.split(separator: ",").contains { item in
            item.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("text/html")
        }
    }

    /// The server, not browser JavaScript, derives the return target. It travels
    /// as URL-safe Base64 rather than a percent-encoded path, because the public
    /// HTTP policy intentionally rejects encoded slash and backslash sequences.
    private func loginLocation(for target: String) -> String {
        guard target.hasPrefix("/"), !target.hasPrefix("//"), target.utf8.count <= 2_048 else {
            return "/login"
        }
        let state = Data(target.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        return "/login?next=\(state)"
    }

    private func loginReturnState(from target: String) -> String? {
        guard let components = URLComponents(string: "http://localhost\(target)"),
              let values = components.queryItems?.filter({ $0.name == "next" }),
              values.count == 1,
              let value = values[0].value,
              value.utf8.count <= 2_732,
              value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
        else { return nil }
        return value
    }

    private func loginReturnPath(from target: String) -> String? {
        guard let state = loginReturnState(from: target) else { return nil }
        let padding = String(repeating: "=", count: (4 - state.count % 4) % 4)
        let base64 = state.replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/") + padding
        guard let data = Data(base64Encoded: base64),
              let value = String(data: data, encoding: .utf8),
              value.hasPrefix("/"), !value.hasPrefix("//"), !value.contains("\\"),
              value.utf8.count <= 2_048
        else { return nil }
        return value
    }

    private func publicProbeResponse(path: String, omitBody: Bool) -> LocalHTTPResponse {
        let body: Data
        if path == "/health" {
            body = ServerCommandOutput.jsonData(
                ServerHealth(serverID: serverID, serverName: serverName)
            ) ?? Data()
        } else {
            body = ServerCommandOutput.jsonData(
                MlinkServerDescriptor(
                    serverID: serverID,
                    serverName: serverName,
                    capabilities: ServerCommandOutput.capabilities
                )
            ) ?? Data()
        }
        return .ok(body: body, omitBody: omitBody)
    }

    private func loginResponse(
        requestHead: String,
        body: Data,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        if let limited = limitedResponse(
            scope: .loginClient,
            identityComponents: [clientAddressKey]
        ) { return limited }
        guard let request = try? JSONDecoder().decode(ServerLoginRequest.self, from: body),
              request.isValid
        else {
            return authenticationService == nil ? .serviceUnavailable() : .badRequest()
        }
        if let limited = limitedResponse(
            scope: .loginIdentity,
            identityComponents: [
                "username",
                ServerIdentityRepository.normalizeUsername(
                    request.username.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        ) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        do {
            switch try authenticationService.login(
                username: request.username,
                password: request.password,
                deviceName: request.deviceName,
                platform: request.platform
            ) {
            case let .success(tokens):
                return authenticationResponse(tokens: tokens, delivery: request.deliveryMode)
            case .rejected:
                return .unauthorized()
            case let .temporarilyLocked(until):
                return .tooManyRequests(retryAfter: max(Int(until.timeIntervalSinceNow.rounded(.up)), 1))
            case .initialSetupRequired:
                return .preconditionRequired()
            }
        } catch {
            return .serviceUnavailable()
        }
    }

    /// A browser can submit this constrained form even when JavaScript is
    /// unavailable. It never places credentials in the URL; the return state is
    /// server-generated Base64URL and is decoded only after successful login.
    private func webFormLoginResponse(
        requestHead: String,
        target: String,
        body: Data,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        guard httpHeader(named: "Content-Type", in: requestHead)?.lowercased() == "application/x-www-form-urlencoded",
              let form = String(data: body, encoding: .utf8),
              let components = URLComponents(string: "http://localhost/?\(form.replacingOccurrences(of: "+", with: "%20"))"),
              let items = components.queryItems,
              Set(items.map(\.name)) == Set(["username", "password", "csrf"]),
              items.count == 3,
              let username = items.first(where: { $0.name == "username" })?.value,
              let password = items.first(where: { $0.name == "password" })?.value,
              let submittedCSRF = items.first(where: { $0.name == "csrf" })?.value,
              submittedCSRF == csrfToken
        else { return .badRequest() }
        if let limited = limitedResponse(
            scope: .loginClient,
            identityComponents: [clientAddressKey]
        ) { return limited }
        let request = ServerLoginRequest(
            username: username,
            password: password,
            deviceName: "Web Browser",
            platform: "Web",
            delivery: "cookie"
        )
        guard request.isValid else { return .badRequest() }
        if let limited = limitedResponse(
            scope: .loginIdentity,
            identityComponents: [
                "username",
                ServerIdentityRepository.normalizeUsername(
                    request.username.trimmingCharacters(in: .whitespacesAndNewlines)
                )
            ]
        ) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        do {
            switch try authenticationService.login(
                username: request.username,
                password: request.password,
                deviceName: request.deviceName,
                platform: request.platform
            ) {
            case let .success(tokens):
                return .seeOther(
                    location: loginReturnPath(from: target) ?? "/",
                    omitBody: false,
                    additionalHeaders: Self.authenticationCookieHeaders(tokens: tokens)
                )
            case .rejected:
                return .unauthorized()
            case let .temporarilyLocked(until):
                return .tooManyRequests(retryAfter: max(Int(until.timeIntervalSinceNow.rounded(.up)), 1))
            case .initialSetupRequired:
                return .preconditionRequired()
            }
        } catch {
            return .serviceUnavailable()
        }
    }

    private func refreshResponse(
        requestHead: String,
        body: Data,
        clientAddressKey: String
    ) -> LocalHTTPResponse {
        if let limited = limitedResponse(
            scope: .refreshClient,
            identityComponents: [clientAddressKey]
        ) { return limited }
        guard let authenticationService else { return .serviceUnavailable() }
        let cookieToken = authenticationService.refreshToken(forRequestHead: requestHead)
        let request: ServerRefreshRequest
        if body.isEmpty {
            request = ServerRefreshRequest(refreshToken: nil, delivery: nil)
        } else if let decoded = try? JSONDecoder().decode(ServerRefreshRequest.self, from: body) {
            request = decoded
        } else {
            return .badRequest()
        }
        guard request.isValid,
              !(cookieToken != nil && request.refreshToken != nil),
              let token = request.refreshToken ?? cookieToken
        else {
            return .badRequest()
        }
        if let limited = limitedResponse(
            scope: .refreshCredential,
            identityComponents: ["refresh", token]
        ) { return limited }
        do {
            guard let tokens = try authenticationService.refresh(refreshToken: token) else {
                return .unauthorized(clearingCookies: cookieToken != nil)
            }
            let delivery: ServerAuthenticationDelivery = cookieToken != nil ? .cookie : request.deliveryMode
            return authenticationResponse(tokens: tokens, delivery: delivery)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func logoutResponse(principal: ServerRequestPrincipal) -> LocalHTTPResponse {
        guard let authenticationService else { return .serviceUnavailable() }
        do {
            try authenticationService.logout(principal: principal)
            return .noContent(clearingAuthenticationCookies: true)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func passwordChangeResponse(
        body: Data,
        principal: ServerRequestPrincipal
    ) -> LocalHTTPResponse {
        guard let request = try? JSONDecoder().decode(ServerPasswordChangeRequest.self, from: body),
              let authenticationService
        else { return .badRequest() }
        do {
            try authenticationService.changePassword(
                for: principal,
                currentPassword: request.currentPassword,
                newPassword: request.newPassword
            )
            // 轮换服务已撤销所有会话；清除当前浏览器的双 Cookie，强制使用新口令重新登录。
            return .noContent(clearingAuthenticationCookies: true)
        } catch {
            // 不区分当前密码错误、重用、并发修改、禁用或 Argon2 参数错误，避免通过 HTTP
            // 形成凭据/账户状态预言机。服务已在需要时记录脱敏拒绝审计。
            return .badRequest()
        }
    }

    private func authenticationResponse(
        tokens: ServerIssuedTokens,
        delivery: ServerAuthenticationDelivery
    ) -> LocalHTTPResponse {
        switch delivery {
        case .token:
            guard let body = ServerCommandOutput.jsonData(tokens) else { return .serviceUnavailable() }
            return .ok(body: body, omitBody: false)
        case .cookie:
            let session = ServerBrowserSession(
                accessExpiresAt: tokens.accessExpiresAt,
                refreshExpiresAt: tokens.refreshExpiresAt,
                sessionID: tokens.sessionID,
                deviceID: tokens.deviceID
            )
            guard let body = ServerCommandOutput.jsonData(session) else { return .serviceUnavailable() }
            return .json(
                body: body,
                additionalHeaders: Self.authenticationCookieHeaders(tokens: tokens)
            )
        }
    }

    private func limitedResponse(
        scope: ServerRateLimitScope,
        identityComponents: [String],
        cost: Double = 1
    ) -> LocalHTTPResponse? {
        let decision = rateLimiter.evaluate(
            scope: scope,
            identityComponents: identityComponents,
            cost: cost
        )
        return decision.isAllowed ? nil : .tooManyRequests(retryAfter: decision.retryAfterSeconds)
    }

    private func limitedResponse(
        scope: ServerRateLimitScope,
        principal: ServerRequestPrincipal,
        clientAddressKey: String,
        cost: Double = 1
    ) -> LocalHTTPResponse? {
        if let limited = limitedResponse(
            scope: scope,
            identityComponents: ["client", clientAddressKey],
            cost: cost
        ) { return limited }
        return limitedResponse(
            scope: scope,
            identityComponents: ["principal", principal.userID, principal.deviceID],
            cost: cost
        )
    }

    private func ifMatchVersion(in requestHead: String) -> Int? {
        guard let raw = httpHeader(named: "If-Match", in: requestHead),
              !raw.contains(","), !raw.hasPrefix("W/")
        else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let value = trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
            ? String(trimmed.dropFirst().dropLast())
            : trimmed
        guard !value.isEmpty, value.allSatisfy(\.isNumber), let version = Int(value), version >= 0 else {
            return nil
        }
        return version
    }

    private func etagHeader(_ version: Int) -> String { "ETag: \"\(max(version, 0))\"" }

    private func experienceMutationErrorResponse(_ error: Error) -> LocalHTTPResponse {
        switch error {
        case ServerExperienceRepositoryError.invalidValue:
            return .badRequest()
        case let ServerExperienceRepositoryError.versionConflict(currentVersion):
            return .conflict(additionalHeaders: [etagHeader(currentVersion)])
        case ServerExperienceRepositoryError.notFound:
            return .notFound()
        default:
            return .serviceUnavailable()
        }
    }

    private func playbackOverrideRoute(_ path: String) -> (scope: ServerTrackOverrideScope, id: String)? {
        let prefix = "/api/v1/me/playback-overrides/"
        guard path.hasPrefix(prefix) else { return nil }
        let pieces = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              let scope = ServerTrackOverrideScope(rawValue: String(pieces[0])),
              let decoded = String(pieces[1]).removingPercentEncoding,
              !decoded.isEmpty, !decoded.contains("/"), !decoded.contains("\\")
        else { return nil }
        return (scope, decoded)
    }

    private func administrationUserPolicyID(_ path: String) -> String? {
        let prefix = "/api/v1/admin/users/"
        let suffix = "/policy"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let raw = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let decoded = raw.removingPercentEncoding,
              !decoded.isEmpty, decoded.utf8.count <= 128,
              !decoded.contains("/"), !decoded.contains("\\"),
              !decoded.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
        else { return nil }
        return decoded
    }

    private func experiencePolicy(for principal: ServerRequestPrincipal) -> ServerUserPolicy? {
        guard let experienceRepository else { return ServerUserPolicy() }
        return try? experienceRepository.userPolicy(userID: principal.userID).value
    }

    private func policyAllowsPlayback(_ policy: ServerUserPolicy, clientAddressKey: String) -> Bool {
        guard policy.isValid, policy.playbackAllowed else { return false }
        if isRemoteClientAddressKey(clientAddressKey), !policy.remoteAccessAllowed { return false }
        guard let start = policy.accessStartMinute, let end = policy.accessEndMinute else { return true }
        let components = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let hour = components.hour, let minute = components.minute else { return false }
        let current = hour * 60 + minute
        return start <= end ? (start...end).contains(current) : (current >= start || current <= end)
    }

    private func policyAllowsItem(
        _ policy: ServerUserPolicy,
        itemID: String,
        principal: ServerRequestPrincipal
    ) -> Bool {
        guard policy.maximumContentRating != nil else { return true }
        guard let detail = try? mediaDetailProvider(itemID, principal) else { return false }
        return ServerContentRatingPolicy.allows(
            contentRating: detail.detailExtras?.contentRating,
            maximum: policy.maximumContentRating
        )
    }

    private func isRemoteClientAddressKey(_ value: String) -> Bool {
        let normalized = value.lowercased()
        return !(normalized == "localhost" || normalized == "::1" || normalized == "[::1]" ||
            normalized.hasPrefix("127.") || normalized.hasPrefix("loopback"))
    }

    private func strictlyDecode<Value: Decodable>(
        _ type: Value.Type,
        from body: Data,
        allowedKeys: Set<String>,
        nestedAllowedKeys: [String: Set<String>] = [:]
    ) -> Value? {
        guard let raw = try? JSONSerialization.jsonObject(with: body),
              let object = raw as? [String: Any],
              Set(object.keys).isSubset(of: allowedKeys)
        else { return nil }
        for (key, keys) in nestedAllowedKeys {
            guard let nested = object[key] else { continue }
            if nested is NSNull { continue }
            guard let dictionary = nested as? [String: Any],
                  Set(dictionary.keys).isSubset(of: keys)
            else { return nil }
        }
        return try? JSONDecoder().decode(type, from: body)
    }

    private func effectivePreferences(
        _ account: ServerUserExperiencePreferences,
        device: ServerDeviceExperienceOverrides?
    ) -> ServerUserExperiencePreferences {
        guard let device else { return account }
        var effective = account
        if let value = device.appearance { effective.appearance = value }
        if let value = device.contentDensity { effective.contentDensity = value }
        if let value = device.motion { effective.motion = value }
        if let value = device.defaultQuality { effective.defaultQuality = value }
        if let value = device.remoteBitrateMbps { effective.remoteBitrateMbps = value }
        return effective
    }

    private static func authenticationCookieHeaders(tokens: ServerIssuedTokens) -> [String] {
        let accessAge = max(Int(tokens.accessExpiresAt.timeIntervalSinceNow), 1)
        let refreshAge = max(Int(tokens.refreshExpiresAt.timeIntervalSinceNow), 1)
        return [
            "Set-Cookie: \(ServerAuthenticationService.accessCookieName)=\(tokens.accessToken); Path=/; Max-Age=\(accessAge); HttpOnly; Secure; SameSite=Strict",
            "Set-Cookie: \(ServerAuthenticationService.refreshCookieName)=\(tokens.refreshToken); Path=/api/v1/auth; Max-Age=\(refreshAge); HttpOnly; Secure; SameSite=Strict"
        ]
    }
}

private struct ServerPreferencesResponse: Encodable {
    let account: ServerVersionedDocument<ServerUserExperiencePreferences>
    let device: ServerVersionedDocument<ServerDeviceExperienceOverrides>?
    let effective: ServerUserExperiencePreferences
}

private struct ServerTrackOverrideMutation: Decodable {
    let audioFingerprint: String?
    let subtitleFingerprint: String?
    let subtitleDisabled: Bool

    private enum CodingKeys: String, CodingKey {
        case audioFingerprint, subtitleFingerprint, subtitleDisabled
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        audioFingerprint = try values.decodeIfPresent(String.self, forKey: .audioFingerprint)
        subtitleFingerprint = try values.decodeIfPresent(String.self, forKey: .subtitleFingerprint)
        subtitleDisabled = try values.decodeIfPresent(Bool.self, forKey: .subtitleDisabled) ?? false
    }
}

private struct ServerJobCreationRequest: Decodable {
    let kind: String

    var isValid: Bool {
        ["library.scan", "library.reindex", "metadata.refresh"]
            .contains(kind)
    }
}

private struct ServerAdminDashboardResponse: Encodable {
    let serverName: String
    let apiVersion: String
    let settingsVersion: Int
    let maximumTranscodeSessions: Int
    let queuedJobCount: Int
    let runningJobCount: Int
    let failedJobCount: Int
    let recentSecurityEventCount: Int
    let playback: ServerPlaybackTelemetrySnapshot
    let lan: ServerLanAccessReadiness
    let runtime: ServerRuntimeDiagnosticsSnapshot?
}

private enum ServerAuthenticationDelivery: String, Decodable {
    case token
    case cookie
}

private struct ServerLoginRequest: Decodable {
    let username: String
    let password: String
    let deviceName: String
    let platform: String
    let delivery: String?

    var deliveryMode: ServerAuthenticationDelivery {
        ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") ?? .token
    }

    var isValid: Bool {
        !username.isEmpty && username.utf8.count <= 128 &&
            !password.isEmpty && password.utf8.count <= 1_024 &&
            !deviceName.isEmpty && deviceName.utf8.count <= 128 &&
            !platform.isEmpty && platform.utf8.count <= 128 &&
            (delivery == nil || ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") != nil)
    }
}

private struct ServerRefreshRequest: Decodable {
    let refreshToken: String?
    let delivery: String?

    var deliveryMode: ServerAuthenticationDelivery {
        ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") ?? .token
    }

    var isValid: Bool {
        (refreshToken == nil || (32...1_024).contains(refreshToken?.utf8.count ?? 0)) &&
            (delivery == nil || ServerAuthenticationDelivery(rawValue: delivery?.lowercased() ?? "") != nil)
    }
}

private struct ServerBrowserSession: Encodable {
    let accessExpiresAt: Date
    let refreshExpiresAt: Date
    let sessionID: String
    let deviceID: String
}

struct LocalHTTPResponse {
    let statusCode: Int
    let reason: String
    let contentType: String
    let payload: LocalHTTPResponsePayload
    let declaredContentLength: Int
    let additionalHeaders: [String]

    /// `declaredContentLength` 取这个值时不发 `Content-Length`：长度要等 ffmpeg
    /// 转完才知道，而读者按下播放的那一刻就要开始收字节。响应因此只能以关闭连接
    /// 结束，`write(response:)` 会强制 `Connection: close`。
    static let unknownContentLength = -1

    var body: Data {
        switch payload {
        case let .data(body): return body
        case let .remoteRange(range): return range.materializedBody()
        // Full remote entities deliberately stay lazy. Materializing a movie
        // exists only for small explicit Range fixtures in router tests.
        case .fileRange, .remoteFull, .remuxStream: return Data()
        }
    }

    static func ok(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "application/json; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: []
        )
    }

    static func json(body: Data, omitBody: Bool = false, additionalHeaders: [String] = []) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "application/json; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: additionalHeaders
        )
    }

    static func jsonError(
        statusCode: Int,
        reason: String,
        body: Data,
        additionalHeaders: [String] = []
    ) -> Self {
        Self(
            statusCode: statusCode,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            payload: .data(body),
            declaredContentLength: body.count,
            additionalHeaders: additionalHeaders
        )
    }

    static func created(body: Data, additionalHeaders: [String] = []) -> Self {
        Self(
            statusCode: 201,
            reason: "Created",
            contentType: "application/json; charset=utf-8",
            payload: .data(body),
            declaredContentLength: body.count,
            additionalHeaders: additionalHeaders
        )
    }

    static func accepted(body: Data, additionalHeaders: [String] = []) -> Self {
        Self(
            statusCode: 202,
            reason: "Accepted",
            contentType: "application/json; charset=utf-8",
            payload: .data(body),
            declaredContentLength: body.count,
            additionalHeaders: additionalHeaders
        )
    }

    static func html(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "text/html; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Cache-Control: no-cache, no-store, must-revalidate"]
        )
    }

    static func javascript(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "text/javascript; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            // Every HTML reference includes ServerWebAssets.version, so a new
            // asset URL is issued whenever the bundle changes. Let the browser
            // retain a matching static resource instead of revalidating the
            // complete CSS/JS set on every authenticated navigation.
            additionalHeaders: ["Cache-Control: private, max-age=31536000, immutable"]
        )
    }

    static func stylesheet(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "text/css; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Cache-Control: private, max-age=31536000, immutable"]
        )
    }

    static func asset(body: Data, contentType: String, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: contentType,
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Cache-Control: private, max-age=31536000, immutable"]
        )
    }

    static func seeOther(location: String, omitBody: Bool, additionalHeaders: [String] = []) -> Self {
        let body = Data("See Other".utf8)
        return Self(
            statusCode: 303,
            reason: "See Other",
            contentType: "text/plain; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Location: \(location)"] + additionalHeaders
        )
    }

    static func fullFile(
        asset: ServerMediaAsset,
        omitBody: Bool,
        cacheControl: String? = nil,
        entityTag: String? = nil,
        additionalHeaders: [String] = []
    ) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: asset.contentType,
            payload: omitBody
                ? .data(Data())
                : .fileRange(LocalHTTPFileRange(url: asset.fileURL, offset: 0, length: asset.byteLength)),
            declaredContentLength: Int(asset.byteLength),
            additionalHeaders: ["Accept-Ranges: bytes"]
                + (cacheControl.map { ["Cache-Control: \($0)"] } ?? [])
                + (entityTag.map { ["ETag: \($0)"] } ?? [])
                + additionalHeaders
        )
    }

    static func partialFile(
        asset: ServerMediaAsset,
        range: ResolvedHTTPByteRange,
        omitBody: Bool,
        additionalHeaders: [String] = []
    ) -> Self {
        Self(
            statusCode: 206,
            reason: "Partial Content",
            contentType: asset.contentType,
            payload: omitBody
                ? .data(Data())
                : .fileRange(LocalHTTPFileRange(url: asset.fileURL, offset: range.lowerBound, length: range.length)),
            declaredContentLength: Int(range.length),
            additionalHeaders: [
                "Accept-Ranges: bytes",
                "Content-Range: \(range.contentRangeHeader)"
            ] + additionalHeaders
        )
    }

    static func file(
        url: URL,
        byteLength: Int64,
        contentType: String,
        omitBody: Bool,
        additionalHeaders: [String] = []
    ) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: contentType,
            payload: omitBody
                ? .data(Data())
                : .fileRange(LocalHTTPFileRange(url: url, offset: 0, length: byteLength)),
            declaredContentLength: Int(byteLength),
            additionalHeaders: additionalHeaders
        )
    }

    static func badRequest() -> Self { error(statusCode: 400, reason: "Bad Request") }
    static func unauthorized(clearingCookies: Bool = false) -> Self {
        let response = error(statusCode: 401, reason: "Unauthorized")
        var headers = ["WWW-Authenticate: Bearer realm=\"MediaLIB\", charset=\"UTF-8\""]
        if clearingCookies { headers.append(contentsOf: expiredAuthenticationCookieHeaders) }
        return Self(
            statusCode: response.statusCode,
            reason: response.reason,
            contentType: response.contentType,
            payload: response.payload,
            declaredContentLength: response.declaredContentLength,
            additionalHeaders: headers
        )
    }
    static func forbidden() -> Self { error(statusCode: 403, reason: "Forbidden") }
    static func notFound() -> Self { error(statusCode: 404, reason: "Not Found") }
    static func methodNotAllowed() -> Self { error(statusCode: 405, reason: "Method Not Allowed") }
    static func payloadTooLarge() -> Self { error(statusCode: 413, reason: "Payload Too Large") }
    static func conflict(additionalHeaders: [String] = []) -> Self {
        let response = error(statusCode: 409, reason: "Conflict")
        return Self(
            statusCode: response.statusCode,
            reason: response.reason,
            contentType: response.contentType,
            payload: response.payload,
            declaredContentLength: response.declaredContentLength,
            additionalHeaders: additionalHeaders
        )
    }
    static func serviceUnavailable() -> Self { error(statusCode: 503, reason: "Service Unavailable") }
    static func preconditionRequired() -> Self {
        error(statusCode: 428, reason: "Precondition Required")
    }
    static func tooManyRequests(retryAfter: Int) -> Self {
        let response = error(statusCode: 429, reason: "Too Many Requests")
        return Self(
            statusCode: response.statusCode,
            reason: response.reason,
            contentType: response.contentType,
            payload: response.payload,
            declaredContentLength: response.declaredContentLength,
            additionalHeaders: ["Retry-After: \(max(retryAfter, 1))"]
        )
    }
    static func rangeNotSatisfiable(totalLength: Int64) -> Self {
        var response = error(statusCode: 416, reason: "Range Not Satisfiable")
        response = Self(
            statusCode: response.statusCode,
            reason: response.reason,
            contentType: response.contentType,
            payload: response.payload,
            declaredContentLength: response.declaredContentLength,
            additionalHeaders: ["Content-Range: bytes */\(max(totalLength, 0))"]
        )
        return response
    }

    /// 复验命中：内容没变，不重传字节。
    ///
    /// 海报墙此前无论如何都是一次带 body 的 200：服务端从不发 `ETag`／
    /// `Last-Modified`，浏览器也就无从复验。`max-age` 一过、用户按一次刷新、或者
    /// 缓存被挤掉，整墙海报就重新完整下载一遍——远程封面还要连带一次上游取图。
    /// 304 让这些情况退化成一次几十字节的往返。
    static func notModified(entityTag: String, cacheControl: String?) -> Self {
        Self(
            statusCode: 304,
            reason: "Not Modified",
            contentType: "application/octet-stream",
            payload: .data(Data()),
            declaredContentLength: 0,
            additionalHeaders: ["ETag: \(entityTag)"]
                + (cacheControl.map { ["Cache-Control: \($0)"] } ?? [])
        )
    }

    static func noContent(clearingAuthenticationCookies: Bool = false) -> Self {
        Self(
            statusCode: 204,
            reason: "No Content",
            contentType: "application/json; charset=utf-8",
            payload: .data(Data()),
            declaredContentLength: 0,
            additionalHeaders: clearingAuthenticationCookies ? expiredAuthenticationCookieHeaders : []
        )
    }

    func serialized() -> Data {
        var headers = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(declaredContentLength)",
            "Connection: close"
        ]
        if declaredContentLength < 0 { headers.remove(at: 2) }
        if !additionalHeaders.contains(where: { $0.hasPrefix("Cache-Control:") }) {
            headers.append("Cache-Control: no-store")
        }
        if statusCode == 405 {
            headers.append("Allow: GET, HEAD")
        }
        headers.append(contentsOf: additionalHeaders)
        var data = serializedHeaders()
        data.append(body)
        return data
    }

    func serializedHeaders(keepAlive: Bool = false) -> Data {
        var headers = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Type: \(contentType)",
            keepAlive ? "Connection: keep-alive" : "Connection: close"
        ]
        if declaredContentLength >= 0 {
            headers.insert("Content-Length: \(declaredContentLength)", at: 2)
        }
        if keepAlive {
            headers.append("Keep-Alive: timeout=10, max=64")
        }
        // API/HTML/媒体响应默认 no-store；只有代码明确标注的无身份静态资源
        // 才能以 private 缓存复用，防止重复加载与用户数据缓存混淆。
        if !additionalHeaders.contains(where: { $0.hasPrefix("Cache-Control:") }) {
            headers.append("Cache-Control: no-store")
        }
        if statusCode == 405 {
            headers.append("Allow: GET, HEAD")
        }
        headers.append(contentsOf: additionalHeaders)
        headers.append(contentsOf: Self.securityHeaders)
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
    }

    private static func error(statusCode: Int, reason: String) -> Self {
        let body = Data("{\"error\":\"\(reason)\"}".utf8)
        return Self(
            statusCode: statusCode,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            payload: .data(body),
            declaredContentLength: body.count,
            additionalHeaders: []
        )
    }

    private static let securityHeaders = [
        "Content-Security-Policy: default-src 'none'; script-src 'self'; worker-src 'self' blob:; style-src 'self'; img-src 'self' data:; media-src 'self' blob:; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'",
        "Cross-Origin-Embedder-Policy: require-corp",
        "Cross-Origin-Opener-Policy: same-origin",
        "Cross-Origin-Resource-Policy: same-origin",
        "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        // `no-referrer` 曾经让整套「从哪来回哪去」的服务端推导变成死代码：详情页
        // 的返回目标是从 `Referer` 解析出来的，而浏览器一个字节都不会发，于是每
        // 一页的返回都落到兜底的「返回首页」——不管读者是从搜索结果、合集还是
        // 人物页点进来的。`same-origin` 只对同源请求带上完整地址，跨站请求仍然
        // 一个字节都不发，泄露面没有变化。
        "Referrer-Policy: same-origin",
        "X-Content-Type-Options: nosniff",
        "X-Frame-Options: DENY"
    ]

    private static let expiredAuthenticationCookieHeaders = [
        "Set-Cookie: \(ServerAuthenticationService.accessCookieName)=; Path=/; Max-Age=0; HttpOnly; Secure; SameSite=Strict",
        "Set-Cookie: \(ServerAuthenticationService.refreshCookieName)=; Path=/api/v1/auth; Max-Age=0; HttpOnly; Secure; SameSite=Strict"
    ]
}

enum LocalHTTPResponsePayload {
    case data(Data)
    case fileRange(LocalHTTPFileRange)
    case remoteRange(LocalHTTPRemoteRange)
    case remoteFull(LocalHTTPRemoteFull)
    /// 长度未知的实时重封装流。它是唯一一种不带 `Content-Length` 的响应，
    /// 因此也必须是连接上的最后一个响应（见 `LocalHTTPResponse.unknownContentLength`）。
    case remuxStream(ServerAudioRemuxStream)
}

struct LocalHTTPFileRange {
    let url: URL
    let offset: Int64
    let length: Int64
}

/// The production write path streams this payload directly to the client. Its
/// `materializedBody` helper exists only for the in-process router tests, whose
/// response API intentionally exposes a `Data` body for assertions.
struct LocalHTTPRemoteRange {
    let fetcher: ServerRemoteAssetFetcher
    let url: URL
    let offset: Int64
    let length: Int64

    func stream(_ consume: @escaping (Data) -> Bool) -> Bool {
        fetcher.streamMediaBytes(url: url, offset: offset, length: length, consume: consume)
    }

    func materializedBody() -> Data {
        var body = Data()
        guard stream({ chunk in
            body.append(chunk)
            return true
        }) else { return Data() }
        return body
    }
}

/// A full remote entity delivered as bounded upstream Range windows. The
/// browser receives one standards-compliant 200 response with the real length;
/// only the private server-to-source side is split into bounded requests.
struct LocalHTTPRemoteFull {
    let fetcher: ServerRemoteAssetFetcher
    let url: URL
    let byteLength: Int64

    func stream(_ consume: @escaping (Data) -> Bool) -> Bool {
        guard byteLength > 0 else { return false }
        var offset: Int64 = 0
        while offset < byteLength {
            let length = min(
                byteLength - offset,
                Int64(ServerRemoteAssetFetcher.maximumMediaRangeByteLength)
            )
            guard fetcher.streamMediaBytes(
                url: url,
                offset: offset,
                length: length,
                consume: consume
            ) else { return false }
            offset += length
        }
        return true
    }
}

/// 在固定内存上限内读取文件范围。该函数不创建完整媒体文件的 `Data`，是服务端
/// 直放写 socket 与未来 Hummingbird body stream 之间可复用的边界。
func streamFileRange(
    _ range: LocalHTTPFileRange,
    maximumChunkLength: Int = 256 * 1024,
    consume: (Data) -> Bool
) throws {
    precondition(maximumChunkLength > 0)
    let handle = try FileHandle(forReadingFrom: range.url)
    defer { try? handle.close() }
    try handle.seek(toOffset: UInt64(range.offset))

    var remaining = range.length
    while remaining > 0 {
        let chunk = try handle.read(upToCount: Int(min(remaining, Int64(maximumChunkLength)))) ?? Data()
        guard !chunk.isEmpty else { throw CocoaError(.fileReadCorruptFile) }
        guard consume(chunk) else { return }
        remaining -= Int64(chunk.count)
    }
}

private enum LocalHTTPServerError: LocalizedError {
    case socketCreationFailed(errno: Int32)
    case socketOptionFailed(errno: Int32)
    case loopbackAddressCreationFailed
    case bindFailed(port: Int, errno: Int32)
    case listenFailed(errno: Int32)
    case acceptFailed(errno: Int32)

    var errorDescription: String? {
        switch self {
        case let .socketCreationFailed(errno):
            return "无法创建本机 HTTP socket：\(errorMessage(errno))"
        case let .socketOptionFailed(errno):
            return "无法配置本机 HTTP socket：\(errorMessage(errno))"
        case .loopbackAddressCreationFailed:
            return "无法创建本机回环地址。"
        case let .bindFailed(port, errno):
            return "无法监听 127.0.0.1:\(port)：\(errorMessage(errno))"
        case let .listenFailed(errno):
            return "无法启动本机 HTTP 服务：\(errorMessage(errno))"
        case let .acceptFailed(errno):
            return "本机 HTTP 服务接收连接失败：\(errorMessage(errno))"
        }
    }

    private func errorMessage(_ code: Int32) -> String {
        String(cString: strerror(code))
    }
}
