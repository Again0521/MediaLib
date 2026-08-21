import Foundation

/// 只重编码音频的实时重封装流。
///
/// 要解决的问题：MKV 里常见的 AC-3 / E-AC-3 / DTS / TrueHD 没有任何浏览器能解码。
/// 画面照常出来（H.264 在 Matroska 里 Chrome 是认的），声音一点也没有，而且浏览器
/// 不会报错——从读者那边看就是"这个格式没有声音"。
///
/// 通路：`-c:v copy` 把画面原样搬进 MP4（不重编码，家用 NAS 上只是磁盘吞吐），
/// 音频转成 AAC，输出分片 MP4 直接写进 socket。这条路同时也是**换音轨**的实现：
/// 一条 `<video>` 里浏览器没有切音轨的手段，换轨等于换一条只含目标音轨的流。
///
/// 明确的取舍：分片 MP4 是边转边发的，长度未知，因此**不支持 Range**——浏览器无法
/// 用拖动进度条的方式跳转。跳转由播放器改写 `start=` 重新起一条流来完成，页面上
/// 维持一条虚拟时间轴。这比"看不了"好得多，也比在 NAS 上预先转码一整部片子好得多。
struct ServerAudioRemuxStream {
    let asset: ServerMediaAsset
    /// 类型内序号（`-map 0:a:<audioTrackID>`）。
    let audioTrackID: Int
    /// 从第几秒开始。跳转就是换一个这个值。
    let startSeconds: Double
    let executableURL: URL

    /// 同时在跑的重封装进程数上限。超出时不排队等待——排队会让读者盯着一个不动
    /// 的画面，直到前一个人看完。
    private static let slots = DispatchSemaphore(value: ServerMediaToolchain.maximumConcurrentRemuxes)
    private static let chunkLength = 128 * 1024

    static func make(
        asset: ServerMediaAsset,
        audioTrackID: Int,
        startSeconds: Double
    ) -> ServerAudioRemuxStream? {
        guard asset.remoteURL == nil,
              audioTrackID >= 0,
              audioTrackID < ServerWebAudioTrackSet.maximumTrackCount,
              startSeconds >= 0,
              startSeconds.isFinite,
              startSeconds < 86_400,
              let executableURL = ServerMediaToolchain.ffmpegURL()
        else { return nil }
        return ServerAudioRemuxStream(
            asset: asset,
            audioTrackID: audioTrackID,
            startSeconds: startSeconds,
            executableURL: executableURL
        )
    }

    var arguments: [String] {
        [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            // `-ss` 放在 `-i` **之前**：输入侧跳转是索引查找，输出侧跳转要把前面
            // 的内容整段解码丢掉。一部两小时的片子跳到第 100 分钟，两者是毫秒与
            // 分钟的差别。
            "-ss", String(format: "%.3f", startSeconds),
            "-i", ServerMediaToolchain.inputArgument(for: asset.fileURL),
            "-map", "0:v:0?",
            "-map", "0:a:\(audioTrackID)?",
            // 字幕与数据流不进 MP4：内封字幕由字幕端点单独交付，混进来只会让
            // 封装失败。
            "-sn", "-dn", "-map_chapters", "-1",
            "-c:v", "copy",
            "-c:a", "aac", "-ac", "2", "-b:a", "256k",
            // 输入侧跳转后第一帧的时间戳不是 0；不归零的话浏览器会认为这段视频
            // 从第 100 分钟开始，进度条直接跑到尽头。
            "-avoid_negative_ts", "make_zero",
            "-f", "mp4",
            // 边转边发必须是分片 MP4：普通 MP4 的 moov 在文件末尾，要等整部片子
            // 转完才能开始播。
            "-movflags", "frag_keyframe+empty_moov+default_base_moof",
            "-"
        ]
    }

    /// 把 ffmpeg 的标准输出逐块交给 `consume`。`consume` 返回 false（读者关掉了
    /// 页面）时立刻杀掉进程——否则一个离开的读者会在服务器上留下一个一直转到
    /// 片尾的 ffmpeg。
    @discardableResult
    func stream(_ consume: @escaping (Data) -> Bool) -> Bool {
        guard Self.slots.wait(timeout: .now() + 0.5) == .success else { return false }
        defer { Self.slots.signal() }

        let process = Process()
        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.executableURL = executableURL
        process.arguments = arguments
        process.standardOutput = outputPipe
        process.standardError = errorPipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return false }

        // 标准错误一定要有人读干净：管道缓冲区写满后 ffmpeg 会阻塞在写日志上，
        // 表现为播放到某一处永远卡住。
        let drained = DispatchGroup()
        drained.enter()
        DispatchQueue.global(qos: .utility).async {
            defer { drained.leave() }
            while !errorPipe.fileHandleForReading.availableData.isEmpty {}
        }

        var delivered = 0
        var clientLeft = false
        let handle = outputPipe.fileHandleForReading
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            var offset = 0
            while offset < chunk.count {
                let end = min(offset + Self.chunkLength, chunk.count)
                guard consume(chunk.subdata(in: offset..<end)) else {
                    clientLeft = true
                    break
                }
                offset = end
            }
            if clientLeft { break }
            delivered += chunk.count
        }
        if clientLeft || process.isRunning {
            process.terminate()
            // 关掉读端，让还卡在写管道上的 ffmpeg 立刻收到 EPIPE 退出。
            try? handle.close()
        }
        process.waitUntilExit()
        drained.wait()
        return !clientLeft && delivered > 0
    }
}
