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
        return ServerMediaPlaybackInfo(
            itemID: asset.id,
            durationSeconds: Self.double(document.format?.duration),
            container: document.format?.formatName,
            bitrate: Self.integer(document.format?.bitRate),
            streams: document.streams.compactMap(Self.streamInfo)
        )
    }

    static func arguments(for fileURL: URL) -> [String] {
        [
            "-v", "error",
            "-print_format", "json",
            "-show_format",
            "-show_streams",
            "-i", fileURL.absoluteString
        ]
    }

    private static func streamInfo(_ stream: FFprobeStream) -> ServerMediaStreamInfo? {
        guard ["video", "audio", "subtitle"].contains(stream.codecType) else { return nil }
        return ServerMediaStreamInfo(
            id: stream.index,
            type: stream.codecType,
            codec: stream.codecName,
            profile: stream.profile,
            language: stream.tags?["language"],
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

    private static func defaultExecutableURL() -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("ffprobe"),
            CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent("ffprobe")
            },
            URL(fileURLWithPath: "/opt/homebrew/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/local/bin/ffprobe"),
            URL(fileURLWithPath: "/usr/bin/ffprobe")
        ].compactMap { $0 }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
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
    let channels: Int?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case codecType = "codec_type"
        case codecName = "codec_name"
        case profile, width, height, channels, tags
    }
}
