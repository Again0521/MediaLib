import Darwin
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

    func testSimultaneousCreatesCannotBypassPerUserConcurrentStreamPolicy() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-AtomicReservation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let assetURL = root.appendingPathComponent("fixture.mkv")
        try Data("fixture".utf8).write(to: assetURL)

        let contenderCount = 8
        let barrier = ConcurrentReservationBarrier(participantCount: contenderCount)
        let releaseResolver = DispatchSemaphore(value: 0)
        let descriptors = LockedHLSDescriptors()
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1,
            ffmpegFilterCapabilities: .init(
                softwareHDRToneMapping: false,
                videoToolboxHDRToneMapping: false
            ),
            ffmpegURLProvider: { URL(fileURLWithPath: "/usr/bin/false") },
            beforeReservation: { barrier.arriveAndWait() }
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        var configuredPolicy = ServerUserPolicy()
        configuredPolicy.maximumConcurrentStreams = 1
        let policy = configuredPolicy
        let requests = DispatchGroup()

        for index in 0..<contenderCount {
            requests.enter()
            DispatchQueue.global(qos: .userInitiated).async {
                defer { requests.leave() }
                if let descriptor = manager.create(
                    asset: ServerMediaAsset(
                        id: "simultaneous-\(index)", fileURL: assetURL, byteLength: 7
                    ),
                    request: ServerHLSPlaybackRequest(
                        audioTrackID: 0, startSeconds: 0, durationSeconds: 30
                    ),
                    actualStartSeconds: 0,
                    startResolver: { _ in
                        releaseResolver.wait()
                        return 0
                    },
                    videoCodec: "h264",
                    audioCodec: "aac",
                    principal: principal,
                    policy: policy
                ) {
                    descriptors.append(descriptor)
                }
            }
        }

        XCTAssertEqual(requests.wait(timeout: .now() + 5), .success)
        XCTAssertEqual(descriptors.values.count, 1)
        XCTAssertEqual(
            manager.administrativeSessions().filter {
                [.queued, .preparing, .ready, .playing].contains($0.state)
            }.count,
            1
        )
        releaseResolver.signal()
        if let accepted = descriptors.values.first {
            manager.cancel(sessionID: accepted.sessionID, principal: principal)
        }
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

    func testHEVCAndH265ParticipateInKeyframeAlignedSeeks() {
        XCTAssertTrue(ServerHLSPlaybackSessionManager.supportsKeyframeAlignedSeek(videoCodec: "hevc"))
        XCTAssertTrue(ServerHLSPlaybackSessionManager.supportsKeyframeAlignedSeek(videoCodec: "H265"))
        XCTAssertTrue(ServerHLSPlaybackSessionManager.supportsKeyframeAlignedSeek(videoCodec: "h264"))
        XCTAssertFalse(ServerHLSPlaybackSessionManager.supportsKeyframeAlignedSeek(videoCodec: "vp9"))
        XCTAssertFalse(ServerHLSPlaybackSessionManager.supportsKeyframeAlignedSeek(videoCodec: nil))
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

    func testKeyframePreparationReturnsImmediatelyPublishesResolvedStartAndCanBeForceCancelled() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-Preparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let executable = base.appendingPathComponent("fake-ffmpeg")
        let processIDFile = base.appendingPathComponent("ffmpeg.pid")
        let script = """
        #!/bin/sh
        printf '%s' "$$" > '\(processIDFile.path)'
        for last_argument do :; done
        printf '#EXTM3U\n#EXT-X-VERSION:3\n' > "$last_argument"
        trap '' TERM
        exec /usr/bin/tail -f /dev/null
        """
        try Data(script.utf8).write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let assetURL = base.appendingPathComponent("fixture.mkv")
        try Data("fixture".utf8).write(to: assetURL)

        let resolverEntered = DispatchSemaphore(value: 0)
        let releaseResolver = DispatchSemaphore(value: 0)
        let capturedCancellation = LockedProcessCancellation()
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: base.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1,
            ffmpegFilterCapabilities: .init(
                softwareHDRToneMapping: false,
                videoToolboxHDRToneMapping: false
            ),
            ffmpegURLProvider: { executable }
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let startedAt = ProcessInfo.processInfo.systemUptime
        let descriptor = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(id: "local-mkv", fileURL: assetURL, byteLength: 7),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 7, durationSeconds: 30),
            actualStartSeconds: 7,
            startResolver: { cancellation in
                capturedCancellation.value = cancellation
                resolverEntered.signal()
                releaseResolver.wait()
                return 6.5
            },
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ))

        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 0.2)
        XCTAssertEqual(descriptor.state, .preparing)
        XCTAssertEqual(resolverEntered.wait(timeout: .now() + 2), .success)
        XCTAssertEqual(
            manager.status(sessionID: descriptor.sessionID, principal: principal)?.state,
            .preparing
        )
        releaseResolver.signal()

        let readyDeadline = ContinuousClock.now.advanced(by: .seconds(2))
        var ready = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        while ready.state == .preparing && ContinuousClock.now < readyDeadline {
            try await Task.sleep(for: .milliseconds(20))
            ready = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(ready.state, .ready)
        XCTAssertEqual(
            ready.actualStartSeconds,
            6.25,
            "copied video exposes the resolved keyframe minus the bounded 250ms preroll"
        )
        let processID = try XCTUnwrap(Int(String(decoding: Data(contentsOf: processIDFile), as: UTF8.self)))

        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
        XCTAssertTrue(capturedCancellation.value?.isCancelled == true)
        XCTAssertNil(manager.status(sessionID: descriptor.sessionID, principal: principal))
        try await Task.sleep(for: .milliseconds(800))
        XCTAssertEqual(Darwin.kill(Int32(processID), 0), -1, "忽略 SIGTERM 的 HLS 进程必须被强制终止")
        XCTAssertEqual(errno, ESRCH)
    }

    func testCancellingPreparingSessionCancelsResolverAndNeverLaunchesFFmpeg() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-CancelPreparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let launchMarker = base.appendingPathComponent("ffmpeg-launched")
        let executable = base.appendingPathComponent("fake-ffmpeg")
        try Data("#!/bin/sh\nprintf launched > '\(launchMarker.path)'\n".utf8)
            .write(to: executable, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let assetURL = base.appendingPathComponent("fixture.mkv")
        try Data("fixture".utf8).write(to: assetURL)
        let resolverEntered = DispatchSemaphore(value: 0)
        let releaseResolver = DispatchSemaphore(value: 0)
        let capturedCancellation = LockedProcessCancellation()
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: base.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1,
            ffmpegFilterCapabilities: .init(
                softwareHDRToneMapping: false,
                videoToolboxHDRToneMapping: false
            ),
            ffmpegURLProvider: { executable }
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let descriptor = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(id: "cancelled-mkv", fileURL: assetURL, byteLength: 7),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 12, durationSeconds: 30),
            actualStartSeconds: 12,
            startResolver: { cancellation in
                capturedCancellation.value = cancellation
                resolverEntered.signal()
                releaseResolver.wait()
                return 10
            },
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ))
        XCTAssertEqual(resolverEntered.wait(timeout: .now() + 2), .success)

        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
        XCTAssertTrue(capturedCancellation.value?.isCancelled == true)
        releaseResolver.signal()
        try await Task.sleep(for: .milliseconds(250))

        XCTAssertNil(manager.status(sessionID: descriptor.sessionID, principal: principal))
        XCTAssertFalse(FileManager.default.fileExists(atPath: launchMarker.path))
    }

    func testInvalidResolvedStartFailsSessionWithoutHoldingConcurrencySlot() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-InvalidPreparation-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let assetURL = base.appendingPathComponent("fixture.mkv")
        try Data("fixture".utf8).write(to: assetURL)
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: base.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1,
            ffmpegFilterCapabilities: .init(
                softwareHDRToneMapping: false,
                videoToolboxHDRToneMapping: false
            ),
            ffmpegURLProvider: { base.appendingPathComponent("must-not-launch") }
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let descriptor = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(id: "invalid-start", fileURL: assetURL, byteLength: 7),
            request: ServerHLSPlaybackRequest(audioTrackID: 0, startSeconds: 7, durationSeconds: 30),
            actualStartSeconds: 7,
            startResolver: { _ in .nan },
            videoCodec: "h264",
            audioCodec: "aac",
            principal: principal
        ))

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        while status.state == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .failed)
        XCTAssertFalse(manager.administrativeSessions().contains { $0.state == .preparing || $0.state == .queued })
    }

    func testMissingRemoteProbeFallsBackToFullTranscodeInsteadOfFailingPreparation() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-ProbeFallback-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: base) }
        let remoteURL = URL(string: "https://media.example/unavailable.mkv?token=SECRET")!
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: base.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1,
            ffmpegFilterCapabilities: .init(
                softwareHDRToneMapping: false,
                videoToolboxHDRToneMapping: false
            ),
            ffmpegURLProvider: { URL(fileURLWithPath: "/usr/bin/false") }
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let descriptor = try XCTUnwrap(manager.create(
            asset: ServerMediaAsset(
                id: "probe-fallback", remoteURL: remoteURL,
                byteLength: 1_024, contentType: "video/x-matroska"
            ),
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0, startSeconds: 0, durationSeconds: 30
            ),
            actualStartSeconds: 0,
            videoCodec: nil,
            audioCodec: nil,
            preparationResolver: { _, cancellation in
                guard !cancellation.isCancelled else { return nil }
                return ServerHLSPreparedMedia(
                    remoteProbe: nil,
                    selectedAudioID: 0,
                    fallbackDurationSeconds: 30,
                    actualStartSeconds: 0
                )
            },
            principal: principal
        ))
        XCTAssertEqual(descriptor.mode, "hlsPreparing")

        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        var status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        while status.state == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(20))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .failed, "fake FFmpeg exits, but negotiation itself must succeed")
        XCTAssertEqual(status.mode, "hlsTranscode")
        XCTAssertEqual(status.reason, "videoCodecCompatibility")
        XCTAssertEqual(status.durationSeconds, 30)
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
        let remoteAsset = ServerMediaAsset(
            id: "remote-mkv",
            remoteURL: upstream,
            byteLength: Int64(fixtureData.count),
            contentType: "video/x-matroska"
        )
        let trackCatalog = ServerMediaTrackCatalog()
        let descriptor = try XCTUnwrap(manager.create(
            asset: remoteAsset,
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0,
                startSeconds: 0,
                durationSeconds: 7
            ),
            actualStartSeconds: 0,
            videoCodec: nil,
            audioCodec: nil,
            preparationResolver: { bridgeURL, cancellation in
                guard let probe = trackCatalog.probeRemote(
                    asset: remoteAsset,
                    through: bridgeURL,
                    cancellation: cancellation
                ) else { return nil }
                return ServerHLSPreparedMedia(
                    videoCodec: probe.video.first?.codec,
                    videoHeight: probe.video.first?.height,
                    sourceIsHDR: probe.video.first?.isHDR == true,
                    audioCodec: probe.audio.first?.codec,
                    durationSeconds: probe.durationSeconds,
                    actualStartSeconds: 0
                )
            },
            principal: principal
        ))

        XCTAssertEqual(descriptor.mode, "hlsPreparing")
        XCTAssertEqual(descriptor.reason, "capabilityNegotiation")
        XCTAssertEqual(descriptor.durationSeconds, 7)
        XCTAssertEqual(descriptor.state, .preparing)
        XCTAssertFalse(descriptor.mediaURL.contains("emby.example"))
        XCTAssertFalse(descriptor.mediaURL.contains("secret"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = descriptor
        while status.state == .preparing && ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .ready)
        XCTAssertEqual(status.mode, "hlsRemux")
        XCTAssertEqual(status.reason, "containerCompatibility")
        XCTAssertEqual(status.durationSeconds ?? 0, 7, accuracy: 0.1)
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

    func testRemoteH264AC3MKVTranscodesOnlyAudioToAAC() async throws {
        guard let ffmpeg = ServerMediaToolchain.ffmpegURL(),
              let ffprobe = ServerMediaToolchain.ffprobeURL()
        else { throw XCTSkip("ffmpeg and ffprobe are required") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-Remote-AC3-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("remote-ac3.mkv")
        try run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=523:sample_rate=48000",
            "-t", "4", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-pix_fmt", "yuv420p", "-g", "48", "-c:a", "ac3", "-b:a", "384k",
            fixture.path
        ])
        let fixtureData = try Data(contentsOf: fixture)
        let upstream = URL(string: "https://plex.example/library/parts/opaque/file.mkv?X-Plex-Token=SECRET")!
        let fetcher = ServerRemoteAssetFetcher(
            responseOverride: { url, offset, length in
                guard url == upstream, let offset, let length,
                      offset >= 0, length > 0,
                      offset <= Int64(fixtureData.count),
                      length <= Int64(fixtureData.count) - offset
                else { return nil }
                return fixtureData.subdata(in: Int(offset)..<Int(offset + length))
            },
            mediaLengthOverride: { $0 == upstream ? Int64(fixtureData.count) : nil }
        )
        let asset = ServerMediaAsset(
            id: "remote-ac3", remoteURL: upstream,
            byteLength: Int64(fixtureData.count), contentType: "video/x-matroska"
        )
        let trackCatalog = ServerMediaTrackCatalog()
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: fetcher,
            rootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let descriptor = try XCTUnwrap(manager.create(
            asset: asset,
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0, startSeconds: 0, durationSeconds: 4
            ),
            actualStartSeconds: 0,
            videoCodec: nil,
            audioCodec: nil,
            preparationResolver: { bridgeURL, cancellation in
                let probe = trackCatalog.probeRemote(
                    asset: asset, through: bridgeURL, cancellation: cancellation
                )
                guard !cancellation.isCancelled else { return nil }
                return ServerHLSPreparedMedia(
                    remoteProbe: probe,
                    selectedAudioID: 0,
                    fallbackDurationSeconds: 4,
                    actualStartSeconds: 0
                )
            },
            principal: principal
        ))
        XCTAssertEqual(descriptor.mode, "hlsPreparing")

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = descriptor
        while [.queued, .preparing, .ready, .playing].contains(status.state),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .finished)
        XCTAssertEqual(status.mode, "hlsAudioTranscode")
        XCTAssertEqual(status.reason, "audioCodecCompatibility")
        let playlist = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        guard case let .file(playlistURL, _) = playlist.storage else {
            return XCTFail("HLS manifest must remain a streamed file resource")
        }
        let codecs = try runOutput(ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name",
            "-of", "csv=p=0", playlistURL.path
        ])
        XCTAssertTrue(codecs.contains("h264"), "video must remain copied as H.264")
        XCTAssertTrue(codecs.contains("aac"), "AC-3 must be transcoded to browser-compatible AAC")
        XCTAssertFalse(codecs.contains("ac3"))
        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
    }

    func testLocalH264TrueHDMKVTranscodesOnlyAudioToAACAndRetainsSeekOrigin() async throws {
        guard let ffmpeg = ServerMediaToolchain.ffmpegURL(),
              let ffprobe = ServerMediaToolchain.ffprobeURL()
        else { throw XCTSkip("ffmpeg and ffprobe are required") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-Local-TrueHD-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("h264-truehd.mkv")
        try run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=587:sample_rate=48000",
            "-t", "5", "-c:v", "h264_videotoolbox", "-allow_sw", "1",
            "-pix_fmt", "yuv420p", "-g", "48",
            "-c:a", "truehd", "-ac", "2", "-strict", "-2", fixture.path
        ])
        let sourceCodecs = try runOutput(ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name", "-of", "csv=p=0", fixture.path
        ])
        XCTAssertTrue(sourceCodecs.contains("h264"))
        XCTAssertTrue(sourceCodecs.contains("truehd"), "fixture must exercise a real TrueHD decoder input")

        let byteLength = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value
        )
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: root.appendingPathComponent("sessions", isDirectory: true),
            maximumConcurrentSessions: 1
        )
        let trackCatalog = ServerMediaTrackCatalog()
        let asset = ServerMediaAsset(id: "h264-truehd", fileURL: fixture, byteLength: byteLength)
        let principal = ServerRequestPrincipal.testAdministrator()
        let requestedStart = 2.8
        let descriptor = try XCTUnwrap(manager.create(
            asset: asset,
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0, startSeconds: requestedStart, durationSeconds: 5
            ),
            actualStartSeconds: requestedStart,
            startResolver: { cancellation in
                trackCatalog.keyframeStart(
                    for: asset, at: requestedStart, cancellation: cancellation
                ) ?? requestedStart
            },
            videoCodec: "h264",
            audioCodec: "truehd",
            principal: principal
        ))
        XCTAssertEqual(descriptor.mode, "hlsAudioTranscode")
        XCTAssertEqual(descriptor.reason, "audioCodecCompatibility")

        let deadline = ContinuousClock.now.advanced(by: .seconds(12))
        var status = descriptor
        while [.queued, .preparing, .ready, .playing].contains(status.state),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .finished)
        XCTAssertEqual(status.mode, "hlsAudioTranscode")
        XCTAssertLessThan(status.actualStartSeconds, requestedStart)
        XCTAssertGreaterThanOrEqual(status.actualStartSeconds, 0)

        let playlist = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        guard case let .file(playlistURL, _) = playlist.storage else {
            return XCTFail("TrueHD HLS manifest must remain a streamed file resource")
        }
        let outputProbe = try runOutput(ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name,start_time",
            "-of", "json", playlistURL.path
        ])
        let outputProbeJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(outputProbe.utf8)) as? [String: Any]
        )
        let outputStreams: [[String: Any]] = try XCTUnwrap(
            outputProbeJSON["streams"] as? [[String: Any]]
        )
        let video = try XCTUnwrap(outputStreams.first { $0["codec_name"] as? String == "h264" })
        let outputAudio = try XCTUnwrap(outputStreams.first { $0["codec_name"] as? String == "aac" })
        let videoStart = Double(video["start_time"] as? String ?? "")
        let audioStart = Double(outputAudio["start_time"] as? String ?? "")
        XCTAssertNotNil(videoStart)
        XCTAssertNotNil(audioStart)
        XCTAssertEqual(videoStart ?? 0, audioStart ?? 0, accuracy: 0.30,
                       "seeked TrueHD audio and copied H.264 must share the bounded preroll")
        let audioProbeData = try runOutput(ffprobe, [
            "-v", "error", "-select_streams", "a:0", "-count_packets",
            "-show_entries", "stream=codec_name,nb_read_packets", "-of", "json", playlistURL.path
        ])
        let audioProbe = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(audioProbeData.utf8)) as? [String: Any]
        )
        let streams: [[String: Any]] = try XCTUnwrap(audioProbe["streams"] as? [[String: Any]])
        guard let audio: [String: Any] = streams.first else {
            return XCTFail("transcoded HLS must contain one readable audio stream")
        }
        XCTAssertEqual(audio["codec_name"] as? String, "aac")
        XCTAssertGreaterThan(Int(audio["nb_read_packets"] as? String ?? "0") ?? 0, 0)
        try run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error", "-i", playlistURL.path,
            "-map", "0:a:0", "-f", "null", "-"
        ])

        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
    }

    func testNativeHEVCHLSUsesDecodableFragmentedMP4Resources() async throws {
        guard let ffmpeg = ServerMediaToolchain.ffmpegURL(),
              let ffprobe = ServerMediaToolchain.ffprobeURL()
        else { throw XCTSkip("ffmpeg and ffprobe are required") }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-HLS-HEVC-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = root.appendingPathComponent("hevc.mkv")
        try run(ffmpeg, [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "lavfi", "-i", "testsrc2=size=320x180:rate=24",
            "-f", "lavfi", "-i", "sine=frequency=660:sample_rate=48000",
            "-t", "5", "-c:v", "hevc_videotoolbox", "-allow_sw", "1",
            "-pix_fmt", "yuv420p", "-g", "48", "-c:a", "aac", fixture.path
        ])
        let byteLength = try XCTUnwrap(
            (FileManager.default.attributesOfItem(atPath: fixture.path)[.size] as? NSNumber)?.int64Value
        )
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let manager = ServerHLSPlaybackSessionManager(
            remoteAssetFetcher: ServerRemoteAssetFetcher(),
            rootDirectory: sessions,
            maximumConcurrentSessions: 1
        )
        let principal = ServerRequestPrincipal.testAdministrator()
        let capabilities = ServerWebClientCapabilities(
            nativeHLS: true,
            mediaSource: false,
            videoCodecs: ["hevc"],
            audioCodecs: ["aac"],
            screenWidth: 1_920,
            screenHeight: 1_080,
            hdrDisplay: false,
            measuredDownlinkMbps: 80
        )
        let asset = ServerMediaAsset(id: "hevc-mkv", fileURL: fixture, byteLength: byteLength)
        let trackCatalog = ServerMediaTrackCatalog()
        let descriptor = try XCTUnwrap(manager.create(
            asset: asset,
            request: ServerHLSPlaybackRequest(
                audioTrackID: 0,
                startSeconds: 2.8,
                durationSeconds: 5,
                capabilities: capabilities
            ),
            actualStartSeconds: 2.8,
            startResolver: { cancellation in
                trackCatalog.keyframeStart(for: asset, at: 2.8, cancellation: cancellation) ?? 2.8
            },
            videoCodec: "hevc",
            audioCodec: "aac",
            principal: principal
        ))
        XCTAssertEqual(descriptor.mode, "hlsRemux")

        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        var status = descriptor
        while [.queued, .preparing, .ready, .playing].contains(status.state),
              ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50))
            status = try XCTUnwrap(manager.status(sessionID: descriptor.sessionID, principal: principal))
        }
        XCTAssertEqual(status.state, .finished)
        XCTAssertLessThan(status.actualStartSeconds, 2.8)
        XCTAssertEqual(
            status.actualStartSeconds,
            1.75,
            accuracy: 0.15,
            "native HEVC HLS exposes the keyframe plus the copied-video preroll"
        )

        let playlist = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        guard case let .file(playlistURL, _) = playlist.storage else {
            return XCTFail("HEVC manifest must remain a streamed file resource")
        }
        let manifest = try String(contentsOf: playlistURL, encoding: .utf8)
        XCTAssertTrue(manifest.contains("#EXT-X-MAP:URI=\"init.mp4\""))
        XCTAssertTrue(manifest.contains("segment-00000.m4s"))
        XCTAssertFalse(manifest.contains("segment-00000.ts"))

        let initialization = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "init.mp4",
            principal: principal
        ))
        XCTAssertEqual(initialization.contentType, "video/mp4")
        guard case .file = initialization.storage else {
            return XCTFail("HEVC initialization resource must stream from disk")
        }
        let fragment = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "segment-00000.m4s",
            principal: principal
        ))
        XCTAssertEqual(fragment.contentType, "video/iso.segment")
        guard case .file = fragment.storage else {
            return XCTFail("HEVC media fragment must stream from disk")
        }
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "segment-00000.mp4",
            principal: principal
        ))

        // A successful ffprobe read across the generated manifest, init file
        // and media fragments proves this is not only a string-shaped HLS
        // fixture: the bundled toolchain can demux the complete HEVC stream.
        try run(ffprobe, [
            "-v", "error", "-show_entries", "stream=codec_name",
            "-of", "default=noprint_wrappers=1", playlistURL.path
        ])
        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
    }

    private func run(_ executable: URL, _ arguments: [String]) throws {
        _ = try runOutput(executable, arguments)
    }

    private func runOutput(_ executable: URL, _ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0 else {
            let message = String(data: data, encoding: .utf8) ?? ""
            XCTFail("ffmpeg fixture creation failed: \(message)")
            throw CocoaError(.fileWriteUnknown)
        }
        return String(data: data, encoding: .utf8) ?? ""
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

private final class LockedProcessCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValue: ServerBoundedProcess.Cancellation?

    var value: ServerBoundedProcess.Cancellation? {
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

private final class ConcurrentReservationBarrier: @unchecked Sendable {
    private let condition = NSCondition()
    private let participantCount: Int
    private var arrived = 0

    init(participantCount: Int) { self.participantCount = participantCount }

    func arriveAndWait() {
        condition.lock()
        arrived += 1
        if arrived == participantCount {
            condition.broadcast()
        } else {
            while arrived < participantCount { condition.wait() }
        }
        condition.unlock()
    }
}

private final class LockedHLSDescriptors: @unchecked Sendable {
    private let lock = NSLock()
    private var storedValues: [ServerHLSPlaybackDescriptor] = []

    func append(_ value: ServerHLSPlaybackDescriptor) {
        lock.lock()
        storedValues.append(value)
        lock.unlock()
    }

    var values: [ServerHLSPlaybackDescriptor] {
        lock.lock()
        defer { lock.unlock() }
        return storedValues
    }
}
