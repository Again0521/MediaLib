import CryptoKit
import Foundation
import MediaLibServerProtocol

/// 已授权远程资源的有界读取器。它只接收资料库同步阶段保存的 HTTP(S) URL；
/// 路由层绝不把 URL、查询串中的上游 token 或响应头交给浏览器。每次请求都禁用
/// 重定向，避免凭据随 30x 跳转泄露到另一个 origin。
final class ServerRemoteAssetFetcher {
    /// Sticky cancellation for one bounded metadata/body request. The handle
    /// deliberately retains only the URLSession task, never the authorized
    /// URL, so keeping it in a subtitle flight cannot widen the credential
    /// logging surface.
    final class Cancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var task: URLSessionTask?
        private var cancelled = false

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let current = task
            lock.unlock()
            current?.cancel()
        }

        fileprivate func bind(_ task: URLSessionTask) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            self.task = task
            return true
        }

        fileprivate func unbind(_ task: URLSessionTask) {
            lock.lock()
            if self.task === task { self.task = nil }
            lock.unlock()
        }
    }

    static let maximumMediaRangeByteLength = 16 * 1_024 * 1_024
    private static let mediaTransferChunkLength = 256 * 1_024
    static let maximumArtworkByteLength = 8 * 1_024 * 1_024
    private static let maximumArtworkCacheByteLength = 64 * 1_024 * 1_024
    private static let maximumArtworkCacheEntries = 192
    private static let artworkCacheLifetime: TimeInterval = 300
    // A poster wall must never occupy the limited upstream capacity that feeds
    // an active video. Keeping the budgets separate preserves artwork back
    // pressure without turning image decoding into a playback stall.
    private static let mediaRequestSlots = DispatchSemaphore(value: 4)
    // 封面并发从 2 提到 8。两类槽位本来就是**互相独立**的信号量，图片再多也占不到
    // 媒体的 4 路，因此 2 这个值保护的其实不是播放，只是把海报墙硬生生排成了
    // 十几轮串行往返（实测 24 张需要 13.1 轮）。一张封面是一次短往返，8 路对
    // 家用 NAS/Emby 仍然温和，却把墙的等待压到约 3 轮。
    private static let artworkRequestSlots = DispatchSemaphore(value: 8)

    // 单个 Range 允许的最长空闲间隔与总时长。空闲计时随每个已到达的分块重置：
    // 弱网上一段仍在稳定推进的 16 MiB 传输不应因为"总时长超过一次请求超时"
    // 而被服务端主动切断，那会把可恢复的慢速播放变成播放失败。
    private static let upstreamIdleTimeout: TimeInterval = 25
    private static let maximumSingleRangeDuration: TimeInterval = 600

    private let sessionPool: RemoteUpstreamSessionPool
    private let telemetry: ServerPlaybackTelemetry
    private let responseOverride: ((URL, Int64?, Int64?) -> Data?)?
    private let mediaLengthOverride: ((URL) -> Int64?)?
    private let artworkCacheLock = NSLock()
    private var artworkCache: [String: (data: Data, expiresAt: Date)] = [:]
    private var artworkCacheOrder: [String] = []
    private var mediaLengthCache: [String: (length: Int64, expiresAt: Date)] = [:]
    // A <video> element often issues several early Range requests in parallel.
    // When the upstream source did not provide a length, make those requests
    // share one `bytes=0-0` probe instead of competing for media slots.
    private var mediaLengthProbes: [String: DispatchGroup] = [:]
    // 海报墙、首页与详情页可能在同一瞬间引用同一张封面。没有合并时它们会各自
    // 占一个上游槽位，把真正不同的封面挤到后面——实测同一张图的 12 个并发请求
    // 产生了 12 次上游取图。
    private var artworkFetches: [String: DispatchGroup] = [:]

    init(
        sessionPool: RemoteUpstreamSessionPool = .shared,
        telemetry: ServerPlaybackTelemetry = .shared,
        responseOverride: ((URL, Int64?, Int64?) -> Data?)? = nil,
        mediaLengthOverride: ((URL) -> Int64?)? = nil
    ) {
        self.sessionPool = sessionPool
        self.telemetry = telemetry
        self.responseOverride = responseOverride
        self.mediaLengthOverride = mediaLengthOverride
    }

    func mediaBytes(url: URL, offset: Int64, length: Int64) -> Data? {
        var result = Data()
        guard streamMediaBytes(url: url, offset: offset, length: length, consume: { chunk in
            result.append(chunk)
            return true
        }) else { return nil }
        return result
    }

    /// Streams one exact, already-authorized remote byte range. The body is
    /// delivered in small chunks directly to the local client socket, so a
    /// 16 MiB browser Range never becomes a 16 MiB server `Data` allocation.
    /// The consumer can stop early when the browser disconnects.
    func streamMediaBytes(
        url: URL,
        offset: Int64,
        length: Int64,
        cancellation: Cancellation? = nil,
        consume: @escaping (Data) -> Bool
    ) -> Bool {
        // Keep the complete Range arithmetic representable before interpolating
        // it into a header. Callers normally resolve against a known entity
        // length, but this boundary must still fail closed for direct/internal
        // calls near Int64.max instead of trapping on `offset + length - 1`.
        guard cancellation?.isCancelled != true,
              offset >= 0,
              length > 0,
              length <= Int64(Self.maximumMediaRangeByteLength),
              // A representable entity length must be at least
              // `offset + length`; reject even a one-byte range starting at
              // Int64.max because no Int64 total can contain that byte.
              offset <= Int64.max - length
        else {
            return false
        }
        if let responseOverride {
            guard let data = responseOverride(url, offset, length), data.count == Int(length) else {
                return false
            }
            var start = 0
            while start < data.count {
                guard cancellation?.isCancelled != true else { return false }
                let end = min(start + Self.mediaTransferChunkLength, data.count)
                guard consume(data.subdata(in: start..<end)) else { return false }
                start = end
            }
            return true
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 25
        request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
        return stream(
            request,
            expectedOrigin: url,
            expectedOffset: offset,
            expectedLength: length,
            cancellation: cancellation,
            consume: consume
        )
    }

    /// 当同步方未给出文件大小时，以单字节 Range 探测上游总长度。浏览器从未得到
    /// 此 URL 或响应头；结果只保留在服务端短缓存中，用来构造同源 Content-Range。
    func mediaByteLength(url: URL) -> Int64? {
        let cacheKey = Self.artworkCacheKey(for: url)
        if let cached = cachedMediaLength(for: cacheKey) { return cached }

        let probe: DispatchGroup
        let shouldProbe: Bool
        artworkCacheLock.lock()
        if let entry = mediaLengthCache[cacheKey], entry.expiresAt > Date() {
            artworkCacheLock.unlock()
            return entry.length
        }
        mediaLengthCache.removeValue(forKey: cacheKey)
        if let existingProbe = mediaLengthProbes[cacheKey] {
            probe = existingProbe
            shouldProbe = false
        } else {
            probe = DispatchGroup()
            probe.enter()
            mediaLengthProbes[cacheKey] = probe
            shouldProbe = true
        }
        artworkCacheLock.unlock()

        guard shouldProbe else {
            guard probe.wait(timeout: .now() + 13) == .success else { return nil }
            return cachedMediaLength(for: cacheKey)
        }
        defer {
            artworkCacheLock.lock()
            mediaLengthProbes.removeValue(forKey: cacheKey)
            artworkCacheLock.unlock()
            probe.leave()
        }

        let total: Int64?
        if let mediaLengthOverride {
            total = mediaLengthOverride(url)
        } else {
            total = probedMediaByteLength(url: url)
        }
        guard let total, total > 0 else { return nil }
        cacheMediaLength(total, for: cacheKey)
        return total
    }

    private func probedMediaByteLength(url: URL) -> Int64? {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        request.setValue("bytes=0-0", forHTTPHeaderField: "Range")
        guard let response = performResponse(
            request,
            expectedOrigin: url,
            maximumByteLength: 1,
            expectedLength: 1,
            requestClass: .media
        ),
        response.http.statusCode == 206,
        let header = response.http.value(forHTTPHeaderField: "Content-Range"),
        let total = Self.totalLength(fromContentRange: header),
        total > 0
        else { return nil }
        return total
    }

    func artworkBytes(url: URL) -> Data? {
        if let responseOverride { return responseOverride(url, nil, nil) }
        let cacheKey = Self.artworkCacheKey(for: url)
        if let cached = cachedArtwork(for: cacheKey) { return cached }

        // 同一张封面的并发请求合并为一次上游取图，其余等待者复用结果。
        let fetch: DispatchGroup
        let shouldFetch: Bool
        artworkCacheLock.lock()
        if let cached = artworkCache[cacheKey], cached.expiresAt > Date() {
            artworkCacheLock.unlock()
            return cached.data
        }
        if let existing = artworkFetches[cacheKey] {
            fetch = existing
            shouldFetch = false
        } else {
            fetch = DispatchGroup()
            fetch.enter()
            artworkFetches[cacheKey] = fetch
            shouldFetch = true
        }
        artworkCacheLock.unlock()

        guard shouldFetch else {
            guard fetch.wait(timeout: .now() + 13) == .success else { return nil }
            return cachedArtwork(for: cacheKey)
        }
        defer {
            artworkCacheLock.lock()
            artworkFetches.removeValue(forKey: cacheKey)
            artworkCacheLock.unlock()
            fetch.leave()
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        guard let data = perform(
            request,
            expectedOrigin: url,
            maximumByteLength: Self.maximumArtworkByteLength,
            expectedLength: nil,
            requestClass: .artwork
        ) else { return nil }
        cacheArtwork(data, for: cacheKey)
        return data
    }

    /// 一次有界的远程**元数据/文本**读取：字幕轨清单与字幕正文走这里。
    ///
    /// 合并、缓存与队列由上层按资源修订处理；这里负责上游读取的严格大小、origin、
    /// 超时与主动取消。它共用封面槽位，因此字幕不会挤掉播放用的 4 路媒体槽。
    func metadataBytes(
        url: URL,
        maximumByteLength: Int,
        accept: String? = nil,
        cancellation: Cancellation? = nil
    ) -> Data? {
        guard cancellation?.isCancelled != true else { return nil }
        if let responseOverride { return responseOverride(url, nil, nil) }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 12
        if let accept { request.setValue(accept, forHTTPHeaderField: "Accept") }
        return perform(
            request,
            expectedOrigin: url,
            maximumByteLength: maximumByteLength,
            expectedLength: nil,
            requestClass: .artwork,
            cancellation: cancellation
        )
    }

    private func perform(
        _ request: URLRequest,
        expectedOrigin: URL,
        maximumByteLength: Int,
        expectedLength: Int?,
        requestClass: RequestClass,
        cancellation: Cancellation? = nil
    ) -> Data? {
        performResponse(
            request,
            expectedOrigin: expectedOrigin,
            maximumByteLength: maximumByteLength,
            expectedLength: expectedLength,
            requestClass: requestClass,
            cancellation: cancellation
        )?.data
    }

    private func performResponse(
        _ request: URLRequest,
        expectedOrigin: URL,
        maximumByteLength: Int,
        expectedLength: Int?,
        requestClass: RequestClass,
        cancellation: Cancellation? = nil
    ) -> (data: Data, http: HTTPURLResponse)? {
        // 所有浏览器可见图片和媒体块共享小型全局并发上限：不能让一页几十张
        // 海报同时淹没上游服务器，也避免占满本地服务线程。
        let slots = Self.slots(for: requestClass)
        guard Self.waitForSlot(
            slots,
            timeout: request.timeoutInterval,
            cancellation: cancellation
        ) else { return nil }
        defer { slots.signal() }
        // 会话按 origin 复用：连续的封面或长度探测不再各自重做一次 TCP/TLS 握手。
        let session = sessionPool.session(for: expectedOrigin).session

        let completion = DispatchSemaphore(value: 0)
        let result = ServerRemoteResponseBox()
        let task = session.dataTask(with: request) { data, response, error in
            result.store(data: data, response: response, error: error)
            completion.signal()
        }
        guard cancellation?.bind(task) ?? true else { return nil }
        defer { cancellation?.unbind(task) }
        task.resume()
        guard Self.waitForCompletion(
            completion,
            task: task,
            timeout: request.timeoutInterval + 1,
            cancellation: cancellation
        ),
              let (data, response) = result.value,
              let http = response as? HTTPURLResponse,
              Self.sameOrigin(http.url, expectedOrigin),
              (200...299).contains(http.statusCode),
              data.count > 0,
              data.count <= maximumByteLength,
              expectedLength.map({ data.count == $0 }) ?? true
        else { return nil }
        return (data, http)
    }

    private static func waitForSlot(
        _ slots: DispatchSemaphore,
        timeout: TimeInterval,
        cancellation: Cancellation?
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            guard cancellation?.isCancelled != true else { return false }
            if slots.wait(timeout: .now() + 0.05) == .success { return true }
        } while Date() < deadline
        return false
    }

    private static func waitForCompletion(
        _ completion: DispatchSemaphore,
        task: URLSessionTask,
        timeout: TimeInterval,
        cancellation: Cancellation?
    ) -> Bool {
        let deadline = Date().addingTimeInterval(max(0, timeout))
        repeat {
            if completion.wait(timeout: .now() + 0.05) == .success {
                return cancellation?.isCancelled != true
            }
            if cancellation?.isCancelled == true {
                task.cancel()
                return false
            }
        } while Date() < deadline
        task.cancel()
        return false
    }

    private func stream(
        _ request: URLRequest,
        expectedOrigin: URL,
        expectedOffset: Int64,
        expectedLength: Int64,
        cancellation: Cancellation?,
        consume: @escaping (Data) -> Bool
    ) -> Bool {
        let telemetry = self.telemetry
        let startedAt = Date()
        telemetry.rangeBegan()
        defer { telemetry.rangeEnded() }

        let slots = Self.mediaRequestSlots
        guard Self.waitForSlot(
            slots,
            timeout: request.timeoutInterval,
            cancellation: cancellation
        ) else {
            let outcome: ServerRangeOutcome = cancellation?.isCancelled == true
                ? .clientDisconnected
                : .upstreamStalled
            telemetry.recordRange(
                source: .remoteUpstream,
                requestedByteLength: expectedLength,
                deliveredByteLength: 0,
                outcome: outcome,
                upstreamTimeToFirstByte: nil,
                totalDuration: Date().timeIntervalSince(startedAt)
            )
            return false
        }
        defer { slots.signal() }

        let handler = StreamingMediaHandler(
            expectedOrigin: expectedOrigin,
            expectedOffset: expectedOffset,
            expectedLength: expectedLength,
            consume: { chunk in
                // 缓冲计量按"分块进入服务端 → 写完客户端"配对，因此峰值反映的是
                // 真实同时驻留的字节，不是累计流量。
                telemetry.acquiredBuffer(chunk.count)
                defer { telemetry.releasedBuffer(chunk.count) }
                return consume(chunk)
            }
        )
        let pooled = sessionPool.session(for: expectedOrigin)
        let task = pooled.session.dataTask(with: request)
        // 先登记再 resume：委托回调按 taskIdentifier 派发，晚一步登记会丢首个分块。
        pooled.delegate.register(handler, for: task.taskIdentifier)
        defer { pooled.delegate.unregister(task.taskIdentifier) }
        guard cancellation?.bind(task) ?? true else {
            telemetry.recordRange(
                source: .remoteUpstream,
                requestedByteLength: expectedLength,
                deliveredByteLength: 0,
                outcome: .clientDisconnected,
                upstreamTimeToFirstByte: nil,
                totalDuration: Date().timeIntervalSince(startedAt)
            )
            return false
        }
        defer { cancellation?.unbind(task) }
        task.resume()
        let finished = Self.waitForStreamCompletion(
            handler: handler,
            task: task,
            cancellation: cancellation
        )
        let succeeded = finished && handler.succeeded
        let wasCancelled = cancellation?.isCancelled == true
        telemetry.recordRange(
            source: .remoteUpstream,
            requestedByteLength: expectedLength,
            deliveredByteLength: handler.deliveredByteLength,
            outcome: handler.succeeded
                ? .completed
                : (wasCancelled ? .clientDisconnected : (finished ? handler.outcome : .upstreamStalled)),
            upstreamTimeToFirstByte: handler.timeToFirstByte,
            totalDuration: Date().timeIntervalSince(startedAt)
        )
        return succeeded
    }

    /// 只在上游**完全没有推进**时才放弃。固定的"总时长 = 一次请求超时"会把
    /// 慢但健康的大 Range 判成失败，浏览器随后只能整段重试，反而更慢。
    private static func waitForStreamCompletion(
        handler: StreamingMediaHandler,
        task: URLSessionDataTask,
        cancellation: Cancellation?
    ) -> Bool {
        let startedAt = Date()
        while true {
            if handler.completed.wait(timeout: .now() + 0.05) == .success {
                return cancellation?.isCancelled != true
            }
            if cancellation?.isCancelled == true {
                task.cancel()
                // The delegate owns callbacks until completion. Wait briefly
                // after cancellation so unregistering cannot release a handler
                // while URLSession is still delivering its terminal callback.
                _ = handler.completed.wait(timeout: .now() + 5)
                return false
            }
            let now = Date()
            guard handler.secondsSinceProgress(now: now) <= upstreamIdleTimeout,
                  now.timeIntervalSince(startedAt) <= maximumSingleRangeDuration
            else {
                task.cancel()
                // 取消后仍要等委托的完成回调，否则 handler 可能在回调途中被释放。
                _ = handler.completed.wait(timeout: .now() + 5)
                return false
            }
        }
    }

    private enum RequestClass {
        case media
        case artwork
    }

    private static func slots(for requestClass: RequestClass) -> DispatchSemaphore {
        switch requestClass {
        case .media: return mediaRequestSlots
        case .artwork: return artworkRequestSlots
        }
    }

    private func cachedArtwork(for key: String) -> Data? {
        artworkCacheLock.lock()
        defer { artworkCacheLock.unlock() }
        guard let entry = artworkCache[key], entry.expiresAt > Date() else {
            artworkCache.removeValue(forKey: key)
            artworkCacheOrder.removeAll { $0 == key }
            return nil
        }
        artworkCacheOrder.removeAll { $0 == key }
        artworkCacheOrder.append(key)
        return entry.data
    }

    private func cachedMediaLength(for key: String) -> Int64? {
        artworkCacheLock.lock()
        defer { artworkCacheLock.unlock() }
        guard let entry = mediaLengthCache[key], entry.expiresAt > Date() else {
            mediaLengthCache.removeValue(forKey: key)
            return nil
        }
        return entry.length
    }

    private func cacheMediaLength(_ length: Int64, for key: String) {
        artworkCacheLock.lock()
        defer { artworkCacheLock.unlock() }
        mediaLengthCache[key] = (length, Date().addingTimeInterval(Self.artworkCacheLifetime))
    }

    private func cacheArtwork(_ data: Data, for key: String) {
        artworkCacheLock.lock()
        defer { artworkCacheLock.unlock() }
        artworkCache[key] = (data, Date().addingTimeInterval(Self.artworkCacheLifetime))
        artworkCacheOrder.removeAll { $0 == key }
        artworkCacheOrder.append(key)
        var byteLength = artworkCache.values.reduce(0) { $0 + $1.data.count }
        while artworkCache.count > Self.maximumArtworkCacheEntries || byteLength > Self.maximumArtworkCacheByteLength {
            guard let oldest = artworkCacheOrder.first else { break }
            artworkCacheOrder.removeFirst()
            byteLength -= artworkCache.removeValue(forKey: oldest)?.data.count ?? 0
        }
    }

    private static func artworkCacheKey(for url: URL) -> String {
        SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private static func totalLength(fromContentRange value: String) -> Int64? {
        // 仅接受 RFC 7233 单一区间格式 `bytes 0-0/12345`；没有总长度或异常值时
        // 保守失败，绝不猜测大小并把 Range 代理变成无界下载。
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0].trimmingCharacters(in: .whitespaces).hasPrefix("bytes 0-0"),
              !pieces[1].isEmpty,
              pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let length = Int64(pieces[1])
        else { return nil }
        return length
    }

    static func sameOrigin(_ lhs: URL?, _ rhs: URL) -> Bool {
        guard let lhs,
              let left = URLComponents(url: lhs, resolvingAgainstBaseURL: false),
              let right = URLComponents(url: rhs, resolvingAgainstBaseURL: false),
              left.scheme?.caseInsensitiveCompare(right.scheme ?? "") == .orderedSame,
              left.host?.caseInsensitiveCompare(right.host ?? "") == .orderedSame
        else { return false }
        let leftPort = left.port ?? (left.scheme?.lowercased() == "https" ? 443 : 80)
        let rightPort = right.port ?? (right.scheme?.lowercased() == "https" ? 443 : 80)
        return leftPort == rightPort
    }
}

/// 一个上游 origin 一组连接。此前每个 Range 都新建并 `invalidateAndCancel` 一个
/// ephemeral 会话，等于让浏览器的每次 seek 都重付一次 TCP + TLS 握手；池化后
/// 同一 NAS/Emby 的连续 Range 复用既有连接，同时保持"永不跟随重定向"的边界。
final class RemoteUpstreamSessionPool: @unchecked Sendable {
    static let shared = RemoteUpstreamSessionPool()

    typealias Pooled = (session: URLSession, delegate: UpstreamSessionDelegate)

    /// 每个 origin 的连接上限。媒体槽 4 + 图片槽 8，因此 12 条让所有允许并发的
    /// 请求各占一条，而不会对家用 NAS 打开过多连接。
    ///
    /// 这里从前是 6，注释还写着"图片槽为 2"——图片槽后来提到了 8，连接数没跟上。
    /// 于是 8 路并发取图挤在 6 条连接里，还要和正在播放的 Range 抢：把海报墙的
    /// 并发上限从 8 悄悄压回了不到 6，而这正是上一轮提槽位想解决的事。
    private static let maximumConnectionsPerHost = 12
    private static let maximumPooledOrigins = 8
    /// 会话级资源上限只用来兜底：单个 Range 的真实判定在 `waitForStreamCompletion`
    /// 的空闲计时里，这里给出的是绝不允许超过的天花板。
    private static let resourceTimeout: TimeInterval = 900

    private let lock = NSLock()
    private var sessions: [String: Pooled] = [:]
    private var order: [String] = []

    func session(for url: URL) -> Pooled {
        let key = Self.originKey(for: url)
        lock.lock()
        defer { lock.unlock() }
        if let existing = sessions[key] {
            order.removeAll { $0 == key }
            order.append(key)
            return existing
        }
        let delegate = UpstreamSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForResource = Self.resourceTimeout
        configuration.httpMaximumConnectionsPerHost = Self.maximumConnectionsPerHost
        let pooled: Pooled = (
            URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil),
            delegate
        )
        sessions[key] = pooled
        order.append(key)
        while order.count > Self.maximumPooledOrigins {
            let oldest = order.removeFirst()
            // `finishTasksAndInvalidate` 不会打断仍在传输的 Range；被淘汰的
            // origin 只是不再接受新请求。
            sessions.removeValue(forKey: oldest)?.session.finishTasksAndInvalidate()
        }
        return pooled
    }

    private static func originKey(for url: URL) -> String {
        let scheme = url.scheme?.lowercased() ?? ""
        let host = url.host?.lowercased() ?? ""
        let port = url.port ?? (scheme == "https" ? 443 : 80)
        return "\(scheme)://\(host):\(port)"
    }
}

/// 池化会话的共享委托。它按 `taskIdentifier` 把数据回调派发给登记的流式处理器，
/// 并对**所有**任务（含带 completion handler 的图片与探测请求）拒绝重定向。
/// URLSession completes on a delegate queue. Keeping its result behind a lock
/// avoids publishing callback-owned values through unsynchronised stack vars
/// when a timeout/cancellation races completion.
private final class ServerRemoteResponseBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: (Data, URLResponse)?

    var value: (Data, URLResponse)? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }

    func store(data: Data?, response: URLResponse?, error: Error?) {
        lock.lock()
        if error == nil, let data, let response {
            stored = (data, response)
        } else {
            stored = nil
        }
        lock.unlock()
    }
}

final class UpstreamSessionDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var handlers: [Int: StreamingMediaHandler] = [:]

    fileprivate func register(_ handler: StreamingMediaHandler, for taskIdentifier: Int) {
        lock.lock()
        handlers[taskIdentifier] = handler
        lock.unlock()
    }

    fileprivate func unregister(_ taskIdentifier: Int) {
        lock.lock()
        handlers.removeValue(forKey: taskIdentifier)
        lock.unlock()
    }

    private func handler(for taskIdentifier: Int) -> StreamingMediaHandler? {
        lock.lock()
        defer { lock.unlock() }
        return handlers[taskIdentifier]
    }

    func urlSession(
        _ session: URLSession,
        dataTask: URLSessionDataTask,
        didReceive response: URLResponse,
        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
    ) {
        guard let handler = handler(for: dataTask.taskIdentifier) else {
            completionHandler(.allow)
            return
        }
        completionHandler(handler.accept(response) ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        guard let handler = handler(for: dataTask.taskIdentifier) else { return }
        if !handler.receive(data) { dataTask.cancel() }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        handler(for: task.taskIdentifier)?.finish(error: error)
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // 即使跳回同一来源也不自动追随：上游 URL 已包含凭据，显式失败比在
        // 重定向链中保留凭据更容易审计，也不会把 token 外发给别的 origin。
        completionHandler(nil)
    }
}

final class StreamingMediaHandler {
    let completed = DispatchSemaphore(value: 0)
    private let expectedOrigin: URL
    private let expectedOffset: Int64
    private let expectedLength: Int64
    private let consume: (Data) -> Bool
    private let stateLock = NSLock()
    private var receivedLength: Int64 = 0
    private var acceptedResponse = false
    private var failed = false
    private var lastProgressAt = Date()
    private let startedAt = Date()
    private var firstByteAt: Date?
    private var failureOutcome: ServerRangeOutcome?

    init(
        expectedOrigin: URL,
        expectedOffset: Int64,
        expectedLength: Int64,
        consume: @escaping (Data) -> Bool
    ) {
        self.expectedOrigin = expectedOrigin
        self.expectedOffset = expectedOffset
        self.expectedLength = expectedLength
        self.consume = consume
    }

    var succeeded: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return acceptedResponse && !failed && receivedLength == expectedLength
    }

    func secondsSinceProgress(now: Date) -> TimeInterval {
        stateLock.lock()
        defer { stateLock.unlock() }
        return now.timeIntervalSince(lastProgressAt)
    }

    var deliveredByteLength: Int64 {
        stateLock.lock()
        defer { stateLock.unlock() }
        return receivedLength
    }

    /// 上游响应头到达的耗时。只有真正收到并接受了响应才有值。
    var timeToFirstByte: TimeInterval? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return firstByteAt.map { $0.timeIntervalSince(startedAt) }
    }

    var outcome: ServerRangeOutcome {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let failureOutcome { return failureOutcome }
        if failed { return .transportFailed }
        return receivedLength == expectedLength ? .completed : .transportFailed
    }

    /// 严格校验上游确实返回了 `206` 与请求一致的 `Content-Range`。上游忽略
    /// Range 而回 `200` 整片时在这里失败，不会悄悄变成整片下载。
    func accept(_ response: URLResponse) -> Bool {
        let http = response as? HTTPURLResponse
        // 分开判定状态码与 Content-Range，否则"上游忽略 Range 回 200"和
        // "上游返回了另一段字节"会记成同一个原因，排障时无从区分。
        guard let http, http.statusCode == 206,
              ServerRemoteAssetFetcher.sameOrigin(http.url, expectedOrigin)
        else {
            stateLock.lock()
            failed = true
            failureOutcome = .upstreamRejected
            stateLock.unlock()
            return false
        }
        guard Self.matchesExpectedRange(
            http.value(forHTTPHeaderField: "Content-Range"),
            offset: expectedOffset,
            length: expectedLength
        ) else {
            stateLock.lock()
            failed = true
            failureOutcome = .contentRangeMismatch
            stateLock.unlock()
            return false
        }
        stateLock.lock()
        acceptedResponse = true
        firstByteAt = Date()
        lastProgressAt = Date()
        stateLock.unlock()
        return true
    }

    func receive(_ data: Data) -> Bool {
        stateLock.lock()
        let mayConsume = acceptedResponse && !failed && receivedLength + Int64(data.count) <= expectedLength
        stateLock.unlock()
        guard mayConsume else {
            stateLock.lock()
            failed = true
            failureOutcome = .contentRangeMismatch
            stateLock.unlock()
            return false
        }
        guard consume(data) else {
            // 消费者拒绝写入只意味着客户端 socket 已经走了（换集、seek、关页面），
            // 这是正常终止而不是故障，混进故障计数会让告警永远在响。
            stateLock.lock()
            failed = true
            failureOutcome = .clientDisconnected
            stateLock.unlock()
            return false
        }
        stateLock.lock()
        receivedLength += Int64(data.count)
        lastProgressAt = Date()
        stateLock.unlock()
        return true
    }

    func finish(error: Error?) {
        if error != nil {
            stateLock.lock()
            failed = true
            stateLock.unlock()
        }
        completed.signal()
    }

    private static func matchesExpectedRange(_ value: String?, offset: Int64, length: Int64) -> Bool {
        guard let value else { return false }
        let expectedRange = "bytes \(offset)-\(offset + length - 1)"
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0].trimmingCharacters(in: .whitespacesAndNewlines) == expectedRange,
              !pieces[1].isEmpty,
              pieces[1].allSatisfy({ $0.isASCII && $0.isNumber }),
              let totalLength = Int64(pieces[1])
        else { return false }
        return totalLength >= offset + length
    }
}
