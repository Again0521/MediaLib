import Foundation
import MediaLibServerProtocol
import XCTest
@testable import MediaLibServer

/// P4 的压测前置：在开放局域网访问之前，必须先证明同源代理在并发下的行为是
/// 有界且可预期的。这些用例把请求打到一个**真实**的回环上游 socket，而不是内存
/// 替身，因此连接复用、Range 校验和分块写入都被真正执行。
///
/// 这里刻意不断言绝对吞吐或 FPS：那类数字取决于当时的机器负载，写死只会制造
/// 一个随机失败的测试。断言的是结构性上限——并发期间同时持有的媒体字节数、
/// 上游连接数与响应正确性。实测耗时以 p50/p95 打印出来供人工比较。
final class ServerRemoteProxyStressTests: XCTestCase {
    private var upstream: LoopbackRangeUpstream!

    override func setUpWithError() throws {
        try super.setUpWithError()
        // 足够容纳并发用例里所有互不重叠的偏移；上游按需生成字节，不预先分配。
        upstream = try LoopbackRangeUpstream(totalLength: 64 * 1_024 * 1_024)
    }

    override func tearDownWithError() throws {
        upstream.shutDown()
        upstream = nil
        try super.tearDownWithError()
    }

    /// 48 个并发 Range（模拟多设备同时起播与随机 seek）必须全部正确返回，
    /// 且服务端同时持有的媒体字节数保持在"分块大小 × 媒体槽位"量级，
    /// 而不是"Range 大小 × 并发数"。
    func testConcurrentRangeRequestsStayByteBoundedAndCorrect() throws {
        let telemetry = ServerPlaybackTelemetry()
        let fetcher = ServerRemoteAssetFetcher(telemetry: telemetry)
        let requestCount = 48
        let rangeLength: Int64 = 512 * 1_024

        let meter = ConcurrentByteMeter()
        let durationsLock = NSLock()
        var durations: [TimeInterval] = []
        var failures: [String] = []
        let group = DispatchGroup()

        for index in 0..<requestCount {
            group.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { group.leave() }
                // 每个请求落在不同偏移上，模拟随机 seek 而不是重复同一块。
                let offset = Int64(index) * rangeLength
                let startedAt = Date()
                var received = 0
                let succeeded = fetcher.streamMediaBytes(
                    url: self.upstream.url,
                    offset: offset,
                    length: rangeLength
                ) { chunk in
                    meter.acquired(chunk.count)
                    received += chunk.count
                    // 模拟客户端 socket 写入耗时，让并发窗口真实重叠。
                    Thread.sleep(forTimeInterval: 0.001)
                    meter.released(chunk.count)
                    return true
                }
                let elapsed = Date().timeIntervalSince(startedAt)
                durationsLock.lock()
                durations.append(elapsed)
                if !succeeded { failures.append("range@\(offset) 未成功") }
                if received != Int(rangeLength) {
                    failures.append("range@\(offset) 收到 \(received) 字节，应为 \(rangeLength)")
                }
                durationsLock.unlock()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 120), .success, "并发 Range 压测超时")
        XCTAssertEqual(failures, [])

        // 媒体槽位为 4，单块上限 256 KiB。留出一块的余量吸收调度抖动，但仍远小于
        // "48 × 512 KiB = 24 MiB" 这个未加约束时会出现的量级。
        let allowedPeak = 5 * 256 * 1_024
        XCTAssertLessThanOrEqual(
            meter.peak, allowedPeak,
            "并发期间同时持有的媒体字节应有明确上限，实测峰值 \(meter.peak) 字节"
        )
        // 连接池的直接证据：48 个 Range 不应产生 48 条上游连接。
        XCTAssertLessThan(
            upstream.acceptedConnectionCount, requestCount,
            "按 origin 复用会话后，上游连接数必须少于 Range 请求数"
        )

        // 服务端遥测必须与外部观测一致——遥测是验收报告的数据来源，
        // 它自己先得可信。
        let snapshot = telemetry.snapshot()
        XCTAssertEqual(snapshot.remoteRangeCount, requestCount)
        XCTAssertEqual(snapshot.localRangeCount, 0)
        XCTAssertEqual(snapshot.outcomes[.completed], requestCount)
        XCTAssertEqual(snapshot.deliveredByteCount, Int64(requestCount) * rangeLength)
        XCTAssertEqual(snapshot.rangeSizeBuckets[.upTo1MiB], requestCount)
        XCTAssertEqual(snapshot.upstreamTimeToFirstByte.sampleCount, requestCount)
        XCTAssertLessThanOrEqual(snapshot.peakConcurrentBufferedBytes, allowedPeak)
        XCTAssertLessThanOrEqual(
            snapshot.peakConcurrentRanges, requestCount,
            "同时在传输中的 Range 数不可能超过发出的请求数"
        )

        durationsLock.lock()
        let sorted = durations.sorted()
        durationsLock.unlock()
        let p50 = sorted[sorted.count / 2]
        let p95 = sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.95))]
        print("[stress] Range p50=\(String(format: "%.3f", p50))s p95=\(String(format: "%.3f", p95))s " +
              "peakBytes=\(meter.peak) upstreamConnections=\(upstream.acceptedConnectionCount)")
        print("[stress] 服务端遥测 ttfb_p50=\(snapshot.upstreamTimeToFirstByte.p50Milliseconds)ms " +
              "ttfb_p95=\(snapshot.upstreamTimeToFirstByte.p95Milliseconds)ms " +
              "range_p50=\(snapshot.rangeCompletion.p50Milliseconds)ms " +
              "range_p95=\(snapshot.rangeCompletion.p95Milliseconds)ms " +
              "peakBuffered=\(snapshot.peakConcurrentBufferedBytes) " +
              "peakConcurrentRanges=\(snapshot.peakConcurrentRanges)")
    }

    /// 失败必须被分类，而不是笼统记成"失败"。上游忽略 Range 与客户端断开是
    /// 两种完全不同的处置，混在一起就没法从遥测判断该修哪边。
    func testTelemetryDistinguishesUpstreamRejectionFromClientDisconnect() throws {
        let rejected = ServerPlaybackTelemetry()
        upstream.ignoresRange = true
        _ = ServerRemoteAssetFetcher(telemetry: rejected)
            .streamMediaBytes(url: upstream.url, offset: 0, length: 256 * 1_024) { _ in true }
        XCTAssertEqual(rejected.snapshot().outcomes[.upstreamRejected], 1)
        XCTAssertNil(rejected.snapshot().outcomes[.clientDisconnected])

        upstream.ignoresRange = false
        let disconnected = ServerPlaybackTelemetry()
        _ = ServerRemoteAssetFetcher(telemetry: disconnected)
            .streamMediaBytes(url: upstream.url, offset: 0, length: 1_024 * 1_024) { _ in false }
        XCTAssertEqual(disconnected.snapshot().outcomes[.clientDisconnected], 1)
        XCTAssertNil(disconnected.snapshot().outcomes[.upstreamRejected])
    }

    /// 上游忽略 Range 而返回整片 `200` 时必须失败，不能悄悄变成整片下载。
    func testUpstreamIgnoringRangeIsRejectedInsteadOfDownloadingWholeFile() throws {
        upstream.ignoresRange = true
        let fetcher = ServerRemoteAssetFetcher()
        var received = 0

        let succeeded = fetcher.streamMediaBytes(
            url: upstream.url,
            offset: 0,
            length: 256 * 1_024
        ) { chunk in
            received += chunk.count
            return true
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(received, 0, "上游忽略 Range 时不得向客户端写出任何字节")
    }

    /// 客户端中途断开（写 socket 返回失败）后必须立即停止读取上游。
    func testDisconnectedClientStopsUpstreamReadImmediately() throws {
        let fetcher = ServerRemoteAssetFetcher()
        var chunks = 0

        let succeeded = fetcher.streamMediaBytes(
            url: upstream.url,
            offset: 0,
            length: 4 * 1_024 * 1_024
        ) { _ in
            chunks += 1
            return false
        }

        XCTAssertFalse(succeeded)
        XCTAssertEqual(chunks, 1, "消费者拒绝首块后不得继续拉取上游")
    }
}

/// 记录并发期间同时被持有的字节数峰值。
private final class ConcurrentByteMeter {
    private let lock = NSLock()
    private var current = 0
    private var peakValue = 0

    var peak: Int {
        lock.lock()
        defer { lock.unlock() }
        return peakValue
    }

    func acquired(_ count: Int) {
        lock.lock()
        current += count
        peakValue = max(peakValue, current)
        lock.unlock()
    }

    func released(_ count: Int) {
        lock.lock()
        current -= count
        lock.unlock()
    }
}

/// 极小的回环 HTTP 上游，只实现压测需要的 Range 语义。它存在的意义是让测试
/// 真的走一遍 TCP、`URLSession` 与 206/Content-Range 校验，而不是用内存替身
/// 把被测路径整段跳过。
private final class LoopbackRangeUpstream: @unchecked Sendable {
    let url: URL
    /// 置为 true 时故意忽略 Range 并返回整片 200，用于验证服务端拒绝该行为。
    var ignoresRange = false

    private let listener: Int32
    private let totalLength: Int
    private let queue = DispatchQueue(label: "medialib.test.upstream", attributes: .concurrent)
    private let stateLock = NSLock()
    private var acceptedConnections = 0
    private var isRunning = true

    var acceptedConnectionCount: Int {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptedConnections
    }

    init(totalLength: Int) throws {
        self.totalLength = totalLength
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw UpstreamError.socketFailed }
        var reuse: Int32 = 1
        setsockopt(descriptor, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        guard inet_pton(AF_INET, "127.0.0.1", &address.sin_addr) == 1 else {
            close(descriptor)
            throw UpstreamError.socketFailed
        }
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(descriptor, 128) == 0 else {
            close(descriptor)
            throw UpstreamError.socketFailed
        }

        var boundAddress = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &boundAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard named == 0,
              let resolved = URL(string: "http://127.0.0.1:\(UInt16(bigEndian: boundAddress.sin_port))/media.mp4")
        else {
            close(descriptor)
            throw UpstreamError.socketFailed
        }
        self.listener = descriptor
        self.url = resolved
        queue.async { [weak self] in self?.acceptLoop() }
    }

    func shutDown() {
        stateLock.lock()
        isRunning = false
        stateLock.unlock()
        close(listener)
    }

    private func acceptLoop() {
        while true {
            let client = accept(listener, nil, nil)
            stateLock.lock()
            let running = isRunning
            if running, client >= 0 { acceptedConnections += 1 }
            stateLock.unlock()
            guard running else {
                if client >= 0 { close(client) }
                return
            }
            guard client >= 0 else { return }
            queue.async { [weak self] in self?.serve(client: client) }
        }
    }

    private func serve(client: Int32) {
        defer { close(client) }
        // 客户端提前断开是被测行为之一；没有这一项，写入已关闭的 socket 会用
        // SIGPIPE 直接杀掉整个测试进程。
        var noSignalPipe: Int32 = 1
        setsockopt(
            client, SOL_SOCKET, SO_NOSIGPIPE, &noSignalPipe, socklen_t(MemoryLayout<Int32>.size)
        )
        // keep-alive：同一条连接上串行处理多个 Range，这样"连接数 < 请求数"
        // 才能真正反映会话复用而不是测试构造。
        while let head = readRequestHead(client) {
            guard respond(to: head, on: client) else { return }
        }
    }

    private func readRequestHead(_ client: Int32) -> String? {
        var buffer = [UInt8]()
        var byte = [UInt8](repeating: 0, count: 1)
        let terminator: [UInt8] = Array("\r\n\r\n".utf8)
        while buffer.count < terminator.count || Array(buffer.suffix(terminator.count)) != terminator {
            let count = recv(client, &byte, 1, 0)
            guard count == 1 else { return nil }
            buffer.append(byte[0])
            if buffer.count > 8_192 { return nil }
        }
        return String(bytes: buffer, encoding: .utf8)
    }

    private func respond(to head: String, on client: Int32) -> Bool {
        let payloadByte: UInt8 = 0x5A
        if ignoresRange {
            let body = Data(repeating: payloadByte, count: 1_024)
            let header = "HTTP/1.1 200 OK\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
            return send(header: header, body: body, on: client)
        }
        guard let rangeLine = head.components(separatedBy: "\r\n")
            .first(where: { $0.lowercased().hasPrefix("range:") }),
            let spec = rangeLine.split(separator: "=").last
        else {
            let header = "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return send(header: header, body: Data(), on: client)
        }
        let bounds = spec.split(separator: "-", omittingEmptySubsequences: false)
        guard bounds.count == 2,
              let start = Int(bounds[0].trimmingCharacters(in: .whitespaces)),
              let end = Int(bounds[1].trimmingCharacters(in: .whitespaces)),
              start >= 0, end >= start, end < totalLength
        else {
            let header = "HTTP/1.1 416 Range Not Satisfiable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
            return send(header: header, body: Data(), on: client)
        }
        let body = Data(repeating: payloadByte, count: end - start + 1)
        let header = """
        HTTP/1.1 206 Partial Content\r
        Content-Type: video/mp4\r
        Content-Range: bytes \(start)-\(end)/\(totalLength)\r
        Content-Length: \(body.count)\r
        Connection: keep-alive\r
        \r\n
        """
        return send(header: header, body: body, on: client)
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
