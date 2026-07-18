import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerLibraryCatalogTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibServerCatalogTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("catalog.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testSnapshotExcludesPrivateSourcesAndPathFields() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "public", name: "客厅电影", path: "/Volumes/Movies", mediaType: .movie))
        try sourceRepository.save(MediaSource(id: "vault", name: "保险库", path: "/Volumes/Vault", mediaType: .privateCollection))
        try mediaRepository.upsert(MediaItem(
            id: "public-movie",
            type: .movie,
            title: "公开电影",
            year: 2025,
            posterPath: "/Volumes/Movies/poster.jpg",
            sourcePath: "/Volumes/Movies",
            filePath: "/Volumes/Movies/public.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "vault-item",
            type: .other,
            title: "不应泄露",
            sourcePath: "/Volumes/Vault",
            filePath: "/Volumes/Vault/private.mp4"
        ))

        let snapshot = try ServerLibraryCatalog(database: database).snapshot(for: .testAdministrator())

        XCTAssertEqual(snapshot.summary.totalItemCount, 1)
        XCTAssertEqual(snapshot.summary.countsByType, ["movie": 1])
        XCTAssertEqual(snapshot.items.items.count, 1)
        XCTAssertEqual(snapshot.items.items.first?.id, "public-movie")
        XCTAssertEqual(snapshot.items.items.first?.title, "公开电影")
        XCTAssertTrue(snapshot.items.items.first?.artworkAvailable == true)
    }

    func testHomeSnapshotCountsAuthorizedEpisodesButLimitsCardsToRecentTopLevelItems() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "public", name: "客厅电影", path: "/Volumes/Movies", mediaType: .movie))
        let older = Date(timeIntervalSince1970: 100)
        let newer = Date(timeIntervalSince1970: 200)
        try mediaRepository.upsert(MediaItem(
            id: "movie-a", type: .movie, title: "A 电影", sourcePath: "/Volumes/Movies",
            filePath: "/Volumes/Movies/a.mp4", updatedAt: older
        ))
        try mediaRepository.upsert(MediaItem(
            id: "movie-b", type: .movie, title: "B 电影", sourcePath: "/Volumes/Movies",
            filePath: "/Volumes/Movies/b.mp4", updatedAt: newer
        ))
        try mediaRepository.upsert(MediaItem(
            id: "episode", type: .episode, title: "第一集", sourcePath: "/Volumes/Movies",
            parentID: "series", filePath: "/Volumes/Movies/e1.mp4", updatedAt: newer
        ))

        let snapshot = try ServerLibraryCatalog(database: database).snapshot(for: .testAdministrator())
        let categories = try ServerLibraryCatalog(database: database).categories(for: .testAdministrator())

        XCTAssertEqual(snapshot.summary.totalItemCount, 3)
        XCTAssertEqual(snapshot.summary.countsByType, ["movie": 2, "episode": 1])
        XCTAssertEqual(snapshot.items.items.map(\.id), ["movie-b", "movie-a"])
        XCTAssertEqual(categories.categories.first(where: { $0.id == "movie" })?.itemCount, 2)
        XCTAssertEqual(categories.categories.first(where: { $0.id == "episode" })?.itemCount, 1)
    }

    func testMemberSeesOnlyGrantedSourceAndCannotResolveOtherSourceAsset() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let allowedDirectory = temporaryDirectory.appendingPathComponent("allowed", isDirectory: true)
        let deniedDirectory = temporaryDirectory.appendingPathComponent("denied", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: true)
        let allowedFile = allowedDirectory.appendingPathComponent("allowed.mp4")
        let deniedFile = deniedDirectory.appendingPathComponent("denied.mp4")
        try Data("allowed".utf8).write(to: allowedFile)
        try Data("denied".utf8).write(to: deniedFile)
        try sourceRepository.save(MediaSource(
            id: "library-allowed", name: "允许", path: allowedDirectory.path, mediaType: .movie
        ))
        try sourceRepository.save(MediaSource(
            id: "library-denied", name: "拒绝", path: deniedDirectory.path, mediaType: .movie
        ))
        try mediaRepository.upsert(MediaItem(
            id: "allowed-item", type: .movie, title: "允许影片",
            sourcePath: allowedDirectory.path, filePath: allowedFile.path
        ))
        try mediaRepository.upsert(MediaItem(
            id: "denied-item", type: .movie, title: "拒绝影片",
            sourcePath: deniedDirectory.path, filePath: deniedFile.path
        ))
        let grant = ServerLibraryGrant(
            userID: "member", libraryID: "library-allowed",
            canView: true, canPlay: true, canDownload: false
        )
        let principal = ServerRequestPrincipal(
            userID: "member",
            deviceID: "device",
            sessionID: "session",
            permissions: [.viewMedia, .playMedia, .transcodePlayback],
            libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let snapshot = try catalog.snapshot(for: principal)

        XCTAssertEqual(snapshot.items.items.map(\.id), ["allowed-item"])
        XCTAssertNotNil(try catalog.publicAsset(id: "allowed-item", for: principal))
        XCTAssertNil(try catalog.publicAsset(id: "denied-item", for: principal))
    }

    func testWebVTTSidecarsStayAuthorizedBoundedAndPathFree() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let directory = temporaryDirectory.appendingPathComponent("subtitles", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let media = directory.appendingPathComponent("movie.mkv")
        try Data("media".utf8).write(to: media)
        let expectedVTT = Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHello\n".utf8)
        try expectedVTT.write(to: directory.appendingPathComponent("movie.en.vtt"))
        try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nHidden\n".utf8)
            .write(to: directory.appendingPathComponent("other.vtt"))
        let outside = temporaryDirectory.appendingPathComponent("outside.vtt")
        try Data("WEBVTT\n\n00:00.000 --> 00:01.000\nOutside\n".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(
            atPath: directory.appendingPathComponent("movie.escape.vtt").path,
            withDestinationPath: outside.path
        )
        try sourceRepository.save(MediaSource(id: "subtitle-library", name: "字幕库", path: directory.path, mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "subtitle-item", type: .movie, title: "字幕影片", sourcePath: directory.path, filePath: media.path
        ))
        let grant = ServerLibraryGrant(userID: "member", libraryID: "subtitle-library", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant]
        )
        let denied = ServerRequestPrincipal(
            userID: "denied", deviceID: "other", sessionID: "other-session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [:]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let tracks = try XCTUnwrap(catalog.webVTTSubtitleTracks(id: "subtitle-item", for: principal))
        let asset = try XCTUnwrap(catalog.publicWebVTTSubtitleAsset(id: "subtitle-item", trackID: 0, for: principal))
        let encoded = try JSONEncoder().encode(tracks)

        XCTAssertEqual(tracks, [ServerWebVTTSubtitleTrack(id: 0, label: "字幕 1")])
        XCTAssertEqual(asset.contentType, "text/vtt; charset=utf-8")
        XCTAssertEqual(try Data(contentsOf: asset.fileURL), expectedVTT)
        XCTAssertFalse((String(data: encoded, encoding: .utf8) ?? "").contains(directory.path))
        XCTAssertNil(try catalog.webVTTSubtitleTracks(id: "subtitle-item", for: denied))
        XCTAssertNil(try catalog.publicWebVTTSubtitleAsset(id: "subtitle-item", trackID: 0, for: denied))
        XCTAssertNil(try catalog.publicWebVTTSubtitleAsset(id: "subtitle-item", trackID: 16, for: principal))
    }

    func testEpisodeNavigationUsesOnlyAuthorizedPlayableSiblings() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let allowedDirectory = temporaryDirectory.appendingPathComponent("episodes-allowed", isDirectory: true)
        let deniedDirectory = temporaryDirectory.appendingPathComponent("episodes-denied", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: true)
        let first = allowedDirectory.appendingPathComponent("episode-1.mp4")
        let second = allowedDirectory.appendingPathComponent("episode-2.mp4")
        let denied = deniedDirectory.appendingPathComponent("episode-3.mp4")
        try Data("one".utf8).write(to: first)
        try Data("two".utf8).write(to: second)
        try Data("three".utf8).write(to: denied)
        try sourceRepository.save(MediaSource(id: "allowed-series", name: "允许剧集", path: allowedDirectory.path, mediaType: .tvShow))
        try sourceRepository.save(MediaSource(id: "denied-series", name: "拒绝剧集", path: deniedDirectory.path, mediaType: .tvShow))
        for (id, title, number, source, file) in [
            ("episode-1", "第一集", 1, allowedDirectory.path, first.path),
            ("episode-2", "第二集", 2, allowedDirectory.path, second.path),
            ("episode-3", "不应出现", 3, deniedDirectory.path, denied.path)
        ] {
            try mediaRepository.upsert(MediaItem(
                id: id, type: .episode, title: title, sourcePath: source, parentID: "show-1",
                seasonNumber: 1, episodeNumber: number, filePath: file
            ))
        }
        let grant = ServerLibraryGrant(userID: "member", libraryID: "allowed-series", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let firstDetail = try XCTUnwrap(catalog.publicDetail(id: "episode-1", for: principal))
        let secondDetail = try XCTUnwrap(catalog.publicDetail(id: "episode-2", for: principal))
        let text = String(data: try JSONEncoder().encode(secondDetail), encoding: .utf8) ?? ""

        XCTAssertNil(firstDetail.previousEpisode)
        XCTAssertEqual(firstDetail.nextEpisode, ServerEpisodeNavigation(id: "episode-2", title: "S01E02  第二集"))
        XCTAssertEqual(secondDetail.previousEpisode, ServerEpisodeNavigation(id: "episode-1", title: "S01E01  第一集"))
        XCTAssertNil(secondDetail.nextEpisode, "未授权资料库的同组剧集不能成为网页下一集")
        XCTAssertFalse(text.contains("show-1"))
        XCTAssertFalse(text.contains(deniedDirectory.path))
    }

    func testDetailIsBoundedAuthorizedAndExcludesDesktopPlaybackTrace() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let mediaDirectory = temporaryDirectory.appendingPathComponent("detail", isDirectory: true)
        try FileManager.default.createDirectory(at: mediaDirectory, withIntermediateDirectories: true)
        let mediaFile = mediaDirectory.appendingPathComponent("detail.mp4")
        try Data("media".utf8).write(to: mediaFile)
        try sourceRepository.save(MediaSource(
            id: "library-detail", name: "详情库", path: mediaDirectory.path, mediaType: .movie
        ))
        try mediaRepository.upsert(MediaItem(
            id: "detail-item",
            type: .movie,
            title: String(repeating: "片", count: 600),
            originalTitle: "Original",
            year: 2026,
            overview: String(repeating: "介", count: 8_100),
            posterPath: mediaDirectory.appendingPathComponent("poster.jpg").path,
            backdropPath: mediaDirectory.appendingPathComponent("backdrop.jpg").path,
            rating: 8.6,
            runtime: 120,
            sourcePath: mediaDirectory.path,
            filePath: mediaFile.path,
            videoCodec: "h264",
            audioCodec: "aac",
            resolution: "1920x1080",
            playCount: 42,
            playPosition: 900,
            playProgress: 0.5,
            watched: true,
            favorite: true,
            watchlist: true,
            genre: (0..<30).map { "类型\($0)" }.joined(separator: ",")
        ))
        let grant = ServerLibraryGrant(
            userID: "member", libraryID: "library-detail",
            canView: true, canPlay: true, canDownload: false
        )
        let principal = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia, .transcodePlayback],
            libraryGrants: [grant.libraryID: grant]
        )
        let deniedPrincipal = ServerRequestPrincipal(
            userID: "denied", deviceID: "device", sessionID: "session-denied",
            permissions: [.viewMedia, .playMedia, .transcodePlayback], libraryGrants: [:]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let detail = try XCTUnwrap(catalog.publicDetail(id: "detail-item", for: principal))

        XCTAssertEqual(detail.title.count, 512)
        XCTAssertEqual(detail.overview?.count, 8_000)
        XCTAssertEqual(detail.genres.count, 24)
        XCTAssertEqual(detail.runtimeSeconds, 7_200)
        XCTAssertEqual(detail.communityRating, 8.6)
        XCTAssertTrue(detail.canDirectPlay)
        XCTAssertFalse(detail.canTranscode)
        XCTAssertNil(try catalog.publicDetail(id: "detail-item", for: deniedPrincipal))
        let encoded = try JSONEncoder().encode(detail)
        let text = String(data: encoded, encoding: .utf8)?.lowercased() ?? ""
        XCTAssertFalse(text.contains("playposition"))
        XCTAssertFalse(text.contains("playprogress"))
        XCTAssertFalse(text.contains(mediaDirectory.path.lowercased()))
    }

    func testPlaybackStateUsesAuthenticatedUserAndCannotMutateAnUnauthorizedItem() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let identityRepository = ServerIdentityRepository(database: database)
        let directory = temporaryDirectory.appendingPathComponent("state", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("movie.mp4")
        try Data("media".utf8).write(to: file)
        try sourceRepository.save(MediaSource(id: "state-library", name: "状态库", path: directory.path, mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "state-item", type: .movie, title: "状态影片",
            sourcePath: directory.path, filePath: file.path, duration: 600,
            playPosition: 599, playProgress: 0.99, watched: true
        ))
        _ = try identityRepository.createUser(id: "viewer-a", username: "viewer-a", displayName: "A")
        _ = try identityRepository.createUser(id: "viewer-b", username: "viewer-b", displayName: "B")
        let grantA = ServerLibraryGrant(
            userID: "viewer-a", libraryID: "state-library", canView: true, canPlay: true, canDownload: false
        )
        let grantB = ServerLibraryGrant(
            userID: "viewer-b", libraryID: "state-library", canView: true, canPlay: true, canDownload: false
        )
        let principalA = ServerRequestPrincipal(
            userID: "viewer-a", deviceID: "device-a", sessionID: "session-a",
            permissions: [.viewMedia, .playMedia], libraryGrants: ["state-library": grantA]
        )
        let principalB = ServerRequestPrincipal(
            userID: "viewer-b", deviceID: "device-b", sessionID: "session-b",
            permissions: [.viewMedia, .playMedia], libraryGrants: ["state-library": grantB]
        )
        let denied = ServerRequestPrincipal(
            userID: "viewer-b", deviceID: "device-b", sessionID: "session-b",
            permissions: [.viewMedia, .playMedia], libraryGrants: [:]
        )
        let catalog = ServerLibraryCatalog(database: database)
        let request = ServerPlaybackStateUpdateRequest(
            event: .progress, positionSeconds: 300, durationSeconds: 600
        )

        let stateA = try XCTUnwrap(catalog.updatePlaybackState(id: "state-item", request: request, for: principalA))
        XCTAssertEqual(stateA.progress, 0.5, accuracy: 0.0001)
        XCTAssertEqual(try catalog.publicDetail(id: "state-item", for: principalA)?.userState, stateA)
        XCTAssertEqual(try catalog.snapshot(for: principalA).items.items.first?.userState, stateA)
        XCTAssertNil(try catalog.publicDetail(id: "state-item", for: principalB)?.userState)
        XCTAssertEqual(
            try catalog.browse(ServerLibraryQuery(limit: 10, playbackFilter: .inProgress), for: principalA).items.map(\.id),
            ["state-item"]
        )
        XCTAssertTrue(
            try catalog.browse(ServerLibraryQuery(limit: 10, playbackFilter: .inProgress), for: principalB).items.isEmpty
        )
        XCTAssertNil(try catalog.updatePlaybackState(id: "state-item", request: request, for: denied))
        XCTAssertNil(try catalog.publicDetail(id: "missing", for: principalA))
    }

    func testSeriesHierarchyUsesAuthorizedSourcesAndCurrentUserSeasonState() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        let identities = ServerIdentityRepository(database: database)
        let states = ServerUserMediaStateRepository(database: database)
        let preferences = ServerUserMediaPreferenceRepository(database: database)
        try sources.save(MediaSource(id: "series-allowed", name: "剧集库", path: "/Volumes/Series", mediaType: .tvShow))
        try sources.save(MediaSource(id: "series-denied", name: "隐藏剧集库", path: "/Volumes/HiddenSeries", mediaType: .tvShow))
        try media.upsert(MediaItem(
            id: "series-1", type: .tvShow, title: "测试系列", year: 2026,
            overview: "系列简介", sourcePath: "/Volumes/Series"
        ))
        try media.upsert(MediaItem(
            id: "episode-1", type: .episode, title: "第一集", sourcePath: "/Volumes/Series",
            parentID: "series-1", seasonNumber: 1, episodeNumber: 1, duration: 1_200
        ))
        try media.upsert(MediaItem(
            id: "episode-2", type: .episode, title: "第二集", sourcePath: "/Volumes/Series",
            parentID: "series-1", seasonNumber: 1, episodeNumber: 2, duration: 1_500
        ))
        try media.upsert(MediaItem(
            id: "episode-special", type: .episode, title: "幕后", sourcePath: "/Volumes/Series",
            parentID: "series-1", episodeNumber: 1
        ))
        try media.upsert(MediaItem(
            id: "denied-episode", type: .episode, title: "不应出现", sourcePath: "/Volumes/HiddenSeries",
            parentID: "series-1", seasonNumber: 1, episodeNumber: 3
        ))
        _ = try identities.createUser(id: "series-member", username: "series-member", displayName: "成员")
        _ = try identities.createUser(id: "series-other", username: "series-other", displayName: "另一成员")
        _ = try states.update(userID: "series-member", mediaID: "episode-1", event: .completed, position: 1_200, duration: 1_200)
        _ = try states.update(userID: "series-member", mediaID: "episode-2", event: .progress, position: 300, duration: 1_500)
        _ = try states.update(userID: "series-other", mediaID: "episode-2", event: .completed, position: 1_500, duration: 1_500)
        _ = try preferences.update(userID: "series-member", mediaID: "series-1", preference: .favorite(true))
        let grant = ServerLibraryGrant(
            userID: "series-member", libraryID: "series-allowed", canView: true, canPlay: true, canDownload: false
        )
        let principal = ServerRequestPrincipal(
            userID: "series-member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant]
        )
        let denied = ServerRequestPrincipal(
            userID: "series-other", deviceID: "other-device", sessionID: "other-session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [:]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let detail = try XCTUnwrap(catalog.seriesDetail(id: "series-1", for: principal))
        XCTAssertEqual(detail.totalEpisodeCount, 3)
        XCTAssertEqual(detail.seasons.map(\.title), ["第 1 季", "未分季"])
        XCTAssertEqual(detail.seasons.first?.episodeCount, 2)
        XCTAssertEqual(detail.seasons.first?.watchedCount, 1)
        XCTAssertEqual(detail.seasons.first?.inProgressCount, 1)
        XCTAssertTrue(detail.userPreference.isFavorite)
        XCTAssertNil(try catalog.seriesDetail(id: "series-1", for: denied))
        XCTAssertNil(try catalog.seriesDetail(id: "episode-1", for: principal))

        let firstPage = try XCTUnwrap(catalog.seriesEpisodes(
            id: "series-1", season: .numbered(1), offset: 0, limit: 1, for: principal
        ))
        XCTAssertEqual(firstPage.totalItemCount, 2)
        XCTAssertEqual(firstPage.items.map(\.id), ["episode-1"])
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(firstPage.items.first?.userState?.isWatched, true)
        let secondPage = try XCTUnwrap(catalog.seriesEpisodes(
            id: "series-1", season: .numbered(1), offset: 1, limit: 10, for: principal
        ))
        XCTAssertEqual(secondPage.items.map(\.id), ["episode-2"])
        XCTAssertEqual(secondPage.items.first?.userState?.progress ?? 0, 0.2, accuracy: 0.0001)
        let unspecified = try XCTUnwrap(catalog.seriesEpisodes(
            id: "series-1", season: .unspecified, offset: 0, limit: 10, for: principal
        ))
        XCTAssertEqual(unspecified.items.map(\.id), ["episode-special"])
        XCTAssertNil(try catalog.seriesEpisodes(
            id: "series-1", season: .numbered(1), offset: 0, limit: 10, for: denied
        ))
        let encoded = try JSONEncoder().encode(detail)
        let text = String(data: encoded, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains("/Volumes/"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("sourcePath"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("parentID"))
        XCTAssertFalse(text.contains("series-other"))
    }

    func testBrowseUsesServerCategoriesPaginationSearchAndCurrentUserState() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "browse", name: "浏览", path: "/Volumes/Browse", mediaType: .movie))
        for index in 0..<5 {
            try mediaRepository.upsert(MediaItem(
                id: "movie-\(index)", type: .movie,
                title: index == 3 ? "银河档案" : "影片 \(index)", year: 2020 + index,
                sourcePath: "/Volumes/Browse",
                updatedAt: Date(timeIntervalSince1970: TimeInterval(index))
            ))
        }
        try mediaRepository.upsert(MediaItem(
            id: "episode-1", type: .episode, title: "银河 第一集", sourcePath: "/Volumes/Browse"
        ))
        let userStateRepository = ServerUserMediaStateRepository(database: database)
        _ = try userStateRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-3", event: .started, position: 0, duration: 100,
            at: Date(timeIntervalSince1970: 100)
        )
        _ = try userStateRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-3", event: .progress, position: 30, duration: 100,
            at: Date(timeIntervalSince1970: 110)
        )
        _ = try userStateRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-0", event: .started, position: 0, duration: 100,
            at: Date(timeIntervalSince1970: 200)
        )
        _ = try userStateRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-0", event: .completed, position: 100, duration: 100,
            at: Date(timeIntervalSince1970: 201)
        )
        let preferenceRepository = ServerUserMediaPreferenceRepository(database: database)
        _ = try ServerIdentityRepository(database: database).createUser(
            id: "another-user", username: "another", displayName: "另一用户"
        )
        _ = try preferenceRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-2", preference: .favorite(true)
        )
        _ = try preferenceRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-4", preference: .watchlist(true)
        )
        _ = try preferenceRepository.update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-1", preference: .rating(4.5)
        )
        _ = try preferenceRepository.update(
            userID: "another-user", mediaID: "movie-1", preference: .favorite(true)
        )
        let catalog = ServerLibraryCatalog(database: database)
        let principal = ServerRequestPrincipal(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            deviceID: "device", sessionID: "session",
            permissions: Set(ServerPermission.allCases), libraryGrants: [:]
        )

        let categories = try catalog.categories(for: principal)
        let firstPage = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 2, sort: .yearDescending),
            for: principal
        )
        let search = try catalog.browse(
            ServerLibraryQuery(searchText: "银河", type: "movie", limit: 10),
            for: principal
        )
        let episodes = try catalog.browse(
            ServerLibraryQuery(type: "episode", limit: 10),
            for: principal
        )
        let continuing = try catalog.browse(
            ServerLibraryQuery(limit: 10, playbackFilter: .inProgress),
            for: principal
        )
        let history = try catalog.browse(
            ServerLibraryQuery(limit: 10, sort: .lastPlayedDescending, playbackFilter: .history),
            for: principal
        )
        let favorites = try catalog.browse(
            ServerLibraryQuery(limit: 10, preferenceFilter: .favorite), for: principal
        )
        let watchlist = try catalog.browse(
            ServerLibraryQuery(limit: 10, preferenceFilter: .watchlist), for: principal
        )
        let ratings = try catalog.browse(
            ServerLibraryQuery(limit: 10, preferenceFilter: .rated), for: principal
        )
        let watched = try catalog.browse(
            ServerLibraryQuery(limit: 10, playbackFilter: .watched), for: principal
        )
        let unwatched = try catalog.browse(
            ServerLibraryQuery(limit: 10, playbackFilter: .unwatched), for: principal
        )

        XCTAssertEqual(categories.categories.first(where: { $0.id == "movie" })?.itemCount, 5)
        XCTAssertEqual(categories.categories.first(where: { $0.id == "episode" })?.itemCount, 1)
        XCTAssertEqual(firstPage.totalItemCount, 5)
        XCTAssertEqual(firstPage.items.map(\.year), [2024, 2023])
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(search.items.map(\.id), ["movie-3"])
        XCTAssertEqual(search.items.first?.userState?.progress ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(episodes.items.map(\.id), ["episode-1"])
        XCTAssertEqual(continuing.items.map(\.id), ["movie-3"])
        XCTAssertEqual(history.items.map(\.id), ["movie-0", "movie-3"])
        XCTAssertEqual(favorites.items.map(\.id), ["movie-2"])
        XCTAssertTrue(favorites.items.first?.userPreference.isFavorite == true)
        XCTAssertEqual(watchlist.items.map(\.id), ["movie-4"])
        XCTAssertTrue(watchlist.items.first?.userPreference.isWatchlist == true)
        XCTAssertEqual(ratings.items.map(\.id), ["movie-1"])
        XCTAssertEqual(ratings.items.first?.userPreference.rating, 4.5)
        XCTAssertEqual(watched.items.map(\.id), ["movie-0"])
        XCTAssertFalse(unwatched.items.map(\.id).contains("movie-0"))
        XCTAssertTrue(unwatched.items.map(\.id).contains("episode-1"))
    }

    func testArtworkRequiresItemAuthorizationAndRejectsUnsafeOrOversizedFiles() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let artworkDirectory = temporaryDirectory.appendingPathComponent("artwork", isDirectory: true)
        try FileManager.default.createDirectory(at: artworkDirectory, withIntermediateDirectories: true)
        let poster = artworkDirectory.appendingPathComponent("poster.jpg")
        let unsafe = artworkDirectory.appendingPathComponent("poster.svg")
        let oversized = artworkDirectory.appendingPathComponent("huge.png")
        try Data([0xff, 0xd8, 0xff, 0xd9]).write(to: poster)
        try Data("<svg><script>alert(1)</script></svg>".utf8).write(to: unsafe)
        FileManager.default.createFile(atPath: oversized.path, contents: Data([0x89]))
        let handle = try FileHandle(forWritingTo: oversized)
        try handle.truncate(atOffset: UInt64(ServerArtworkKind.maximumByteLength + 1))
        try handle.close()
        try sourceRepository.save(MediaSource(id: "art", name: "海报", path: artworkDirectory.path, mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "valid", type: .movie, title: "有效", posterPath: poster.path, sourcePath: artworkDirectory.path
        ))
        try mediaRepository.upsert(MediaItem(
            id: "unsafe", type: .movie, title: "不安全", posterPath: unsafe.path, sourcePath: artworkDirectory.path
        ))
        try mediaRepository.upsert(MediaItem(
            id: "huge", type: .movie, title: "过大", posterPath: oversized.path, sourcePath: artworkDirectory.path
        ))
        let catalog = ServerLibraryCatalog(database: database)
        let denied = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia], libraryGrants: [:]
        )

        let asset = try XCTUnwrap(catalog.publicArtwork(id: "valid", kind: .poster, for: .testAdministrator()))

        XCTAssertEqual(asset.contentType, "image/jpeg")
        XCTAssertEqual(asset.byteLength, 4)
        XCTAssertNil(try catalog.publicArtwork(id: "valid", kind: .poster, for: denied))
        XCTAssertNil(try catalog.publicArtwork(id: "unsafe", kind: .poster, for: .testAdministrator()))
        XCTAssertNil(try catalog.publicArtwork(id: "huge", kind: .poster, for: .testAdministrator()))
        XCTAssertNil(try catalog.publicArtwork(id: "missing", kind: .poster, for: .testAdministrator()))
    }
}
