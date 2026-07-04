import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级媒体详情快照原子写入与孤儿演职员垃圾清理专项】
/// 审计目标：验证 `MediaDetailRepository.save` 在执行跨 6 张关连表（详情、外部ID、演员、演职员表、海报图片、相关影视）
/// 的快照保存时，能够通过底层 SQL 事务确保原子操作；并验证其在替换演职员列表时，
/// 能够自动触发 `cleanupOrphanedPeople()` 清除不再被任何影片引用的孤儿演职员记录，防范数据库无限膨胀。
/// 对应报告问题 ID：TC-DB-008
final class MediaDetailRepositoryAuditTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var repo: MediaDetailRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaDetailRepoAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbManager = try DatabaseManager(url: tempDir.appendingPathComponent("audit_detail.sqlite"))
        repo = MediaDetailRepository(database: dbManager)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试保存完整快照并重新精准读取
    func testSaveAndFetchFullSnapshotWithPeopleAndArtwork() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-interstellar", type: .movie, title: "Interstellar"))
        let meta = MediaDetailMetadata(
            mediaID: "movie-interstellar",
            status: "Released",
            firstAirDate: "2014-11-05",
            contentRating: "PG-13",
            provider: "tmdb",
            language: "zh-CN"
        )
        let nolan = MediaPerson(id: "person-nolan", name: "Christopher Nolan", knownForDepartment: "Directing")
        let mcconaughey = MediaPerson(id: "person-matthew", name: "Matthew McConaughey", knownForDepartment: "Acting")
        
        let credit1 = MediaCredit(id: "cred-1", mediaID: "movie-interstellar", personID: "person-nolan", category: "crew", role: "Director", department: "Directing", order: 0)
        let credit2 = MediaCredit(id: "cred-2", mediaID: "movie-interstellar", personID: "person-matthew", category: "cast", role: "Cooper", department: "Acting", order: 1)
        
        let artwork = MediaArtwork(
            id: "art-poster-01",
            mediaID: "movie-interstellar",
            kind: "poster",
            thumbURL: "https://image.tmdb.org/t/p/w200/interstellar.jpg",
            fullURL: "https://image.tmdb.org/t/p/original/interstellar.jpg",
            aspectRatio: 0.67,
            order: 0
        )
        
        let snapshot = MediaDetailSnapshot(
            metadata: meta,
            externalIDs: [MediaExternalID(provider: "imdb", value: "tt0816692")],
            people: [nolan, mcconaughey],
            credits: [credit1, credit2],
            artwork: [artwork],
            relatedTitles: []
        )
        
        try repo.save(snapshot)
        
        guard let fetched = try repo.fetch(mediaID: "movie-interstellar") else {
            XCTFail("已写入快照必须能被完整复原")
            return
        }
        
        XCTAssertEqual(fetched.metadata.status, "Released")
        XCTAssertEqual(fetched.externalIDs.first?.value, "tt0816692")
        XCTAssertEqual(fetched.people.count, 2)
        XCTAssertEqual(fetched.credits.first(where: { $0.personID == "person-matthew" })?.role, "Cooper")
        XCTAssertEqual(fetched.artwork.first?.fullURL, "https://image.tmdb.org/t/p/original/interstellar.jpg")
    }

    /// 测试更新快照撤下某演员时，该演员记录若不再被其他媒体引用，应被孤儿回收机制清除
    func testOrphanedPeopleAreAutomaticallyCleanedUpWhenCreditsAreRemoved() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-solo", type: .movie, title: "Solo Movie"))
        let meta = MediaDetailMetadata(mediaID: "movie-solo", provider: "tmdb", language: "en")
        let actorSolo = MediaPerson(id: "person-solo-actor", name: "One Time Actor")
        let credit = MediaCredit(id: "cred-solo", mediaID: "movie-solo", personID: "person-solo-actor", category: "cast", role: "Actor", order: 0)
        
        let initialSnapshot = MediaDetailSnapshot(
            metadata: meta,
            externalIDs: [],
            people: [actorSolo],
            credits: [credit],
            artwork: [],
            relatedTitles: []
        )
        try repo.save(initialSnapshot)
        
        // 确认该演员在库中
        let beforePeopleCount = try dbManager.query("SELECT COUNT(*) FROM media_people WHERE id = 'person-solo-actor'") { $0.int(0) ?? 0 }.first ?? 0
        XCTAssertEqual(beforePeopleCount, 1)
        
        // 现在更新该影片，移除这名演员的解约
        let updatedSnapshot = MediaDetailSnapshot(
            metadata: meta,
            externalIDs: [],
            people: [], // 不再传人
            credits: [], // 不再有演职记录
            artwork: [],
            relatedTitles: []
        )
        try repo.save(updatedSnapshot)
        
        // 验证孤儿清理函数是否发挥了威力
        let afterPeopleCount = try dbManager.query("SELECT COUNT(*) FROM media_people WHERE id = 'person-solo-actor'") { $0.int(0) ?? 0 }.first ?? 0
        XCTAssertEqual(afterPeopleCount, 0, "没有演职员表引用的孤儿演员必须被自愈机制自动回收清除，杜绝垃圾行堆积！")
    }
}
