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

    func testFetchServerMediaItemUsesAuthorizedSourceAndIDFilter() throws {
        try repo.upsert(mediaItem(id: "authorized-item", sourcePath: "/library/allowed"))
        try repo.upsert(mediaItem(id: "other-source-item", sourcePath: "/library/other"))
        try repo.upsert(MediaItem(
            id: "private-item",
            type: .privateCollection,
            title: "private-item",
            sourcePath: "/library/allowed"
        ))

        let authorized = try repo.fetchServerMediaItem(
            id: "authorized-item",
            allowedSourcePaths: ["/library/allowed"]
        )
        XCTAssertEqual(authorized?.id, "authorized-item")
        let batch = try repo.fetchServerMediaItems(
            ids: ["authorized-item", "other-source-item", "authorized-item"],
            allowedSourcePaths: ["/library/allowed"]
        )
        XCTAssertEqual(batch.map(\.id), ["authorized-item"])
        XCTAssertNil(try repo.fetchServerMediaItem(id: "other-source-item", allowedSourcePaths: ["/library/allowed"]))
        XCTAssertNil(try repo.fetchServerMediaItem(id: "private-item", allowedSourcePaths: ["/library/allowed"]))
    }

    func testServerMusicAndSeriesQueriesStayWithinAuthorizedSource() throws {
        try repo.upsert(MediaItem(
            id: "allowed-track", type: .music, title: "允许歌曲", artist: "艺术家", album: "专辑",
            sourcePath: "/library/allowed", filePath: "/library/allowed/track.m4a"
        ))
        try repo.upsert(MediaItem(
            id: "denied-track", type: .music, title: "拒绝歌曲",
            sourcePath: "/library/other", filePath: "/library/other/track.m4a"
        ))
        try repo.upsert(MediaItem(
            id: "episode-2", type: .episode, title: "第二集", sourcePath: "/library/allowed", parentID: "series-1",
            seasonNumber: 1, episodeNumber: 2, filePath: "/library/allowed/e2.mp4"
        ))
        try repo.upsert(MediaItem(
            id: "episode-1", type: .episode, title: "第一集", sourcePath: "/library/allowed", parentID: "series-1",
            seasonNumber: 1, episodeNumber: 1, filePath: "/library/allowed/e1.mp4"
        ))
        try repo.upsert(MediaItem(
            id: "denied-episode", type: .episode, title: "拒绝剧集", sourcePath: "/library/other", parentID: "series-1",
            seasonNumber: 1, episodeNumber: 3, filePath: "/library/other/e3.mp4"
        ))

        XCTAssertEqual(
            try repo.fetchServerMusicItems(allowedSourcePaths: ["/library/allowed"]).map(\.id),
            ["allowed-track"]
        )
        XCTAssertEqual(
            try repo.fetchServerSeriesEpisodes(allowedSourcePaths: ["/library/allowed"], seriesID: "series-1").map(\.id),
            ["episode-1", "episode-2"]
        )
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

    func testDeleteItemsSourcePathPrefixKeepsCaseDifferingLocalPaths() throws {
        try repo.upsert(mediaItem(id: "root", sourcePath: "/Volumes/Media/Library"))
        try repo.upsert(mediaItem(id: "child", sourcePath: "/Volumes/Media/Library/Nested"))
        try repo.upsert(mediaItem(id: "case-different", sourcePath: "/Volumes/media/Library/Nested"))
        try repo.upsert(mediaItem(id: "sibling", sourcePath: "/Volumes/Media/Library2"))

        try repo.deleteItems(sourcePathPrefix: "/Volumes/Media/Library")

        let ids = Set(try repo.fetchAll().map(\.id))
        XCTAssertFalse(ids.contains("root"))
        XCTAssertFalse(ids.contains("child"))
        XCTAssertTrue(ids.contains("case-different"))
        XCTAssertTrue(ids.contains("sibling"))
    }

    func testReplaceRemoteItemsKeepsCaseDifferingRemotePathSegments() throws {
        let remoteSourcePath = "emby://server/Library"
        let refreshed = mediaItem(id: "remote-keep", sourcePath: remoteSourcePath)
        try repo.upsert(mediaItem(id: "remote-stale", sourcePath: "\(remoteSourcePath)/old"))
        try repo.upsert(mediaItem(id: "remote-case-different", sourcePath: "emby://server/library/old"))
        try repo.upsert(mediaItem(id: "remote-sibling", sourcePath: "emby://server/Library2/old"))

        try repo.replaceRemoteItems(sourcePathPrefix: remoteSourcePath, with: [refreshed])

        let ids = Set(try repo.fetchAll().map(\.id))
        XCTAssertTrue(ids.contains("remote-keep"))
        XCTAssertFalse(ids.contains("remote-stale"))
        XCTAssertTrue(ids.contains("remote-case-different"))
        XCTAssertTrue(ids.contains("remote-sibling"))
    }

    func testUpsertAndRemoteReplaceNormalizePlaybackValuesBeforeBinding() throws {
        var local = MediaItem(id: "local-invalid-playback", type: .movie, title: "Local Invalid")
        local.playPosition = Double.nan
        local.playProgress = Double.infinity

        XCTAssertNoThrow(try repo.upsert(local))
        var fetched = try XCTUnwrap(repo.fetch(id: "local-invalid-playback"))
        XCTAssertEqual(fetched.playPosition, 0)
        XCTAssertEqual(fetched.playProgress, 0)

        var remote = mediaItem(
            id: "remote-invalid-playback",
            sourcePath: "emby://server/Playback",
            filePath: "https://server.example/videos/remote-invalid.mkv"
        )
        remote.playPosition = -Double.infinity
        remote.playProgress = 1.4

        XCTAssertNoThrow(try repo.replaceRemoteItems(sourcePathPrefix: "emby://server/Playback", with: [remote]))
        fetched = try XCTUnwrap(repo.fetch(id: "remote-invalid-playback"))
        XCTAssertEqual(fetched.playPosition, 0)
        XCTAssertEqual(fetched.playProgress, 1)
    }

    func testUpsertAndFetchNormalizeNegativePlayCount() throws {
        var item = MediaItem(id: "negative-play-count", type: .movie, title: "Negative Play Count")
        item.playCount = -7

        try repo.upsert(item)

        var fetched = try XCTUnwrap(repo.fetch(id: "negative-play-count"))
        XCTAssertEqual(fetched.playCount, 0)

        try dbManager.execute(
            "UPDATE media_items SET play_count = ? WHERE id = ?",
            bindings: [.int(-12), .text("negative-play-count")]
        )

        fetched = try XCTUnwrap(repo.fetch(id: "negative-play-count"))
        XCTAssertEqual(fetched.playCount, 0, "旧库或外部写入的负播放次数读取时也应归零")
    }

    func testUpsertUpdateAndFetchNormalizeRatingFields() throws {
        var item = MediaItem(id: "rating-boundary", type: .movie, title: "Rating Boundary")
        item.rating = 12
        item.userRating = 7

        try repo.upsert(item)

        var fetched = try XCTUnwrap(repo.fetch(id: "rating-boundary"))
        XCTAssertNil(fetched.rating)
        XCTAssertNil(fetched.userRating)

        item.rating = 8.4
        item.userRating = 0.5
        try repo.upsert(item)

        fetched = try XCTUnwrap(repo.fetch(id: "rating-boundary"))
        XCTAssertEqual(try XCTUnwrap(fetched.rating), 8.4, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.userRating), 0.5, accuracy: 0.0001)

        try repo.updateRating(id: "rating-boundary", rating: 3.5)
        fetched = try XCTUnwrap(repo.fetch(id: "rating-boundary"))
        XCTAssertEqual(try XCTUnwrap(fetched.userRating), 3.5, accuracy: 0.0001)

        try repo.updateRating(id: "rating-boundary", rating: 0)
        fetched = try XCTUnwrap(repo.fetch(id: "rating-boundary"))
        XCTAssertNil(fetched.userRating)

        try dbManager.execute(
            "UPDATE media_items SET rating = ?, user_rating = ? WHERE id = ?",
            bindings: [.double(-2), .double(9), .text("rating-boundary")]
        )

        fetched = try XCTUnwrap(repo.fetch(id: "rating-boundary"))
        XCTAssertNil(fetched.rating, "旧库或外部写入的越界资料源评分读取时应视为缺失")
        XCTAssertNil(fetched.userRating, "旧库或外部写入的越界用户评级读取时应视为未评级")
    }

    func testUpsertUpdateAndFetchNormalizeMetadataNumericFields() throws {
        var item = MediaItem(id: "numeric-boundary", type: .music, title: "Numeric Boundary")
        item.trackNumber = 0
        item.year = -2024
        item.runtime = 0
        item.duration = -30
        item.loudnessTrackGainDB = .infinity
        item.loudnessAlbumGainDB = -Double.infinity
        item.loudnessTrackPeak = 0
        item.loudnessAlbumPeak = -0.5

        try repo.upsert(item)

        var fetched = try XCTUnwrap(repo.fetch(id: "numeric-boundary"))
        XCTAssertNil(fetched.trackNumber)
        XCTAssertNil(fetched.year)
        XCTAssertNil(fetched.runtime)
        XCTAssertNil(fetched.duration)
        XCTAssertNil(fetched.loudnessTrackGainDB)
        XCTAssertNil(fetched.loudnessAlbumGainDB)
        XCTAssertNil(fetched.loudnessTrackPeak)
        XCTAssertNil(fetched.loudnessAlbumPeak)

        item.trackNumber = 2
        item.year = 2026
        item.runtime = 91
        item.duration = 240
        item.loudnessTrackGainDB = -7.25
        item.loudnessAlbumGainDB = 3.5
        item.loudnessTrackPeak = 0.97
        item.loudnessAlbumPeak = 1.2
        try repo.upsert(item)

        fetched = try XCTUnwrap(repo.fetch(id: "numeric-boundary"))
        XCTAssertEqual(fetched.trackNumber, 2)
        XCTAssertEqual(fetched.year, 2026)
        XCTAssertEqual(fetched.runtime, 91)
        XCTAssertEqual(try XCTUnwrap(fetched.duration), 240, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.loudnessTrackGainDB), -7.25, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.loudnessAlbumGainDB), 3.5, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.loudnessTrackPeak), 0.97, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(fetched.loudnessAlbumPeak), 1.2, accuracy: 0.0001)

        _ = try repo.updateMetadata(
            id: "numeric-boundary",
            metadata: MediaMetadataUpdate(trackNumber: -4, year: 0, runtime: -90)
        )

        fetched = try XCTUnwrap(repo.fetch(id: "numeric-boundary"))
        XCTAssertEqual(fetched.trackNumber, 2, "非法曲序不应覆盖已有合法曲序")
        XCTAssertEqual(fetched.year, 2026, "非法年份不应覆盖已有合法年份")
        XCTAssertEqual(fetched.runtime, 91, "非法 runtime 不应覆盖已有合法 runtime")

        try dbManager.execute(
            """
            UPDATE media_items
            SET track_number = ?,
                year = ?,
                runtime = ?,
                duration = ?,
                loudness_track_gain_db = ?,
                loudness_album_gain_db = ?,
                loudness_track_peak = ?,
                loudness_album_peak = ?
            WHERE id = ?
            """,
            bindings: [
                .int(-2),
                .int(0),
                .int(-1),
                .double(-10),
                .double(Double.infinity),
                .double(-Double.infinity),
                .double(0),
                .double(-0.1),
                .text("numeric-boundary")
            ]
        )

        fetched = try XCTUnwrap(repo.fetch(id: "numeric-boundary"))
        XCTAssertNil(fetched.trackNumber, "旧库或外部写入的非正曲序读取时应视为缺失")
        XCTAssertNil(fetched.year, "旧库或外部写入的非正年份读取时应视为缺失")
        XCTAssertNil(fetched.runtime, "旧库或外部写入的非正 runtime 读取时应视为缺失")
        XCTAssertNil(fetched.duration, "旧库或外部写入的非正 duration 读取时应视为缺失")
        XCTAssertNil(fetched.loudnessTrackGainDB, "旧库或外部写入的非有限 track gain 读取时应视为缺失")
        XCTAssertNil(fetched.loudnessAlbumGainDB, "旧库或外部写入的非有限 album gain 读取时应视为缺失")
        XCTAssertNil(fetched.loudnessTrackPeak, "旧库或外部写入的非正 track peak 读取时应视为缺失")
        XCTAssertNil(fetched.loudnessAlbumPeak, "旧库或外部写入的非正 album peak 读取时应视为缺失")
    }

    func testUpdatePlaybackNormalizesNonFiniteInputsBeforePersisting() throws {
        try repo.upsert(MediaItem(id: "playback-state", type: .movie, title: "Playback State"))

        try repo.updatePlayback(
            id: "playback-state",
            position: Double.nan,
            duration: Double.infinity,
            watchedThreshold: Double.nan
        )

        var fetched = try XCTUnwrap(repo.fetch(id: "playback-state"))
        XCTAssertEqual(fetched.playPosition, 0)
        XCTAssertEqual(fetched.playProgress, 0)
        XCTAssertFalse(fetched.watched)

        try repo.updatePlayback(
            id: "playback-state",
            position: 95,
            duration: 100,
            watchedThreshold: Double.infinity
        )

        fetched = try XCTUnwrap(repo.fetch(id: "playback-state"))
        XCTAssertEqual(fetched.playPosition, 95)
        XCTAssertEqual(fetched.playProgress, 0.95, accuracy: 0.0001)
        XCTAssertTrue(fetched.watched, "非有限阈值应回退到默认 0.9，不能阻断正常片尾已看判定")
    }

    func testDeleteItemsFilePathPrefixKeepsCaseDifferingAndWildcardLikeSiblings() throws {
        let sourcePath = "/Volumes/Media/Wildcard"
        try repo.upsert(mediaItem(
            id: "target",
            sourcePath: sourcePath,
            filePath: "/Volumes/Media/Wildcard/Season_1/movie.mkv"
        ))
        try repo.upsert(mediaItem(
            id: "case-different",
            sourcePath: sourcePath,
            filePath: "/Volumes/Media/Wildcard/season_1/movie.mkv"
        ))
        try repo.upsert(mediaItem(
            id: "wildcard-like-sibling",
            sourcePath: sourcePath,
            filePath: "/Volumes/Media/Wildcard/SeasonX1/movie.mkv"
        ))

        try repo.deleteItems(filePathPrefix: "/Volumes/Media/Wildcard/Season_1", sourcePath: sourcePath)

        let ids = Set(try repo.fetchAll().map(\.id))
        XCTAssertFalse(ids.contains("target"))
        XCTAssertTrue(ids.contains("case-different"))
        XCTAssertTrue(ids.contains("wildcard-like-sibling"))
    }

    private func mediaItem(id: String, sourcePath: String, filePath: String? = nil) -> MediaItem {
        MediaItem(
            id: id,
            type: .movie,
            title: id,
            sourcePath: sourcePath,
            filePath: filePath
        )
    }
}
