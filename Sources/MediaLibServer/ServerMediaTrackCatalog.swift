import Foundation
import MediaLibCore
import MediaLibServerProtocol

/// 网页播放器的音轨 / 字幕轨事实源。
///
/// 从前这两件事在网页上都是浏览器自己的事：字幕靠 `<track>`，音轨靠
/// `HTMLMediaElement.audioTracks`。结果是——
///
/// * 音轨菜单**永远不出现**：`audioTracks` 只有 Safari 实现，Chrome 与 Firefox
///   至今没有这个 API，于是那个 `<details>` 的 `hidden` 从来没被摘掉过；
/// * 字幕菜单只列得出**同目录外挂文件**：封装在 MKV 里的字幕轨浏览器根本看不见，
///   而"内封多语言字幕"恰恰是这类资料库最常见的形态。
///
/// 服务端有 ffprobe，它看得见容器里的每一条流。这个类型把这些流翻译成两份有界
/// 名单交给网页，菜单据此渲染；选中一条非默认音轨时，播放改走
/// `ServerAudioRemuxStream`（浏览器无法在一条流里切音轨）。
final class ServerMediaTrackCatalog {
    enum EmbeddedSubtitleExportState {
        case ready(Data)
        case pending
        case failed
    }

    /// 探测一次的代价是一次 ffprobe 进程；同一部片子在详情页、选集切换与重封装
    /// 决策里会被问好几次，因此按「路径 + 大小 + 修改时间」缓存。文件一变，键就变。
    private struct CacheKey: Hashable {
        let path: String
        let byteLength: Int64
        let modifiedAt: TimeInterval
    }

    private struct SubtitleCacheKey: Hashable {
        let media: CacheKey
        let streamIndex: Int
    }

    /// 一个媒体修订只有一个冷探测。失败结果只共享给已经等在这一班上的请求；
    /// flight 完成后立即移除，因此稍后的页面请求仍能重试临时离线的 NAS 文件。
    private final class ProbeFlight {
        let completion = DispatchGroup()
        var result: FFprobeMediaInspector.ProbedMedia?

        init() {
            completion.enter()
        }
    }

    /// 字幕导出最长会顺序扫描 8 GiB 容器，不能占住 HTTP 客户连接执行队列。
    /// 请求只登记 flight 并立即返回 pending；真正的进程等待发生在专用工作队列。
    private final class SubtitleFlight {}

    private let inspector: FFprobeMediaInspector
    private let lock = NSLock()
    private var cache: [CacheKey: FFprobeMediaInspector.ProbedMedia] = [:]
    private var cacheOrder: [CacheKey] = []
    private var probeFlights: [CacheKey: ProbeFlight] = [:]
    private static let maximumCacheEntries = 256
    private var subtitleCache: [SubtitleCacheKey: Data] = [:]
    private var subtitleCacheOrder: [SubtitleCacheKey] = []
    private var subtitleCacheByteLength = 0
    private var subtitleFlights: [SubtitleCacheKey: SubtitleFlight] = [:]
    private var subtitleFailures: [SubtitleCacheKey: TimeInterval] = [:]
    private static let maximumSubtitleCacheEntries = 64
    private static let maximumSubtitleCacheByteLength = 32 * 1024 * 1024
    private static let maximumPendingSubtitleExports = 8
    private static let subtitleFailureVisibility: TimeInterval = 1
    private let ffmpegURLProvider: () -> URL?
    private let subtitleExporter: (URL, [String], Int, TimeInterval) -> Data?
    private let subtitleExportQueue: DispatchQueue
    private let subtitleExportSlots = DispatchSemaphore(value: 2)
    private let uptimeProvider: () -> TimeInterval

    init(
        inspector: FFprobeMediaInspector = FFprobeMediaInspector(),
        ffmpegURLProvider: @escaping () -> URL? = { ServerMediaToolchain.ffmpegURL() },
        subtitleExporter: @escaping (URL, [String], Int, TimeInterval) -> Data? = {
            executableURL, arguments, maximumOutputByteLength, timeout in
            ServerBoundedProcess.run(
                executableURL: executableURL,
                arguments: arguments,
                maximumOutputByteLength: maximumOutputByteLength,
                timeout: timeout
            )
        },
        subtitleExportQueue: DispatchQueue = DispatchQueue(
            label: "MediaLibServer.SubtitleExports",
            qos: .utility,
            attributes: .concurrent
        ),
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.inspector = inspector
        self.ffmpegURLProvider = ffmpegURLProvider
        self.subtitleExporter = subtitleExporter
        self.subtitleExportQueue = subtitleExportQueue
        self.uptimeProvider = uptimeProvider
    }

    /// 本地文件的探测结果。远程资产没有本地文件可探，一律 nil——它们的轨道由
    /// `ServerRemoteSubtitleCatalog` 从来源服务器问。
    func probe(asset: ServerMediaAsset) -> FFprobeMediaInspector.ProbedMedia? {
        guard asset.remoteURL == nil else { return nil }
        guard let key = cacheKey(for: asset) else { return nil }
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        if let flight = probeFlights[key] {
            lock.unlock()
            flight.completion.wait()
            lock.lock()
            let result = cache[key] ?? flight.result
            lock.unlock()
            return result
        }
        let flight = ProbeFlight()
        probeFlights[key] = flight
        lock.unlock()
        let probed = try? inspector.probe(asset: asset)
        lock.lock()
        if let probed, cache[key] == nil {
            // 同一路径的新大小/mtime 已经是新的媒体修订；旧修订不再可能命中，
            // 立即移除可避免频繁覆盖同一文件把 256 项缓存挤满。
            let superseded = cacheOrder.filter { $0.path == key.path && $0 != key }
            for oldKey in superseded {
                cache.removeValue(forKey: oldKey)
            }
            cacheOrder.removeAll { superseded.contains($0) }
            cache[key] = probed
            cacheOrder.append(key)
            while cacheOrder.count > Self.maximumCacheEntries {
                cache.removeValue(forKey: cacheOrder.removeFirst())
            }
        }
        flight.result = probed
        probeFlights.removeValue(forKey: key)
        lock.unlock()
        flight.completion.leave()
        return probed
    }

    /// `/api/v1/playback/info/*` 与轨道/HLS 路径共用上面的探测和修订缓存，不能另建
    /// 一个 inspector 绕开 single-flight。
    func playbackInfo(for asset: ServerMediaAsset) -> ServerMediaPlaybackInfo? {
        guard let probed = probe(asset: asset) else { return nil }
        return FFprobeMediaInspector.playbackInfo(asset: asset, probed: probed)
    }

    private func cacheKey(for asset: ServerMediaAsset) -> CacheKey? {
        // `URL.resourceValues` 会把同一个 NSURL 的属性缓存在对象上；文件刚被替换或
        // 继续写入时可能仍返回旧大小，结果是新的媒体修订误命中旧 ffprobe。直接
        // 向 FileManager 读取当前目录项属性，失效判断才与磁盘事实一致。
        guard let attributes = try? FileManager.default.attributesOfItem(
            atPath: asset.fileURL.path
        ), let fileSize = (attributes[.size] as? NSNumber)?.int64Value
        else { return nil }
        return CacheKey(
            path: asset.fileURL.path,
            byteLength: fileSize,
            modifiedAt: (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        )
    }

    // MARK: - 音轨

    /// 这个条目的音轨名单，以及"直放能不能出声"。
    ///
    /// 探测不出来（没有 ffprobe、文件在离线的 NAS 上）时返回 nil 而不是空名单：
    /// 空名单的语义是"这个文件确实没有音轨"，会让网页显示一条错误的结论。
    func audioTracks(for asset: ServerMediaAsset) -> ServerWebAudioTrackSet? {
        guard let probed = probe(asset: asset) else { return nil }
        let audio = probed.audio
        guard !audio.isEmpty else {
            return ServerWebAudioTrackSet(tracks: [], remuxable: false, remuxUnavailableReason: nil)
        }
        let tracks = audio.prefix(ServerWebAudioTrackSet.maximumTrackCount).map { stream in
            ServerWebAudioTrack(
                id: stream.typeOrdinal,
                fingerprint: ServerTokenSecurity.digest([
                    "audio", String(stream.typeOrdinal), stream.title ?? "",
                    stream.language ?? "", stream.codec ?? "", stream.channels.map(String.init) ?? ""
                ].joined(separator: "|")) ?? "audio-\(stream.typeOrdinal)",
                label: Self.audioLabel(stream, ordinal: stream.typeOrdinal),
                language: stream.language,
                codec: stream.codec,
                channels: stream.channels,
                browserPlayable: stream.codec.map {
                    ServerMediaToolchain.browserDecodableAudioCodecs.contains($0)
                } ?? false,
                isDefault: stream.isDefault
            )
        }
        let reason = remuxUnavailableReason(probed)
        return ServerWebAudioTrackSet(
            tracks: Array(tracks),
            remuxable: reason == nil,
            remuxUnavailableReason: reason
        )
    }

    /// 能不能为这个文件提供"换音轨 / 补声音"的重封装通路，不能的话卡在哪一步。
    /// 网页要把这句话原样说给读者听，所以它是一条理由而不是一个布尔。
    private func remuxUnavailableReason(_ probed: FFprobeMediaInspector.ProbedMedia) -> String? {
        guard ServerMediaToolchain.ffmpegURL() != nil else {
            return "这台服务器上没有 ffmpeg，无法为这段视频重新封装音轨。"
        }
        guard let video = probed.video.first else {
            // 纯音频条目本来就不需要重封装视频轨。
            return nil
        }
        guard let codec = video.codec,
              ServerMediaToolchain.remuxableVideoCodecs.contains(codec)
        else {
            return "这段视频的编码浏览器无法直接播放，重新封装也帮不上忙。"
        }
        return nil
    }

    private static func audioLabel(_ stream: FFprobeMediaInspector.ProbedStream, ordinal: Int) -> String {
        var pieces: [String] = []
        if let title = stream.title { pieces.append(title) }
        if let language = stream.language, !pieces.contains(where: { $0.caseInsensitiveCompare(language) == .orderedSame }) {
            pieces.append(language)
        }
        if let codec = stream.codec { pieces.append(codec.uppercased()) }
        if let channels = stream.channels {
            pieces.append(channels >= 6 ? "\(channels) 声道" : (channels == 2 ? "立体声" : "\(channels) 声道"))
        }
        let label = pieces.joined(separator: " · ")
        return label.isEmpty ? "音轨 \(ordinal + 1)" : String(label.prefix(80))
    }

    // MARK: - 跳转落点

    /// `-c:v copy` 的重封装只能从**关键帧**开始。
    ///
    /// 要跳到第 7 秒，而最近的关键帧在第 6 秒，ffmpeg 交出来的流实际是从第 6 秒
    /// 开始的——页面上却按第 7 秒记时间轴。差值最多是一整个 GOP（常见 2–10 秒），
    /// 而且会一直留在那条流上：时间显示偏、续播点也跟着偏。
    ///
    /// 这里先把落点问清楚，播放器再拿这个**已经对齐过的**秒数去起流，于是
    /// ffmpeg 的吸附成了空操作，时间轴与画面从第一帧起就是对上的。
    /// 一次查询约几十毫秒，而它只发生在起流/跳转时，不在播放过程中。
    func keyframeStart(for asset: ServerMediaAsset, at seconds: Double) -> Double? {
        guard asset.remoteURL == nil,
              seconds.isFinite, seconds >= 0, seconds < 86_400,
              let ffprobe = ServerMediaToolchain.ffprobeURL()
        else { return nil }
        guard seconds > 0 else { return 0 }
        let output = ServerBoundedProcess.run(
            executableURL: ffprobe,
            arguments: [
                "-v", "error",
                "-select_streams", "v:0",
                // 只读关键帧，且只读目标点附近的一小段——不必扫描整部片子。
                "-skip_frame", "nokey",
                "-read_intervals", "\(String(format: "%.3f", seconds))%+1",
                "-show_entries", "frame=best_effort_timestamp_time",
                "-of", "csv=p=0",
                "-i", ServerMediaToolchain.inputArgument(for: asset.fileURL)
            ],
            maximumOutputByteLength: 64 * 1024,
            timeout: 15
        )
        guard let output, let text = String(data: output, encoding: .utf8) else { return nil }
        // ffprobe 从"目标点之前最近的那个关键帧"开始读，所以第一行就是落点。
        let first = text
            .split(separator: "\n")
            .first?
            .trimmingCharacters(in: CharacterSet(charactersIn: ", \t\r"))
        guard let first, let value = Double(first), value.isFinite, value >= 0, value <= seconds else {
            return nil
        }
        return value
    }

    // MARK: - 内嵌字幕

    /// 可以翻译成 WebVTT 的内嵌字幕编码。
    ///
    /// 图形字幕（PGS / VobSub / DVB）不在其中，而且**不能**放进来：它们是位图，
    /// 转成文本要跑 OCR。把它们列进菜单，读者选中后得到的是一条永远空白的字幕轨。
    static let textSubtitleCodecs: Set<String> = [
        "subrip", "srt", "ass", "ssa", "webvtt", "mov_text", "text", "microdvd", "subviewer"
    ]
    static let bitmapSubtitleCodecs: Set<String> = [
        "hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle", "xsub"
    ]

    func embeddedSubtitleStreams(
        for asset: ServerMediaAsset
    ) -> [FFprobeMediaInspector.ProbedStream] {
        guard ffmpegURLProvider() != nil, let probed = probe(asset: asset) else { return [] }
        return probed.subtitles.filter { stream in
            stream.codec.map { Self.textSubtitleCodecs.contains($0) } ?? false
        }
    }

    func embeddedBitmapSubtitleStreams(
        for asset: ServerMediaAsset
    ) -> [FFprobeMediaInspector.ProbedStream] {
        guard ffmpegURLProvider() != nil, let probed = probe(asset: asset) else { return [] }
        return probed.subtitles.filter { stream in
            stream.codec.map { Self.bitmapSubtitleCodecs.contains($0) } ?? false
        }
    }

    /// 把一条内嵌字幕流导出成 WebVTT。
    ///
    /// 交给 ffmpeg 的是 `-f webvtt`，不是"先导出 ASS 再自己转"：ffmpeg 的 ASS→VTT
    /// 已经处理好时间轴与换行。它丢掉 ASS 的定位信息，所以 ASS 内封轨在网页上是
    /// 一份朴素但正确的字幕；外挂 `.ass` 走 `ServerASSSubtitle`，那条路径保留定位。
    func embeddedSubtitleWebVTT(
        for asset: ServerMediaAsset,
        streamIndex: Int,
        startIfNeeded: Bool = true
    ) -> EmbeddedSubtitleExportState {
        guard asset.remoteURL == nil,
              let ffmpeg = ffmpegURLProvider(),
              streamIndex >= 0,
              let mediaKey = cacheKey(for: asset)
        else { return .failed }
        let subtitleKey = SubtitleCacheKey(media: mediaKey, streamIndex: streamIndex)
        let now = uptimeProvider()
        lock.lock()
        if let cached = subtitleCache[subtitleKey] {
            lock.unlock()
            return .ready(cached)
        }
        if let failureUntil = subtitleFailures[subtitleKey] {
            if now < failureUntil {
                lock.unlock()
                return .failed
            }
            subtitleFailures.removeValue(forKey: subtitleKey)
        }
        if subtitleFlights[subtitleKey] != nil {
            lock.unlock()
            return .pending
        }
        guard startIfNeeded,
              subtitleFlights.count < Self.maximumPendingSubtitleExports
        else {
            lock.unlock()
            return startIfNeeded ? .failed : .pending
        }
        subtitleFlights[subtitleKey] = SubtitleFlight()
        lock.unlock()

        let arguments = [
                "-nostdin", "-hide_banner", "-loglevel", "error",
                "-i", ServerMediaToolchain.inputArgument(for: asset.fileURL),
                "-map", "0:\(streamIndex)",
                "-map_metadata", "-1", "-map_chapters", "-1",
                "-c:s", "webvtt",
                "-f", "webvtt",
                "-"
        ]
        let timeout = Self.embeddedSubtitleExtractionTimeout(byteLength: mediaKey.byteLength)
        subtitleExportQueue.async { [self] in
            subtitleExportSlots.wait()
            defer { subtitleExportSlots.signal() }
            let output = subtitleExporter(
                ffmpeg,
                arguments,
                ServerWebVTTSubtitleTrack.maximumByteLength,
                timeout
            )
            let payload = output
                .flatMap(ServerSubtitleSidecar.decodeText)
                .flatMap { text in text.contains("-->") ? Data(text.utf8) : nil }
            finishSubtitleExport(payload, asset: asset, key: subtitleKey)
        }
        return .pending
    }

    private func finishSubtitleExport(
        _ payload: Data?,
        asset: ServerMediaAsset,
        key subtitleKey: SubtitleCacheKey
    ) {
        lock.lock()
        defer { lock.unlock() }
        subtitleFlights.removeValue(forKey: subtitleKey)
        // 文件在长时间扫描中被继续写入或替换时，旧结果不得进入新修订缓存。
        guard cacheKey(for: asset) == subtitleKey.media else { return }
        guard let payload else {
            subtitleFailures[subtitleKey] = uptimeProvider() + Self.subtitleFailureVisibility
            return
        }
        subtitleFailures.removeValue(forKey: subtitleKey)
        if subtitleCache[subtitleKey] == nil {
            let superseded = subtitleCacheOrder.filter {
                $0.media.path == subtitleKey.media.path && $0.media != subtitleKey.media
            }
            for oldKey in superseded {
                if let removed = subtitleCache.removeValue(forKey: oldKey) {
                    subtitleCacheByteLength -= removed.count
                }
                subtitleFailures.removeValue(forKey: oldKey)
            }
            subtitleCacheOrder.removeAll { superseded.contains($0) }
            subtitleCache[subtitleKey] = payload
            subtitleCacheOrder.append(subtitleKey)
            subtitleCacheByteLength += payload.count
            while subtitleCacheOrder.count > Self.maximumSubtitleCacheEntries
                || subtitleCacheByteLength > Self.maximumSubtitleCacheByteLength {
                let expired = subtitleCacheOrder.removeFirst()
                if let removed = subtitleCache.removeValue(forKey: expired) {
                    subtitleCacheByteLength -= removed.count
                }
            }
        }
    }

    /// Matroska 的字幕包与视频包交错存放。导出 20 KiB 字幕仍可能需要扫过整部
    /// 8 GiB 影片，固定 45 秒只对小测试文件成立。按 32 MiB/s 的保守顺序读取速度
    /// 预算，并保留 45 秒下限与 5 分钟硬上限，兼顾 NAS 与服务端有界执行。
    static func embeddedSubtitleExtractionTimeout(byteLength: Int64) -> TimeInterval {
        let safeLength = max(0, byteLength)
        let scanSeconds = Double(safeLength) / Double(32 * 1024 * 1024)
        return min(300, max(45, 15 + scanSeconds))
    }
}

/// 网页拿到的一条音轨。ID 是**类型内序号**，也就是 ffmpeg `-map 0:a:<id>` 里的那个
/// 数字；容器里的全局流序号从不外发。
struct ServerWebAudioTrack: Codable, Equatable {
    let id: Int
    let fingerprint: String
    let label: String
    let language: String?
    let codec: String?
    let channels: Int?
    /// 浏览器能不能自己解码这条轨。为假时选中它必须走重封装，否则就是"有画面
    /// 没声音"。
    let browserPlayable: Bool
    let isDefault: Bool

    init(
        id: Int,
        fingerprint: String? = nil,
        label: String,
        language: String?,
        codec: String?,
        channels: Int?,
        browserPlayable: Bool,
        isDefault: Bool
    ) {
        self.id = id
        self.fingerprint = fingerprint
            ?? ServerTokenSecurity.digest("audio|\(id)|\(label)")
            ?? "audio-\(id)"
        self.label = label
        self.language = language
        self.codec = codec
        self.channels = channels
        self.browserPlayable = browserPlayable
        self.isDefault = isDefault
    }
}

struct ServerWebAudioTrackSet: Codable, Equatable {
    static let maximumTrackCount = 16

    let tracks: [ServerWebAudioTrack]
    let remuxable: Bool
    let remuxUnavailableReason: String?
}
