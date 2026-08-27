import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerHLSPlaybackSessionTests: XCTestCase {
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
