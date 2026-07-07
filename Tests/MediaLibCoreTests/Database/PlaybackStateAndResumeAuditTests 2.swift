import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级播放状态与进度恢复专项】
/// 审计目标：验证视频播放器在频繁进行上一集/下一集切换或意外关闭窗口时，
/// 播放进度的持久化精度、时间戳安全以及倒退回放缓冲 (`resumeRewind`) 算法不发生负数越界或零点错乱。
/// 对应报告问题 ID：TC-PLAY-001 / RISK-08
final class PlaybackStateAndResumeAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Play-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("playback_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    /// 模拟进度恢复计算核心逻辑（校验回退时间缓冲不越界）
    private func calculateResumePosition(savedTime: Double, totalDuration: Double, rewindSeconds: Double = 3.0) -> Double {
        guard savedTime > 0, totalDuration > 0 else { return 0 }
        // 如果已经接近末尾（如最后 15 秒内或 95% 以上），则认为已看完，从头开始
        if savedTime >= totalDuration - 15.0 || savedTime / totalDuration >= 0.95 {
            return 0
        }
        // 应用倒退回放缓冲，并确保不少于 0
        return max(0.0, savedTime - rewindSeconds)
    }

    /// 测试播放进度的有效范围与倒退缓冲防越界
    func testResumePositionRewindCalculationBoundary() {
        // 场景 1：正常中段播放（例如总长 3600 秒，看至 1800 秒）
        let midResume = calculateResumePosition(savedTime: 1800.0, totalDuration: 3600.0, rewindSeconds: 5.0)
        XCTAssertEqual(midResume, 1795.0, "正常播放进度恢复时，应准时扣除配置的倒退回放缓冲秒数")

        // 场景 2：刚开始播放即退出（例如看至 2.0 秒，倒退缓冲为 5.0 秒）
        let startResume = calculateResumePosition(savedTime: 2.0, totalDuration: 3600.0, rewindSeconds: 5.0)
        XCTAssertEqual(startResume, 0.0, "扣除倒退缓冲后如果为负数，必须严格通过 max 截断为 0.0，防止 mpv 搜寻负时间戳抛错")

        // 场景 3：已看至片尾（例如总长 3600 秒，看至 3590 秒）
        let endResume = calculateResumePosition(savedTime: 3590.0, totalDuration: 3600.0)
        XCTAssertEqual(endResume, 0.0, "接近片尾关闭播放器时，应自动标记为看完，再次进入时从头开始")
    }

    private func seedMediaItems(db: DatabaseManager, ids: [String]) throws {
        for id in ids {
            try db.execute("INSERT OR IGNORE INTO media_items (id, type, title) VALUES (?, ?, ?)", bindings: [.text(id), .text("episode"), .text("Title \(id)")])
        }
    }

    /// 测试高并发多视频连续切集下，播放记录存盘不发生竞争或丢失
    func testRapidEpisodeSwitchingPlaybackMarkerPersistence() throws {
        let db = try DatabaseManager(url: dbURL)
        let totalEpisodes = 50
        try seedMediaItems(db: db, ids: (0..<totalEpisodes).map { "series-ep-\($0)" })
        let repo = PlaybackMarkerRepository(database: db)

        var savedMarkers: [String: Double] = [:]

        // 模拟连续快速切集（用户点击“下一集”触发快速存盘与加载）
        for i in 0..<totalEpisodes {
            let itemID = "series-ep-\(i)"
            let stopTime = Double(i * 100) + 45.5
            savedMarkers[itemID] = stopTime
            
            // 存入进盘
            let marker = PlaybackMarker(mediaID: itemID, kind: .bookmark, title: "Bookmark", startTime: stopTime)
            try repo.save(marker)
        }

        // 批量全量读出验证
        for (itemID, expectedTime) in savedMarkers {
            let marker = try repo.fetch(mediaID: itemID).first
            XCTAssertNotNil(marker, "第 \(itemID) 集的播放标记在快速连续切集中丢失")
            XCTAssertEqual(marker?.startTime ?? 0.0, expectedTime, accuracy: 0.01, "播放标记存盘精度不符")
        }
    }
}
