import Darwin
import Foundation

/// A per-transcode, loopback-only HTTP view of one authorized remote asset.
///
/// ffmpeg needs a seekable input for MKV indexes and repeated HLS seeks. Giving
/// it the upstream Emby/Plex URL would expose that URL (and often its token) in
/// process arguments. This bridge keeps the URL in server memory and gives the
/// child process only an ephemeral `127.0.0.1` endpoint. It accepts one path,
/// supports standard byte ranges, and disappears with the playback session.
final class ServerRemoteMediaBridge: @unchecked Sendable {
    let inputURL: URL

    private let listener: Int32
    private let fetcher: ServerRemoteAssetFetcher
    private let remoteURL: URL
    private let byteLength: Int64
    private let contentType: String
    private let requestPath: String
    private let lock = NSLock()
    private var stopped = false
    private var activeClients: [Int32: ServerRemoteAssetFetcher.Cancellation] = [:]
    private let clients = DispatchSemaphore(value: 4)

    init?(asset: ServerMediaAsset, fetcher: ServerRemoteAssetFetcher) {
        guard let remoteURL = asset.remoteURL, asset.byteLength > 0 else { return nil }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }

        var reuse: Int32 = 1
        var noSignal: Int32 = 1
        guard setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size)) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0
        else {
            close(descriptor)
            return nil
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 8) == 0 else {
            close(descriptor)
            return nil
        }
        var actual = sockaddr_in()
        var actualLength = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &actualLength)
            }
        }
        let requestPath = "/\(UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())/media"
        guard named == 0,
              let inputURL = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: actual.sin_port))\(requestPath)")
        else {
            close(descriptor)
            return nil
        }

        self.listener = descriptor
        self.fetcher = fetcher
        self.remoteURL = remoteURL
        self.byteLength = asset.byteLength
        self.contentType = asset.contentType
        self.requestPath = requestPath
        self.inputURL = inputURL
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.acceptLoop() }
    }

    deinit { stop() }

    func stop() {
        lock.lock()
        guard !stopped else { lock.unlock(); return }
        stopped = true
        let cancellations = Array(activeClients.values)
        // Shutdown while holding the registry lock. A worker removes its file
        // descriptor under the same lock before closing it, so the descriptor
        // cannot be reused for an unrelated socket between lookup and shutdown.
        for client in activeClients.keys {
            _ = Darwin.shutdown(client, SHUT_RDWR)
        }
        lock.unlock()
        cancellations.forEach { $0.cancel() }
        shutdown(listener, SHUT_RDWR)
        close(listener)
    }

    var activeClientCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return activeClients.count
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            if client < 0 {
                lock.lock(); let isStopped = stopped; lock.unlock()
                if isStopped { return }
                continue
            }
            let cancellation = ServerRemoteAssetFetcher.Cancellation()
            lock.lock()
            guard !stopped else {
                lock.unlock()
                close(client)
                return
            }
            activeClients[client] = cancellation
            lock.unlock()
            guard configure(client) else {
                unregisterAndClose(client)
                continue
            }
            guard clients.wait(timeout: .now() + 1) == .success else {
                unregisterAndClose(client)
                continue
            }
            DispatchQueue.global(qos: .userInitiated).async { [weak self] in
                guard let self else {
                    close(client)
                    return
                }
                defer {
                    self.clients.signal()
                    self.unregisterAndClose(client)
                }
                self.serve(client, cancellation: cancellation)
            }
        }
    }

    private func serve(_ client: Int32, cancellation: ServerRemoteAssetFetcher.Cancellation) {
        guard let head = readHead(client),
              let first = head.components(separatedBy: "\r\n").first
        else { return }
        let pieces = first.split(separator: " ")
        guard pieces.count == 3,
              (pieces[0] == "GET" || pieces[0] == "HEAD"),
              pieces[1] == Substring(requestPath)
        else {
            _ = send(Data("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: client)
            return
        }
        let rangeHeader = head.components(separatedBy: "\r\n").dropFirst().first { line in
            line.lowercased().hasPrefix("range:")
        }.map { line in
            String(line.dropFirst(line.firstIndex(of: ":").map { line.distance(from: line.startIndex, to: $0) + 1 } ?? line.count))
                .trimmingCharacters(in: .whitespaces)
        }
        let range: ResolvedHTTPByteRange
        let status: String
        if let rangeHeader {
            guard let request = HTTPByteRangeRequest(headerValue: rangeHeader),
                  let resolved = request.resolve(totalLength: byteLength)
            else {
                _ = send(Data("HTTP/1.1 416 Range Not Satisfiable\r\nContent-Range: bytes */\(byteLength)\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8), to: client)
                return
            }
            range = resolved
            status = "206 Partial Content"
        } else {
            range = ResolvedHTTPByteRange(lowerBound: 0, upperBound: byteLength - 1, totalLength: byteLength)
            status = "200 OK"
        }
        var headerLines = [
            "HTTP/1.1 \(status)",
            "Content-Type: \(contentType)",
            "Content-Length: \(range.length)",
            "Accept-Ranges: bytes",
            "Connection: close"
        ]
        if status.hasPrefix("206") { headerLines.append("Content-Range: \(range.contentRangeHeader)") }
        guard send(Data((headerLines.joined(separator: "\r\n") + "\r\n\r\n").utf8), to: client),
              pieces[0] != "HEAD"
        else { return }

        var offset = range.lowerBound
        let end = range.upperBound + 1
        while offset < end {
            guard !cancellation.isCancelled else { return }
            let length = min(end - offset, Int64(ServerRemoteAssetFetcher.maximumMediaRangeByteLength))
            let delivered = fetcher.streamMediaBytes(
                url: remoteURL,
                offset: offset,
                length: length,
                cancellation: cancellation
            ) { [weak self] data in
                guard self != nil else { return false }
                return self?.send(data, to: client) == true
            }
            guard delivered else { return }
            offset += length
        }
    }

    private func configure(_ client: Int32) -> Bool {
        var noSignal: Int32 = 1
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        let timeoutSize = socklen_t(MemoryLayout<timeval>.size)
        return setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)
        ) == 0 && setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, timeoutSize) == 0 &&
            setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, timeoutSize) == 0
    }

    private func unregisterAndClose(_ client: Int32) {
        lock.lock()
        activeClients.removeValue(forKey: client)
        lock.unlock()
        close(client)
    }

    private func readHead(_ client: Int32) -> String? {
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2_048)
        while data.count <= 16_384 {
            let count = recv(client, &buffer, buffer.count, 0)
            guard count > 0 else { return nil }
            data.append(buffer, count: count)
            if data.range(of: Data("\r\n\r\n".utf8)) != nil {
                return String(data: data, encoding: .utf8)
            }
        }
        return nil
    }

    @discardableResult
    private func send(_ data: Data, to client: Int32) -> Bool {
        guard !data.isEmpty else { return true }
        return data.withUnsafeBytes { bytes in
            guard let base = bytes.baseAddress else { return false }
            var sent = 0
            while sent < bytes.count {
                let result = Darwin.send(client, base.advanced(by: sent), bytes.count - sent, 0)
                guard result > 0 else { return false }
                sent += result
            }
            return true
        }
    }
}
