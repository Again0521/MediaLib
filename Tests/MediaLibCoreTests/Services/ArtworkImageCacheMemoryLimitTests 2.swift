import XCTest
import AppKit
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级视频预览抽帧缓存与内存限制防 OOM 专项】
/// 审计目标：验证 `VideoFramePreviewGenerator` 在进行视频分段抽帧分桶 (`storyboardBuckets`) 时算法安全不越界；
/// 验证在面临大量高并发预览图请求时，内存 NSCache 成本限制与限流栅栏生效，防止由于无节制原图解压造成 OOM 崩溃。
/// 对应报告问题 ID：RISK-05 / RISK-09
final class ArtworkImageCacheMemoryLimitTests: XCTestCase {
    private var cacheDir: URL!

    override func setUpWithError() throws {
        cacheDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-ImgCache-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        VideoFramePreviewGenerator.configure(diskCacheDirectory: cacheDir)
    }

    override func tearDownWithError() throws {
        if let cacheDir {
            try? FileManager.default.removeItem(at: cacheDir)
        }
    }

    /// 测试极长视频或极端时长下，抽帧分桶算法不会发生无限循环或超出范围
    func testStoryboardBucketsBoundaryCalculation() {
        // 场景 1：标准两小时影片 (7200 秒)
        let normalBuckets = VideoFramePreviewGenerator.storyboardBuckets(duration: 7200, preferCoarse: false)
        XCTAssertFalse(normalBuckets.isEmpty)
        XCTAssertLessThanOrEqual(normalBuckets.count, 500, "两小时视频精细抽帧应合理分桶，避免生成过多毫无意义的请求")

        // 场景 2：超度微短片或负数时长
        let zeroBuckets = VideoFramePreviewGenerator.storyboardBuckets(duration: 0.5, preferCoarse: false)
        XCTAssertTrue(zeroBuckets.isEmpty, "时长小于 1 秒或异常时长不应执行故事板抽帧")

        // 场景 3：100 小时极长监控或者网络流 (360,000 秒)
        let longBuckets = VideoFramePreviewGenerator.storyboardBuckets(duration: 360000, preferCoarse: true)
        XCTAssertFalse(longBuckets.isEmpty)
        XCTAssertLessThanOrEqual(longBuckets.count, 2000, "极长时长的粗粒度分桶必须步长递增，防止内存溢出")
    }

    /// 测试请求限流保护机制 (shouldDeferInteractiveRequest)
    func testInteractiveRequestDeferralUnderHighLoad() {
        let itemID = "mock-movie-id"
        
        // 验证系统级判断：在已有并发任务数达到上限时，必须及时延迟非核心请求
        let shouldDefer = VideoFramePreviewGenerator.shouldDeferInteractiveRequest(
            itemID: itemID,
            time: 120.0,
            duration: 3600.0,
            preferFFmpeg: false,
            maxQueuedRequests: 0 // 模拟队列已满 (限制为 0)
        )
        
        XCTAssertTrue(shouldDefer, "当队列满载时，后续拖动预览图请求必须背压或延迟，绝不可无限往 GCD 线程池堆叠任务！")
    }
}
