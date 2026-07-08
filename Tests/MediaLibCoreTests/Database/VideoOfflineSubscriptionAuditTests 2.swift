import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级视频离线订阅状态同步与过期清理专项】
/// 审计目标：验证 `VideoOfflineSubscriptionRepository` 在处理离线下载订阅的存取、
/// `ON CONFLICT(series_id)` 幂等更新、以及过期订阅扫描 (`fetchExpired`) 时的状态一致性。
/// 对应报告问题 ID：TC-DB-002 / RISK-07
final class VideoOfflineSubscriptionAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Sub-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("offline_sub_audit.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    private func seedMediaItems(db: DatabaseManager, ids: [String]) throws {
        for id in ids {
            try db.execute("INSERT OR IGNORE INTO media_items (id, type, title) VALUES (?, ?, ?)", bindings: [.text(id), .text("tvShow"), .text("Title \(id)")])
        }
    }

    /// 测试离线订阅保存与冲突更新时，能够幂等覆盖现存的剧集订阅策略
    func testSubscriptionSaveIdempotentlyUpdatesExistingSeriesPolicy() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db: db, ids: ["series-got"])
        let repo = VideoOfflineSubscriptionRepository(database: db)

        let initialSub = VideoOfflineSubscription(
            id: "sub-1",
            seriesID: "series-got",
            seriesTitle: "权力的游戏",
            mode: .nextEpisode,
            episodeLimit: 3,
            seasonNumber: 8,
            qualityID: "1080p",
            enabled: true,
            networkPolicy: .allowRemote
        )

        _ = try repo.save(initialSub)

        // 模拟用户在设置中将离线策略改为下载全部季，仅限 Wi-Fi，并且限制调整为 10 集
        var modifiedSub = initialSub
        modifiedSub.mode = .fullSeries
        modifiedSub.episodeLimit = 10
        modifiedSub.networkPolicy = .wifiOnly

        let updated = try repo.save(modifiedSub)

        XCTAssertEqual(updated.seriesID, "series-got")
        XCTAssertEqual(updated.mode, .fullSeries, "更新剧集订阅时必须幂等覆盖原有模式")
        XCTAssertEqual(updated.episodeLimit, 10)
        XCTAssertEqual(updated.networkPolicy, .wifiOnly)

        // 验证数据库中没有产生重复记录
        let allSubs = try repo.fetchAll()
        XCTAssertEqual(allSubs.count, 1, "同一 series_id 只能维持一条订阅记录")
    }

    /// 测试到期订阅筛选函数 (fetchExpired) 能精准识别过期缓存
    func testFetchExpiredSubscriptionsIdentifiesOverdueItems() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db: db, ids: ["series-old", "series-new", "series-perm"])
        let repo = VideoOfflineSubscriptionRepository(database: db)

        let now = Date()
        let yesterday = now.addingTimeInterval(-86400)
        let tomorrow = now.addingTimeInterval(86400)

        let expiredSub = VideoOfflineSubscription(
            id: "sub-old",
            seriesID: "series-old",
            seriesTitle: "过期剧集",
            mode: .nextEpisode,
            expiresAt: yesterday
        )
        let activeSub = VideoOfflineSubscription(
            id: "sub-new",
            seriesID: "series-new",
            seriesTitle: "正在追剧中",
            mode: .nextEpisode,
            expiresAt: tomorrow
        )
        let permanentSub = VideoOfflineSubscription(
            id: "sub-perm",
            seriesID: "series-perm",
            seriesTitle: "永久收藏",
            mode: .nextEpisode,
            expiresAt: nil
        )

        _ = try repo.save(expiredSub)
        _ = try repo.save(activeSub)
        _ = try repo.save(permanentSub)

        let expiredList = try repo.fetchExpired(now: now)
        XCTAssertEqual(expiredList.count, 1)
        XCTAssertEqual(expiredList.first?.seriesID, "series-old", "过期检查必须精确筛选出小于等于当前时间的订阅，不误删活跃或永久收藏")
    }
}
