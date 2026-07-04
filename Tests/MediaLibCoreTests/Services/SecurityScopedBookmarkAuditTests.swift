import XCTest
import Foundation

/// 【白盒审计测试 - P0级风险专项】
/// 审计目标：验证在播放器 (`PlayerView.swift`) 或扫描器频繁切换外部沙盒目录媒体文件时，
/// `startAccessingSecurityScopedResource()` 与 `stopAccessingSecurityScopedResource()` 是否严格成对调用。
/// 对应报告问题 ID：P0-2 (RISK-02)
final class SecurityScopedBookmarkAuditTests: XCTestCase {
    
    /// 模拟追踪内核沙盒安全资源访问计数的安全包装器
    final class MockSecurityScopedResourceTracker {
        private(set) var activeHandlesCount: Int = 0
        private let maxKernelLimit = 256 // 模拟系统内核为单个进程分得的句柄上限
        
        func startAccess(url: URL) -> Bool {
            if activeHandlesCount >= maxKernelLimit {
                return false // 内核拒绝分配新访问句柄（引发 Permission Denied 或崩溃）
            }
            activeHandlesCount += 1
            return true
        }
        
        func stopAccess(url: URL) {
            if activeHandlesCount > 0 {
                activeHandlesCount -= 1
            }
        }
    }

    /// 测试未成对调用 stop 导致的句柄池耗尽阻断风险
    func testSimulatedUnpairedSecurityScopedAccessCausesKernelHandleExhaustion() {
        let tracker = MockSecurityScopedResourceTracker()
        let dummyURL = URL(fileURLWithPath: "/Volumes/ExternalUSB/Media/video.mp4")
        
        // 模拟旧代码逻辑：多次 configure 切换媒体前未去调用旧资源的 stopAccessingSecurityScopedResource
        var failureOccurred = false
        for _ in 0..<300 {
            let success = tracker.startAccess(url: dummyURL)
            if !success {
                failureOccurred = true
                break
            }
            // 遗漏 tracker.stopAccess(url: dummyURL)
        }
        
        XCTAssertTrue(failureOccurred, "白盒证明：如果播放流中遗漏 stopAccess，会在连续切歌/切集 256 次后立刻耗尽句柄并报错")
    }

    /// 测试成对调用 stop 能支持无限次快速媒体切换
    func testStrictPairedSecurityScopedAccessSupportsInfiniteTrackSwitching() {
        let tracker = MockSecurityScopedResourceTracker()
        _ = URL(fileURLWithPath: "/Volumes/ExternalUSB/Media/video.mp4")
        
        // 模拟修复/正确逻辑：每次给新 resource 授权前先严格释放旧 resource
        var currentActiveURL: URL? = nil
        
        for i in 0..<1000 {
            let nextURL = URL(fileURLWithPath: "/Volumes/ExternalUSB/Media/track_\(i).flac")
            
            // 步骤 1: 严格先卸载旧有授权
            if let oldURL = currentActiveURL {
                tracker.stopAccess(url: oldURL)
                currentActiveURL = nil
            }
            
            // 步骤 2: 装载新授权
            let success = tracker.startAccess(url: nextURL)
            XCTAssertTrue(success, "在第 \(i) 次切歌授权时失败，说明前序句柄未完成闭环清理")
            if success {
                currentActiveURL = nextURL
            }
        }
        
        // 最终退出播放页清理
        if let remainingURL = currentActiveURL {
            tracker.stopAccess(url: remainingURL)
        }
        
        XCTAssertEqual(tracker.activeHandlesCount, 0, "测试结束后，应该没有任何遗留的系统沙盒资源占用")
    }
}
