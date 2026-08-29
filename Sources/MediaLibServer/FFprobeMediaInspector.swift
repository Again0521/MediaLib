import Foundation
import MediaLibServerProtocol

/// 服务端的跨平台媒体流事实源。此适配器仅把 ffprobe JSON 映射为协议 DTO，
/// 不在此处决定直放、Remux 或转码策略。
final class FFprobeMediaInspector {
    typealias Runner = (URL, [String]) throws -> FFprobeProcessOutput

    private let executableURLProvider: () -> URL?
    private let runner: Runner

    init(
        executableURLProvider: @escaping () -> URL? = FFprobeMediaInspector.defaultExecutableURL,
        runner: @escaping Runner = FFprobeMediaInspector.run
    ) {
        self.executableURLProvider = executableURLProvider
        self.runner = runner
    }

    func inspect(asset: ServerMediaAsset) throws -> ServerMediaPlaybackInfo {
        let probed = try probe(asset: asset)
        return Self.playbackInfo(asset: asset, probed: probed)
    }

    /// 把已经探测过的完整事实投影成公开 DTO。
    ///
    /// 播放信息端点、轨道菜单与 HLS 协商必须复用同一份 ffprobe 结果；如果这里再
    /// 调一次 `probe`，详情页冷启动会为同一个文件并发拉起两到三个进程。
    static func playbackInfo(
        asset: ServerMediaAsset,
        probed: ProbedMedia
    ) -> ServerMediaPlaybackInfo {
        return ServerMediaPlaybackInfo(
            itemID: asset.id,
            durationSeconds: probed.durationSeconds,
            container: probed.container,
            bitrate: probed.bitrate,
            streams: probed.streams.compactMap(Self.streamInfo)
        )
    }

    /// 探测结果的完整形态。
    ///
    /// `inspect` 会把它压成协议 DTO 交给网页；轨道菜单与重封装决策需要 DTO 里
    /// 没有的东西——轨道标题、默认/强制标记，以及"这是本类型里的第几条"（ffmpeg
    /// 的 `-map 0:a:N` 用的是类型内序号，不是全局流序号）。
    func probe(asset: ServerMediaAsset) throws -> ProbedMedia {
        guard let executableURL = executableURLProvider() else {
            throw FFprobeMediaInspectorError.unavailable
        }
        let output = try runner(executableURL, Self.arguments(for: asset.fileURL))
        guard output.exitCode == 0 else {
            throw FFprobeMediaInspectorError.failed
        }
        let document: FFprobeDocument
        do {
            document = try JSONDecoder().decode(FFprobeDocument.self, from: output.standardOutput)
        } catch {
            throw FFprobeMediaInspectorError.invalidOutput
        }
        var ordinals: [String: Int] = [:]
        let streams = document.streams.map { stream -> ProbedStream in
            let ordinal = ordinals[stream.codecType, default: 0]
            ordinals[stream.codecType] = ordinal + 1
            let tags = stream.tags ?? [:]
            func tag(_ names: [String]) -> String? {
                for name in names {
                    if let value = tags.first(where: { $0.key.lowercased() == name })?.value,
                       !value.trimmingCharacters(in: .whitespaces).isEmpty {
                        return String(value.trimmingCharacters(in: .whitespaces).prefix(120))
                    }
                }
                return nil
            }
            return ProbedStream(
                index: stream.index,
                typeOrdinal: ordinal,
                type: stream.codecType,
                codec: stream.codecName?.lowercased(),
                profile: stream.profile,
                language: tag(["language"]),
                title: tag(["title", "handler_name"]),
                width: stream.width,
                height: stream.height,
                pixelFormat: stream.pixelFormat,
                colorTransfer: stream.colorTransfer,
                colorPrimaries: stream.colorPrimaries,
                colorSpace: stream.colorSpace,
                channels: stream.channels,
                isDefault: stream.disposition?["default"] == 1,
                isForced: stream.disposition?["forced"] == 1
            )
        }
        return ProbedMedia(
            durationSeconds: Self.double(document.format?.duration),
            container: document.format?.formatName,
            bitrate: Self.integer(document.format?.bitRate),
            streams: streams
        )
    }

    struct ProbedStream: Equatable {
        /// 容器里的全局流序号。
        let index: Int
        /// 本类型内的序号，`-map 0:a:<typeOrdinal>` 用的就是它。
        let typeOrdinal: Int
        let type: String
        let codec: String?
        let profile: String?
        let language: String?
        let title: String?
        let width: Int?
        let height: Int?
        let pixelFormat: String?
        let colorTransfer: String?
        let colorPrimaries: String?
        let colorSpace: String?
        let channels: Int?
        let isDefault: Bool
        let isForced: Bool

        var isHDR: Bool {
            guard type == "video" else { return false }
            return ["smpte2084", "arib-std-b67"].contains(colorTransfer?.lowercased() ?? "")
        }
    }

    struct ProbedMedia: Equatable {
        let durationSeconds: Double?
        let container: String?
        let bitrate: Int?
        let streams: [ProbedStream]

        var video: [ProbedStream] { streams.filter { $0.type == "video" } }
        var audio: [ProbedStream] { streams.filter { $0.type == "audio" } }
        var subtitles: [ProbedStream] { streams.filter { $0.type == "subtitle" } }
    }

    static func arguments(for fileURL: URL) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-i", ServerMediaToolchain.inputArgument(for: fileURL)
        ]
    }

    private static func streamInfo(_ stream: ProbedStream) -> ServerMediaStreamInfo? {
        guard ["video", "audio", "subtitle"].contains(stream.type) else { return nil }
        return ServerMediaStreamInfo(
            id: stream.index,
            type: stream.type,
            codec: stream.codec,
            profile: stream.profile,
            language: stream.language,
            width: stream.width,
            height: stream.height,
            channels: stream.channels
        )
    }

    private static func double(_ value: String?) -> Double? {
        guard let value, let parsed = Double(value), parsed.isFinite else { return nil }
        return parsed
    }

    private static func integer(_ value: String?) -> Int? {
        guard let value, let parsed = Int64(value), parsed >= 0, parsed <= Int64(Int.max) else { return nil }
        return Int(parsed)
    }

    /// 查找顺序与 ffmpeg 完全一致，因此它落在 `ServerMediaToolchain` 里由两者共用：
    /// "能探测"和"能重封装"必须来自同一份事实。
    private static func defaultExecutableURL() -> URL? {
        ServerMediaToolchain.ffprobeURL()
    }

    private static func run(executableURL: URL, arguments: [String]) throws -> FFprobeProcessOutput {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        let completion = DispatchSemaphore(value: 0)
        let readersFinished = DispatchGroup()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.terminationHandler = { _ in completion.signal() }
        try process.run()

        var standardOutput = Data()
        var standardError = Data()
        readersFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            standardOutput = outputPipe.fileHandleForReading.readDataToEndOfFile()
            readersFinished.leave()
        }
        readersFinished.enter()
        DispatchQueue.global(qos: .utility).async {
            standardError = errorPipe.fileHandleForReading.readDataToEndOfFile()
            readersFinished.leave()
        }

        if completion.wait(timeout: .now() + 20) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = completion.wait(timeout: .now() + 2)
            readersFinished.wait()
            throw FFprobeMediaInspectorError.timedOut
        }
        readersFinished.wait()
        return FFprobeProcessOutput(
            exitCode: process.terminationStatus,
            standardOutput: standardOutput,
            standardError: standardError
        )
    }
}

struct FFprobeProcessOutput {
    let exitCode: Int32
    let standardOutput: Data
    let standardError: Data
}

enum FFprobeMediaInspectorError: LocalizedError {
    case unavailable
    case failed
    case invalidOutput
    case timedOut

    var errorDescription: String? {
        switch self {
        case .unavailable: return "ffprobe 不可用。"
        case .failed: return "ffprobe 无法读取媒体信息。"
        case .invalidOutput: return "ffprobe 返回了无法识别的媒体信息。"
        case .timedOut: return "ffprobe 读取媒体信息超时。"
        }
    }
}

private struct FFprobeDocument: Decodable {
    let format: FFprobeFormat?
    let streams: [FFprobeStream]

    init(format: FFprobeFormat?, streams: [FFprobeStream]) {
        self.format = format
        self.streams = streams
    }
}

private struct FFprobeFormat: Decodable {
    let duration: String?
    let formatName: String?
    let bitRate: String?

    enum CodingKeys: String, CodingKey {
        case duration
        case formatName = "format_name"
        case bitRate = "bit_rate"
    }
}

private struct FFprobeStream: Decodable {
    let index: Int
    let codecType: String
    let codecName: String?
    let profile: String?
    let width: Int?
    let height: Int?
    let pixelFormat: String?
    let colorTransfer: String?
    let colorPrimaries: String?
    let colorSpace: String?
    let channels: Int?
    let tags: [String: String]?
    let disposition: [String: Int]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case pixelFormat = "pix_fmt"
        case colorTransfer = "color_transfer"
        case colorPrimaries = "color_primaries"
        case colorSpace = "color_space"
        case profile, width, height, channels, tags, disposition
    }
}
