import Foundation
import XCTest
@testable import MediaLibServer

/// 远程封面吞吐基线。
///
/// 海报墙的观感几乎完全由"上游取图能同时进行几路"决定：Emby 的每张封面都是一次
/// 独立 HTTP 往返，串行化之后墙上最后一张的等待时间是 `往返 × 张数 ÷ 并发`。
/// 这些用例把请求打到带人为延迟的真实回环 socket，因此测的是真实的排队行为，
/// 而不是从常量推断出来的结论。
final class ServerRemoteArtworkThroughputTests: XCTestCase {
    private var upstream: LoopbackArtworkUpstream!

    override func setUpWithError() throws {
        try super.setUpWithError()
        upstream = try LoopbackArtworkUpstream(latency: 0.06)
    }

    override func tearDownWithError() throws {
        upstream.shutDown()
        upstream = nil
        try super.tearDownWithError()
    }

    /// 一面海报墙必须让多个不同上游封面同时在飞，而不是退化为少量串行槽位。
    func testPosterWallFetchesInBoundedRounds() throws {
        let fetcher = ServerRemoteAssetFetcher()
        let posterCount = 24
        let group = DispatchGroup()
        let lock = NSLock()
        var failures = 0

        for index in 0..<posterCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                // 每张封面是不同的上游地址，因此不会被任何缓存短路。
                let url = self.upstream.posterURL(index: index)
                if fetcher.artworkBytes(url: url) == nil {
                    lock.lock(); failures += 1; lock.unlock()
                }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "海报墙取图超时")
        XCTAssertEqual(failures, 0)

        print(String(
            format: "[artwork] %d 张封面峰值并发 %d，上游连接 %d",
            posterCount, upstream.peakConcurrentRequestCount, upstream.acceptedConnectionCount
        ))
        // 时间受共享 CI 的调度和 socket 建连影响，不是可靠的并发信号。直接观察
        // 上游在延迟窗口内同时处理的请求：槽位若被改回 2，此值不可能达到 4。
        XCTAssertGreaterThanOrEqual(
            upstream.peakConcurrentRequestCount, 4,
            "海报墙不应退化为少量串行上游请求"
        )
    }

    /// 同一张封面被同时请求多次时只应产生一次上游取图。
    ///
    /// 海报墙、首页与详情页可能在同一瞬间引用同一张图；没有单飞合并时，它们会
    /// 各自占用一个本就稀缺的上游槽位，把真正不同的封面挤到后面。
    func testConcurrentRequestsForOnePosterHitUpstreamOnce() throws {
        let fetcher = ServerRemoteAssetFetcher()
        let url = upstream.posterURL(index: 7)
        let group = DispatchGroup()
        let lock = NSLock()
        var results: [Int] = []

        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                let bytes = fetcher.artworkBytes(url: url)
                lock.lock(); results.append(bytes?.count ?? -1); lock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 60), .success)

        XCTAssertEqual(results.count, 12)
        XCTAssertFalse(results.contains(-1), "所有并发请求都应拿到同一份图片字节")
        XCTAssertEqual(
            upstream.requestCount(forIndex: 7), 1,
            "同一张封面的并发请求必须合并成一次上游取图"
        )
    }
}

/// 极小的回环图片上游，带可配置的往返延迟。
private final class LoopbackArtworkUpstream: @unchecked Sendable {
    private let listener: Int32
    private let port: UInt16
    private let latency: TimeInterval
    private let queue = DispatchQueue(label: "medialib.test.artwork", attributes: .concurrent)
    private let stateLock = NSLock()
    private var acceptedConnections = 0
    private var requestsByIndex: [Int: Int] = [:]
    private var activeRequestCount = 0
    private var peakRequestCount = 0
    private var isRunning = true

    var acceptedConnectionCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return acceptedConnections
    }

    var peakConcurrentRequestCount: Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return peakRequestCount
    }

    func requestCount(forIndex index: Int) -> Int {
        stateLock.lock(); defer { stateLock.unlock() }
        return requestsByIndex[index] ?? 0
    }

    func posterURL(index: Int) -> URL {
        URL(string: "http://127.0.0.1:\(port)/Items/\(index)/Images/Primary?maxWidth=700&api_key=token")!
    }

    init(latency: TimeInterval) throws {
        self.latency = latency
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UpstreamError.socketFailed }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(descriptor); throw UpstreamError.socketFailed
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 128) == 0 else { close(descriptor); throw UpstreamError.socketFailed }
        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(descriptor, $0, &length) }
        }
        guard named == 0 else { close(descriptor); throw UpstreamError.socketFailed }
        self.listener = descriptor
        self.port = UInt16(bigEndian: boundAddress.sin_port)
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func shutDown() {
        stateLock.lock(); isRunning = false; stateLock.unlock()
        close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            stateLock.lock()
            let running = isRunning
            if running, client >= 0 { acceptedConnections += 1 }
            stateLock.unlock()
            guard running else { if client >= 0 { close(client) }; return }
            guard client >= 0 else { return }
            queue.async { [weak self] in self?.serve(client: client) }
        }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        var noSignalPipe: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size))
        while let head = readRequestHead(client) {
            beginRequest(index: Self.itemIndex(from: head))
            Thread.sleep(forTimeInterval: latency)
            endRequest()
            // 一个最小的合法 JPEG 头即可：被测的是排队与合并，不是解码。
            let body = Data([0xFF, 0xD8, 0xFF, 0xE0]) + Data(repeating: 0x20, count: 4_096)
            let header = "HTTP/1.1 200 OK\r\nContent-Type: image/jpeg\r\nContent-Length: \(body.count)\r\nConnection: keep-alive\r\n\r\n"
            guard send(header: header, body: body, on: client) else { return }
        }
    }

    private func beginRequest(index: Int?) {
        stateLock.lock()
        if let index { requestsByIndex[index, default: 0] += 1 }
        activeRequestCount += 1
        peakRequestCount = max(peakRequestCount, activeRequestCount)
        stateLock.unlock()
    }

    private func endRequest() {
        stateLock.lock()
        activeRequestCount -= 1
        stateLock.unlock()
    }

    private static func itemIndex(from head: String) -> Int? {
        guard let range = head.range(of: "/Items/") else { return nil }
        let remainder = head[range.upperBound...]
        guard let slash = remainder.firstIndex(of: "/") else { return nil }
        return Int(remainder[..<slash])
    }

    private func readRequestHead(_ client: Int32) -> String? {
        var buffer = [UInt8]()
        var byte = [UInt8](repeating: 0, count: 1)
        let terminator: [UInt8] = Array("\r\n\r\n".utf8)
        while buffer.count < terminator.count || Array(buffer.suffix(terminator.count)) != terminator {
            guard recv(client, &byte, 1, 0) == 1 else { return nil }
            buffer.append(byte[0])
            if buffer.count > 8_192 { return nil }
        }
        return String(bytes: buffer, encoding: .utf8)
    }

    private func send(header: String, body: Data, on client: Int32) -> Bool {
        var payload = Data(header.utf8)
        payload.append(body)
        var offset = 0
        return payload.withUnsafeBytes { bytes -> Bool in
            guard let base = bytes.baseAddress else { return false }
            while offset < bytes.count {
                let written = Darwin.send(client, base.advanced(by: offset), bytes.count - offset, 0)
                guard written > 0 else { return false }
                offset += written
            }
            return true
        }
    }

    private enum UpstreamError: Error { case socketFailed }
}
