import Darwin
import Foundation
import MediaLibServerProtocol
import Security

final class ServerHostControlListener: @unchecked Sendable {
    typealias ApplyHandler = @Sendable (ServerHostRuntimeConfiguration) -> Void

    let socketPath: String
    let token: String

    private let directoryURL: URL
    private let descriptor: Int32
    private let queue = DispatchQueue(label: "MediaLIB.ServerHostControl", qos: .utility)
    private let applyHandler: ApplyHandler
    private let stopLock = NSLock()
    private var isStopped = false
    private var source: DispatchSourceRead?

    init(applyHandler: @escaping ApplyHandler) throws {
        let nonce = UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        directoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("mlhc-\(nonce)", isDirectory: true)
        socketPath = directoryURL.appendingPathComponent("control.sock").path
        token = try Self.randomToken()
        self.applyHandler = applyHandler
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw ServerHostControlListenerError.cannotCreateSocket }

        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false,
                attributes: [.posixPermissions: 0o700]
            )
            guard chmod(directoryURL.path, 0o700) == 0 else {
                throw ServerHostControlListenerError.cannotSecureSocket
            }
            var address = sockaddr_un()
            address.sun_family = sa_family_t(AF_UNIX)
            address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
            guard socketPath.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else {
                throw ServerHostControlListenerError.pathTooLong
            }
            withUnsafeMutableBytes(of: &address.sun_path) { destination in
                socketPath.withCString { source in
                    _ = strlcpy(
                        destination.baseAddress?.assumingMemoryBound(to: CChar.self),
                        source,
                        destination.count
                    )
                }
            }
            let bound = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
                }
            }
            guard bound == 0,
                  chmod(socketPath, 0o600) == 0,
                  listen(descriptor, 8) == 0,
                  fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0
            else { throw ServerHostControlListenerError.cannotBindSocket }
        } catch {
            _ = close(descriptor)
            try? FileManager.default.removeItem(at: directoryURL)
            throw error
        }
    }

    deinit { stop() }

    func start() {
        guard source == nil else { return }
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptAvailableClients() }
        self.source = source
        source.resume()
    }

    func stop() {
        stopLock.lock()
        guard !isStopped else {
            stopLock.unlock()
            return
        }
        isStopped = true
        stopLock.unlock()
        source?.cancel()
        source = nil
        _ = shutdown(descriptor, SHUT_RDWR)
        _ = close(descriptor)
        unlink(socketPath)
        try? FileManager.default.removeItem(at: directoryURL)
    }

    private func acceptAvailableClients() {
        while true {
            let client = accept(descriptor, nil, nil)
            guard client >= 0 else { return }
            handle(client)
            _ = close(client)
        }
    }

    private func handle(_ client: Int32) {
        let currentFlags = fcntl(client, F_GETFL)
        if currentFlags >= 0 { _ = fcntl(client, F_SETFL, currentFlags & ~O_NONBLOCK) }
        var noSignal: Int32 = 1
        _ = withUnsafePointer(to: &noSignal) {
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, $0, socklen_t(MemoryLayout<Int32>.size))
        }
        var peerUID = uid_t()
        var peerGID = gid_t()
        guard getpeereid(client, &peerUID, &peerGID) == 0,
              peerUID == geteuid()
        else { return }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        _ = withUnsafePointer(to: &timeout) {
            setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, $0, socklen_t(MemoryLayout<timeval>.size))
        }
        guard let data = readLine(client),
              let request = try? JSONDecoder().decode(ServerHostControlRequest.self, from: data),
              request.protocolVersion == 1,
              request.requestID.utf8.count <= 64,
              Self.constantTimeEqual(request.token, token)
        else { return }

        let response = ServerHostControlResponse(
            requestID: request.requestID,
            status: .accepted,
            resultCode: "runtime.apply.accepted"
        )
        guard var payload = try? JSONEncoder().encode(response) else { return }
        payload.append(0x0A)
        writeAll(payload, to: client)
        switch request.action {
        case .applyRuntimeConfiguration:
            applyHandler(request.configuration)
        }
    }

    private func readLine(_ descriptor: Int32) -> Data? {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while result.count <= 8_192 {
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return nil }
            if let newline = buffer[..<count].firstIndex(of: 0x0A) {
                result.append(contentsOf: buffer[..<newline])
                return result
            }
            result.append(contentsOf: buffer[..<count])
        }
        return nil
    }

    private func writeAll(_ data: Data, to descriptor: Int32) {
        data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return }
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(descriptor, base.advanced(by: offset), bytes.count - offset)
                guard count > 0 else { return }
                offset += count
            }
        }
    }

    private static func randomToken() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw ServerHostControlListenerError.randomGenerationFailed
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    private static func constantTimeEqual(_ lhs: String, _ rhs: String) -> Bool {
        let left = Array(lhs.utf8)
        let right = Array(rhs.utf8)
        var difference = UInt8(truncatingIfNeeded: left.count ^ right.count)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            difference |= l ^ r
        }
        return difference == 0
    }
}

enum ServerHostControlListenerError: LocalizedError {
    case cannotCreateSocket
    case cannotSecureSocket
    case cannotBindSocket
    case pathTooLong
    case randomGenerationFailed

    var errorDescription: String? {
        "无法建立受保护的本机服务控制通道。"
    }
}
