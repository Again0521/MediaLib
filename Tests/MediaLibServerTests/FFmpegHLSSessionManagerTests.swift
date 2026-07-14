import Foundation
import XCTest
@testable import MediaLibServer
import MediaLibServerProtocol

final class FFmpegHLSSessionManagerTests: XCTestCase {
    private let ownerSessionID = "owner-session"
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testStartBuildsIsolatedSessionAndCancelRemovesIt() throws {
        let cacheDirectory = try makeTemporaryDirectory()
        let process = ProcessStub()
        var capturedArguments: [String] = []
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, arguments, _ in
                capturedArguments = arguments
                return process
            }
        )

        let session = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        guard let manifestPath = capturedArguments.last else { return XCTFail("Missing manifest argument") }
        let manifestURL = URL(fileURLWithPath: manifestPath)
        try Data("#EXTM3U\n".utf8).write(to: manifestURL)

        XCTAssertEqual(session.itemID, "movie-1")
        XCTAssertEqual(session.manifestPath, "/api/v1/hls/\(session.id)/index.m3u8")
        XCTAssertFalse(session.manifestPath.contains("private"))
        XCTAssertTrue(capturedArguments.contains("-hls_segment_filename"))
        XCTAssertEqual(manager.outputURL(sessionID: session.id, fileName: "index.m3u8", ownerSessionID: ownerSessionID), manifestURL)
        XCTAssertNil(manager.outputURL(sessionID: session.id, fileName: "index.m3u8", ownerSessionID: "other-session"))
        XCTAssertNil(manager.outputURL(sessionID: session.id, fileName: "../secret.m3u8", ownerSessionID: ownerSessionID))
        XCTAssertNil(manager.outputURL(sessionID: session.id, fileName: "anything.mp4", ownerSessionID: ownerSessionID))

        XCTAssertFalse(manager.cancel(sessionID: session.id, ownerSessionID: "other-session"))
        XCTAssertTrue(manager.cancel(sessionID: session.id, ownerSessionID: ownerSessionID))

        XCTAssertTrue(process.didTerminate)
        XCTAssertEqual(manager.activeSessionCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: manifestURL.deletingLastPathComponent().path))
    }

    func testFailedStartCleansTemporaryDirectory() throws {
        let cacheDirectory = try makeTemporaryDirectory()
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, _, _ in throw StartupFailure.unavailable }
        )

        XCTAssertThrowsError(try manager.start(asset: asset(), ownerSessionID: ownerSessionID))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: cacheDirectory.path), [])
    }

    func testConcurrentSessionLimitPreventsTranscodeResourceExhaustion() throws {
        let cacheDirectory = try makeTemporaryDirectory()
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, _, _ in ProcessStub() },
            maximumConcurrentSessions: 1
        )
        let first = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        defer { manager.cancel(sessionID: first.id, ownerSessionID: ownerSessionID) }

        XCTAssertThrowsError(try manager.start(asset: asset(), ownerSessionID: ownerSessionID)) { error in
            guard case FFmpegHLSSessionManagerError.capacityReached = error else {
                return XCTFail("Expected capacityReached, received \(error)")
            }
        }
        XCTAssertEqual(manager.activeSessionCount, 1)
    }

    func testCompletedSessionsDoNotConsumeTranscodeConcurrencyAndRetentionIsBounded() throws {
        let cacheDirectory = try makeTemporaryDirectory()
        var processes: [ProcessStub] = []
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, _, _ in
                let process = ProcessStub()
                processes.append(process)
                return process
            },
            maximumConcurrentSessions: 1,
            maximumRetainedSessions: 2
        )

        let first = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        processes[0].terminate()
        let second = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        processes[1].terminate()
        let third = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        defer { manager.cancel(sessionID: third.id, ownerSessionID: ownerSessionID) }

        XCTAssertEqual(manager.activeSessionCount, 2)
        XCTAssertNil(manager.outputURL(sessionID: first.id, fileName: "index.m3u8", ownerSessionID: ownerSessionID))
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: cacheDirectory.appendingPathComponent(first.id, isDirectory: true).path
        ))
        XCTAssertNotEqual(second.id, third.id)
    }

    func testIdleSessionExpiresAndCleansDirectoryWithoutClientDelete() throws {
        let cacheDirectory = try makeTemporaryDirectory()
        var now = Date(timeIntervalSince1970: 100)
        let process = ProcessStub()
        let manager = FFmpegHLSSessionManager(
            cacheDirectory: cacheDirectory,
            executableURLProvider: { URL(fileURLWithPath: "/usr/bin/ffmpeg-test-double") },
            processFactory: { _, _, _ in process },
            idleSessionLifetime: 10,
            clock: { now }
        )
        let session = try manager.start(asset: asset(), ownerSessionID: ownerSessionID)
        let directory = cacheDirectory.appendingPathComponent(session.id, isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: directory.path))

        now = now.addingTimeInterval(11)

        XCTAssertEqual(manager.activeSessionCount, 0)
        XCTAssertTrue(process.didTerminate)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testDefaultFFmpegGeneratesPlaylistFromBundledImageWhenInstalled() throws {
        let fixtureURL = repositoryRoot().appendingPathComponent("Sources/MediaLib/Resources/AppIcon.png")
        guard FileManager.default.fileExists(atPath: fixtureURL.path) else {
            throw XCTSkip("未找到 HLS 集成验证的内置图标。")
        }
        let cacheDirectory = try makeTemporaryDirectory()
        let manager = FFmpegHLSSessionManager(cacheDirectory: cacheDirectory)
        let session: ServerHLSPlaybackSession
        do {
            session = try manager.start(
                asset: ServerMediaAsset(id: "icon-fixture", fileURL: fixtureURL, byteLength: 1),
                ownerSessionID: ownerSessionID
            )
        } catch FFmpegHLSSessionManagerError.unavailable {
            throw XCTSkip("当前环境未安装 ffmpeg；仅跳过真实 HLS 集成验证。")
        }
        defer { manager.cancel(sessionID: session.id, ownerSessionID: ownerSessionID) }

        let deadline = Date().addingTimeInterval(8)
        var manifestURL: URL?
        while Date() < deadline {
            manifestURL = manager.outputURL(
                sessionID: session.id,
                fileName: "index.m3u8",
                ownerSessionID: ownerSessionID
            )
            if manifestURL != nil { break }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
        }

        guard let manifestURL else { return XCTFail("ffmpeg 未在期限内生成 HLS playlist") }
        let playlist = try String(contentsOf: manifestURL, encoding: .utf8)
        XCTAssertTrue(playlist.hasPrefix("#EXTM3U"))
        XCTAssertTrue(playlist.contains("segment-"))
    }

    private func asset() -> ServerMediaAsset {
        ServerMediaAsset(
            id: "movie-1",
            fileURL: URL(fileURLWithPath: "/private/never-disclosed/movie.mkv"),
            byteLength: 128
        )
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FFmpegHLSSessionManagerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        temporaryDirectories.append(directory)
        return directory
    }

    private func repositoryRoot() -> URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}

private final class ProcessStub: HLSManagedProcess {
    private(set) var didTerminate = false
    var isRunning: Bool { !didTerminate }

    func terminate() { didTerminate = true }
}

private enum StartupFailure: Error {
    case unavailable
}
