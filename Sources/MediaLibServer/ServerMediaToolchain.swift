import Foundation

/// 服务端可用的 ffmpeg / ffprobe 可执行文件解析。
///
/// 两者的查找顺序完全一致（随 App 分发的那一份优先，然后是常见的 Homebrew 与
/// 系统路径），此前只有 ffprobe 有这段逻辑。抽出来是因为现在有第二个调用方：
/// 音轨重封装与内嵌字幕导出都要 ffmpeg，而"能不能转"这个判断必须和"能不能探测"
/// 用同一份事实，否则网页会显示一个按下去什么都不会发生的入口。
enum ServerMediaToolchain {
    static func ffprobeURL() -> URL? { executable(named: "ffprobe") }
    static func ffmpegURL() -> URL? { executable(named: "ffmpeg") }

    private static func executable(named name: String) -> URL? {
        let fileManager = FileManager.default
        let candidates = [
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent(name),
            CommandLine.arguments.first.map {
                URL(fileURLWithPath: $0).deletingLastPathComponent().appendingPathComponent(name)
            },
            URL(fileURLWithPath: "/opt/homebrew/bin/\(name)"),
            URL(fileURLWithPath: "/usr/local/bin/\(name)"),
            URL(fileURLWithPath: "/usr/bin/\(name)")
        ].compactMap { $0 }
        return candidates.first(where: { fileManager.isExecutableFile(atPath: $0.path) })
    }

    /// 浏览器能自己解码的音频编码。
    ///
    /// 这份名单决定"直放还是重封装"，所以宁可漏也不能多：把一条其实解不了的编码
    /// 认成能解，读者得到的是一段**有画面没有声音**的视频，而且没有任何提示——正是
    /// 这次要修的那个症状。AC-3 / E-AC-3 / DTS / TrueHD 是 MKV 里最常见的几种，
    /// 没有任何主流浏览器解码它们。
    static let browserDecodableAudioCodecs: Set<String> = [
        "aac", "mp3", "mp2", "opus", "vorbis", "flac"
    ]

    /// 能被原样封进 MP4、且浏览器能解码的视频编码。
    ///
    /// 重封装只动音频：视频重编码在家用 NAS 上是几小时的事，不是一个"点一下就好"
    /// 的功能。视频编码不在这份名单里时，重封装入口整个不提供，而不是提供一个
    /// 会把机器跑满的按钮。
    static let remuxableVideoCodecs: Set<String> = ["h264", "hevc", "av1", "mpeg4", "vp9"]

    /// 同时允许的重封装进程数。每一路都是一个 ffmpeg，且会一直跑到读者离开页面。
    static let maximumConcurrentRemuxes = 2

    /// 交给 ffmpeg / ffprobe 的 `-i` 参数。
    ///
    /// 这里**不能**用 `URL.absoluteString`。那是一个百分号编码过的 URL，而 ffmpeg 的
    /// file 协议是逐字节取用的，它不做百分号解码——于是
    /// `file:///…/%E6%97%A0%E5%A3%B0.mkv` 得到的是 "No such file or directory"。
    /// 后果不是报错，而是**每一个带非 ASCII 文件名的条目都探测失败**：中日韩资料库
    /// 里那几乎是全部，音轨名单于是恒为空，"这段视频有没有声音"永远判不出来。
    ///
    /// 保留 `file:` 前缀是为了另外两类文件名：含冒号的会被当成协议名
    /// （`My Movie: Part 2.mkv`），以横线开头的会被当成选项。`file:` 之后的一切
    /// 都按字面路径处理。
    static func inputArgument(for fileURL: URL) -> String {
        "file:\(fileURL.path)"
    }
}

/// 一次有界的子进程调用：把标准输出整份读回来。用于内嵌字幕导出这类**小而有限**
/// 的输出；流式播放走 `ServerAudioRemuxStream`，不经过这里。
enum ServerBoundedProcess {
    static func run(
        executableURL: URL,
        arguments: [String],
        maximumOutputByteLength: Int,
        timeout: TimeInterval
    ) -> Data? {
        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        // The completion handler must exist before `run()`.  Subtitle-only ffmpeg
        // jobs can finish in a few milliseconds; installing the handler after the
        // process has started leaves a race where the exit is missed and a valid
        // embedded subtitle waits for the full 45-second timeout.
        let finished = DispatchGroup()
        finished.enter()
        process.terminationHandler = { _ in finished.leave() }
        do { try process.run() } catch {
            process.terminationHandler = nil
            finished.leave()
            return nil
        }

        let lock = NSLock()
        var output = Data()
        var overflowed = false
        let readers = DispatchGroup()
        readers.enter()
        DispatchQueue.global(qos: .userInitiated).async {
            defer { readers.leave() }
            while true {
                let chunk = outputPipe.fileHandleForReading.availableData
                if chunk.isEmpty { return }
                lock.lock()
                if output.count + chunk.count > maximumOutputByteLength {
                    overflowed = true
                    lock.unlock()
                    // 超限就地掐断：让 ffmpeg 自己因为管道关闭而退出，而不是把
                    // 一份没有上限的输出继续读进内存。
                    process.terminate()
                    return
                }
                output.append(chunk)
                lock.unlock()
            }
        }
        // 标准错误必须一起读干净，否则 ffmpeg 会在写满 64 KiB 管道缓冲区后卡死，
        // 表现为"导出字幕永远超时"。
        readers.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { readers.leave() }
            while !errorPipe.fileHandleForReading.availableData.isEmpty {}
        }

        if finished.wait(timeout: .now() + timeout) == .timedOut {
            if process.isRunning { process.terminate() }
            _ = finished.wait(timeout: .now() + 2)
            readers.wait()
            return nil
        }
        readers.wait()
        lock.lock()
        defer { lock.unlock() }
        guard !overflowed, process.terminationStatus == 0, !output.isEmpty else { return nil }
        return output
    }
}
