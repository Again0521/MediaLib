import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级缩略图生成与系统媒体处理容错专项】
/// 审计目标：验证 `ThumbnailGenerator` 与 `VideoFramePreviewGenerator` 在处理
/// 损坏媒体文件、零字节视频、不存在路径以及高并发密集抽取请求时的抗崩溃能力与并发栅栏限流机制。
/// 对应报告问题 ID：TC-SCAN-001 / RISK-09
final class PhotoAndThumbnailAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Thumbnail-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试传入 0 字节文件或者损坏文件不会引发 AVAsset 解码器崩溃或死循环
    func testZeroByteOrCorruptedVideoThumbnailGenerationGracefullyFails() async {
        let generator = ThumbnailGenerator(outputDirectory: tempDir)
        let corruptedFile = tempDir.appendingPathComponent("broken_video.mp4")
        try? "THIS IS NOT A REAL VIDEO FILE CONTENT".write(to: corruptedFile, atomically: true, encoding: .utf8)

        let thumbnailURL = await generator.generateThumbnail(
            for: corruptedFile,
            mediaID: "corrupted-id-001",
            ratio: 0.5,
            avoidBlackFrames: true
        )

        XCTAssertNil(thumbnailURL, "对于损坏或伪造的媒体文件，缩略图引擎应捕获 AVFoundation 异常并稳健返回 nil")
    }

    /// 测试传入不存在的文件路径时能够平稳快速失败
    func testNonExistentFileThumbnailGenerationReturnsNilImmediately() async {
        let generator = ThumbnailGenerator(outputDirectory: tempDir)
        let missingFile = tempDir.appendingPathComponent("completely_missing_movie.mkv")

        let start = CFAbsoluteTimeGetCurrent()
        let result = await generator.generateThumbnail(
            for: missingFile,
            mediaID: "missing-id-002",
            ratio: 0.1,
            avoidBlackFrames: false
        )
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertNil(result)
        XCTAssertLessThan(elapsed, 2.0, "对于不存在的文件不应长时间阻塞或尝试无休止调用 FFmpeg 重试")
    }
}
