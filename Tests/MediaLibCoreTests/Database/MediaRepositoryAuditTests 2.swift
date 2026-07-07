import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级媒体总仓库与订正防覆盖专项】
/// 审计目标：验证 `MediaRepository` 在执行批量插入 (`upsert`) 时，
/// 如果某媒体条目存在用户手动修改过的 `metadata_correction_history`（元数据订正记录），
/// SQL 层的 CASE WHEN 逻辑能否百分之百拦截远端刮削器的覆盖尝试，守护用户自定标题不被篡改；
/// 同时验证其在替换远端同步列表 (`replaceRemoteItems`) 时对 file_path 唯一约束冲突的提前自愈清除。
/// 对应报告问题 ID：TC-DB-006 / RISK-01
final class MediaRepositoryAuditTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var repo: MediaRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaRepoAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbManager = try DatabaseManager(url: tempDir.appendingPathComponent("audit_media.sqlite"))
        repo = MediaRepository(database: dbManager)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试媒体条目 upsert 能够正确插入和更新属性，防写错位
    func testUpsertAndFetchAllBasicAttributes() throws {
        var item = MediaItem(id: "media-001", type: .movie, title: "Inception")
        item.year = 2010
        item.overview = "A thief who steals corporate secrets..."
        item.posterPath = "/posters/inception.jpg"
        item.rating = 8.8
        item.filePath = "/Movies/Inception.mp4"
        
        try repo.upsert(item)
        
        // 验证持久化查询
        var fetched = try repo.fetchAll()
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.title, "Inception")
        XCTAssertEqual(fetched.first?.year, 2010)
        XCTAssertEqual(fetched.first?.filePath, "/Movies/Inception.mp4")
        
        // 更新部分字段
        item.rating = 9.0
        try repo.upsert(item)
        
        fetched = try repo.fetchAll()
        XCTAssertEqual(fetched.count, 1, "同一 ID 的 upsert 绝不能生成重复多行记录")
        XCTAssertEqual(fetched.first?.rating, 9.0)
    }

    /// 测试当且仅当存在未撤销的历史订正记录时，upsert 绝不覆盖用户的标题
    func testUpsertProtectsUserCorrectedTitleFromRemoteScraperOverwrite() throws {
        let item = MediaItem(id: "media-protected", type: .movie, title: "用户精修专有译名")
        try repo.upsert(item)
        
        // 人为在 metadata_correction_history 中插入该 ID 的订正历史
        try dbManager.execute(
            """
            INSERT INTO metadata_correction_history (id, batch_id, media_id, field_name, old_value, new_value, source, created_at, undone_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, NULL)
            """,
            bindings: [.text(UUID().uuidString), .text(UUID().uuidString), .text("media-protected"), .text("title"), .text("旧译名"), .text("用户精修专有译名"), .text("manual"), .optionalDate(Date())]
        )
        
        // 随后远端刮削服务企图用英文名或通用译名覆盖它
        var scraperItem = MediaItem(id: "media-protected", type: .movie, title: "Generic Scraped Title")
        scraperItem.overview = "New scraper overview added"
        try repo.upsert(scraperItem)
        
        let fetched = try repo.fetchAll().first(where: { $0.id == "media-protected" })
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.title, "用户精修专有译名", "有用户手动订正记录时，标题必须被严格保护，不能被远端覆盖！")
        XCTAssertEqual(fetched?.overview, "New scraper overview added", "未被保护的其他字段可以正常更新")
    }

    /// 测试 replaceRemoteItems 能自动处理 file_path 冲突，避免抛出 UNIQUE constraint failed
    func testReplaceRemoteItemsResolvesFilePathConflictsWithoutCrash() throws {
        let oldItem = MediaItem(id: "emby-old-id", type: .movie, title: "Avatar")
        var oldWithPath = oldItem
        oldWithPath.filePath = "http://emby.server/stream/12345.mkv"
        try repo.upsert(oldWithPath)
        
        // 模拟远端重连后，同一 file_path 但换了新 ID
        let newItem = MediaItem(id: "emby-new-id", type: .movie, title: "Avatar Remastered")
        var newWithPath = newItem
        newWithPath.filePath = "http://emby.server/stream/12345.mkv"
        
        // 应该能安全执行，自动剔除旧 ID，不抛数据库唯一索引冲突异常
        XCTAssertNoThrow(try repo.replaceRemoteItems(sourcePathPrefix: "http://emby.server", with: [newWithPath]))
        
        let all = try repo.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.id, "emby-new-id")
        XCTAssertEqual(all.first?.title, "Avatar Remastered")
    }
}
