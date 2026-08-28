import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerHLSPlaybackSessionTests: XCTestCase {
    func testOperationalSettingsProviderControlsNewSessionsWithoutRestart() {
        let settings = LockedOperationalSettings(ServerOperationalSettings(
            transcodeEngine: .software,
            maximumTranscodeSessions: 1,
            defaultRemoteBitrateMbps: 8,
            sessionIdleMinutes: 5
        ))
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            operationalSettingsProvider: { settings.value },
            configurationCacheLifetime: 0
        )
        XCTAssertEqual(manager.operationalSettingsSnapshot().maximumTranscodeSessions, 1)
        settings.value = ServerOperationalSettings(
            transcodeEngine: .videoToolbox,
            maximumTranscodeSessions: 4,
            defaultRemoteBitrateMbps: 40,
            sessionIdleMinutes: 30
        )
        XCTAssertEqual(manager.operationalSettingsSnapshot().maximumTranscodeSessions, 4)
        XCTAssertEqual(manager.operationalSettingsSnapshot().defaultRemoteBitrateMbps, 40)
        XCTAssertEqual(
            ServerHLSPlaybackSessionManager.encoderArguments(for: .software),
            ["-c:v", "libx264", "-preset", "medium"]
        )
        XCTAssertEqual(
            ServerHLSPlaybackSessionManager.encoderArguments(for: .videoToolbox),
            ["-c:v", "h264_videotoolbox", "-allow_sw", "0"]
        )
    }

    func testFFmpegHDRFilterCapabilitiesRequireACompleteChain() {
        XCTAssertEqual(
            ServerMediaToolchain.FFmpegFilterCapabilities.parse(" TS tonemap V->V\n TS zscale V->V\n"),
            .init(softwareHDRToneMapping: true, videoToolboxHDRToneMapping: false)
        )
        XCTAssertEqual(
            ServerMediaToolchain.FFmpegFilterCapabilities.parse(" TS tonemap V->V\n"),
            .init(softwareHDRToneMapping: false, videoToolboxHDRToneMapping: false),
            "tonemap 没有 zscale 不能正确线性化 HDR 输入"
        )
        XCTAssertTrue(ServerHLSPlaybackSessionManager.softwareHDRToneMappingFilter.contains("bt709"))
    }

    func testQualityNegotiationNeverUpscalesAndBoundsBitrateByNetworkTierAndPolicy() {
        let capabilities = ServerWebClientCapabilities(
            nativeHLS: false,
            mediaSource: true,
            videoCodecs: ["h264"],
            audioCodecs: ["aac"],
            screenWidth: 1920,
            screenHeight: 1080,
            hdrDisplay: false,
            measuredDownlinkMbps: 6
        )
        let request = ServerHLSPlaybackRequest(
            audioTrackID: 0,
            startSeconds: 0,
            durationSeconds: 3_600,
            capabilities: capabilities,
            quality: .quality720p,
            maximumBitrateMbps: 100
        )
        XCTAssertEqual(ServerHLSPlaybackSessionManager.targetVideoHeight(
            quality: .quality720p, sourceHeight: 2_160, capabilities: capabilities
        ), 720)
        XCTAssertNil(ServerHLSPlaybackSessionManager.targetVideoHeight(
            quality: .quality2160p, sourceHeight: 1_080, capabilities: capabilities
        ), "手动画质不能把 1080p 源放大成 2160p")
        XCTAssertEqual(ServerHLSPlaybackSessionManager.targetVideoHeight(
            quality: .auto, sourceHeight: 2_160, capabilities: capabilities
        ), 720, "自动档同时受屏幕与测得吞吐约束")
        var policy = ServerUserPolicy()
        policy.remoteBitrateLimitMbps = 3
        XCTAssertEqual(ServerHLSPlaybackSessionManager.effectiveBitrateMbps(
            request: request, policy: policy, defaultValue: 20, targetHeight: 720
        ), 3)
        XCTAssertFalse(ServerHLSPlaybackRequest(
            audioTrackID: 0,
            startSeconds: 0,
            durationSeconds: 1,
            capabilities: capabilities,
            maximumBitrateMbps: 201
        ).isValid)
    }

    func testRemoteMKVProducesAuthenticatedHLSWithoutExposingUpstreamURL() async throws {
        guard let ffmpeg = ServerMediaToolchain.ffmpegURL() else {
            throw XCTSkip("ffmpeg is not installed in this test environment")
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-Test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("fixture.mkv")
        try run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=440:sample_rate=48000",
            "-t", "7", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-pix_fmt", "yuv420p", "-g", "48", "-c:a", "aac", fixture.path
        ])
        let fixtureData = try Data(contentsOf: fixture)
        let upstream = URL(string: "https://emby.example/Videos/opaque/stream?api_key=secret")!
        let fetcher = ServerRemoteAssetFetcher(
            responseOverride: { url, offset, length in
                guard url == upstream, let offset, let length,
                      offset >= 0, length > 0, offset + length <= Int64(fixtureData.count)
                else { return nil }
                return fixtureData.subdata(in: Int(offset)..<Int(offset + length))
            },
            mediaLengthOverride: { $0 == upstream ? Int64(fixtureData.count) : nil }
        )
        let output = root.appendingPathComponent("sessions", isDirectory: true)
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: fetcher,
            rootDirectory: output,
            maximumConcurrentSessions: 1
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let descriptor = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(
                id: "remote-mkv",
                remoteURL: upstream,
                byteLength: Int64(fixtureData.count),
                contentType: "video/x-matroska"
            ),
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0,
                startSeconds: 0,
                durationSeconds: 7
            ),
            actualStartSeconds: 0,
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ))

        XCTAssertEqual(descriptor.mode, "hlsRemux")
        XCTAssertEqual(descriptor.durationSeconds, 7)
        XCTAssertTrue([.preparing, .ready].contains(descriptor.state))
        XCTAssertFalse(descriptor.mediaURL.contains("emby.example"))
        XCTAssertFalse(descriptor.mediaURL.contains("secret"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = descriptor
        while status.state == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .ready)
        let playlist = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        guard case let .file(playlistURL, _) = playlist.storage else {
            return XCTFail("生产 HLS 资源必须通过文件流响应，而不是整体读入 Data")
        }
        let manifest = try XCTUnwrap(String(data: Data(contentsOf: playlistURL), encoding: .utf8))
        XCTAssertTrue(manifest.hasPrefix("#EXTM3U"))
        XCTAssertTrue(manifest.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(manifest.contains("segment-00000.ts"))
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "../fixture.mkv",
            principal: principal
        ))

        let queued = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(
                id: "remote-mkv-queued", remoteURL: upstream,
                byteLength: Int64(fixtureData.count), contentType: "video/x-matroska"
            ),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 0, durationSeconds: 7),
            actualStartSeconds: 0,
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ))
        XCTAssertEqual(queued.state, .queued)
        XCTAssertNil(manager.create(
            asset: ServerMediaAsset(
                id: "remote-mkv-over-limit", remoteURL: upstream,
                byteLength: Int64(fixtureData.count), contentType: "video/x-matroska"
            ),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 0, durationSeconds: 7),
            actualStartSeconds: 0,
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ), "账号默认最多同时拥有两个进行中或排队中的播放会话")

        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        var queuedStatus = try XCTUnwrap(manager.status(sessionID: queued.sessionID, principal: principal))
        let queuedDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        while [.queued, .preparing].contains(queuedStatus.state) && ContinuousClock.now < queuedDeadline {
            try await Task.sleep(for: .milliseconds(50))
            queuedStatus = try XCTUnwrap(manager.status(sessionID: queued.sessionID, principal: principal))
        }
        XCTAssertEqual(queuedStatus.state, .ready)
        manager.cancel(sessionID: queued.sessionID, principal: principal)

        var noRemuxPolicy = ServerUserPolicy()
        noRemuxPolicy.remuxAllowed = false
        XCTAssertNil(manager.create(
            asset: ServerMediaAsset(
                id: "remote-mkv-policy-denied", remoteURL: upstream,
                byteLength: Int64(fixtureData.count), contentType: "video/x-matroska"
            ),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 0, durationSeconds: 7),
            actualStartSeconds: 0,
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal,
            policy: noRemuxPolicy
        ))
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            XCTFail("ffmpeg fixture creation failed: \(message)")
            throw CocoaError(.fileWriteUnknown)
        }
    }
}

private final class LockedOperationalSettings: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ServerOperationalSettings

    init(_ value: ServerOperationalSettings) { storedValue = value }

    var value: ServerOperationalSettings {
        get {
            lock.lock()
            defer { lock.unlock() }
            return storedValue
        }
        set {
            lock.lock()
            storedValue = newValue
            lock.unlock()
        }
    }
}
