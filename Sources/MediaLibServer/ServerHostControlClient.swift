import Darwin
import Foundation
import MediaLibServerProtocol

enum ServerHostControlClientError: Error, Equatable {
    case unavailable
    case unsafeSocket
    case invalidRequest
    case transportFailed
    case invalidResponse
    case rejected(String)
}

/// Server 子进程只作为 0600 Unix Socket 的客户端。它不会直接写桌面端配置，
/// 也不会自行扩大监听边界；真正的持久化、重启、健康检查和回滚由宿主完成。
final class ServerHostControlClient: @unchecked Sendable {
    private let socketPath: String
    private let token: String
    private let timeoutSeconds: Int

    init?(environment: [String: String] = ProcessInfo.processInfo.environment) {
        guard let socketPath = environment[ServerHostControlEnvironment.socketPath],
              socketPath.hasPrefix("/"),
              socketPath.utf8.count < MemoryLayout.size(ofValue: sockaddr_un().sun_path),
              let token = environment[ServerHostControlEnvironment.token],
              (32...256).contains(token.utf8.count),
              token.utf8.allSatisfy({ byte in
                  (48...57).contains(byte) || (65...90).contains(byte) ||
                      (97...122).contains(byte) || byte == 45 || byte == 95
              })
        else { return nil }
        self.socketPath = socketPath
        self.token = token
        timeoutSeconds = 2
    }

    var isAvailable: Bool {
        guard let metadata = socketMetadata() else { return false }
        let type = metadata.st_mode & S_IFMT
        let permissions = metadata.st_mode & 0o777
        return type == S_IFSOCK && metadata.st_uid == geteuid() && permissions == 0o600
    }

    func apply(_ configuration: ServerHostRuntimeConfiguration) throws -> ServerHostControlResponse {
        guard isAvailable else { throw ServerHostControlClientError.unsafeSocket }
        let request = ServerHostControlRequest(
            requestID: UUID().uuidString.lowercased(),
            token: token,
            action: .applyRuntimeConfiguration,
            configuration: configuration
        )
        var payload = try JSONEncoder().encode(request)
        guard payload.count <= 8_192 else { throw ServerHostControlClientError.invalidRequest }
        payload.append(0x0A)

        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerHostControlClientError.transportFailed }
        defer { _ = close(descriptor) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var timeout = timeval(tv_sec: timeoutSeconds, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { destination in
            socketPath.withCString { source in
                _ = strlcpy(
                    destination.baseAddress?.assumingMemoryBound(to: CChar.self),
                    source,
                    destination.count
                )
            }
        }
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { throw ServerHostControlClientError.transportFailed }
        try writeAll(payload, to: descriptor)
        let responseData = try readLine(from: descriptor)
        guard let response = try? JSONDecoder().decode(ServerHostControlResponse.self, from: responseData),
              response.protocolVersion == 1,
              response.requestID == request.requestID
        else { throw ServerHostControlClientError.invalidResponse }
        guard response.status == .accepted else {
            throw ServerHostControlClientError.rejected(response.resultCode)
        }
        return response
    }

    private func socketMetadata() -> stat? {
        var metadata = stat()
        guard lstat(socketPath, &metadata) == 0 else { return nil }
        return metadata
    }

    private func writeAll(_ data: Data, to descriptor: Int32) throws {
        try data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { throw ServerHostControlClientError.transportFailed }
                offset += count
            }
        }
    }

    private func readLine(from descriptor: Int32) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while result.count <= 8_192 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { throw ServerHostControlClientError.transportFailed }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        throw ServerHostControlClientError.invalidResponse
    }
}
