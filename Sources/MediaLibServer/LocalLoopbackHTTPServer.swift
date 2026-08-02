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
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail? = { _, _ in nil },
        seriesDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerSeriesDetail? = { _, _ in nil },
        seriesEpisodesProvider: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage? = { _, _, _, _, _ in nil },
        peopleProvider: @escaping (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage = { _, offset, limit, _ in ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        personDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail? = { _, _, _, _ in nil },
        collectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage = { offset, limit, _ in ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        collectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail? = { _, _, _, _ in nil },
        queueProvider: @escaping (ServerRequestPrincipal) throws -> ServerQueueResponse = { _ in ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) },
        queueMutationProvider: @escaping (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse? = { _, _ in nil },
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaPreferenceUpdater: @escaping (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        webVTTSubtitleTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]? = { _, _ in nil },
        webVTTSubtitleAssetProvider: @escaping (String, Int, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        currentUserProfileProvider: @escaping (ServerRequestPrincipal) throws -> ServerCurrentUserProfile? = { _ in nil },
        administrationCatalog: ServerAdministrationCatalog? = nil,
        authenticationService: ServerAuthenticationService? = nil,
        authenticationProvider: @escaping (String) throws -> ServerRequestPrincipal? = { _ in nil },
        rateLimiter: ServerRequestRateLimiter = ServerRequestRateLimiter(),
        csrfToken: String = ServerRequestSecurityToken.generate()
    ) throws {
        guard ["127.0.0.1", "localhost"].contains(configuration.host.lowercased()) else {
            throw ServerConfigurationError.nonLoopbackHost(configuration.host)
        }
        self.configuration = configuration
        self.requestSecurityPolicy = HTTPRequestSecurityPolicy(
            allowedHosts: ["127.0.0.1", "localhost"],
            allowedPort: configuration.port,
            csrfToken: csrfToken
        )
        self.router = LocalHTTPRouter(
            serverID: configuration.serverID,
            serverName: configuration.serverName,
            librarySnapshotProvider: librarySnapshotProvider,
            libraryBrowseProvider: libraryBrowseProvider,
            libraryCategoriesProvider: libraryCategoriesProvider,
            mediaDetailProvider: mediaDetailProvider,
            seriesDetailProvider: seriesDetailProvider,
            seriesEpisodesProvider: seriesEpisodesProvider,
            peopleProvider: peopleProvider,
            personDetailProvider: personDetailProvider,
            collectionsProvider: collectionsProvider,
            collectionDetailProvider: collectionDetailProvider,
            queueProvider: queueProvider,
            queueMutationProvider: queueMutationProvider,
            mediaPlaybackStateUpdater: mediaPlaybackStateUpdater,
            mediaPreferenceUpdater: mediaPreferenceUpdater,
            mediaAssetProvider: mediaAssetProvider,
            webVTTSubtitleTracksProvider: webVTTSubtitleTracksProvider,
            webVTTSubtitleAssetProvider: webVTTSubtitleAssetProvider,
            artworkAssetProvider: artworkAssetProvider,
            playbackInfoProvider: playbackInfoProvider,
            currentUserProfileProvider: currentUserProfileProvider,
            administrationCatalog: administrationCatalog,
            authenticationService: authenticationService,
            authenticationProvider: authenticationProvider,
            rateLimiter: rateLimiter,
            csrfToken: csrfToken
        )
    }

    func run() throws {
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
            if let rejection = requestSecurityPolicy.validate(request.head, bodyLength: request.body.count) {
                let response: LocalHTTPResponse
                switch rejection {
                case .badRequest: response = .badRequest()
                case .forbidden: response = .forbidden()
                case .payloadTooLarge: response = .payloadTooLarge()
                }
                write(response: response, to: client)
                return
            }
            let keepAlive = requestIndex + 1 < Self.maximumRequestsPerConnection &&
                ProcessInfo.processInfo.systemUptime <= connectionDeadline &&
                Self.supportsPersistentConnection(request.head)
            write(
                response: router.response(
                    for: request.head,
                    body: request.body,
                    clientAddressKey: clientAddressKey
                ),
                to: client,
                keepAlive: keepAlive
            )
            if !keepAlive { return }
        }
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
        return setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0 &&
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
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

    private func write(response: LocalHTTPResponse, to client: Int32, keepAlive: Bool = false) {
        write(data: response.serializedHeaders(keepAlive: keepAlive), to: client)
        switch response.payload {
        case let .data(body):
            write(data: body, to: client)
        case let .fileRange(range):
            write(fileRange: range, to: client)
        }
    }

    private func write(data: Data, to client: Int32) {
        var remaining = data
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { bytes in
                send(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return }
            remaining.removeFirst(Int(count))
        }
    }

    private func write(fileRange: LocalHTTPFileRange, to client: Int32) {
        try? streamFileRange(fileRange) { [weak self] chunk in
            guard let self else { return false }
            self.write(data: chunk, to: client)
            return true
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

struct LocalHTTPRouter {
    private let serverID: String
    private let serverName: String
    private let librarySnapshotProvider: (ServerRequestPrincipal) throws -> ServerLibrarySnapshot
    private let libraryBrowseProvider: (ServerLibraryQuery, ServerRequestPrincipal) throws -> ServerLibraryItemsPage
    private let libraryCategoriesProvider: (ServerRequestPrincipal) throws -> ServerLibraryCategoriesResponse
    private let mediaDetailProvider: (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail?
    private let seriesDetailProvider: (String, ServerRequestPrincipal) throws -> ServerSeriesDetail?
    private let seriesEpisodesProvider: (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage?
    private let peopleProvider: (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage
    private let personDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail?
    private let collectionsProvider: (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage
    private let collectionDetailProvider: (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail?
    private let queueProvider: (ServerRequestPrincipal) throws -> ServerQueueResponse
    private let queueMutationProvider: (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse?
    private let mediaPlaybackStateUpdater: (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState?
    private let mediaPreferenceUpdater: (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference?
    private let mediaAssetProvider: (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset?
    private let webVTTSubtitleTracksProvider: (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]?
    private let webVTTSubtitleAssetProvider: (String, Int, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let artworkAssetProvider: (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let playbackInfoProvider: (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo?
    private let currentUserProfileProvider: (ServerRequestPrincipal) throws -> ServerCurrentUserProfile?
    private let administrationCatalog: ServerAdministrationCatalog?
    private let authenticationService: ServerAuthenticationService?
    private let authenticationProvider: (String) throws -> ServerRequestPrincipal?
    private let rateLimiter: ServerRequestRateLimiter
    private let csrfToken: String

    init(
        serverID: String,
        serverName: String,
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
        mediaDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaItemDetail? = { _, _ in nil },
        seriesDetailProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerSeriesDetail? = { _, _ in nil },
        seriesEpisodesProvider: @escaping (String, ServerSeriesSeasonSelector, Int, Int, ServerRequestPrincipal) throws -> ServerSeriesEpisodesPage? = { _, _, _, _, _ in nil },
        peopleProvider: @escaping (String?, Int, Int, ServerRequestPrincipal) throws -> ServerPeoplePage = { _, offset, limit, _ in ServerPeoplePage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        personDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerPersonDetail? = { _, _, _, _ in nil },
        collectionsProvider: @escaping (Int, Int, ServerRequestPrincipal) throws -> ServerCollectionsPage = { offset, limit, _ in ServerCollectionsPage(totalItemCount: 0, offset: offset, limit: limit, items: []) },
        collectionDetailProvider: @escaping (String, Int, Int, ServerRequestPrincipal) throws -> ServerCollectionDetail? = { _, _, _, _ in nil },
        queueProvider: @escaping (ServerRequestPrincipal) throws -> ServerQueueResponse = { _ in ServerQueueResponse(repeatMode: "sequential", shuffleEnabled: false, currentPosition: 0, items: []) },
        queueMutationProvider: @escaping (ServerQueueMutationRequest, ServerRequestPrincipal) throws -> ServerQueueResponse? = { _, _ in nil },
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaPreferenceUpdater: @escaping (String, ServerUserMediaPreferenceUpdate, ServerRequestPrincipal) throws -> ServerMediaUserPreference? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        webVTTSubtitleTracksProvider: @escaping (String, ServerRequestPrincipal) throws -> [ServerWebVTTSubtitleTrack]? = { _, _ in nil },
        webVTTSubtitleAssetProvider: @escaping (String, Int, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        currentUserProfileProvider: @escaping (ServerRequestPrincipal) throws -> ServerCurrentUserProfile? = { _ in nil },
        administrationCatalog: ServerAdministrationCatalog? = nil,
        authenticationService: ServerAuthenticationService? = nil,
        authenticationProvider: @escaping (String) throws -> ServerRequestPrincipal? = { _ in nil },
        rateLimiter: ServerRequestRateLimiter = ServerRequestRateLimiter(),
        csrfToken: String = "test-csrf-token"
    ) {
        self.serverID = serverID
        self.serverName = serverName
        self.librarySnapshotProvider = librarySnapshotProvider
        self.libraryBrowseProvider = libraryBrowseProvider
        self.libraryCategoriesProvider = libraryCategoriesProvider
        self.mediaDetailProvider = mediaDetailProvider
        self.seriesDetailProvider = seriesDetailProvider
        self.seriesEpisodesProvider = seriesEpisodesProvider
        self.peopleProvider = peopleProvider
        self.personDetailProvider = personDetailProvider
        self.collectionsProvider = collectionsProvider
        self.collectionDetailProvider = collectionDetailProvider
        self.queueProvider = queueProvider
        self.queueMutationProvider = queueMutationProvider
        self.mediaPlaybackStateUpdater = mediaPlaybackStateUpdater
        self.mediaPreferenceUpdater = mediaPreferenceUpdater
        self.mediaAssetProvider = mediaAssetProvider
        self.webVTTSubtitleTracksProvider = webVTTSubtitleTracksProvider
        self.webVTTSubtitleAssetProvider = webVTTSubtitleAssetProvider
        self.artworkAssetProvider = artworkAssetProvider
        self.playbackInfoProvider = playbackInfoProvider
        self.currentUserProfileProvider = currentUserProfileProvider
        self.administrationCatalog = administrationCatalog
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
                body: Data(ServerWebLoginPage.render(serverName: serverName, csrfToken: csrfToken).utf8),
                omitBody: isHeadRequest
            )
        }
        if (method == "GET" || isHeadRequest), path == "/assets/login.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebLoginPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/login.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebLoginPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/app-shell.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebShellStyle.css.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/library.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebLibraryPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/home.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebHomePage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/account.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebAccountPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/status.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebStatusPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/sources.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebSourcesPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/admin.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebAdministrationPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/player.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebMediaDetailPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/series.css" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .stylesheet(body: Data(ServerWebSeriesPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/people.css" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .stylesheet(body: Data(ServerWebPeoplePage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/collections.css" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .stylesheet(body: Data(ServerWebCollectionsPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/photos.css" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .stylesheet(body: Data(ServerWebPhotosPage.style.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/admin.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebAdministrationPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/sources.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebSourcesPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/status.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebStatusPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/account.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebAccountPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/player.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebMediaDetailPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/series.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebSeriesPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/people.js" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .javascript(body: Data(ServerWebPeoplePage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/collections.js" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .javascript(body: Data(ServerWebCollectionsPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/photos.js" {
            if let limited = limitedResponse(scope: .publicProbe, identityComponents: [clientAddressKey]) { return limited }
            return .javascript(body: Data(ServerWebPhotosPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/library.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebLibraryPage.script.utf8), omitBody: isHeadRequest)
        }
        if method == "POST", path == "/api/v1/auth/login" {
            return loginResponse(requestHead: requestHead, body: body, clientAddressKey: clientAddressKey)
        }
        if method == "POST", path == "/api/v1/auth/refresh" {
            return refreshResponse(requestHead: requestHead, body: body, clientAddressKey: clientAddressKey)
        }
        if let limited = limitedResponse(
            scope: .unauthenticated,
            identityComponents: [clientAddressKey]
        ) { return limited }
        guard let principal = try? authenticationProvider(requestHead) else {
            if (method == "GET" || isHeadRequest), path == "/" || path == "/index.html" {
                return .seeOther(location: "/login", omitBody: isHeadRequest)
            }
            return .unauthorized()
        }
        if method == "POST" {
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
            if path == "/api/v1/admin/users" {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
                return createAdministrationMemberResponse(body: body, principal: principal)
            }
            if path.hasPrefix("/api/v1/admin/sessions/") {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageSessions) else { return .forbidden() }
                return revokeAdministrationSessionResponse(path: path, principal: principal)
            }
            if path.hasPrefix("/api/v1/admin/users/") {
                if let limited = limitedResponse(
                    scope: .authenticatedMutation,
                    principal: principal,
                    clientAddressKey: clientAddressKey
                ) { return limited }
                guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
                return updateAdministrationUserAvailabilityResponse(path: path, principal: principal)
            }
            return .methodNotAllowed()
        }
        guard method == "GET" || isHeadRequest else {
            return .methodNotAllowed()
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
            return .html(
                body: Data(
                    ServerWebHomePage.render(
                        serverName: serverName,
                        snapshot: snapshot,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/admin":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            return .html(
                body: Data(
                    ServerWebAdministrationPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/sources":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            return .html(
                body: Data(
                    ServerWebSourcesPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/status":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            return .html(
                body: Data(
                    ServerWebStatusPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/account":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            return .html(
                body: Data(
                    ServerWebAccountPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/library":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else {
                return .serviceUnavailable()
            }
            let selectedCategoryID = selectedLibraryCategoryID(
                from: target,
                allowedCategories: categories.categories
            )
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer,
                        categories: categories.categories,
                        selectedCategoryID: selectedCategoryID
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/people":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page = try peopleProvider(nil, 0, 24, principal)
                return .html(
                    body: Data(ServerWebPeoplePage.directory(
                        serverName: serverName, page: page, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
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
                return .html(
                    body: Data(ServerWebCollectionsPage.directory(
                        serverName: serverName, page: page, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case "/photos":
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            do {
                let page = try libraryBrowseProvider(ServerLibraryQuery(type: "photo", offset: 0, limit: 24), principal)
                return .html(body: Data(ServerWebPhotosPage.gallery(serverName: serverName, page: page, csrfToken: csrfToken, showAdministration: principal.canManageServer).utf8), omitBody: isHeadRequest)
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
                        categories: categories.categories
                    ).utf8
                ),
                omitBody: isHeadRequest
            )
        case "/queue":
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            guard let categories = try? libraryCategoriesProvider(principal) else { return .serviceUnavailable() }
            return .html(
                body: Data(ServerWebLibraryPage.render(
                    serverName: serverName, csrfToken: csrfToken,
                    showAdministration: principal.canManageServer,
                    page: .queue, categories: categories.categories
                ).utf8),
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                        categories: categories.categories
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
                return .html(
                    body: Data(
                        ServerWebMediaDetailPage.render(
                            serverName: serverName,
                            detail: detail,
                            csrfToken: csrfToken,
                            showAdministration: principal.canManageServer
                        ).utf8
                    ),
                    omitBody: isHeadRequest
                )
            } catch {
                return .serviceUnavailable()
            }
        case let seriesPagePath where seriesPagePath.hasPrefix("/series/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard let seriesID = decodedPathIdentifier(seriesPagePath, prefix: "/series/") else {
                return .notFound()
            }
            do {
                guard let detail = try seriesDetailProvider(seriesID, principal) else { return .notFound() }
                return .html(
                    body: Data(
                        ServerWebSeriesPage.render(
                            serverName: serverName,
                            detail: detail,
                            csrfToken: csrfToken,
                            showAdministration: principal.canManageServer
                        ).utf8
                    ),
                    omitBody: isHeadRequest
                )
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
                return .html(
                    body: Data(ServerWebPeoplePage.detail(
                        serverName: serverName, detail: detail, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
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
                return .html(
                    body: Data(ServerWebCollectionsPage.detail(
                        serverName: serverName, detail: detail, csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
                    ).utf8),
                    omitBody: isHeadRequest
                )
            } catch { return .serviceUnavailable() }
        case let photoPagePath where photoPagePath.hasPrefix("/photo/"):
            if let limited = limitedResponse(scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey) { return limited }
            guard let itemID = decodedPathIdentifier(photoPagePath, prefix: "/photo/") else { return .notFound() }
            do {
                guard let detail = try mediaDetailProvider(itemID, principal), detail.type == "photo" else { return .notFound() }
                return .html(body: Data(ServerWebPhotosPage.detail(serverName: serverName, item: detail, csrfToken: csrfToken, showAdministration: principal.canManageServer).utf8), omitBody: isHeadRequest)
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
        case let imagePath where imagePath.hasPrefix("/api/v1/images/"):
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            let remainder = imagePath.dropFirst("/api/v1/images/".count)
            let segments = remainder.split(separator: "/", omittingEmptySubsequences: false)
            guard segments.count == 2,
                  let kind = ServerArtworkKind(rawValue: String(segments[1])),
                  let itemID = decodedPathIdentifier("/image/\(segments[0])", prefix: "/image/")
            else { return .notFound() }
            guard let asset = try? artworkAssetProvider(itemID, kind, principal) else { return .notFound() }
            return .fullFile(asset: asset, omitBody: isHeadRequest, cacheControl: "private, max-age=300")
        case "/api/v1/admin/users":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageUsers) else { return .forbidden() }
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.users(),
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
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.activeSessions(),
                  let data = ServerCommandOutput.jsonData(encoded)
            else {
                return .serviceUnavailable()
            }
            body = data
        case "/api/v1/admin/security-events":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.manageServer) else { return .forbidden() }
            guard let administrationCatalog,
                  let encoded = try? administrationCatalog.securityEvents(),
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
        case let subtitlePath where subtitlePath.hasPrefix("/api/v1/subtitles/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            return webVTTSubtitleResponse(path: subtitlePath, principal: principal, omitBody: isHeadRequest)
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
                      ["q", "type", "offset", "limit", "sort", "state", "preference"].contains(key),
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
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "48"), (1...100).contains(limit),
              let sort = ServerLibrarySort(rawValue: values["sort"] ?? ServerLibrarySort.updatedDescending.rawValue)
        else { return nil }
        return ServerLibraryQuery(
            searchText: searchText, type: type, offset: offset, limit: limit,
            sort: sort, playbackFilter: playbackFilter, preferenceFilter: preferenceFilter
        )
    }

    private func decodeQueryComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
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
    private func collectionsQuery(from target: String) -> (offset: Int, limit: Int)? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/api/v1/collections" else { return nil }
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
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count == 2 else { return nil }
        let path = String(pieces[0])
        let prefix = "/api/v1/collections/"
        let suffix = "/items"
        guard path.hasPrefix(prefix), path.hasSuffix(suffix) else { return nil }
        let encodedID = String(path.dropFirst(prefix.count).dropLast(suffix.count))
        guard let id = decodedPathIdentifier("/collections/\(encodedID)", prefix: "/collections/") else { return nil }
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

    /// Returns an active category only when the page query contains one unique,
    /// well-formed value that is present in the current principal's authorized list.
    private func selectedLibraryCategoryID(
        from target: String,
        allowedCategories: [ServerLibraryCategory]
    ) -> String? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.first == "/library", pieces.count == 2 else { return nil }
        var selected: String?
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decodeQueryComponent(String(keyValue[0])),
                  let value = decodeQueryComponent(String(keyValue[1]))
            else { return nil }
            guard key == "type" else { continue }
            guard selected == nil,
                  value.utf8.count <= 512,
                  !value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f })
            else { return nil }
            selected = value
        }
        guard let selected,
              allowedCategories.prefix(32).contains(where: { $0.id == selected })
        else { return nil }
        return selected
    }

    private func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }

    private func streamResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        rangeHeader: String?,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let asset = try? mediaAssetProvider(itemID, principal, .playMedia) else {
            // 与不存在的条目统一返回 404，避免 ID 或资料库权限被枚举。
            return .notFound()
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
              trackID < ServerWebVTTSubtitleTrack.maximumTrackCount,
              let asset = try? webVTTSubtitleAssetProvider(itemID, trackID, principal)
        else { return .notFound() }
        return .file(
            url: asset.fileURL,
            byteLength: asset.byteLength,
            contentType: "text/vtt; charset=utf-8",
            omitBody: omitBody
        )
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

    private static func authenticationCookieHeaders(tokens: ServerIssuedTokens) -> [String] {
        let accessAge = max(Int(tokens.accessExpiresAt.timeIntervalSinceNow), 1)
        let refreshAge = max(Int(tokens.refreshExpiresAt.timeIntervalSinceNow), 1)
        return [
            "Set-Cookie: \(ServerAuthenticationService.accessCookieName)=\(tokens.accessToken); Path=/; Max-Age=\(accessAge); HttpOnly; Secure; SameSite=Strict",
            "Set-Cookie: \(ServerAuthenticationService.refreshCookieName)=\(tokens.refreshToken); Path=/api/v1/auth; Max-Age=\(refreshAge); HttpOnly; Secure; SameSite=Strict"
        ]
    }
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

    var body: Data {
        guard case let .data(body) = payload else { return Data() }
        return body
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

    static func json(body: Data, additionalHeaders: [String] = []) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
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
            additionalHeaders: []
        )
    }

    static func javascript(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "text/javascript; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Cache-Control: private, max-age=300"]
        )
    }

    static func stylesheet(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "text/css; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Cache-Control: private, max-age=300"]
        )
    }

    static func seeOther(location: String, omitBody: Bool) -> Self {
        let body = Data("See Other".utf8)
        return Self(
            statusCode: 303,
            reason: "See Other",
            contentType: "text/plain; charset=utf-8",
            payload: .data(omitBody ? Data() : body),
            declaredContentLength: body.count,
            additionalHeaders: ["Location: \(location)"]
        )
    }

    static func fullFile(asset: ServerMediaAsset, omitBody: Bool, cacheControl: String? = nil) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: asset.contentType,
            payload: omitBody
                ? .data(Data())
                : .fileRange(LocalHTTPFileRange(url: asset.fileURL, offset: 0, length: asset.byteLength)),
            declaredContentLength: Int(asset.byteLength),
            additionalHeaders: ["Accept-Ranges: bytes"] + (cacheControl.map { ["Cache-Control: \($0)"] } ?? [])
        )
    }

    static func partialFile(asset: ServerMediaAsset, range: ResolvedHTTPByteRange, omitBody: Bool) -> Self {
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
            ]
        )
    }

    static func file(url: URL, byteLength: Int64, contentType: String, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: contentType,
            payload: omitBody
                ? .data(Data())
                : .fileRange(LocalHTTPFileRange(url: url, offset: 0, length: byteLength)),
            declaredContentLength: Int(byteLength),
            additionalHeaders: []
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
            "Content-Length: \(declaredContentLength)",
            keepAlive ? "Connection: keep-alive" : "Connection: close"
        ]
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
        "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; img-src 'self' data:; media-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'self'; frame-ancestors 'none'; object-src 'none'",
        "Cross-Origin-Embedder-Policy: require-corp",
        "Cross-Origin-Opener-Policy: same-origin",
        "Cross-Origin-Resource-Policy: same-origin",
        "Permissions-Policy: camera=(), microphone=(), geolocation=(), payment=(), usb=()",
        "Referrer-Policy: no-referrer",
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
}

struct LocalHTTPFileRange {
    let url: URL
    let offset: Int64
    let length: Int64
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
