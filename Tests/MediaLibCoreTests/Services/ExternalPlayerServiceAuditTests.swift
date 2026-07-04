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

    override func setUpWithError() throws {
        service = ExternalPlayerService()
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
}
