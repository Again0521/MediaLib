import Foundation
import MediaLibServerProtocol

#if os(Linux)
import Glibc
private func streamSocketType() -> Int32 { Int32(SOCK_STREAM.rawValue) }
#else
import Darwin
private func streamSocketType() -> Int32 { SOCK_STREAM }
#endif

/// Phase 0 的最小本机 HTTP 适配层。它仅用于把 Mlink 健康探测协议落地为真实端点；
/// 不承担认证、静态 Web、流式媒体或公网访问，后续由完整 HTTP 框架替换。
final class LocalLoopbackHTTPServer {
    private let configuration: ServerLaunchConfiguration
    private let router: LocalHTTPRouter

    init(configuration: ServerLaunchConfiguration) throws {
        guard ["127.0.0.1", "localhost"].contains(configuration.host.lowercased()) else {
            throw ServerConfigurationError.nonLoopbackHost(configuration.host)
        }
        self.configuration = configuration
        self.router = LocalHTTPRouter(
            serverID: configuration.serverID,
            serverName: configuration.serverName
        )
    }

    func run() throws {
        let listener = try makeListener()
        defer { _ = close(listener) }

        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                throw LocalHTTPServerError.acceptFailed(errno: errno)
            }
            handle(client: client)
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

    private func handle(client: Int32) {
        defer { _ = close(client) }
        guard let requestHead = receiveRequestHead(from: client) else { return }
        write(response: router.response(for: requestHead), to: client)
    }

    private func receiveRequestHead(from client: Int32) -> String? {
        let headerTerminator = Data([13, 10, 13, 10])
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)

        while request.count < 16_384 {
            let count = buffer.withUnsafeMutableBytes { bytes in
                recv(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return nil }
            request.append(contentsOf: buffer.prefix(Int(count)))
            if request.range(of: headerTerminator) != nil {
                return String(data: request, encoding: .utf8)
            }
        }
        return nil
    }

    private func write(response: LocalHTTPResponse, to client: Int32) {
        var remaining = response.serialized()
        while !remaining.isEmpty {
            let count = remaining.withUnsafeBytes { bytes in
                send(client, bytes.baseAddress, bytes.count, 0)
            }
            guard count > 0 else { return }
            remaining.removeFirst(Int(count))
        }
    }
}

struct LocalHTTPRouter {
    private let serverID: String
    private let serverName: String

    init(serverID: String, serverName: String) {
        self.serverID = serverID
        self.serverName = serverName
    }

    func response(for requestHead: String) -> LocalHTTPResponse {
        guard let requestLine = requestHead.split(separator: "\r\n", maxSplits: 1).first else {
            return .badRequest()
        }
        let parts = requestLine.split(separator: " ", omittingEmptySubsequences: true)
        guard parts.count >= 2 else { return .badRequest() }

        let method = String(parts[0]).uppercased()
        let isHeadRequest = method == "HEAD"
        guard method == "GET" || isHeadRequest else {
            return .methodNotAllowed()
        }

        let path = String(parts[1].split(separator: "?", maxSplits: 1).first ?? "")
        let body: Data
        switch path {
        case "/health":
            body = ServerCommandOutput.jsonData(
                ServerHealth(serverID: serverID, serverName: serverName)
            ) ?? Data()
        case "/.well-known/mlink":
            body = ServerCommandOutput.jsonData(
                MlinkServerDescriptor(
                    serverID: serverID,
                    serverName: serverName,
                    capabilities: ["health", "server-discovery"]
                )
            ) ?? Data()
        default:
            return .notFound()
        }
        return .ok(body: body, omitBody: isHeadRequest)
    }
}

struct LocalHTTPResponse: Equatable {
    let statusCode: Int
    let reason: String
    let contentType: String
    let body: Data
    let declaredContentLength: Int

    static func ok(body: Data, omitBody: Bool) -> Self {
        Self(
            statusCode: 200,
            reason: "OK",
            contentType: "application/json; charset=utf-8",
            body: omitBody ? Data() : body,
            declaredContentLength: body.count
        )
    }

    static func badRequest() -> Self { error(statusCode: 400, reason: "Bad Request") }
    static func notFound() -> Self { error(statusCode: 404, reason: "Not Found") }
    static func methodNotAllowed() -> Self { error(statusCode: 405, reason: "Method Not Allowed") }

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
        var data = Data((headers.joined(separator: "\r\n") + "\r\n\r\n").utf8)
        data.append(body)
        return data
    }

    private static func error(statusCode: Int, reason: String) -> Self {
        let body = Data("{\"error\":\"\(reason)\"}".utf8)
        return Self(
            statusCode: statusCode,
            reason: reason,
            contentType: "application/json; charset=utf-8",
            body: body,
            declaredContentLength: body.count
        )
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
