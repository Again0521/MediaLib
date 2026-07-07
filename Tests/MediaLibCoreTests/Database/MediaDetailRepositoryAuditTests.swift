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

    func testSaveAndFetchNormalizeExternalNumericFields() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-numeric", type: .movie, title: "Numeric Movie"))
        let meta = MediaDetailMetadata(
            mediaID: "movie-numeric",
            seasonCount: -1,
            episodeCount: -12,
            provider: "tmdb",
            language: "zh-CN"
        )
        let person = MediaPerson(
            id: "person-numeric",
            name: "Numeric Actor",
            knownFor: [
                MediaPersonWork(id: "work-nan", title: "NaN Work", mediaKind: "movie", popularity: .nan),
                MediaPersonWork(id: "work-valid", title: "Valid Work", mediaKind: "movie", popularity: 12.5)
            ],
            filmography: [
                MediaPersonWork(id: "work-negative", title: "Negative Work", mediaKind: "movie", popularity: -0.01)
            ]
        )
        let snapshot = MediaDetailSnapshot(
            metadata: meta,
            people: [person],
            credits: [
                MediaCredit(id: "cred-numeric", mediaID: "movie-numeric", personID: "person-numeric", category: "cast", role: "Lead")
            ],
            artwork: [
                MediaArtwork(
                    id: "art-nan",
                    mediaID: "movie-numeric",
                    kind: "backdrop",
                    thumbURL: "thumb",
                    fullURL: "full",
                    aspectRatio: .nan,
                    localPath: "/tmp/numeric-backdrop.jpg"
                ),
                MediaArtwork(
                    id: "art-wide",
                    mediaID: "movie-numeric",
                    kind: "backdrop",
                    thumbURL: "thumb-wide",
                    fullURL: "full-wide",
                    aspectRatio: 2.35
                )
            ],
            relatedTitles: [
                MediaRelatedTitle(
                    id: "related-invalid",
                    mediaID: "movie-numeric",
                    relation: "similar",
                    externalID: "rel-invalid",
                    title: "Invalid Related",
                    rating: -1,
                    popularity: -.infinity
                ),
                MediaRelatedTitle(
                    id: "related-valid",
                    mediaID: "movie-numeric",
                    relation: "similar",
                    externalID: "rel-valid",
                    title: "Valid Related",
                    rating: 9.25,
                    popularity: 42
                )
            ]
        )

        try repo.save(snapshot)

        let fetched = try XCTUnwrap(repo.fetch(mediaID: "movie-numeric"))
        XCTAssertNil(fetched.metadata.seasonCount)
        XCTAssertNil(fetched.metadata.episodeCount)
        XCTAssertEqual(try XCTUnwrap(fetched.artwork.first(where: { $0.id == "art-nan" })?.aspectRatio), 1.78, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.artwork.first(where: { $0.id == "art-wide" })?.aspectRatio), 2.35, accuracy: 0.0001)
        XCTAssertNil(fetched.relatedTitles.first(where: { $0.id == "related-invalid" })?.rating)
        XCTAssertNil(fetched.relatedTitles.first(where: { $0.id == "related-invalid" })?.popularity)
        XCTAssertEqual(try XCTUnwrap(fetched.relatedTitles.first(where: { $0.id == "related-valid" })?.rating), 9.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.relatedTitles.first(where: { $0.id == "related-valid" })?.popularity), 42, accuracy: 0.0001)

        let fetchedPerson = try XCTUnwrap(fetched.people.first(where: { $0.id == "person-numeric" }))
        XCTAssertNil(fetchedPerson.knownFor.first(where: { $0.id == "work-nan" })?.popularity)
        XCTAssertEqual(try XCTUnwrap(fetchedPerson.knownFor.first(where: { $0.id == "work-valid" })?.popularity), 12.5, accuracy: 0.0001)
        XCTAssertNil(fetchedPerson.filmography.first(where: { $0.id == "work-negative" })?.popularity)
    }

    func testFetchNormalizesDirtyDetailNumericRows() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-dirty-numeric", type: .movie, title: "Dirty Numeric Movie"))
        let meta = MediaDetailMetadata(
            mediaID: "movie-dirty-numeric",
            seasonCount: 2,
            episodeCount: 20,
            provider: "tmdb",
            language: "zh-CN"
        )
        let snapshot = MediaDetailSnapshot(
            metadata: meta,
            artwork: [
                MediaArtwork(
                    id: "art-dirty",
                    mediaID: "movie-dirty-numeric",
                    kind: "backdrop",
                    thumbURL: "thumb",
                    fullURL: "full",
                    aspectRatio: 1.5,
                    localPath: "/tmp/dirty-backdrop.jpg"
                )
            ],
            relatedTitles: [
                MediaRelatedTitle(
                    id: "related-dirty",
                    mediaID: "movie-dirty-numeric",
                    relation: "similar",
                    externalID: "rel-dirty",
                    title: "Dirty Related",
                    rating: 8,
                    popularity: 8
                )
            ]
        )
        try repo.save(snapshot)
        try dbManager.execute(
            "UPDATE media_detail_metadata SET season_count = ?, episode_count = ? WHERE media_id = ?",
            bindings: [.int(-2), .int(-10), .text("movie-dirty-numeric")]
        )
        try dbManager.execute(
            "UPDATE media_artwork SET aspect_ratio = ? WHERE id = ?",
            bindings: [.double(0), .text("art-dirty")]
        )
        try dbManager.execute(
            "UPDATE media_related_titles SET rating = ?, popularity = ? WHERE id = ?",
            bindings: [.double(99), .double(-5), .text("related-dirty")]
        )

        let fetched = try XCTUnwrap(repo.fetch(mediaID: "movie-dirty-numeric"))
        XCTAssertNil(fetched.metadata.seasonCount)
        XCTAssertNil(fetched.metadata.episodeCount)
        XCTAssertEqual(try XCTUnwrap(fetched.artwork.first?.aspectRatio), 1.78, accuracy: 0.0001)
        XCTAssertNil(fetched.relatedTitles.first?.rating)
        XCTAssertNil(fetched.relatedTitles.first?.popularity)

        let backdropPaths = try repo.firstBackdropPathsByMediaID()
        XCTAssertEqual(backdropPaths["movie-dirty-numeric"], "/tmp/dirty-backdrop.jpg")
    }

    func testDetailCompletenessUsesWhitelistedPresenceTablesAndTreatsMediaIDsAsData() throws {
        let mediaRepo = MediaRepository(database: dbManager)
        let completeID = "movie-complete'); DROP TABLE media_artwork; --"
        let partialID = "movie-partial"
        try mediaRepo.upsert(MediaItem(id: completeID, type: .movie, title: "Complete Detail"))
        try mediaRepo.upsert(MediaItem(id: partialID, type: .movie, title: "Partial Detail"))

        try repo.save(MediaDetailSnapshot(
            metadata: MediaDetailMetadata(mediaID: completeID, provider: "tmdb", language: "zh-CN"),
            externalIDs: [MediaExternalID(provider: "imdb", value: "tt-complete")],
            people: [MediaPerson(id: "person-complete", name: "Complete Actor")],
            credits: [
                MediaCredit(
                    id: "credit-complete",
                    mediaID: completeID,
                    personID: "person-complete",
                    category: "cast",
                    role: "Lead",
                    order: 0
                )
            ],
            artwork: [
                MediaArtwork(
                    id: "art-complete",
                    mediaID: completeID,
                    kind: "backdrop",
                    thumbURL: "thumb",
                    fullURL: "full",
                    aspectRatio: 1.78
                )
            ],
            relatedTitles: [
                MediaRelatedTitle(
                    id: "related-complete",
                    mediaID: completeID,
                    relation: "similar",
                    externalID: "rel-complete",
                    title: "Related Complete"
                )
            ]
        ))
        try repo.save(MediaDetailSnapshot(
            metadata: MediaDetailMetadata(mediaID: partialID, provider: "tmdb", language: "zh-CN"),
            externalIDs: [MediaExternalID(provider: "imdb", value: "tt-partial")]
        ))

        let completeness = try repo.detailCompleteness(mediaIDs: [completeID, partialID, "movie-missing"])

        XCTAssertNil(completeness[completeID])
        XCTAssertEqual(completeness[partialID], Set(["人物", "艺术照", "推荐"]))
        XCTAssertEqual(completeness["movie-missing"], Set(["外部 ID", "人物", "艺术照", "推荐"]))

        let artworkRows = try dbManager.query("SELECT COUNT(*) FROM media_artwork") { $0.int(0) ?? 0 }.first ?? 0
        XCTAssertEqual(artworkRows, 1)
    }
}
