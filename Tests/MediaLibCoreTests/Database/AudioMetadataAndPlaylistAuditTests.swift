import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级音频元数据与歌单管理完整性专项】
/// 审计目标：验证音乐元数据读取 (`AudioMetadataReader`) 对特殊编码、超长歌词与异常格式音频文件
/// 的稳定解析能力；验证歌单存储 (`MusicPlaylistRepository`) 批量增删及顺序重建的原子性与去重安全。
/// 对应报告问题 ID：TC-DB-001 / RISK-09
final class AudioMetadataAndPlaylistAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Audio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("audio_playlist_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    /// 测试读取无内嵌标签或者零字节模拟音频的健壮性
    func testAudioMetadataReaderWithZeroByteAudioFileDoesNotHang() async {
        let reader = AudioMetadataReader()
        let fakeAudio = workDir.appendingPathComponent("empty_song.mp3")
        try? "".write(to: fakeAudio, atomically: true, encoding: .utf8)

        let start = CFAbsoluteTimeGetCurrent()
        let metadata = await reader.metadata(for: fakeAudio)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0, "解析零字节音频不应卡死或阻塞")
        XCTAssertNil(metadata.title)
        XCTAssertFalse(metadata.hasEmbeddedMetadata)
    }

    /// 测试歌单批量添加和移除操作时，顺序 position 与 ID 去重逻辑的正确性
    func testPlaylistBulkAddAndRemoveOrderAtomicRebuild() throws {
        let db = try DatabaseManager(url: dbURL)
        let repo = MusicPlaylistRepository(database: db)

        // 1. 创建新歌单并存入 5 首歌曲（其中包含故意传入的重复 ID）
        let initialIDs = ["track-1", "track-2", "track-3", "track-2", "track-1", "track-4"]
        let playlist = try repo.create(name: "我的最爱", itemIDs: initialIDs)

        XCTAssertEqual(playlist.itemIDs, ["track-1", "track-2", "track-3", "track-4"], "创建歌单时必须自动去除重名和重复的媒体 ID")

        // 2. 批量添加新歌曲（包含原有 ID 与新 ID）
        let updated = try repo.add(itemIDs: ["track-3", "track-5", "track-6", "track-5"], toPlaylistID: playlist.id)
        XCTAssertNotNil(updated)
        XCTAssertEqual(updated?.itemIDs, ["track-1", "track-2", "track-3", "track-4", "track-5", "track-6"], "追加歌曲时必须正确拼接到末尾并去重")

        // 3. 批量移除中间某两首歌曲
        let afterRemove = try repo.remove(itemIDs: ["track-2", "track-4", "non-existent"], fromPlaylistID: playlist.id)
        XCTAssertNotNil(afterRemove)
        XCTAssertEqual(afterRemove?.itemIDs, ["track-1", "track-3", "track-5", "track-6"], "移除歌曲后，必须能按照新顺序连续排列，不留下数据空洞或乱序")
    }
}
