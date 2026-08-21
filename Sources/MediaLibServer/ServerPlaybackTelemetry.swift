import Foundation
import MediaLibServerProtocol

/// 播放热路径的聚合遥测。
///
/// 设计上只有一个数据出口：`snapshot()` 返回的计数、分桶与分位数。记录接口
/// **不接受**媒体 ID、路径、上游 URL、token、用户或客户端地址，因此"不记录敏感
/// 信息"不是靠调用方自觉，而是类型上就传不进来。
///
/// 之所以要在服务端量而不是只靠浏览器量：`waiting`/`stalled` 在页面里看得到，
/// 但看不到它是被上游 TTFB、槽位排队还是本地磁盘拖住的。两侧的数字合在一起才
/// 能定位，单独任何一侧都只能猜。
final class ServerPlaybackTelemetry: @unchecked Sendable {
    static let shared = ServerPlaybackTelemetry()

    /// 分位数需要样本，但样本不能无限增长。保留最近 512 个：足够稳定地估计
    /// p50/p95，又不会让长时间运行的服务把内存耗在遥测上。
    private static let maximumLatencySamples = 512

    private let lock = NSLock()
    private var startedAt = Date()
    private var localRangeCount = 0
    private var remoteRangeCount = 0
    private var deliveredByteCount: Int64 = 0
    private var rangeSizeBuckets: [ServerRangeSizeBucket: Int] = [:]
    private var outcomes: [ServerRangeOutcome: Int] = [:]
    private var transportReasons: [ServerMediaTransportReason: Int] = [:]
    private var upstreamTTFBSamples: [Int] = []
    private var rangeCompletionSamples: [Int] = []
    private var bufferedBytes = 0
    private var peakBufferedBytes = 0
    private var activeRanges = 0
    private var peakActiveRanges = 0

    enum Source {
        case localFile
        case remoteUpstream
    }

    /// 一次 Range 的完整记录。调用方在传输结束后调用一次。
    func recordRange(
        source: Source,
        requestedByteLength: Int64,
        deliveredByteLength: Int64,
        outcome: ServerRangeOutcome,
        upstreamTimeToFirstByte: TimeInterval?,
        totalDuration: TimeInterval
    ) {
        lock.lock()
        defer { lock.unlock() }
        switch source {
        case .localFile: localRangeCount += 1
        case .remoteUpstream: remoteRangeCount += 1
        }
        deliveredByteCount += max(0, deliveredByteLength)
        rangeSizeBuckets[ServerRangeSizeBucket(byteLength: requestedByteLength), default: 0] += 1
        outcomes[outcome, default: 0] += 1
        if let upstreamTimeToFirstByte {
            append(&upstreamTTFBSamples, milliseconds(upstreamTimeToFirstByte))
        }
        append(&rangeCompletionSamples, milliseconds(totalDuration))
    }

    /// 播放通路的选择原因。它解释"为什么这次是代理"，不涉及是哪一个条目。
    func recordTransportReason(_ reason: ServerMediaTransportReason) {
        lock.lock()
        transportReasons[reason, default: 0] += 1
        lock.unlock()
    }

    /// 分块进入服务端缓冲。与 `releasedBuffer` 成对调用，用来观测"同时持有多少
    /// 媒体字节"——这是内存随并发有上限的直接证据，而不是从代码推断的结论。
    func acquiredBuffer(_ byteCount: Int) {
        lock.lock()
        bufferedBytes += byteCount
        peakBufferedBytes = max(peakBufferedBytes, bufferedBytes)
        lock.unlock()
    }

    func releasedBuffer(_ byteCount: Int) {
        lock.lock()
        bufferedBytes = max(0, bufferedBytes - byteCount)
        lock.unlock()
    }

    func rangeBegan() {
        lock.lock()
        activeRanges += 1
        peakActiveRanges = max(peakActiveRanges, activeRanges)
        lock.unlock()
    }

    func rangeEnded() {
        lock.lock()
        activeRanges = max(0, activeRanges - 1)
        lock.unlock()
    }

    func snapshot(now: Date = Date()) -> ServerPlaybackTelemetrySnapshot {
        lock.lock()
        defer { lock.unlock() }
        return ServerPlaybackTelemetrySnapshot(
            windowSeconds: max(0, Int(now.timeIntervalSince(startedAt))),
            localRangeCount: localRangeCount,
            remoteRangeCount: remoteRangeCount,
            deliveredByteCount: deliveredByteCount,
            rangeSizeBuckets: rangeSizeBuckets,
            outcomes: outcomes,
            upstreamTimeToFirstByte: Self.summarize(upstreamTTFBSamples),
            rangeCompletion: Self.summarize(rangeCompletionSamples),
            peakConcurrentBufferedBytes: peakBufferedBytes,
            peakConcurrentRanges: peakActiveRanges,
            transportReasons: transportReasons
        )
    }

    /// 压测与验收脚本需要一个干净的观测窗口，否则前一轮的数据会污染本轮结论。
    func reset(now: Date = Date()) {
        lock.lock()
        startedAt = now
        localRangeCount = 0
        remoteRangeCount = 0
        deliveredByteCount = 0
        rangeSizeBuckets = [:]
        outcomes = [:]
        transportReasons = [:]
        upstreamTTFBSamples = []
        rangeCompletionSamples = []
        bufferedBytes = 0
        peakBufferedBytes = 0
        activeRanges = 0
        peakActiveRanges = 0
        lock.unlock()
    }

    private func append(_ samples: inout [Int], _ value: Int) {
        samples.append(value)
        if samples.count > Self.maximumLatencySamples {
            samples.removeFirst(samples.count - Self.maximumLatencySamples)
        }
    }

    private func milliseconds(_ interval: TimeInterval) -> Int {
        guard interval.isFinite, interval > 0 else { return 0 }
        return Int((interval * 1_000).rounded())
    }

    private static func summarize(_ samples: [Int]) -> ServerLatencySummary {
        guard !samples.isEmpty else { return .empty }
        let sorted = samples.sorted()
        let p50Index = min(sorted.count - 1, sorted.count / 2)
        let p95Index = min(sorted.count - 1, Int((Double(sorted.count) * 0.95).rounded(.down)))
        return ServerLatencySummary(
            sampleCount: sorted.count,
            p50Milliseconds: sorted[p50Index],
            p95Milliseconds: sorted[p95Index],
            maximumMilliseconds: sorted[sorted.count - 1]
        )
    }
}
