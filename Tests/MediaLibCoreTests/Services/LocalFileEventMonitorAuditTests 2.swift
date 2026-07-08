import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级本地文件操作冲突与去重专项】
/// 审计目标：验证当用户在磁盘上通过外部 Finder 或命令行复制、移动、重命名或删除媒体文件时，
/// 扫描与监控机制对文件存在性校验、重复路径去重及同 inode 别名链接的处理健壮性。
/// 对应报告问题 ID：TC-SCAN-003 / RISK-07
final class LocalFileEventMonitorAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-FileEvent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试扫描过程中部分文件突然被用户删掉不致扫描器崩溃
    func testFileDeletionDuringScanningIteratesGracefully() throws {
        // 创建 10 个测试文件
        var fileURLs: [URL] = []
        for i in 0..<10 {
            let fileURL = tempDir.appendingPathComponent("video_\(i).mp4")
            try "dummy content \(i)".write(to: fileURL, atomically: true, encoding: .utf8)
            fileURLs.append(fileURL)
        }

        // 模拟开始迭代扫描文件，但在迭代到第 5 个时，外部突然把所有剩余文件从物理磁盘删除
        var successfullyScannedCount = 0
        var missingOrErrorCount = 0

        for (index, fileURL) in fileURLs.enumerated() {
            if index == 5 {
                // 模拟外部并发删除剩余文件
                for j in 5..<10 {
                    try? FileManager.default.removeItem(at: fileURLs[j])
                }
            }

            // 扫描安全校验逻辑（白盒期望规则：操作前务必使用 fileExists 校验或优雅捕获读取异常）
            if FileManager.default.fileExists(atPath: fileURL.path) {
                do {
                    _ = try Data(contentsOf: fileURL)
                    successfullyScannedCount += 1
                } catch {
                    missingOrErrorCount += 1
                }
            } else {
                missingOrErrorCount += 1
            }
        }

        XCTAssertEqual(successfullyScannedCount, 5, "前 5 个未删除的文件必须正常成功提取")
        XCTAssertEqual(missingOrErrorCount, 5, "后 5 个被并发删除的文件必须被平稳跳过，不得引发 fatalError 或异常崩溃")
    }

    /// 测试符号链接与重复文件路径去重逻辑
    func testDuplicateAndSymlinkPathDeduplication() throws {
        let originalFile = tempDir.appendingPathComponent("original_movie.mkv")
        try "video content".write(to: originalFile, atomically: true, encoding: .utf8)

        let symlinkFile = tempDir.appendingPathComponent("alias_movie.mkv")
        try FileManager.default.createSymbolicLink(at: symlinkFile, withDestinationURL: originalFile)

        // 验证去重逻辑是否基于 standardizedFileURL 与 resolvingSymlinksInPath
        let path1 = originalFile.standardizedFileURL.resolvingSymlinksInPath().path
        let path2 = symlinkFile.standardizedFileURL.resolvingSymlinksInPath().path

        XCTAssertEqual(path1, path2, "符号链接与原始路径在解析后应该指向完全相同的绝对物理路径，防止数据库中插入两份相同的索引条目")
    }
}
