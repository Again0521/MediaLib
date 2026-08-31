import Foundation
import XCTest
@testable import MediaLibServer

/// 容器内部的音轨与内嵌字幕轨。
///
/// 这一层回答的是"直放会不会没有声音"。答错的代价不是报错，而是读者看到一段
/// **有画面没有声音**的视频，而且浏览器不会给任何提示——正是这次要修的症状。
final class ServerMediaTrackCatalogTests: XCTestCase {
    private var temporaryDirectory = FileManager.default.temporaryDirectory

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: self.temporaryDirectory) }
    }

    private func asset(named name: String = "影片.mkv") throws -> ServerMediaAsset {
        let url = temporaryDirectory.appendingPathComponent(name)
        try Data("media".utf8).write(to: url)
        return ServerMediaAsset(id: "item-1", fileURL: url, byteLength: 5)
    }

    private func catalog(streams: String, callCount: UnsafeMutablePointer<Int>? = nil) -> ServerMediaTrackCatalog {
        let json = Data(#"{"format":{"duration":"120.0"},"streams":[\#(streams)]}"#.utf8)
        return ServerMediaTrackCatalog(inspector: FFprobeMediaInspector(
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffprobe-test-double") },
            runner: { _, _ in
                callCount?.pointee += 1
                return FFprobeProcessOutput(exitCode: 0, standardOutput: json, standardError: Data())
            }
        ))
    }

    /// 真实流媒体 MKV 会把简中/繁中排在第 17、18 条。上限若仍是 16，菜单再好看也
    /// 永远不可能让读者选到中文；32 仍是明确的安全边界，字幕内容也只在选中后转换。
    func testSubtitleBoundIncludesHighLanguageCounts() {
        XCTAssertGreaterThanOrEqual(ServerWebVTTSubtitleTrack.maximumTrackCount, 18)
        XCTAssertLessThanOrEqual(ServerWebVTTSubtitleTrack.maximumTrackCount, 32)
    }

    /// Loki 这类 8 GiB Matroska 即使字幕本身只有几十 KiB，字幕包仍与视频包交错，
    /// 导出时需要扫描整部容器。固定 45 秒会把正常轨道误判成失败。
    func testEmbeddedSubtitleExtractionTimeoutScalesWithContainerSizeButStaysBounded() {
        let gibibyte = Int64(1024 * 1024 * 1024)

        XCTAssertEqual(ServerMediaTrackCatalog.embeddedSubtitleExtractionTimeout(byteLength: 0), 45)
        XCTAssertGreaterThan(ServerMediaTrackCatalog.embeddedSubtitleExtractionTimeout(byteLength: 8 * gibibyte), 240)
        XCTAssertEqual(ServerMediaTrackCatalog.embeddedSubtitleExtractionTimeout(byteLength: 100 * gibibyte), 300)
        XCTAssertEqual(ServerMediaTrackCatalog.embeddedSubtitleExtractionTimeout(byteLength: -1), 45)
    }

    /// AC-3 是 MKV 里最常见的音轨编码，没有任何浏览器解得了它。
    func testMarksUndecodableAudioCodecs() throws {
        let catalog = catalog(streams: """
        {"index":0,"codec_type":"video","codec_name":"h264"},
        {"index":1,"codec_type":"audio","codec_name":"ac3","channels":6,"tags":{"language":"eng","title":"Surround"},"disposition":{"default":1}},
        {"index":2,"codec_type":"audio","codec_name":"aac","channels":2,"tags":{"language":"jpn"}}
        """)
        let set = try XCTUnwrap(catalog.audioTracks(for: try asset()))
        XCTAssertEqual(set.tracks.count, 2)
        XCTAssertFalse(set.tracks[0].browserPlayable)
        XCTAssertTrue(set.tracks[0].isDefault)
        XCTAssertTrue(set.tracks[1].browserPlayable)
        // ID 是**类型内**序号，`-map 0:a:<id>` 用的就是它，不是容器里的全局流序号。
        XCTAssertEqual(set.tracks.map(\.id), [0, 1])
        XCTAssertTrue(set.tracks[0].label.contains("Surround"))
        XCTAssertTrue(set.tracks[0].label.contains("AC3"))
    }

    /// 视频编码没法原样搬进 MP4 时，不提供换轨入口——一个按下去只会把机器跑满
    /// 的按钮比没有按钮更糟。
    func testRefusesRemuxWhenVideoCodecCannotBeCopied() throws {
        let catalog = catalog(streams: """
        {"index":0,"codec_type":"video","codec_name":"mpeg2video"},
        {"index":1,"codec_type":"audio","codec_name":"ac3"}
        """)
        let set = try XCTUnwrap(catalog.audioTracks(for: try asset()))
        XCTAssertFalse(set.remuxable)
        XCTAssertNotNil(set.remuxUnavailableReason, "不能转的时候必须给出可以显示给读者的理由")
    }

    /// 图形字幕（PGS/VobSub）是位图，转成文本要跑 OCR。列出来读者只会选到一条
    /// 永远空白的轨道。
    func testEmbeddedSubtitlesExcludeBitmapCodecs() throws {
        let catalog = catalog(streams: """
        {"index":0,"codec_type":"video","codec_name":"h264"},
        {"index":1,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"chi"}},
        {"index":2,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle","tags":{"language":"eng"}},
        {"index":3,"codec_type":"subtitle","codec_name":"ass","tags":{"language":"jpn","title":"日本語"}}
        """)
        let streams = catalog.embeddedSubtitleStreams(for: try asset())
        // ffmpeg 不在这台机器上时整条内嵌通路都不提供——那是正确的降级，不是失败。
        guard ServerMediaToolchain.ffmpegURL() != nil else {
            XCTAssertTrue(streams.isEmpty)
            return
        }
        XCTAssertEqual(streams.map(\.index), [1, 3])
    }

    /// 位图字幕不能伪装成 WebVTT，但必须作为一条明确要求烧录转码的轨道提供给
    /// 播放协商层。两份目录互斥，避免同一轨道同时走文字覆盖与画面烧录。
    func testBitmapSubtitlesAreDiscoveredOnlyByBurnInCatalog() throws {
        let catalog = catalog(streams: """
        {"index":0,"codec_type":"video","codec_name":"h264"},
        {"index":1,"codec_type":"subtitle","codec_name":"subrip","tags":{"language":"chi"}},
        {"index":2,"codec_type":"subtitle","codec_name":"hdmv_pgs_subtitle","tags":{"language":"eng"}},
        {"index":3,"codec_type":"subtitle","codec_name":"dvd_subtitle","tags":{"language":"jpn"}}
        """)
        guard ServerMediaToolchain.ffmpegURL() != nil else {
            throw XCTSkip("ffmpeg is required before bitmap subtitle tracks can be offered")
        }
        let media = try asset()
        XCTAssertEqual(catalog.embeddedSubtitleStreams(for: media).map(\.index), [1])
        XCTAssertEqual(catalog.embeddedBitmapSubtitleStreams(for: media).map(\.index), [2, 3])
    }

    /// 探测一次是一个 ffprobe 进程。同一部片子在详情页、字幕菜单与重封装决策里
    /// 会被问好几次，不缓存的话每次都要重新起进程。
    func testProbeIsCachedPerFile() throws {
        var calls = 0
        let catalog = withUnsafeMutablePointer(to: &calls) { pointer in
            self.catalog(streams: #"{"index":0,"codec_type":"audio","codec_name":"aac"}"#, callCount: pointer)
        }
        let asset = try asset()
        _ = catalog.audioTracks(for: asset)
        _ = catalog.audioTracks(for: asset)
        XCTAssertEqual(calls, 1)
    }

    func testPlaybackInfoAndTrackMenusShareTheSameProbe() throws {
        var calls = 0
        let catalog = withUnsafeMutablePointer(to: &calls) { pointer in
            self.catalog(
                streams: #"{"index":0,"codec_type":"video","codec_name":"h264","width":1920,"height":1080},{"index":1,"codec_type":"audio","codec_name":"aac"}"#,
                callCount: pointer
            )
        }
        let media = try asset()

        XCTAssertEqual(catalog.audioTracks(for: media)?.tracks.count, 1)
        XCTAssertEqual(catalog.playbackInfo(for: media)?.streams.count, 2)
        XCTAssertEqual(calls, 1)
    }

    func testConcurrentColdRequestsSingleFlightOneSuccessfulProbe() throws {
        let probe = ConcurrentProbeRunner(outcomes: [.success(duration: 120)])
        let catalog = ServerMediaTrackCatalog(inspector: probe.inspector())
        let media = try asset()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = LockedProbeResultCounter()

        for index in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let succeeded = index.isMultiple(of: 2)
                    ? catalog.playbackInfo(for: media) != nil
                    : catalog.audioTracks(for: media) != nil
                results.record(succeeded)
                group.leave()
            }
        }
        for _ in 0..<12 { start.signal() }

        XCTAssertEqual(probe.firstCallEntered.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(probe.callCount, 1)
        probe.releaseFirstCall.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.successCount, 12)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testConcurrentRemoteBridgeProbesShareOneFlightAndCache() throws {
        let probe = ConcurrentProbeRunner(outcomes: [.success(duration: 321)])
        let catalog = ServerMediaTrackCatalog(inspector: probe.inspector())
        let remote = ServerMediaAsset(
            id: "remote-probe",
            remoteURL: URL(string: "https://media.example/stream.mkv?api_key=SECRET")!,
            byteLength: 5_000_000
        )
        let bridgeURL = URL(
            string: "http://127.0.0.1:54321/0123456789abcdef0123456789abcdef/media"
        )!
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = LockedProbeResultCounter()

        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                let cancellation = ServerBoundedProcess.Cancellation()
                results.record(catalog.probeRemote(
                    asset: remote,
                    through: bridgeURL,
                    cancellation: cancellation
                )?.durationSeconds == 321)
                group.leave()
            }
        }
        for _ in 0..<12 { start.signal() }

        XCTAssertEqual(probe.firstCallEntered.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(probe.callCount, 1)
        probe.releaseFirstCall.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.successCount, 12)
        XCTAssertEqual(probe.callCount, 1)
        XCTAssertEqual(catalog.probeRemote(
            asset: remote,
            through: bridgeURL,
            cancellation: ServerBoundedProcess.Cancellation()
        )?.durationSeconds, 321)
        XCTAssertEqual(probe.callCount, 1)
    }

    func testRemoteProbeRejectsNonLoopbackBridge() {
        let probe = ConcurrentProbeRunner(outcomes: [.success(duration: 10)], blockFirstCall: false)
        let catalog = ServerMediaTrackCatalog(inspector: probe.inspector())
        let remote = ServerMediaAsset(
            id: "remote-probe",
            remoteURL: URL(string: "https://media.example/stream.mkv?token=SECRET")!,
            byteLength: 1_024
        )

        XCTAssertNil(catalog.probeRemote(
            asset: remote,
            through: URL(string: "http://192.168.1.2:54321/media")!,
            cancellation: ServerBoundedProcess.Cancellation()
        ))
        XCTAssertEqual(probe.callCount, 0)
        XCTAssertNil(catalog.probeRemote(
            asset: remote,
            through: URL(string: "http://127.0.0.1:54321/media")!,
            cancellation: ServerBoundedProcess.Cancellation()
        ))
        XCTAssertEqual(probe.callCount, 0)
    }

    func testConcurrentFailureIsSharedButLaterRequestCanRetry() throws {
        let probe = ConcurrentProbeRunner(outcomes: [.failure, .success(duration: 240)])
        let catalog = ServerMediaTrackCatalog(inspector: probe.inspector())
        let media = try asset()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = LockedProbeResultCounter()

        for _ in 0..<8 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                results.record(catalog.probe(asset: media) != nil)
                group.leave()
            }
        }
        for _ in 0..<8 { start.signal() }

        XCTAssertEqual(probe.firstCallEntered.wait(timeout: .now() + 2), .success)
        Thread.sleep(forTimeInterval: 0.05)
        XCTAssertEqual(probe.callCount, 1)
        probe.releaseFirstCall.signal()
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.successCount, 0)
        XCTAssertEqual(probe.callCount, 1)

        XCTAssertEqual(catalog.probe(asset: media)?.durationSeconds, 240)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testFileRevisionChangeInvalidatesCachedProbe() throws {
        let probe = ConcurrentProbeRunner(outcomes: [
            .success(duration: 120), .success(duration: 180)
        ], blockFirstCall: false)
        let catalog = ServerMediaTrackCatalog(inspector: probe.inspector())
        let media = try asset()

        XCTAssertEqual(catalog.probe(asset: media)?.durationSeconds, 120)
        let handle = try FileHandle(forWritingTo: media.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
        XCTAssertEqual(catalog.probe(asset: media)?.durationSeconds, 180)
        XCTAssertEqual(probe.callCount, 2)
    }

    func testConcurrentEmbeddedSubtitleRequestsShareOneAsynchronousExport() throws {
        let payload = Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n你好\n".utf8)
        let exporter = ConcurrentSubtitleExporter(outcomes: [payload], blockedCallCount: 1)
        let catalog = subtitleCatalog(exporter: exporter)
        let media = try asset()
        let start = DispatchSemaphore(value: 0)
        let group = DispatchGroup()
        let results = LockedSubtitleStateCounter()

        for _ in 0..<12 {
            group.enter()
            DispatchQueue.global().async {
                start.wait()
                results.record(catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 17))
                group.leave()
            }
        }
        for _ in 0..<12 { start.signal() }

        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(group.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(results.pendingCount, 12)
        XCTAssertEqual(exporter.callCount, 1)
        exporter.release.signal()
        XCTAssertEqual(waitForSubtitle(catalog, asset: media, streamIndex: 17), payload)
        XCTAssertEqual(exporter.callCount, 1)
    }

    func testEmbeddedSubtitleFailureIsSharedThenExplicitRetryCanStartNewExport() throws {
        let payload = Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n重试成功\n".utf8)
        let clock = LockedUptime()
        let exporter = ConcurrentSubtitleExporter(outcomes: [nil, payload])
        let catalog = subtitleCatalog(exporter: exporter, uptimeProvider: { clock.value })
        let media = try asset()

        guard case .pending = catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 3) else {
            return XCTFail("首个请求应异步排队")
        }
        XCTAssertTrue(waitForSubtitleFailure(catalog, asset: media, streamIndex: 3))
        XCTAssertEqual(exporter.callCount, 1)
        guard case .failed = catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 3) else {
            return XCTFail("短暂失败窗口内的轮询必须共享失败")
        }

        clock.advance(by: 2)
        guard case .pending = catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 3) else {
            return XCTFail("失败窗口结束后的明确重试应启动新任务")
        }
        XCTAssertEqual(waitForSubtitle(catalog, asset: media, streamIndex: 3), payload)
        XCTAssertEqual(exporter.callCount, 2)
    }

    func testFileRevisionChangingDuringSubtitleExportDiscardsStalePayload() throws {
        let stale = Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n旧字幕\n".utf8)
        let current = Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n新字幕\n".utf8)
        let exporter = ConcurrentSubtitleExporter(outcomes: [stale, current], blockedCallCount: 1)
        let catalog = subtitleCatalog(exporter: exporter)
        let media = try asset()

        guard case .pending = catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 5) else {
            return XCTFail("首个请求应异步排队")
        }
        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        let handle = try FileHandle(forWritingTo: media.fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("+".utf8))
        try handle.close()
        guard case .pending = catalog.embeddedSubtitleWebVTT(for: media, streamIndex: 5) else {
            return XCTFail("新文件修订应立即启动自己的导出")
        }
        XCTAssertTrue(exporter.cancellations.first?.isCancelled == true)
        exporter.release.signal()

        XCTAssertEqual(waitForSubtitle(catalog, asset: media, streamIndex: 5), current)
        XCTAssertEqual(exporter.callCount, 2)
    }

    func testSubtitleWorkerPoolAllowsOnlyTwoFFmpegExportsAtOnce() throws {
        let payload = Data("WEBVTT\n\n00:00:00.000 --> 00:00:01.000\n字幕\n".utf8)
        let exporter = ConcurrentSubtitleExporter(
            outcomes: [payload, payload, payload],
            blockedCallCount: 3
        )
        let catalog = subtitleCatalog(exporter: exporter)
        let media = try asset()

        for streamIndex in 0..<3 {
            guard case .pending = catalog.embeddedSubtitleWebVTT(
                for: media, streamIndex: streamIndex
            ) else { return XCTFail("每条冷字幕都应异步排队") }
        }
        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(exporter.callCount, 2)
        XCTAssertEqual(exporter.peakConcurrentCount, 2)
        exporter.release.signal()
        XCTAssertEqual(exporter.entered.wait(timeout: .now() + 2), .success)
        exporter.release.signal()
        exporter.release.signal()

        for streamIndex in 0..<3 {
            XCTAssertEqual(waitForSubtitle(catalog, asset: media, streamIndex: streamIndex), payload)
        }
        XCTAssertEqual(exporter.callCount, 3)
        XCTAssertEqual(exporter.peakConcurrentCount, 2)
    }

    func testEmbeddedSubtitleHeadDoesNotStartExpensiveExport() throws {
        let exporter = ConcurrentSubtitleExporter(outcomes: [Data("unused".utf8)])
        let catalog = subtitleCatalog(exporter: exporter)

        guard case .pending = catalog.embeddedSubtitleWebVTT(
            for: try asset(), streamIndex: 0, startIfNeeded: false
        ) else { return XCTFail("未缓存的 HEAD 应报告尚未就绪") }
        XCTAssertEqual(exporter.callCount, 0)
    }

    /// 远程条目的字节在别人家的服务器上，ffprobe 够不着。这里返回 nil 而不是空
    /// 名单——空名单的语义是"这个文件确实没有音轨"。
    func testRemoteAssetsAreNotProbed() {
        let catalog = catalog(streams: #"{"index":0,"codec_type":"audio","codec_name":"aac"}"#)
        let remote = ServerMediaAsset(
            id: "remote-1",
            remoteURL: URL(string: "https://media.example/Videos/a/stream.mkv?api_key=SECRET")!,
            byteLength: 0
        )
        XCTAssertNil(catalog.audioTracks(for: remote))
        XCTAssertTrue(catalog.embeddedSubtitleStreams(for: remote).isEmpty)
    }

    private func subtitleCatalog(
        exporter: ConcurrentSubtitleExporter,
        uptimeProvider: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> ServerMediaTrackCatalog {
        ServerMediaTrackCatalog(
            ffmpegURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            subtitleExporter: { executable, arguments, maximumBytes, timeout, cancellation in
                exporter.run(executable, arguments, maximumBytes, timeout, cancellation)
            },
            uptimeProvider: uptimeProvider
        )
    }

    private func waitForSubtitle(
        _ catalog: ServerMediaTrackCatalog,
        asset: ServerMediaAsset,
        streamIndex: Int,
        timeout: TimeInterval = 2
    ) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            switch catalog.embeddedSubtitleWebVTT(for: asset, streamIndex: streamIndex) {
            case let .ready(payload): return payload
            case .failed: return nil
            case .pending: Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return nil
    }

    private func waitForSubtitleFailure(
        _ catalog: ServerMediaTrackCatalog,
        asset: ServerMediaAsset,
        streamIndex: Int
    ) -> Bool {
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline {
            switch catalog.embeddedSubtitleWebVTT(for: asset, streamIndex: streamIndex) {
            case .failed: return true
            case .ready: return false
            case .pending: Thread.sleep(forTimeInterval: 0.005)
            }
        }
        return false
    }
}

private final class LockedSubtitleStateCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPendingCount = 0

    var pendingCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPendingCount
    }

    func record(_ state: ServerMediaTrackCatalog.EmbeddedSubtitleExportState) {
        guard case .pending = state else { return }
        lock.lock()
        storedPendingCount += 1
        lock.unlock()
    }
}

private final class LockedUptime: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: TimeInterval = 100

    var value: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return storedValue
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        storedValue += interval
        lock.unlock()
    }
}

private final class ConcurrentSubtitleExporter: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let outcomes: [Data?]
    private let blockedCallCount: Int
    private var storedCallCount = 0
    private var activeCount = 0
    private var storedPeakConcurrentCount = 0
    private var storedCancellations: [ServerBoundedProcess.Cancellation] = []

    init(outcomes: [Data?], blockedCallCount: Int = 0) {
        self.outcomes = outcomes
        self.blockedCallCount = blockedCallCount
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    var peakConcurrentCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedPeakConcurrentCount
    }

    var cancellations: [ServerBoundedProcess.Cancellation] {
        lock.lock()
        defer { lock.unlock() }
        return storedCancellations
    }

    func run(
        _ executableURL: URL,
        _ arguments: [String],
        _ maximumBytes: Int,
        _ timeout: TimeInterval,
        _ cancellation: ServerBoundedProcess.Cancellation
    ) -> Data? {
        XCTAssertEqual(executableURL.path, "/usr/bin/ffmpeg-test-double")
        XCTAssertTrue(arguments.contains("webvtt"))
        XCTAssertEqual(maximumBytes, ServerWebVTTSubtitleTrack.maximumByteLength)
        XCTAssertGreaterThanOrEqual(timeout, 45)
        lock.lock()
        let index = storedCallCount
        storedCallCount += 1
        activeCount += 1
        storedPeakConcurrentCount = max(storedPeakConcurrentCount, activeCount)
        storedCancellations.append(cancellation)
        let outcome = outcomes[min(index, outcomes.count - 1)]
        lock.unlock()
        entered.signal()
        if index < blockedCallCount { release.wait() }
        lock.lock()
        activeCount -= 1
        lock.unlock()
        return outcome
    }
}

private final class LockedProbeResultCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var storedSuccessCount = 0

    var successCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedSuccessCount
    }

    func record(_ succeeded: Bool) {
        guard succeeded else { return }
        lock.lock()
        storedSuccessCount += 1
        lock.unlock()
    }
}

private final class ConcurrentProbeRunner: @unchecked Sendable {
    enum Outcome {
        case success(duration: Double)
        case failure
    }

    let firstCallEntered = DispatchSemaphore(value: 0)
    let releaseFirstCall = DispatchSemaphore(value: 0)
    private let lock = NSLock()
    private let outcomes: [Outcome]
    private let blockFirstCall: Bool
    private var storedCallCount = 0

    init(outcomes: [Outcome], blockFirstCall: Bool = true) {
        self.outcomes = outcomes
        self.blockFirstCall = blockFirstCall
    }

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return storedCallCount
    }

    func inspector() -> FFprobeMediaInspector {
        FFprobeMediaInspector(
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffprobe-test-double") },
            runner: { [self] _, _ in run() }
        )
    }

    private func run() -> FFprobeProcessOutput {
        lock.lock()
        let index = storedCallCount
        storedCallCount += 1
        let outcome = outcomes[min(index, outcomes.count - 1)]
        lock.unlock()
        if index == 0, blockFirstCall {
            firstCallEntered.signal()
            releaseFirstCall.wait()
        }
        switch outcome {
        case let .success(duration):
            let json = #"{"format":{"duration":"\#(duration)"},"streams":[{"index":0,"codec_type":"video","codec_name":"h264"},{"index":1,"codec_type":"audio","codec_name":"aac"}]}"#
            return FFprobeProcessOutput(
                exitCode: 0, standardOutput: Data(json.utf8), standardError: Data()
            )
        case .failure:
            return FFprobeProcessOutput(exitCode: 1, standardOutput: Data(), standardError: Data())
        }
    }
}

/// 重封装命令行。它决定了"画面会不会被重编码"——写错一个参数，家用 NAS 就要为
/// 每一次播放跑满几个小时的 CPU。
final class ServerAudioRemuxStreamTests: XCTestCase {
    private func stream(start: Double = 0, audio: Int = 1) -> ServerAudioRemuxStream {
        ServerAudioRemuxStream(
            asset: ServerMediaAsset(id: "item-1", fileURL: URL(fileURLWithPath: "/media/影片.mkv"), byteLength: 10),
            audioTrackID: audio,
            startSeconds: start,
            executableURL: URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double")
        )
    }

    func testCopiesVideoAndOnlyReencodesAudio() {
        let arguments = stream().arguments
        XCTAssertTrue(arguments.contains("copy"))
        XCTAssertEqual(arguments.firstIndex(of: "-c:v").map { arguments[$0 + 1] }, "copy")
        XCTAssertEqual(arguments.firstIndex(of: "-c:a").map { arguments[$0 + 1] }, "aac")
        XCTAssertEqual(arguments.firstIndex(of: "-map").map { arguments[$0 + 1] }, "0:v:0?")
        // 结尾的 `?` 让映射变成可选：探测与实际封装之间轨道消失了也不该整条流失败。
        XCTAssertTrue(arguments.contains("0:a:1?"))
    }

    /// `-ss` 必须在 `-i` **之前**：输入侧跳转是索引查找，输出侧跳转要把前面的
    /// 内容整段解码丢掉——一部两小时的片子跳到第 100 分钟，两者是毫秒与分钟的差别。
    func testSeekArgumentPrecedesInput() throws {
        let arguments = stream(start: 6000).arguments
        let seek = try XCTUnwrap(arguments.firstIndex(of: "-ss"))
        let input = try XCTUnwrap(arguments.firstIndex(of: "-i"))
        XCTAssertLessThan(seek, input)
        XCTAssertEqual(arguments[seek + 1], "6000.000")
    }

    /// 边转边发必须是分片 MP4：普通 MP4 的 moov 在文件末尾，要等整部片子转完才
    /// 能开始播。
    func testEmitsFragmentedMP4() {
        let arguments = stream().arguments
        XCTAssertEqual(arguments.firstIndex(of: "-f").map { arguments[$0 + 1] }, "mp4")
        XCTAssertEqual(
            arguments.firstIndex(of: "-movflags").map { arguments[$0 + 1] },
            "frag_keyframe+empty_moov+default_base_moof"
        )
        XCTAssertEqual(arguments.last, "-")
    }

    func testRejectsRemoteAssetsAndOutOfRangeInputs() {
        let remote = ServerMediaAsset(
            id: "remote", remoteURL: URL(string: "https://media.example/a")!, byteLength: 0
        )
        XCTAssertNil(ServerAudioRemuxStream.make(asset: remote, audioTrackID: 0, startSeconds: 0))
        let local = ServerMediaAsset(id: "a", fileURL: URL(fileURLWithPath: "/media/a.mkv"), byteLength: 1)
        XCTAssertNil(ServerAudioRemuxStream.make(asset: local, audioTrackID: -1, startSeconds: 0))
        XCTAssertNil(ServerAudioRemuxStream.make(asset: local, audioTrackID: 99, startSeconds: 0))
        XCTAssertNil(ServerAudioRemuxStream.make(asset: local, audioTrackID: 0, startSeconds: -1))
        XCTAssertNil(ServerAudioRemuxStream.make(asset: local, audioTrackID: 0, startSeconds: .infinity))
    }
}
