import XCTest
@testable import MediaLibServer

final class ServerCommandOutputTests: XCTestCase {
    func testUsageDescribesCurrentAuthenticatedLoopbackBoundary() {
        XCTAssertTrue(ServerCommandOutput.usage.contains("登录/刷新/注销"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("HTTP Range"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("桌面多用户与逐资料库授权、安全审计"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("Web 列表/详情/浏览器原生播放、逐用户续播/已看、只读管理"))
        XCTAssertTrue(ServerCommandOutput.capabilities.contains("media-detail"))
        XCTAssertTrue(ServerCommandOutput.capabilities.contains("web-playback"))
        XCTAssertTrue(ServerCommandOutput.capabilities.contains("per-user-playback-state"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("浏览器原生播放"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("限速参数压测、"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("告警聚合、可信代理、TLS"))
        XCTAssertFalse(ServerCommandOutput.usage.contains("管理员恢复、TLS"))
        XCTAssertTrue(ServerCommandOutput.usage.contains("不会接受局域网或公网监听地址"))
        XCTAssertFalse(ServerCommandOutput.usage.contains("不提供用户、媒体、认证"))
        XCTAssertFalse(ServerCommandOutput.usage.contains("首次管理员设置、限速审计"))
        XCTAssertFalse(ServerCommandOutput.usage.contains("Phase 0"))
    }
}
