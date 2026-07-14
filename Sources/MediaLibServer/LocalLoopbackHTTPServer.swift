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
    private static let requestDeadline: TimeInterval = 10

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
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        hlsSessionManager: FFmpegHLSSessionManager? = nil,
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
            mediaPlaybackStateUpdater: mediaPlaybackStateUpdater,
            mediaAssetProvider: mediaAssetProvider,
            artworkAssetProvider: artworkAssetProvider,
            playbackInfoProvider: playbackInfoProvider,
            hlsSessionManager: hlsSessionManager,
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
        guard let received = receiveRequest(from: client) else { return }
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
        write(
            response: router.response(
                for: request.head,
                body: request.body,
                clientAddressKey: clientAddressKey
            ),
            to: client
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

    private static func clientAddressKey(_ address: sockaddr_in) -> String {
        var address = address
        var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
        let result = withUnsafePointer(to: &address.sin_addr) { pointer in
            inet_ntop(AF_INET, pointer, &buffer, socklen_t(buffer.count))
        }
        guard result != nil else { return "unresolved-client" }
        return String(cString: buffer)
    }

    private func write(response: LocalHTTPResponse, to client: Int32) {
        write(data: response.serializedHeaders(), to: client)
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
    private let mediaPlaybackStateUpdater: (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState?
    private let mediaAssetProvider: (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset?
    private let artworkAssetProvider: (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset?
    private let playbackInfoProvider: (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo?
    private let hlsSessionManager: FFmpegHLSSessionManager?
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
        mediaPlaybackStateUpdater: @escaping (String, ServerPlaybackStateUpdateRequest, ServerRequestPrincipal) throws -> ServerMediaUserState? = { _, _, _ in nil },
        mediaAssetProvider: @escaping (String, ServerRequestPrincipal, ServerPermission) throws -> ServerMediaAsset? = { _, _, _ in nil },
        artworkAssetProvider: @escaping (String, ServerArtworkKind, ServerRequestPrincipal) throws -> ServerMediaAsset? = { _, _, _ in nil },
        playbackInfoProvider: @escaping (String, ServerRequestPrincipal) throws -> ServerMediaPlaybackInfo? = { _, _ in nil },
        hlsSessionManager: FFmpegHLSSessionManager? = nil,
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
        self.mediaPlaybackStateUpdater = mediaPlaybackStateUpdater
        self.mediaAssetProvider = mediaAssetProvider
        self.artworkAssetProvider = artworkAssetProvider
        self.playbackInfoProvider = playbackInfoProvider
        self.hlsSessionManager = hlsSessionManager
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
        if (method == "GET" || isHeadRequest), path == "/assets/admin.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebAdministrationPage.script.utf8), omitBody: isHeadRequest)
        }
        if (method == "GET" || isHeadRequest), path == "/assets/player.js" {
            if let limited = limitedResponse(
                scope: .publicProbe, identityComponents: [clientAddressKey]
            ) { return limited }
            return .javascript(body: Data(ServerWebMediaDetailPage.script.utf8), omitBody: isHeadRequest)
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
        if method == "DELETE" {
            if let limited = limitedResponse(
                scope: .authenticatedMutation,
                principal: principal,
                clientAddressKey: clientAddressKey
            ) { return limited }
            return cancelHLSResponse(path: path, principal: principal)
        }
        if method == "POST" {
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
            guard path.hasPrefix("/api/v1/playback/hls/") else { return .methodNotAllowed() }
            let encodedID = String(path.dropFirst("/api/v1/playback/hls/".count))
            guard !encodedID.isEmpty,
                  let itemID = encodedID.removingPercentEncoding,
                  !itemID.contains("/")
            else {
                return .notFound()
            }
            if let limited = limitedResponse(
                scope: .transcodeMutation,
                principal: principal,
                clientAddressKey: clientAddressKey,
                cost: 2
            ) { return limited }
            return startHLSResponse(itemID: itemID, principal: principal, omitBody: false)
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
        case "/library":
            if let limited = limitedResponse(
                scope: .apiRead, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            guard principal.permissions.contains(.viewMedia) else { return .forbidden() }
            return .html(
                body: Data(
                    ServerWebLibraryPage.render(
                        serverName: serverName,
                        csrfToken: csrfToken,
                        showAdministration: principal.canManageServer
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
        case let hlsOutputPath where hlsOutputPath.hasPrefix("/api/v1/hls/"):
            if let limited = limitedResponse(
                scope: .mediaStream, principal: principal, clientAddressKey: clientAddressKey
            ) { return limited }
            return hlsOutputResponse(path: hlsOutputPath, principal: principal, omitBody: isHeadRequest)
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
                      ["q", "type", "offset", "limit", "sort"].contains(key),
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
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"), offset <= 1_000_000,
              let limit = strictNonnegativeInteger(values["limit"] ?? "48"), (1...100).contains(limit),
              let sort = ServerLibrarySort(rawValue: values["sort"] ?? ServerLibrarySort.updatedDescending.rawValue)
        else { return nil }
        return ServerLibraryQuery(searchText: searchText, type: type, offset: offset, limit: limit, sort: sort)
    }

    private func decodeQueryComponent(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
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

    private func startHLSResponse(
        itemID: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        guard let hlsSessionManager,
              let asset = try? mediaAssetProvider(itemID, principal, .transcodePlayback)
        else {
            return .notFound()
        }
        do {
            let session = try hlsSessionManager.start(asset: asset, ownerSessionID: principal.sessionID)
            guard let body = ServerCommandOutput.jsonData(session) else { return .serviceUnavailable() }
            return .ok(body: body, omitBody: omitBody)
        } catch {
            return .serviceUnavailable()
        }
    }

    private func hlsOutputResponse(
        path: String,
        principal: ServerRequestPrincipal,
        omitBody: Bool
    ) -> LocalHTTPResponse {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 5,
              components[0] == "api", components[1] == "v1", components[2] == "hls",
              let outputURL = hlsSessionManager?.outputURL(
                sessionID: String(components[3]),
                fileName: String(components[4]),
                ownerSessionID: principal.sessionID
              ),
              let attributes = try? FileManager.default.attributesOfItem(atPath: outputURL.path),
              let byteLength = attributes[.size] as? NSNumber
        else {
            return .notFound()
        }
        return .file(
            url: outputURL,
            byteLength: byteLength.int64Value,
            contentType: outputURL.pathExtension == "m3u8" ? "application/vnd.apple.mpegurl" : "video/mp2t",
            omitBody: omitBody
        )
    }

    private func cancelHLSResponse(path: String, principal: ServerRequestPrincipal) -> LocalHTTPResponse {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard components.count == 4,
              components[0] == "api", components[1] == "v1", components[2] == "hls",
              let hlsSessionManager
        else {
            return .notFound()
        }
        guard hlsSessionManager.cancel(
            sessionID: String(components[3]),
            ownerSessionID: principal.sessionID
        ) else {
            return .notFound()
        }
        return .noContent()
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
            additionalHeaders: []
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
            "Cache-Control: no-store",
            "Connection: close"
        ]
        if statusCode == 405 {
            headers.append("Allow: GET, HEAD")
        }
        headers.append(contentsOf: additionalHeaders)
        var data = serializedHeaders()
        data.append(body)
        return data
    }

    func serializedHeaders() -> Data {
        var headers = [
            "HTTP/1.1 \(statusCode) \(reason)",
            "Content-Type: \(contentType)",
            "Content-Length: \(declaredContentLength)",
            "Cache-Control: no-store",
            "Connection: close"
        ]
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
