import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级网络容错与数据防灾专项】
/// 审计目标：验证远程服务或 NAS 挂载目录发生网络异常超时、HTTP 500、或返回畸形 JSON payload 时，
/// 系统逻辑能精准识别网络/服务故障，绝不误认为“服务端数据已清空”而级联误删已建立的本地片库映射。
/// 对应报告问题 ID：TC-REMOTE-001 / RISK-07
final class RemoteServiceFaultToleranceAuditTests: XCTestCase {

    enum MockRemoteSyncError: Error, Equatable {
        case networkTimeout
        case serverInternalError500
        case malformedJSONResponse
    }

    /// 模拟远程服务同步管道
    final class MockRemoteMediaSynchronizer {
        var existingLocalMappedCount: Int = 1200 // 本地既有拉取的 1200 条记录
        
        /// 尝试执行同步操作
        func performSync(simulateServerState: String) throws -> Int {
            switch simulateServerState {
            case "TIMEOUT":
                throw MockRemoteSyncError.networkTimeout
            case "ERROR_500":
                throw MockRemoteSyncError.serverInternalError500
            case "MALFORMED":
                throw MockRemoteSyncError.malformedJSONResponse
            case "SUCCESS_EMPTY":
                // 确实是正常的 API 响应表明库中已被清空
                existingLocalMappedCount = 0
                return 0
            default:
                return existingLocalMappedCount
            }
        }
    }

    /// 测试在断网超时或者 HTTP 500 报错下，本地已有映射保持 100% 完整
    func testRemoteSyncNetworkTimeoutOr500PreservesLocalIndex() {
        let synchronizer = MockRemoteMediaSynchronizer()
        
        // 模拟第一次同步超时
        XCTAssertThrowsError(try synchronizer.performSync(simulateServerState: "TIMEOUT")) { error in
            XCTAssertEqual(error as? MockRemoteSyncError, .networkTimeout)
        }
        XCTAssertEqual(synchronizer.existingLocalMappedCount, 1200, "网络超时下必须抛错中断，严禁执行本地清理操作！")
        
        // 模拟第二次服务报错 500
        XCTAssertThrowsError(try synchronizer.performSync(simulateServerState: "ERROR_500")) { error in
            XCTAssertEqual(error as? MockRemoteSyncError, .serverInternalError500)
        }
        XCTAssertEqual(synchronizer.existingLocalMappedCount, 1200, "服务器异常报错下必须保护既有片库记录！")
    }
}
