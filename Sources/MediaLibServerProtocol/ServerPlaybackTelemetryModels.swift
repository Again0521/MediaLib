import Foundation

/// 一次 Range 读取的结束原因。它是策略/故障分类，不是消息文本，
/// 因此不会随媒体、账号或上游地址变化。
public enum ServerRangeOutcome: String, Codable, Equatable, Sendable, CaseIterable {
    /// 请求的字节全部送达客户端。
    case completed
    /// 客户端提前断开（换集、seek、关页面），服务端随即停止读取上游。
    case clientDisconnected
    /// 上游状态码不是 206，或忽略了 Range。
    case upstreamRejected
    /// 上游 `Content-Range` 与请求的区间不一致。
    case contentRangeMismatch
    /// 上游在空闲超时内没有推进任何字节。
    case upstreamStalled
    /// 传输层错误或本地读取失败。
    case transportFailed
}

/// Range 大小的固定分桶。用固定桶而不是原始尺寸列表，是为了让遥测天然聚合：
/// 单条记录无法反推具体是哪个媒体的哪一次读取。
public enum ServerRangeSizeBucket: String, Codable, Equatable, Sendable, CaseIterable {
    case upTo64KiB
    case upTo256KiB
    case upTo1MiB
    case upTo4MiB
    case upTo16MiB

    public init(byteLength: Int64) {
        switch byteLength {
        case ..<65_537: self = .upTo64KiB
        case ..<262_145: self = .upTo256KiB
        case ..<1_048_577: self = .upTo1MiB
        case ..<4_194_305: self = .upTo4MiB
        default: self = .upTo16MiB
        }
    }
}

/// 一组延迟样本的聚合形态。只保留计数与分位数，不保留逐次样本，
/// 因此无法从中还原单次播放的时间线。
public struct ServerLatencySummary: Codable, Equatable, Sendable {
    public let sampleCount: Int
    public let p50Milliseconds: Int
    public let p95Milliseconds: Int
    public let maximumMilliseconds: Int

    public init(sampleCount: Int, p50Milliseconds: Int, p95Milliseconds: Int, maximumMilliseconds: Int) {
        self.sampleCount = sampleCount
        self.p50Milliseconds = p50Milliseconds
        self.p95Milliseconds = p95Milliseconds
        self.maximumMilliseconds = maximumMilliseconds
    }

    public static let empty = ServerLatencySummary(
        sampleCount: 0, p50Milliseconds: 0, p95Milliseconds: 0, maximumMilliseconds: 0
    )
}

/// 服务端播放热路径的聚合遥测快照。
///
/// 刻意不包含、也无法包含：媒体 ID、标题、文件路径、上游 URL、上游 token、
/// 用户、设备、会话与客户端地址。它回答的是"代理整体表现如何"，不是
/// "谁在什么时候看了什么"。
public struct ServerPlaybackTelemetrySnapshot: Codable, Equatable, Sendable {
    /// 自进程启动（或上次重置）以来的观测窗口秒数。
    public let windowSeconds: Int
    /// 本地/网络挂载文件的 Range 读取次数。
    public let localRangeCount: Int
    /// 已授权远程上游的 Range 读取次数。
    public let remoteRangeCount: Int
    /// 送达客户端的总字节数。
    public let deliveredByteCount: Int64
    /// Range 大小分布。
    public let rangeSizeBuckets: [ServerRangeSizeBucket: Int]
    /// 结束原因分布。
    public let outcomes: [ServerRangeOutcome: Int]
    /// 远程上游从发出请求到收到响应头的耗时（TTFB）。
    public let upstreamTimeToFirstByte: ServerLatencySummary
    /// 单次 Range 的整体完成耗时。
    public let rangeCompletion: ServerLatencySummary
    /// 服务端在任一时刻同时持有的媒体字节峰值。这是"内存随并发有上限"的直接证据。
    public let peakConcurrentBufferedBytes: Int
    /// 同时在传输中的 Range 数量峰值。
    public let peakConcurrentRanges: Int
    /// 播放通路选择原因的计数。
    public let transportReasons: [ServerMediaTransportReason: Int]

    public init(
        windowSeconds: Int,
        localRangeCount: Int,
        remoteRangeCount: Int,
        deliveredByteCount: Int64,
        rangeSizeBuckets: [ServerRangeSizeBucket: Int],
        outcomes: [ServerRangeOutcome: Int],
        upstreamTimeToFirstByte: ServerLatencySummary,
        rangeCompletion: ServerLatencySummary,
        peakConcurrentBufferedBytes: Int,
        peakConcurrentRanges: Int,
        transportReasons: [ServerMediaTransportReason: Int]
    ) {
        self.windowSeconds = windowSeconds
        self.localRangeCount = localRangeCount
        self.remoteRangeCount = remoteRangeCount
        self.deliveredByteCount = deliveredByteCount
        self.rangeSizeBuckets = rangeSizeBuckets
        self.outcomes = outcomes
        self.upstreamTimeToFirstByte = upstreamTimeToFirstByte
        self.rangeCompletion = rangeCompletion
        self.peakConcurrentBufferedBytes = peakConcurrentBufferedBytes
        self.peakConcurrentRanges = peakConcurrentRanges
        self.transportReasons = transportReasons
    }

    private enum CodingKeys: String, CodingKey {
        case windowSeconds, localRangeCount, remoteRangeCount, deliveredByteCount
        case rangeSizeBuckets, outcomes, upstreamTimeToFirstByte, rangeCompletion
        case peakConcurrentBufferedBytes, peakConcurrentRanges, transportReasons
    }

    /// 字典键是枚举，默认编码会退化成数组对。这里显式编成字符串键对象，
    /// 让管理端与压测脚本读到稳定、自解释的 JSON。
    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(windowSeconds, forKey: .windowSeconds)
        try container.encode(localRangeCount, forKey: .localRangeCount)
        try container.encode(remoteRangeCount, forKey: .remoteRangeCount)
        try container.encode(deliveredByteCount, forKey: .deliveredByteCount)
        try container.encode(Self.stringKeyed(rangeSizeBuckets), forKey: .rangeSizeBuckets)
        try container.encode(Self.stringKeyed(outcomes), forKey: .outcomes)
        try container.encode(upstreamTimeToFirstByte, forKey: .upstreamTimeToFirstByte)
        try container.encode(rangeCompletion, forKey: .rangeCompletion)
        try container.encode(peakConcurrentBufferedBytes, forKey: .peakConcurrentBufferedBytes)
        try container.encode(peakConcurrentRanges, forKey: .peakConcurrentRanges)
        try container.encode(Self.stringKeyed(transportReasons), forKey: .transportReasons)
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            windowSeconds: try values.decode(Int.self, forKey: .windowSeconds),
            localRangeCount: try values.decode(Int.self, forKey: .localRangeCount),
            remoteRangeCount: try values.decode(Int.self, forKey: .remoteRangeCount),
            deliveredByteCount: try values.decode(Int64.self, forKey: .deliveredByteCount),
            rangeSizeBuckets: Self.enumKeyed(try values.decode([String: Int].self, forKey: .rangeSizeBuckets)),
            outcomes: Self.enumKeyed(try values.decode([String: Int].self, forKey: .outcomes)),
            upstreamTimeToFirstByte: try values.decode(
                ServerLatencySummary.self, forKey: .upstreamTimeToFirstByte
            ),
            rangeCompletion: try values.decode(ServerLatencySummary.self, forKey: .rangeCompletion),
            peakConcurrentBufferedBytes: try values.decode(Int.self, forKey: .peakConcurrentBufferedBytes),
            peakConcurrentRanges: try values.decode(Int.self, forKey: .peakConcurrentRanges),
            transportReasons: Self.enumKeyed(try values.decode([String: Int].self, forKey: .transportReasons))
        )
    }

    private static func stringKeyed<Key: RawRepresentable>(
        _ source: [Key: Int]
    ) -> [String: Int] where Key.RawValue == String {
        Dictionary(uniqueKeysWithValues: source.map { ($0.key.rawValue, $0.value) })
    }

    private static func enumKeyed<Key: RawRepresentable & Hashable>(
        _ source: [String: Int]
    ) -> [Key: Int] where Key.RawValue == String {
        Dictionary(uniqueKeysWithValues: source.compactMap { pair in
            Key(rawValue: pair.key).map { ($0, pair.value) }
        })
    }
}
