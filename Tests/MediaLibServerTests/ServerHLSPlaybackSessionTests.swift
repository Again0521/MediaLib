import Foundation
import XCTest
@testable import MediaLibServer

final class ServerHLSPlaybackSessionTests: XCTestCase {
    func testRemoteMKVProducesAuthenticatedHLSWithoutExposingUpstreamURL() throws {
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
            rootDirectory: output
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
        XCTAssertFalse(descriptor.mediaURL.contains("emby.example"))
        XCTAssertFalse(descriptor.mediaURL.contains("secret"))
        let playlist = try XCTUnwrap(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
        ))
        let manifest = try XCTUnwrap(String(data: playlist.data, encoding: .utf8))
        XCTAssertTrue(manifest.hasPrefix("#EXTM3U"))
        XCTAssertTrue(manifest.contains("#EXT-X-INDEPENDENT-SEGMENTS"))
        XCTAssertTrue(manifest.contains("segment-00000.ts"))
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "../fixture.mkv",
            principal: principal
        ))

        manager.cancel(sessionID: descriptor.sessionID, principal: principal)
        XCTAssertNil(manager.resource(
            sessionID: descriptor.sessionID,
            fileName: "index.m3u8",
            principal: principal
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
