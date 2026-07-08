import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级外部播放器调度安全与路径解析专项】
/// 审计目标：验证 `ExternalPlayerService` 在调起外部播放器（如 IINA、VLC、QuickTime）时，
/// 对本地文件路径与远程流媒体 URL（HTTP/HTTPS）的智能识别与容错拦截；
/// 确保当本地文件不存在或 URL 协议非法时抛出精准的 localized 错误，并在并发查询和清理缓存时锁机制安全不越界。
/// 对应报告问题 ID：TC-SCAN-009 / RISK-06
final class ExternalPlayerServiceAuditTests: XCTestCase {
    private var service: ExternalPlayerService!
    private var tempDirectory: URL?

    override func setUpWithError() throws {
        service = ExternalPlayerService()
    }

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    /// 测试播放远程 HTTP/HTTPS 流地址时无需本地文件存在，且路径构造合法
    func testRemoteStreamURLDoesNotRequireLocalFileExistence() throws {
        let remotePath = "http://emby.server:8096/videos/stream.mkv?api_key=12345"
        
        // 我们传入一个不存在的自定播放器应用程序路径来验证它通过了 isRemote 和 URL 校验，在最后一步触发应用未找到
        XCTAssertThrowsError(try service.open(filePath: remotePath, preferredPlayerPath: "/Applications/NonExistentPlayer_Audit.app")) { error in
            guard let playerErr = error as? ExternalPlayerError else {
                XCTFail("错误必须被归类为 ExternalPlayerError")
                return
            }
            if case .applicationNotFound(let name) = playerErr {
                XCTAssertEqual(name, "NonExistentPlayer_Audit.app", "远程流应当顺利通过前置校验，直接进入应用调用阶段")
            } else {
                XCTFail("非预期的错误类型：\(playerErr)")
            }
        }
    }

    /// 测试播放本地不存在的视频文件必须立即抛出 missingFile 异常
    func testMissingLocalVideoFileThrowsMissingFileErrorImmediately() throws {
        let fakeLocalPath = "/Users/shared/Movies/NotExistsVideo-\(UUID().uuidString).mp4"
        
        XCTAssertThrowsError(try service.open(filePath: fakeLocalPath, preferredPlayerPath: nil)) { error in
            guard let playerErr = error as? ExternalPlayerError else {
                XCTFail("应该抛出 ExternalPlayerError")
                return
            }
            if case .missingFile = playerErr {
                XCTAssertNotNil(playerErr.errorDescription)
            } else {
                XCTFail("必须抛出 missingFile 错误，但得到了：\(playerErr)")
            }
        }
    }

    func testOpenAsyncRemoteStreamURLDoesNotRequireLocalFileExistence() async {
        let remotePath = "https://emby.server:8096/videos/stream.mkv?api_key=12345"

        do {
            try await service.openAsync(
                filePath: remotePath,
                preferredPlayerPath: "/Applications/NonExistentPlayer_AsyncAudit.app"
            )
            XCTFail("Expected missing preferred external player to throw")
        } catch let error as ExternalPlayerError {
            if case .applicationNotFound(let name) = error {
                XCTAssertEqual(name, "NonExistentPlayer_AsyncAudit.app")
            } else {
                XCTFail("非预期的错误类型：\(error)")
            }
        } catch {
            XCTFail("错误必须被归类为 ExternalPlayerError")
        }
    }

    func testOpenAsyncMissingLocalVideoFileThrowsMissingFile() async {
        let fakeLocalPath = "/Users/shared/Movies/NotExistsVideo-\(UUID().uuidString).mp4"

        do {
            try await service.openAsync(filePath: fakeLocalPath, preferredPlayerPath: nil)
            XCTFail("Expected missing local file to throw")
        } catch let error as ExternalPlayerError {
            if case .missingFile = error {
                XCTAssertNotNil(error.errorDescription)
            } else {
                XCTFail("必须抛出 missingFile 错误，但得到了：\(error)")
            }
        } catch {
            XCTFail("应该抛出 ExternalPlayerError")
        }
    }

    func testAvailablePlayersAsyncIncludesExistingCustomPath() async throws {
        let customPlayer = try temporaryDirectory()
            .appendingPathComponent("Custom Audit Player.app", isDirectory: true)
        try FileManager.default.createDirectory(at: customPlayer, withIntermediateDirectories: true)

        let players = await service.availablePlayersAsync(customPath: customPlayer.path)

        XCTAssertTrue(players.contains { $0.path == customPlayer.path })
        XCTAssertTrue(players.contains { $0.name == "Custom Audit Player" })
    }

    func testAvailablePlayersAsyncOmitsMissingCustomPath() async throws {
        let missingPlayer = try temporaryDirectory()
            .appendingPathComponent("Missing Audit Player.app", isDirectory: true)

        let players = await service.availablePlayersAsync(customPath: missingPlayer.path)

        XCTAssertFalse(players.contains { $0.path == missingPlayer.path })
    }

    func testAvailablePlayersAsyncRunsFileExistenceChecksOnBlockingIOQueue() async throws {
        let customPlayer = try temporaryDirectory()
            .appendingPathComponent("Blocking IO Player.app", isDirectory: true)
        let recorder = RecordingFileExistence(existingPaths: [customPlayer.path])
        let service = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [] }
        )

        let players = await service.availablePlayersAsync(customPath: customPlayer.path)

        XCTAssertTrue(players.contains { $0.path == customPlayer.path })
        XCTAssertTrue(recorder.paths.contains(customPlayer.path))
        XCTAssertTrue(recorder.didObserveBlockingIOQueue)
        XCTAssertTrue(recorder.allCallsObservedOnBlockingIOQueue)
    }

    func testOpenAsyncMissingLocalFileChecksPathOnBlockingIOQueue() async {
        let localPath = "/Volumes/Offline/Missing-\(UUID().uuidString).mkv"
        let recorder = RecordingFileExistence(existingPaths: [])
        let service = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [] }
        )

        do {
            try await service.openAsync(filePath: localPath, preferredPlayerPath: nil)
            XCTFail("Expected missing local file to throw")
        } catch let error as ExternalPlayerError {
            if case .missingFile = error {
                XCTAssertEqual(recorder.paths, [localPath])
                XCTAssertTrue(recorder.didObserveBlockingIOQueue)
                XCTAssertTrue(recorder.allCallsObservedOnBlockingIOQueue)
            } else {
                XCTFail("Expected missingFile, got \(error)")
            }
        } catch {
            XCTFail("Expected ExternalPlayerError, got \(error)")
        }
    }

    func testOpenAsyncMissingPreferredPlayerChecksPathOnBlockingIOQueue() async {
        let preferredPath = "/Applications/Missing Preferred Player.app"
        let recorder = RecordingFileExistence(existingPaths: [])
        let service = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [] }
        )

        do {
            try await service.openAsync(
                filePath: "https://example.test/video/stream.mkv",
                preferredPlayerPath: preferredPath
            )
            XCTFail("Expected missing preferred player to throw")
        } catch let error as ExternalPlayerError {
            if case .applicationNotFound(let name) = error {
                XCTAssertEqual(name, "Missing Preferred Player.app")
                XCTAssertEqual(recorder.paths, [preferredPath])
                XCTAssertTrue(recorder.didObserveBlockingIOQueue)
                XCTAssertTrue(recorder.allCallsObservedOnBlockingIOQueue)
            } else {
                XCTFail("Expected applicationNotFound, got \(error)")
            }
        } catch {
            XCTFail("Expected ExternalPlayerError, got \(error)")
        }
    }

    func testAvailablePlayersAsyncUsesCacheUntilInvalidated() async throws {
        let customPlayer = try temporaryDirectory()
            .appendingPathComponent("Cached Audit Player.app", isDirectory: true)
        let recorder = RecordingFileExistence(existingPaths: [customPlayer.path])
        let service = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [] }
        )

        let first = await service.availablePlayersAsync(customPath: customPlayer.path)
        recorder.replaceExistingPaths([])
        let second = await service.availablePlayersAsync(customPath: customPlayer.path)
        service.invalidatePlayerCache()
        let third = await service.availablePlayersAsync(customPath: customPlayer.path)

        XCTAssertTrue(first.contains { $0.path == customPlayer.path })
        XCTAssertTrue(second.contains { $0.path == customPlayer.path }, "cached result should be reused until explicit invalidation")
        XCTAssertFalse(third.contains { $0.path == customPlayer.path })
        XCTAssertGreaterThanOrEqual(recorder.callCount(for: customPlayer.path), 2)
    }

    func testSynchronousAvailablePlayersUsesInjectedFileExistenceCheckerForCustomPath() async throws {
        let customPlayer = try temporaryDirectory()
            .appendingPathComponent("Sync Injected Player.app", isDirectory: true)
        let recorder = RecordingFileExistence(existingPaths: [customPlayer.path])
        let service = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [] }
        )

        let players = service.availablePlayers(customPath: customPlayer.path)

        XCTAssertTrue(players.contains { $0.path == customPlayer.path })
        XCTAssertTrue(recorder.paths.contains(customPlayer.path))
    }

    /// 测试多并发下频繁调用 invalidatePlayerCache 与 availablePlayers 锁不竞争不崩溃
    func testConcurrentCacheInvalidationAndQueryIsThreadSafe() throws {
        let expectation = XCTestExpectation(description: "并发缓存读写处理完毕")
        expectation.expectedFulfillmentCount = 100
        
        DispatchQueue.concurrentPerform(iterations: 100) { i in
            if i % 2 == 0 {
                service.invalidatePlayerCache()
            } else {
                _ = service.availablePlayers(customPath: "/Applications/Safari.app")
            }
            expectation.fulfill()
        }
        
        wait(for: [expectation], timeout: 3.0)
    }

    func testConcurrentAsyncCacheInvalidationAndQueryIsThreadSafe() async throws {
        let customPlayer = try temporaryDirectory()
            .appendingPathComponent("Concurrent Audit Player.app", isDirectory: true)
        let knownPlayer = ExternalPlayer(
            name: "Known Concurrent Player",
            path: "/Applications/Known Concurrent Player.app",
            bundleIdentifier: "test.known.concurrent"
        )
        let recorder = RecordingFileExistence(existingPaths: [customPlayer.path, knownPlayer.path])
        let isolatedService = ExternalPlayerService(
            fileExists: { recorder.fileExists($0) },
            knownPlayersProvider: { [knownPlayer] }
        )

        await withTaskGroup(of: Void.self) { group in
            for i in 0..<32 {
                group.addTask {
                    if i % 2 == 0 {
                        isolatedService.invalidatePlayerCache()
                    } else {
                        _ = await isolatedService.availablePlayersAsync(customPath: customPlayer.path)
                    }
                }
            }
        }

        XCTAssertTrue(recorder.didObserveBlockingIOQueue)
        XCTAssertTrue(recorder.allCallsObservedOnBlockingIOQueue)
    }

    private func temporaryDirectory() throws -> URL {
        if let tempDirectory {
            return tempDirectory
        }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExternalPlayerServiceAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        tempDirectory = root
        return root
    }
}

private final class RecordingFileExistence: @unchecked Sendable {
    private let lock = NSLock()
    private var existingPaths: Set<String>
    private var records: [(path: String, onBlockingIOQueue: Bool)] = []

    init(existingPaths: Set<String>) {
        self.existingPaths = existingPaths
    }

    var paths: [String] {
        lock.lock()
        defer { lock.unlock() }
        return records.map(\.path)
    }

    var didObserveBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return records.contains { $0.onBlockingIOQueue }
    }

    var allCallsObservedOnBlockingIOQueue: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !records.isEmpty && records.allSatisfy(\.onBlockingIOQueue)
    }

    func fileExists(_ path: String) -> Bool {
        lock.lock()
        records.append((path, BlockingIOExecutor.isCurrentExecutionOnBlockingIOQueue()))
        let exists = existingPaths.contains(path)
        lock.unlock()
        return exists
    }

    func replaceExistingPaths(_ paths: Set<String>) {
        lock.lock()
        existingPaths = paths
        lock.unlock()
    }

    func callCount(for path: String) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return records.filter { $0.path == path }.count
    }
}
