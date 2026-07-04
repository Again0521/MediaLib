import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级媒体来源配置 CRUD 与级联防护专项】
/// 审计目标：验证 `SourceRepository` 在管理不同媒体源（如本地文件夹、SMB 网络盘、Emby 远程服务器）时，
/// 各项复杂开关配置（如 auto_scan, read_nfo, remote_trace_sync_mode）能够准确编解码落盘，
/// 确保当用户修改媒体扫描范围或离线断开时，来源 ID 与参数保持绝对一致不丢失。
/// 对应报告问题 ID：TC-DB-007
final class SourceRepositoryAuditTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var repo: SourceRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SourceRepoAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbManager = try DatabaseManager(url: tempDir.appendingPathComponent("audit_sources.sqlite"))
        repo = SourceRepository(database: dbManager)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试保存与全量拉取各类媒体源配置的完整精度
    func testSaveAndFetchAllSourceTypesWithFullFlags() throws {
        let localSource = MediaSource(
            id: "src-local-01",
            name: "本地高清电影库",
            path: "/Users/shared/Movies",
            mediaType: .movie,
            recursive: true,
            autoScan: true,
            minimumFileSize: 10485760, // 10MB
            ignoreHiddenFiles: true,
            readNFO: true,
            preferLocalArtwork: true,
            networkScrapingEnabled: true
        )
        
        let embySource = MediaSource(
            id: "src-emby-02",
            name: "客厅 Emby 影视台",
            path: "http://192.168.1.100:8096",
            mediaType: .tvShow,
            recursive: false,
            autoScan: false,
            minimumFileSize: 0,
            ignoreHiddenFiles: false,
            readNFO: false,
            preferLocalArtwork: false,
            networkScrapingEnabled: false
        )
        
        try repo.save(localSource)
        try repo.save(embySource)
        
        let sources = try repo.fetchAll()
        XCTAssertEqual(sources.count, 2)
        
        guard let fetchedLocal = sources.first(where: { $0.id == "src-local-01" }),
              let fetchedEmby = sources.first(where: { $0.id == "src-emby-02" }) else {
            XCTFail("保存的媒体源必须完全可被重新查询检索到")
            return
        }
        
        XCTAssertEqual(fetchedLocal.name, "本地高清电影库")
        XCTAssertEqual(fetchedLocal.minimumFileSize, 10485760)
        XCTAssertTrue(fetchedLocal.readNFO)
        XCTAssertTrue(fetchedLocal.preferLocalArtwork)
        
        XCTAssertEqual(fetchedEmby.path, "http://192.168.1.100:8096")
        XCTAssertFalse(fetchedEmby.autoScan)
    }

    /// 测试来源配置幂等更新与删除闭环
    func testSourceIdempotentUpdateAndDelete() throws {
        var source = MediaSource(id: "src-to-delete", name: "临时来源", path: "/tmp/media", mediaType: .other)
        try repo.save(source)
        XCTAssertEqual(try repo.fetchAll().count, 1)
        
        // 更新名称
        source.name = "正式名称"
        try repo.save(source)
        XCTAssertEqual(try repo.fetchAll().count, 1)
        XCTAssertEqual(try repo.fetchAll().first?.name, "正式名称")
        
        // 执行删除
        try repo.delete(id: "src-to-delete")
        XCTAssertTrue(try repo.fetchAll().isEmpty, "执行删除后，该来源必须从库中彻底移除")
    }
}
