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

    func testMusicItemsSupportsLargeAuthorizedLibrariesWithoutStateQueryLimit() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "music", name: "音乐", path: "/Volumes/Music", mediaType: .music))
        for index in 0..<140 {
            try mediaRepository.upsert(MediaItem(
                id: "track-\(index)", type: .music, title: "歌曲 \(index)",
                artist: "艺术家 \(index % 4)", album: "专辑 \(index % 8)",
                sourcePath: "/Volumes/Music", filePath: "/Volumes/Music/track-\(index).mp3",
                duration: Double(180 + index)
            ))
        }

        // 逐用户仓库的按 ID 批量读取一次最多 100 项，而音乐页是整库一次渲染。
        // 痕迹仍要挂上——「收藏」筛选与「播放次数」排序就在这一页上——所以读的是
        // "这个人标过的东西"（随他的操作增长），不是"这一页有多少卡片"。
        let identities = ServerIdentityRepository(database: database)
        _ = try identities.createUser(id: "test-admin", username: "catalog-owner", displayName: "机主")
        _ = try identities.createUser(id: "other", username: "catalog-other", displayName: "另一个人")
        try ServerUserMediaPreferenceRepository(database: database).update(
            userID: "test-admin", mediaID: "track-130", preference: .favorite(true)
        )
        let stateRepository = ServerUserMediaStateRepository(database: database)
        try stateRepository.update(
            userID: "test-admin", mediaID: "track-130", event: .started, position: 0, duration: 180
        )
        try stateRepository.update(
            userID: "test-admin", mediaID: "track-130", event: .completed, position: 180, duration: 180
        )

        let tracks = try ServerLibraryCatalog(database: database).musicItems(for: .testAdministrator())

        XCTAssertEqual(tracks.count, 140)
        XCTAssertTrue(tracks.allSatisfy { $0.type == "music" })
        XCTAssertEqual(tracks.first?.artist, "艺术家 0")
        XCTAssertNotNil(tracks.first?.durationSeconds)
        // 第 131 首在按 ID 批量读取的 100 项上界之外，正是从前一定读不到的那一段。
        let marked = try XCTUnwrap(tracks.first { $0.id == "track-130" })
        XCTAssertTrue(marked.userPreference.isFavorite)
        XCTAssertEqual(marked.userState?.playCount, 1)
        XCTAssertEqual(marked.userState?.isWatched, true)
        XCTAssertTrue(tracks.filter { $0.id != "track-130" }.allSatisfy { !$0.userPreference.isFavorite })

        // 别人的收藏就是别人的：换一个账号，同一首歌什么痕迹都没有。
        let otherPrincipal = ServerRequestPrincipal(
            userID: "other", deviceID: "device", sessionID: "session",
            permissions: Set(ServerPermission.allCases), libraryGrants: [:]
        )
        let otherTracks = try ServerLibraryCatalog(database: database).musicItems(for: otherPrincipal)
        XCTAssertTrue(otherTracks.allSatisfy { $0.userState == nil && $0.userPreference == .empty })
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

    func testRemoteServerItemKeepsURLPrivateButIsPlayableThroughAuthorizedAssetBoundary() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(
            id: "emby-library", name: "客厅 EMBY", path: "emby://media.example/remote-source", mediaType: .movie
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-item", type: .movie, title: "远程电影", sourcePath: "emby://media.example/remote-source",
            filePath: "https://media.example/Videos/remote-item/stream.mp4?api_key=secret-token",
            fileSize: 1_024, metadataProvider: "Emby"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-extensionless", type: .movie, title: "无扩展名远程电影", sourcePath: "emby://media.example/remote-source",
            filePath: "https://media.example/Videos/remote-extensionless/stream?api_key=secret-token",
            fileSize: 1_024, metadataProvider: "Emby"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-unknown-size", type: .music, title: "未知长度远程音乐", sourcePath: "emby://media.example/remote-source",
            filePath: "https://media.example/Audio/remote-unknown-size/stream.mp3?api_key=secret-token",
            metadataProvider: "Emby"
        ))
        // 普通 URL 媒体源不能借服务端代理访问任意地址。
        try sourceRepository.save(MediaSource(id: "url-library", name: "普通 URL", path: "url://items", mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "untrusted-url", type: .movie, title: "不可信", sourcePath: "url://items",
            filePath: "https://private.example/video.mp4", fileSize: 1_024
        ))
        let catalog = ServerLibraryCatalog(database: database)

        let detail = try XCTUnwrap(catalog.publicDetail(id: "remote-item", for: .testAdministrator()))
        let asset = try XCTUnwrap(catalog.publicAsset(id: "remote-item", for: .testAdministrator()))
        let extensionlessDetail = try XCTUnwrap(catalog.publicDetail(id: "remote-extensionless", for: .testAdministrator()))
        let unknownSizeDetail = try XCTUnwrap(catalog.publicDetail(id: "remote-unknown-size", for: .testAdministrator()))
        let unknownSizeAsset = try XCTUnwrap(catalog.publicAsset(id: "remote-unknown-size", for: .testAdministrator()))
        // 一级分类与客户端一致，只含本地来源；远程条目要经来源作用域才出现。
        // 首页快照与一级分类同口径，因此它也不含远程条目——来源角标要在远程
        // 作用域的浏览结果上验证。
        let snapshot = try catalog.snapshot(for: .testAdministrator())
        let localMoviePage = try catalog.browse(
            ServerLibraryQuery(type: "movie", offset: 0, limit: 24), for: .testAdministrator()
        )
        let remoteGroup = try XCTUnwrap(catalog.remoteSourceGroups(for: .testAdministrator()).first)
        let remoteMoviePage = try catalog.browse(
            ServerLibraryQuery(type: "movie", offset: 0, limit: 24, remoteScopeID: remoteGroup.id),
            for: .testAdministrator()
        )
        let remoteCard = try XCTUnwrap(remoteMoviePage.items.first(where: { $0.id == "remote-item" }))

        XCTAssertTrue(detail.canDirectPlay)
        XCTAssertEqual(detail.browserContentType, "video/mp4")
        XCTAssertEqual(
            detail.playbackModes,
            ServerMediaToolchain.ffmpegURL() == nil ? [.directPlay] : [.directPlay, .fullTranscode]
        )
        XCTAssertEqual(asset.remoteURL?.host, "media.example")
        XCTAssertEqual(asset.byteLength, 1_024)
        XCTAssertTrue(extensionlessDetail.canDirectPlay)
        XCTAssertNil(extensionlessDetail.browserContentType)
        XCTAssertTrue(unknownSizeDetail.canDirectPlay)
        XCTAssertEqual(unknownSizeAsset.byteLength, 0)
        XCTAssertTrue(remoteCard.isRemoteSource)
        XCTAssertFalse(
            localMoviePage.items.contains(where: { $0.id == "remote-item" }),
            "远程条目不得混进本地一级分类"
        )
        // 首页看板 = 本地 + 远程，与客户端 `cachedHomeVideoItems` 同口径：接了一台
        // Emby，它的内容就该出现在首页，而不是只能从侧栏的来源分组里进去。
        XCTAssertTrue(
            snapshot.items.items.contains(where: { $0.id == "remote-item" }),
            "首页看板必须含远程条目，与客户端一致"
        )
        // 但它**只是**首页。一级分类仍然只数本地：远程条目混进「电影」，会让同一个
        // 数字在首页和分类页各说各话，只存在于远程的类型还会长出一个
        // `/category/<type>` 会 404 的侧栏入口——这是两件不同的事。
        XCTAssertFalse(
            localMoviePage.items.contains(where: { $0.id == "remote-item" }),
            "一级分类页仍然只有本地条目"
        )
        XCTAssertEqual(
            try catalog.categories(for: .testAdministrator())
                .categories.first(where: { $0.id == "movie" })?.itemCount,
            1,
            "侧栏一级分类的计数仍然只数本地"
        )
        // 概览格子数的是整个资料库，所以它跟着看板走：一部本地 URL 视频 + 两部
        // Emby 电影。
        XCTAssertEqual(snapshot.summary.countsByType["movie"], 3, "首页概览计入远程电影")
        XCTAssertTrue(remoteMoviePage.items.contains(where: { $0.id == "remote-item" && $0.isRemoteSource }))
        XCTAssertFalse(remoteMoviePage.items.contains(where: { $0.id == "remote-unknown-size" }))
        XCTAssertNil(try catalog.publicAsset(id: "untrusted-url", for: .testAdministrator()))
        XCTAssertFalse(String(describing: detail).contains("secret-token"))
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
        let reference = try XCTUnwrap(catalog.subtitleTrack(id: "subtitle-item", trackID: 0, for: principal))
        guard case let .sidecar(asset) = reference.source else {
            return XCTFail("同目录外挂字幕必须解析成 sidecar 来源")
        }
        let encoded = try JSONEncoder().encode(tracks)

        // 标签与语言现在从文件名后缀解析而来（`…​.en.vtt`），不再是无信息的序号，
        // 播放器才能按浏览器语言挑默认轨。
        XCTAssertEqual(tracks, [ServerWebVTTSubtitleTrack(id: 0, label: "en", language: "en")])
        XCTAssertEqual(asset.contentType, "text/vtt; charset=utf-8")
        XCTAssertEqual(try Data(contentsOf: asset.fileURL), expectedVTT)
        XCTAssertFalse((String(data: encoded, encoding: .utf8) ?? "").contains(directory.path))
        XCTAssertNil(try catalog.webVTTSubtitleTracks(id: "subtitle-item", for: denied))
        XCTAssertNil(try catalog.subtitleTrack(id: "subtitle-item", trackID: 0, for: denied))
        XCTAssertNil(try catalog.subtitleTrack(id: "subtitle-item", trackID: 16, for: principal))
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
        XCTAssertEqual(detail.browserContentType, "video/mp4")
        // HLS tiers are advertised only when the actual ffmpeg runtime exists.
        XCTAssertEqual(detail.canTranscode, ServerMediaToolchain.ffmpegURL() != nil)
        XCTAssertEqual(
            detail.playbackModes,
            ServerMediaToolchain.ffmpegURL() == nil
                ? [.directPlay]
                : [.directPlay, .directStream, .fullTranscode]
        )
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

    func testPeopleDirectoryAndCreditsStayWithinAuthorizedSources() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        try sources.save(MediaSource(id: "people-allowed", name: "人物允许", path: "/Volumes/PeopleAllowed", mediaType: .movie))
        try sources.save(MediaSource(id: "people-denied", name: "人物拒绝", path: "/Volumes/PeopleDenied", mediaType: .movie))
        try media.upsert(MediaItem(id: "people-visible", type: .tvShow, title: "可见系列", year: 2026, sourcePath: "/Volumes/PeopleAllowed"))
        try media.upsert(MediaItem(id: "people-hidden", type: .movie, title: "隐藏电影", sourcePath: "/Volumes/PeopleDenied"))
        try database.execute(
            "INSERT INTO media_people (id, name, profile_url, biography, known_for_department, updated_at) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [.text("person-visible"), .text("可见人物"), .text("https://tracker.example/profile.jpg"), .text("人物简介"), .text("演员"), .optionalDate(Date())]
        )
        try database.execute(
            "INSERT INTO media_people (id, name, updated_at) VALUES (?, ?, ?)",
            bindings: [.text("person-hidden"), .text("隐藏人物"), .optionalDate(Date())]
        )
        try database.execute(
            "INSERT INTO media_credits (id, media_id, person_id, category, role, sort_order) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [.text("credit-visible"), .text("people-visible"), .text("person-visible"), .text("cast"), .text("主角"), .int(0)]
        )
        try database.execute(
            "INSERT INTO media_credits (id, media_id, person_id, category, role, sort_order) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [.text("credit-hidden-person"), .text("people-hidden"), .text("person-hidden"), .text("cast"), .text("不应出现"), .int(0)]
        )
        try database.execute(
            "INSERT INTO media_credits (id, media_id, person_id, category, role, sort_order) VALUES (?, ?, ?, ?, ?, ?)",
            bindings: [.text("credit-hidden-work"), .text("people-hidden"), .text("person-visible"), .text("cast"), .text("不应出现"), .int(1)]
        )
        let grant = ServerLibraryGrant(userID: "people-member", libraryID: "people-allowed", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "people-member", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia],
            libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let people = try catalog.people(searchText: "可见", offset: 0, limit: 24, for: principal)
        let detail = try XCTUnwrap(catalog.personDetail(id: "person-visible", offset: 0, limit: 24, for: principal))
        let encoded = String(data: try JSONEncoder().encode(detail), encoding: .utf8) ?? ""

        XCTAssertEqual(people.items.map(\.id), ["person-visible"])
        XCTAssertEqual(detail.credits.items.map(\.id), ["people-visible"])
        XCTAssertTrue(detail.credits.items.first?.isSeries == true)
        XCTAssertEqual(detail.credits.items.first?.role, "主角")
        XCTAssertNil(try catalog.personDetail(id: "person-hidden", offset: 0, limit: 24, for: principal))
        XCTAssertFalse(encoded.contains("tracker.example"))
        XCTAssertFalse(encoded.contains("/Volumes/"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("profileURL"))
        XCTAssertFalse(encoded.contains("隐藏电影"))
    }

    func testManualCollectionsStayWithinAuthorizedSources() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        try sources.save(MediaSource(id: "collections-allowed", name: "合集允许", path: "/Volumes/CollectionsAllowed", mediaType: .movie))
        try sources.save(MediaSource(id: "collections-denied", name: "合集拒绝", path: "/Volumes/CollectionsDenied", mediaType: .movie))
        try media.upsert(MediaItem(id: "collection-visible", type: .tvShow, title: "可见系列", sourcePath: "/Volumes/CollectionsAllowed"))
        try media.upsert(MediaItem(id: "collection-hidden", type: .movie, title: "隐藏电影", sourcePath: "/Volumes/CollectionsDenied"))
        try database.execute(
            "INSERT INTO video_manual_collections (id, name, show_on_home, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [.text("mixed-collection"), .text("混合合集"), .bool(true), .optionalDate(Date()), .optionalDate(Date())]
        )
        try database.execute(
            "INSERT INTO video_manual_collections (id, name, show_on_home, created_at, updated_at) VALUES (?, ?, ?, ?, ?)",
            bindings: [.text("hidden-collection"), .text("隐藏合集"), .bool(false), .optionalDate(Date()), .optionalDate(Date())]
        )
        for (collectionID, mediaID, position) in [("mixed-collection", "collection-visible", 0), ("mixed-collection", "collection-hidden", 1), ("hidden-collection", "collection-hidden", 0)] {
            try database.execute(
                "INSERT INTO video_manual_collection_items (collection_id, media_id, position, added_at) VALUES (?, ?, ?, ?)",
                bindings: [.text(collectionID), .text(mediaID), .int(Int64(position)), .optionalDate(Date())]
            )
        }
        let grant = ServerLibraryGrant(userID: "collections-member", libraryID: "collections-allowed", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "collections-member", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia],
            libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let collections = try catalog.collections(offset: 0, limit: 24, for: principal)
        let detail = try XCTUnwrap(catalog.collectionDetail(id: "mixed-collection", offset: 0, limit: 24, for: principal))
        let encoded = String(data: try JSONEncoder().encode(detail), encoding: .utf8) ?? ""

        XCTAssertEqual(collections.items.map(\.id), ["mixed-collection"])
        XCTAssertEqual(collections.items.first?.mediaCount, 1)
        XCTAssertEqual(detail.items.items.map(\.id), ["collection-visible"])
        XCTAssertTrue(detail.items.items.first?.isSeries == true)
        XCTAssertNil(try catalog.collectionDetail(id: "hidden-collection", offset: 0, limit: 24, for: principal))
        XCTAssertFalse(encoded.contains("/Volumes/"))
        XCTAssertFalse(encoded.contains("隐藏电影"))
        XCTAssertFalse(encoded.contains("hidden-collection"))
    }

    /// 歌单里看不见的曲目，既不出现在列表里，也不许把数字撑大。
    ///
    /// 「计数从可见子集重新数」这一条最容易只抄一半：join 了授权表却仍从原表取
    /// count，于是一个"3 首"就告诉了别人这里面还有两首他没权限看的东西。
    func testMusicPlaylistsHideUnauthorizedTracksFromBothListAndCount() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        try sources.save(MediaSource(id: "music-allowed", name: "允许", path: "/Volumes/MusicAllowed", mediaType: .music))
        try sources.save(MediaSource(id: "music-denied", name: "拒绝", path: "/Volumes/MusicDenied", mediaType: .music))
        try sources.save(MediaSource(id: "music-vault", name: "保险库", path: "/Volumes/MusicVault", mediaType: .privateCollection))
        try media.upsert(MediaItem(id: "track-visible", type: .music, title: "可见曲目", sourcePath: "/Volumes/MusicAllowed"))
        try media.upsert(MediaItem(id: "track-denied", type: .music, title: "无权曲目", sourcePath: "/Volumes/MusicDenied"))
        try media.upsert(MediaItem(id: "track-vault", type: .music, title: "保险库曲目", sourcePath: "/Volumes/MusicVault"))
        try database.execute(
            "INSERT INTO music_playlists (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            bindings: [.text("mixed"), .text("混合歌单"), .optionalDate(Date()), .optionalDate(Date())]
        )
        try database.execute(
            "INSERT INTO music_playlists (id, name, created_at, updated_at) VALUES (?, ?, ?, ?)",
            bindings: [.text("invisible"), .text("全是无权曲目"), .optionalDate(Date()), .optionalDate(Date())]
        )
        for (playlist, track, position) in [
            ("mixed", "track-visible", 0), ("mixed", "track-denied", 1), ("mixed", "track-vault", 2),
            ("invisible", "track-denied", 0)
        ] {
            try database.execute(
                "INSERT INTO music_playlist_items (playlist_id, media_id, position, added_at) VALUES (?, ?, ?, ?)",
                bindings: [.text(playlist), .text(track), .int(Int64(position)), .optionalDate(Date())]
            )
        }
        let grant = ServerLibraryGrant(userID: "member", libraryID: "music-allowed", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia],
            libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        let playlists = try catalog.musicPlaylists(offset: 0, limit: 24, for: principal)
        XCTAssertEqual(playlists.items.map(\.id), ["mixed"], "一首可见曲目都没有的歌单不该出现")
        XCTAssertEqual(playlists.items.first?.trackCount, 1, "曲目数必须按可见子集重新数")

        let detail = try XCTUnwrap(catalog.musicPlaylistDetail(id: "mixed", offset: 0, limit: 24, for: principal))
        XCTAssertEqual(detail.items.items.map(\.id), ["track-visible"])
        XCTAssertEqual(detail.items.totalItemCount, 1)
        XCTAssertNil(try catalog.musicPlaylistDetail(id: "invisible", offset: 0, limit: 24, for: principal))

        let encoded = String(data: try JSONEncoder().encode(detail), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains("/Volumes/"))
        XCTAssertFalse(encoded.contains("保险库曲目"))
        XCTAssertFalse(encoded.contains("无权曲目"))
    }

    /// 智能集合按**请求者**的状态求值，而不是桌面机主的。
    ///
    /// 规则里有"已看/未看"这类条件。若直接拿 `media_items` 上机主的痕迹去算，
    /// 每个登录用户看到的成员和数量就都是机主的观看历史的投影。
    func testSmartCollectionsEvaluateAgainstTheRequestingUsersOwnState() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        let states = ServerUserMediaStateRepository(database: database)
        try sources.save(MediaSource(id: "smart-allowed", name: "允许", path: "/Volumes/SmartAllowed", mediaType: .movie))
        // 机主已经看完了这一部；请求者没有。
        try media.upsert(MediaItem(
            id: "owner-watched", type: .movie, title: "机主看过的电影",
            sourcePath: "/Volumes/SmartAllowed", playProgress: 1, watched: true
        ))
        _ = try VideoSmartCollectionRepository(database: database).save(
            VideoSmartCollection(id: "unwatched", name: "未看完", stateFilter: .unwatched)
        )
        // 逐用户播放状态表有指向 server_users 的外键，所以这个读者必须是真的存在
        // 的用户，而不是一个只在 principal 里出现过的字符串。
        _ = try ServerIdentityRepository(database: database).createUser(
            id: "viewer", username: "viewer", displayName: "读者"
        )
        let grant = ServerLibraryGrant(userID: "viewer", libraryID: "smart-allowed", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(
            userID: "viewer", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia],
            libraryGrants: [grant.libraryID: grant]
        )
        let catalog = ServerLibraryCatalog(database: database)

        // 请求者自己没看过，所以这部片对他来说属于"未看完"。
        let beforeWatching = try catalog.smartCollections(offset: 0, limit: 24, for: principal)
        XCTAssertEqual(beforeWatching.items.first?.mediaCount, 1, "机主看过不代表请求者看过")

        // 请求者自己看完之后，它才从这个集合里消失。
        _ = try states.update(
            userID: "viewer", mediaID: "owner-watched",
            event: .completed, position: 100, duration: 100
        )
        let afterWatching = try catalog.smartCollections(offset: 0, limit: 24, for: principal)
        XCTAssertTrue(afterWatching.items.isEmpty, "请求者看完后该集合对他就空了")
    }

    func testPhotoArtworkStaysWithinAuthorizedSourcesAndNeverReturnsPaths() throws {
        let sources = SourceRepository(database: database)
        let media = MediaRepository(database: database)
        let allowedDirectory = temporaryDirectory.appendingPathComponent("photo-allowed", isDirectory: true)
        let deniedDirectory = temporaryDirectory.appendingPathComponent("photo-denied", isDirectory: true)
        try FileManager.default.createDirectory(at: allowedDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: deniedDirectory, withIntermediateDirectories: true)
        let allowedPhoto = allowedDirectory.appendingPathComponent("sunset.jpg")
        let deniedPhoto = deniedDirectory.appendingPathComponent("private.jpg")
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: allowedPhoto)
        try Data([0xFF, 0xD8, 0xFF, 0xD9]).write(to: deniedPhoto)
        try sources.save(MediaSource(id: "photo-allowed", name: "照片允许", path: allowedDirectory.path, mediaType: .photo))
        try sources.save(MediaSource(id: "photo-denied", name: "照片拒绝", path: deniedDirectory.path, mediaType: .photo))
        try media.upsert(MediaItem(id: "photo-visible", type: .photo, title: "公开日落", posterPath: allowedPhoto.path, sourcePath: allowedDirectory.path, filePath: allowedPhoto.path))
        try media.upsert(MediaItem(id: "photo-hidden", type: .photo, title: "隐藏照片", posterPath: deniedPhoto.path, sourcePath: deniedDirectory.path, filePath: deniedPhoto.path))
        let grant = ServerLibraryGrant(userID: "photo-member", libraryID: "photo-allowed", canView: true, canPlay: true, canDownload: false)
        let principal = ServerRequestPrincipal(userID: "photo-member", deviceID: "device", sessionID: "session", permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant])
        let catalog = ServerLibraryCatalog(database: database)

        let page = try catalog.browse(ServerLibraryQuery(type: MediaType.photo.rawValue, offset: 0, limit: 24), for: principal)
        let artwork = try XCTUnwrap(catalog.publicArtwork(id: "photo-visible", kind: .poster, for: principal))
        let visibleDetail = try XCTUnwrap(catalog.publicDetail(id: "photo-visible", for: principal))

        XCTAssertEqual(page.items.map(\.id), ["photo-visible"])
        XCTAssertEqual(try Data(contentsOf: artwork.fileURL), Data([0xFF, 0xD8, 0xFF, 0xD9]))
        XCTAssertNil(try catalog.publicArtwork(id: "photo-hidden", kind: .poster, for: principal))
        XCTAssertNil(try catalog.publicDetail(id: "photo-hidden", for: principal))
        let encoded = String(data: try JSONEncoder().encode(visibleDetail), encoding: .utf8) ?? ""
        XCTAssertFalse(encoded.contains(allowedDirectory.path))
        XCTAssertFalse(encoded.contains("sourcePath"))
        XCTAssertFalse(encoded.contains("filePath"))
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
            ServerLibraryQuery(offset: 0, limit: 2, sort: .year),
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
            ServerLibraryQuery(limit: 10, sort: .lastPlayed, playbackFilter: .history),
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

    func testVideoGroupUsesServerSideTopLevelVideoOnlyFiltering() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "mixed", name: "混合媒体", path: "/Volumes/Mixed", mediaType: .movie))
        try mediaRepository.upsert(MediaItem(id: "movie", type: .movie, title: "电影", sourcePath: "/Volumes/Mixed"))
        try mediaRepository.upsert(MediaItem(id: "show", type: .tvShow, title: "剧集", sourcePath: "/Volumes/Mixed"))
        try mediaRepository.upsert(MediaItem(id: "song", type: .music, title: "歌曲", sourcePath: "/Volumes/Mixed"))
        try mediaRepository.upsert(MediaItem(id: "photo", type: .photo, title: "照片", sourcePath: "/Volumes/Mixed"))
        try mediaRepository.upsert(MediaItem(id: "episode", type: .episode, title: "第一集", sourcePath: "/Volumes/Mixed", parentID: "show"))

        let page = try ServerLibraryCatalog(database: database).browse(
            ServerLibraryQuery(limit: 24, mediaGroup: .video),
            for: .testAdministrator()
        )

        XCTAssertEqual(page.totalItemCount, 2)
        XCTAssertEqual(Set(page.items.map(\.id)), ["movie", "show"])
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

    // MARK: - 远程来源授权

    /// 远程连接器只为整台服务器建一行 `MediaSource`（`emby://host/<id>`），条目却写
    /// 逐资料库子路径。授权连接原本是精确相等，于是 Emby/Jellyfin/Plex 的内容在网页端
    /// 一条也进不来——侧栏分类为空、资料库为空、播放入口无从谈起。
    func testRemoteLibraryItemsUnderSourceRootAreAuthorized() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(
            id: "emby-1", name: "Emby 服务器", path: "emby://nas.local/emby-1", mediaType: .auto
        ))
        try mediaRepository.upsert(MediaItem(
            id: "emby-movie",
            type: .movie,
            title: "远程电影",
            sourcePath: "emby://nas.local/emby-1/library/9f3a/type/movies/name/%E7%94%B5%E5%BD%B1",
            filePath: "https://nas.local/Videos/42/stream.mp4?api_key=token"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let categories = try catalog.categories(for: .testAdministrator())
        let groups = try catalog.remoteSourceGroups(for: .testAdministrator())

        // 一级分类只含本地来源，因此这里没有"电影"分类。
        XCTAssertNil(categories.categories.first(where: { $0.id == "movie" }))
        // 但条目确实已被授权：它出现在自己的来源分组里，并可经作用域浏览到。
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.itemCount, 1)
        let scoped = try catalog.browse(
            ServerLibraryQuery(type: "movie", remoteScopeID: group.id), for: .testAdministrator()
        )
        XCTAssertEqual(scoped.items.map(\.id), ["emby-movie"])
        XCTAssertTrue(scoped.items.first?.isRemoteSource == true)
        XCTAssertNotNil(try catalog.publicDetail(id: "emby-movie", for: .testAdministrator()))
    }

    /// 角标必须标出真实来源类型。旧实现把"有远程可播放地址"一律标成 Mlink，
    /// 而 Mlink 条目恰恰没有媒体 URL——于是 Emby 顶着 Mlink 的名字，真 Mlink 反而没标。
    func testRemoteSourceKindReflectsActualProviderIncludingMlinkWithoutMediaURL() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "Emby", path: "emby://nas/emby-1"))
        try sourceRepository.save(MediaSource(id: "plex-1", name: "Plex", path: "plex://nas/plex-1"))
        try sourceRepository.save(MediaSource(id: "mlink-1", name: "Mlink", path: "mlink://mlink-1"))
        try sourceRepository.save(MediaSource(id: "local", name: "本地", path: "/Volumes/M", mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "e", type: .movie, title: "E", sourcePath: "emby://nas/emby-1/library/a",
            filePath: "https://nas/e.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "p", type: .movie, title: "P", sourcePath: "plex://nas/plex-1/library/a",
            filePath: "https://nas/p.mp4"
        ))
        // Mlink 条目故意没有 filePath：这正是旧实现漏标它的原因。
        try mediaRepository.upsert(MediaItem(
            id: "m", type: .movie, title: "M", sourcePath: "mlink://mlink-1/item/x"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "l", type: .movie, title: "L", sourcePath: "/Volumes/M", filePath: "/Volumes/M/l.mp4"
        ))

        // 角标要在「首页看板 + 每个远程分组的浏览结果」的并集上验证。首页看板现在
        // 也含远程条目，同一条目会在两处各出现一次，所以这里按 id 去重而不是
        // 用会在重复键上崩溃的 `uniqueKeysWithValues`。
        let catalog = ServerLibraryCatalog(database: database)
        var items = try catalog.snapshot(for: .testAdministrator()).items.items
        for group in try catalog.remoteSourceGroups(for: .testAdministrator()) {
            items += try catalog.browse(
                ServerLibraryQuery(offset: 0, limit: 24, remoteScopeID: group.id),
                for: .testAdministrator()
            ).items
        }
        let kindByID = Dictionary(items.map { ($0.id, $0.remoteSourceKind) }, uniquingKeysWith: { first, _ in first })

        XCTAssertEqual(kindByID["e"], .emby)
        XCTAssertEqual(kindByID["p"], .plex)
        XCTAssertEqual(kindByID["m"], .mlink, "Mlink 条目没有媒体 URL，但仍应标注来源")
        XCTAssertEqual(kindByID["l"], ServerRemoteSourceKind?.none, "本地条目不应有来源角标")
    }

    /// 一级分类严格按客户端：电影/剧集/音乐等只含本地来源，远程内容不混入。
    func testTopLevelCategoriesExcludeRemoteSourcesAndGroupThemSeparately() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "local", name: "本地电影", path: "/Volumes/M", mediaType: .movie))
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "local-movie", type: .movie, title: "本地电影",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-movie", type: .movie, title: "远程电影",
            sourcePath: "emby://nas/emby-1/library/v1/type/movies/name/%E7%94%B5%E5%BD%B1",
            filePath: "https://nas/a.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-song", type: .music, title: "远程歌曲",
            sourcePath: "emby://nas/emby-1/library/v2/type/music/name/%E9%9F%B3%E4%B9%90",
            filePath: "https://nas/b.mp3"
        ))
        let catalog = ServerLibraryCatalog(database: database)
        let principal = ServerRequestPrincipal.testAdministrator()

        // 一级分类只数本地。
        let categories = try catalog.categories(for: principal)
        XCTAssertEqual(categories.categories.first(where: { $0.id == "movie" })?.itemCount, 1)
        XCTAssertNil(categories.categories.first(where: { $0.id == "music" }), "远程音乐不得撑出一级音乐分类")

        // 默认浏览只给本地。
        let browsed = try catalog.browse(ServerLibraryQuery(type: "movie"), for: principal)
        XCTAssertEqual(browsed.items.map(\.id), ["local-movie"])

        // 音乐页只给本地音乐（本例本地无音乐）。
        XCTAssertTrue(try catalog.musicItems(for: principal).isEmpty)

        // 远程内容出现在自己的来源分组里。
        let groups = try catalog.remoteSourceGroups(for: principal)
        XCTAssertEqual(groups.count, 1)
        let group = try XCTUnwrap(groups.first)
        XCTAssertEqual(group.title, "客厅 Emby")
        XCTAssertEqual(group.kind, .emby)
        XCTAssertEqual(group.itemCount, 2)
        // 音乐类资料库不单独成行，与客户端一致。
        XCTAssertEqual(group.libraries.map(\.title), ["电影"])

        // 带作用域浏览时才看得到远程条目。
        let scoped = try catalog.browse(
            ServerLibraryQuery(type: "movie", remoteScopeID: group.id), for: principal
        )
        XCTAssertEqual(scoped.items.map(\.id), ["remote-movie"])

        // 未知作用域失败即关闭。
        let bogus = try catalog.browse(
            ServerLibraryQuery(type: "movie", remoteScopeID: "deadbeefdeadbeef"), for: principal
        )
        XCTAssertTrue(bogus.items.isEmpty)
    }

    /// 同一台远程服务器不得因为路径写法差异裂成多个分组。
    ///
    /// 库里同一台服务器可能以 `emby://host/x`、`EMBY://Host/x`、`emby://host/x/`
    /// 等写法出现（来源注册、同步与迁移各写各的）。按原始字符串分组时它会在侧栏
    /// 裂成几个同名分组，看上去就是"目录不稳定"。
    func testRemoteGroupsAreStableAcrossPathCaseAndTrailingSlash() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        try sourceRepository.save(MediaSource(id: "plex-1", name: "书房 Plex", path: "plex://nas/plex-1/"))
        for (id, path) in [
            ("a", "emby://nas/emby-1/library/v1"),
            ("b", "EMBY://nas/emby-1/library/v2"),
            ("c", "emby://nas/emby-1/"),
            ("d", "plex://nas/plex-1/library/v9"),
            ("e", "Plex://NAS/plex-1/library/v8")
        ] {
            try mediaRepository.upsert(MediaItem(
                id: id, type: .movie, title: id, sourcePath: path, filePath: "https://nas/\(id).mp4"
            ))
        }

        let groups = try ServerLibraryCatalog(database: database)
            .remoteSourceGroups(for: .testAdministrator())

        XCTAssertEqual(groups.count, 2, "同一台服务器只能有一个分组")
        // 顺序由本地化排序决定，不是本用例要锁的行为，因此按集合比较。
        XCTAssertEqual(Set(groups.map(\.title)), ["客厅 Emby", "书房 Plex"])
        XCTAssertEqual(groups.first { $0.title == "客厅 Emby" }?.itemCount, 3)
        XCTAssertEqual(groups.first { $0.title == "书房 Plex" }?.itemCount, 2)
    }

    /// 明确来自在线媒体服务器的条目，即使 `source_path` 写成本地路径也不得进入
    /// 一级分类。仓库里连接器自己的注释就写着"有些条目不一定填了 emby:// 的
    /// sourcePath"，所以只靠路径判断并不稳。
    func testOnlineSourceItemsNeverEnterLocalCategoriesEvenWithLocalSourcePath() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "local", name: "本地", path: "/Volumes/M", mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "local-movie", type: .movie, title: "本地电影",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mp4"
        ))
        // 元数据提供方是 Emby 且文件是 http 流：本地条目不会同时满足这两项。
        try mediaRepository.upsert(MediaItem(
            id: "stray-emby", type: .movie, title: "错位的远程条目",
            sourcePath: "/Volumes/M", filePath: "https://nas/stray.mp4",
            metadataProvider: "Emby"
        ))
        // 只有 http 流、没有提供方的，是用户自己加的 URL 视频源——客户端把它算本地，
        // 不能被一起误伤。
        try mediaRepository.upsert(MediaItem(
            id: "url-video", type: .movie, title: "URL 视频",
            sourcePath: "/Volumes/M", filePath: "https://example/clip.mp4"
        ))
        // 用 Emby 刮削元数据的本地文件同样不能被误伤。
        try mediaRepository.upsert(MediaItem(
            id: "scraped-local", type: .movie, title: "本地但用 Emby 刮削",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/b.mp4",
            metadataProvider: "Emby"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let principal = ServerRequestPrincipal.testAdministrator()
        let browsed = try catalog.browse(ServerLibraryQuery(type: "movie", limit: 100), for: principal)
        let categories = try catalog.categories(for: principal)

        XCTAssertEqual(browsed.items.map(\.id).sorted(), ["local-movie", "scraped-local", "url-video"])
        XCTAssertEqual(categories.categories.first { $0.id == "movie" }?.itemCount, 3)
    }

    /// 相邻来源不得互相越权：`emby://h/src` 授权的是它自己的子树，不是 `src2`。
    func testAdjacentRemoteSourceIsNotAuthorizedByPrefix() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(
            id: "emby-1", name: "已授权", path: "emby://nas.local/src", mediaType: .auto
        ))
        try mediaRepository.upsert(MediaItem(
            id: "granted", type: .movie, title: "已授权条目",
            sourcePath: "emby://nas.local/src/library/a", filePath: "https://nas.local/a.mp4"
        ))
        // 未登记为来源，且名字只比授权根多了一个字符。
        try mediaRepository.upsert(MediaItem(
            id: "adjacent", type: .movie, title: "相邻来源条目",
            sourcePath: "emby://nas.local/src2/library/a", filePath: "https://nas.local/b.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "suffix", type: .movie, title: "同前缀无边界",
            sourcePath: "emby://nas.local/srcX", filePath: "https://nas.local/c.mp4"
        ))

        // 首页看板现在也覆盖远程来源，所以这条边界在两处都看得见：作用域浏览
        // 和首页快照都必须只有 `granted`，相邻来源与同前缀来源一个都不许进来。
        let catalog = ServerLibraryCatalog(database: database)
        let group = try XCTUnwrap(catalog.remoteSourceGroups(for: .testAdministrator()).first)
        let scoped = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 24, remoteScopeID: group.id), for: .testAdministrator()
        )

        XCTAssertEqual(try catalog.snapshot(for: .testAdministrator()).items.items.map(\.id), ["granted"])
        XCTAssertEqual(scoped.items.map(\.id), ["granted"])
    }

    /// 保险库来源嵌套在公开来源之下时，绝不能因为路径前缀而被公开来源授权。
    /// 这是"按最长匹配归属"存在的唯一理由。
    func testPrivateSourceNestedUnderPublicSourceStaysHidden() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(
            id: "public", name: "公开", path: "/Volumes/Media", mediaType: .movie
        ))
        try sourceRepository.save(MediaSource(
            id: "vault", name: "保险库", path: "/Volumes/Media/Vault", mediaType: .privateCollection
        ))
        try mediaRepository.upsert(MediaItem(
            id: "public-item", type: .movie, title: "公开条目",
            sourcePath: "/Volumes/Media", filePath: "/Volumes/Media/a.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "vault-item", type: .movie, title: "不应泄露",
            sourcePath: "/Volumes/Media/Vault", filePath: "/Volumes/Media/Vault/b.mp4"
        ))

        let snapshot = try ServerLibraryCatalog(database: database).snapshot(for: .testAdministrator())

        XCTAssertEqual(snapshot.items.items.map(\.id), ["public-item"])
    }

    /// 远程条目的详情页要和本地条目一样：主创有头像，艺术照有图。
    ///
    /// 这些资料一直都在数据库里（客户端会从 Emby/Jellyfin/Plex 拉详情扩展并落库），
    /// 卡在授权层：图片地址来自那台媒体服务器，而详情图此前只认 TMDB 的图片 CDN
    /// 加图片扩展名。于是同一部片子，本地的有演员表和剧照，Emby 的两样都没有。
    func testRemoteItemDetailExposesCastPortraitsAndArtworkLikeALocalOne() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let detailRepository = MediaDetailRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas.local/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "remote-movie", type: .movie, title: "远程电影",
            sourcePath: "emby://nas.local/emby-1/library/a",
            filePath: "https://nas.local/stream/remote.mp4",
            metadataProvider: "Emby"
        ))
        let actor = MediaPerson(
            id: "emby-person-1", name: "某演员",
            // 媒体服务器给的头像地址：没有扩展名，主机也不是 TMDB。
            profileURL: "https://nas.local/emby/Items/9/Images/Primary?tag=abc",
            knownForDepartment: "Acting"
        )
        try detailRepository.save(MediaDetailSnapshot(
            metadata: MediaDetailMetadata(
                mediaID: "remote-movie",
                status: "Released",
                contentRating: "PG-13",
                countries: ["美国"],
                productionCompanies: ["某制片厂"],
                provider: "Emby",
                language: "zh-CN"
            ),
            externalIDs: [],
            people: [actor],
            credits: [MediaCredit(
                id: "credit-1", mediaID: "remote-movie", personID: "emby-person-1",
                category: "cast", role: "主角", department: "Acting", order: 0
            )],
            artwork: [MediaArtwork(
                id: "art-1", mediaID: "remote-movie", kind: "backdrop",
                thumbURL: "https://nas.local/emby/Items/9/Images/Backdrop/0?maxWidth=500",
                fullURL: "https://nas.local/emby/Items/9/Images/Backdrop/0?maxWidth=1280",
                aspectRatio: 1.78, order: 0
            )],
            relatedTitles: []
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let detail = try XCTUnwrap(catalog.publicDetail(id: "remote-movie", for: .testAdministrator()))
        let extras = try XCTUnwrap(detail.detailExtras)

        // 主创：有名字，也有一个能取到图的头像序号。
        XCTAssertEqual(extras.cast.map(\.name), ["某演员"])
        XCTAssertEqual(extras.cast.first?.portraitIndex, 0, "远程条目的演员头像不该被授权层丢掉")
        XCTAssertEqual(extras.artwork.count, 1, "远程条目的艺术照不该被授权层丢掉")
        // 制作信息同样来自媒体服务器，不再要求必须配 TMDB key。
        XCTAssertEqual(extras.status, "Released")
        XCTAssertEqual(extras.contentRating, "PG-13")
        XCTAssertEqual(extras.countries, ["美国"])
        XCTAssertEqual(extras.productionCompanies, ["某制片厂"])

        // 序号真的能换到一张受权代理的图，而且地址指向那台媒体服务器本身。
        let portrait = try XCTUnwrap(catalog.detailImageAsset(
            itemID: "remote-movie", kind: .portrait, index: 0, for: .testAdministrator()
        ))
        let still = try XCTUnwrap(catalog.detailImageAsset(
            itemID: "remote-movie", kind: .still, index: 0, for: .testAdministrator()
        ))
        XCTAssertEqual(portrait.remoteURL?.host, "nas.local")
        XCTAssertEqual(still.remoteURL?.host, "nas.local")
        // 上游地址一个字节都不进网页：给浏览器的只有条目 ID 和序号。
        XCTAssertFalse(String(describing: extras).contains("nas.local"))
    }

    /// 首页看板跨来源，一级分类不跨——两件事共用一份数据时就会互相打架。
    func testHomeBoardSpansRemoteSourcesWhileCategoriesStayLocal() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "local", name: "本地", path: "/Volumes/M", mediaType: .movie))
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas.local/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "local-movie", type: .movie, title: "本地电影",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mkv"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-movie", type: .movie, title: "远程电影",
            sourcePath: "emby://nas.local/emby-1/library/a",
            filePath: "https://nas.local/a.mp4", metadataProvider: "Emby"
        ))
        // 远程音乐不进首页：音乐栏目讲的是本地曲库，与 `/music/*` 同口径。
        try mediaRepository.upsert(MediaItem(
            id: "remote-song", type: .music, title: "远程歌曲",
            sourcePath: "emby://nas.local/emby-1/library/b",
            filePath: "https://nas.local/b.mp3", metadataProvider: "Emby"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let snapshot = try catalog.snapshot(for: .testAdministrator())
        let categories = try catalog.categories(for: .testAdministrator()).categories

        XCTAssertEqual(Set(snapshot.items.items.map(\.id)), ["local-movie", "remote-movie"])
        XCTAssertEqual(snapshot.summary.countsByType["movie"], 2)
        XCTAssertNil(snapshot.summary.countsByType["music"], "远程音乐不进首页，也不计进音乐那一格")
        XCTAssertEqual(categories.first(where: { $0.id == "movie" })?.itemCount, 1, "一级分类只数本地")
        XCTAssertNil(categories.first(where: { $0.id == "music" }), "远程音乐不会凭空造出一个本地分类")

        // 首页那两栏（最近添加／高分精选）与看板同口径，否则同一页上"继续观看"
        // 有 Emby 的片子、"最近添加"里一部都没有。
        let recentlyAdded = try catalog.browse(
            ServerLibraryQuery(limit: 12, sort: .dateAdded, mediaGroup: .video, includesRemoteSources: true),
            for: .testAdministrator()
        )
        XCTAssertEqual(Set(recentlyAdded.items.map(\.id)), ["local-movie", "remote-movie"])
        // 而普通浏览（一级分类页走的那条）仍然只有本地。
        let localBrowse = try catalog.browse(
            ServerLibraryQuery(limit: 12, sort: .dateAdded, mediaGroup: .video), for: .testAdministrator()
        )
        XCTAssertEqual(localBrowse.items.map(\.id), ["local-movie"])
    }

    // MARK: - 保险库

    private func vaultFixture() throws -> (vaultItemID: String, publicItemID: String) {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "public", name: "公开", path: "/Volumes/M", mediaType: .movie))
        try sourceRepository.save(MediaSource(id: "vault", name: "保险库", path: "/Volumes/V", mediaType: .privateCollection))
        try mediaRepository.upsert(MediaItem(
            id: "public-movie", type: .movie, title: "公开影片",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mkv"
        ))
        // 保险库的顶层条目自己就是 `privateCollection` 类型的容器，与客户端的
        // `privateTopLevelItems` 是同一批东西。
        try mediaRepository.upsert(MediaItem(
            id: "vault-item", type: .privateCollection, title: "私密内容",
            sourcePath: "/Volumes/V", filePath: "/Volumes/V/secret.mkv"
        ))
        return ("vault-item", "public-movie")
    }

    private func vaultMember(granted: Bool) -> ServerRequestPrincipal {
        let grant = ServerLibraryGrant(
            userID: "member", libraryID: granted ? "vault" : "public",
            canView: true, canPlay: true, canDownload: false
        )
        return ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia],
            libraryGrants: [grant.libraryID: grant]
        )
    }

    /// 解锁状态由这台机器上的 App 发布。服务端读不到它时**一律按锁定处理**，
    /// 这条链路的每一环都必须失败即锁定。
    func testVaultStaysInvisibleWhileTheDesktopAppIsLocked() throws {
        _ = try vaultFixture()
        let catalog = ServerLibraryCatalog(database: database)  // 默认锁定
        let member = vaultMember(granted: true)

        XCTAssertEqual(try catalog.vaultAccess(for: member), .locked)
        XCTAssertEqual(
            try catalog.browse(ServerLibraryQuery(limit: 24, vaultScope: true), for: member).items.map(\.id),
            [],
            "锁定时保险库作用域必须是空页，而不是退回公开来源"
        )
        XCTAssertNil(
            try catalog.publicAsset(id: "vault-item", for: member),
            "锁定时拿着 id 也打不开保险库条目"
        )
        // 管理员同样打不开：解锁是这台机器的物理动作，不是一种权限。
        XCTAssertEqual(try catalog.vaultAccess(for: .testAdministrator()), .locked)
        XCTAssertNil(try catalog.publicAsset(id: "vault-item", for: .testAdministrator()))
    }

    /// 解锁 + 已授权时，保险库就是一个普通的资料库页面；而它的内容**仍然**不会
    /// 出现在首页、一级分类或搜索里——保险库在客户端也是它自己的一个入口。
    func testUnlockedVaultIsBrowsableButNeverLeaksIntoTheOrdinaryLibrary() throws {
        _ = try vaultFixture()
        let catalog = ServerLibraryCatalog(database: database, vaultUnlockProvider: { true })
        let member = vaultMember(granted: true)

        XCTAssertEqual(try catalog.vaultAccess(for: member), .unlocked)
        XCTAssertEqual(
            try catalog.browse(ServerLibraryQuery(limit: 24, vaultScope: true), for: member).items.map(\.id),
            ["vault-item"]
        )
        XCTAssertNotNil(try catalog.publicDetail(id: "vault-item", for: member))

        // 三条公开通路一条都不能带出它。
        XCTAssertFalse(
            try catalog.snapshot(for: member).items.items.contains { $0.id == "vault-item" },
            "首页看板不含保险库"
        )
        XCTAssertFalse(
            try catalog.browse(ServerLibraryQuery(limit: 24), for: member).items.contains { $0.id == "vault-item" },
            "一级分类不含保险库"
        )
        XCTAssertFalse(
            try catalog.browse(ServerLibraryQuery(searchText: "私密", limit: 24), for: member)
                .items.contains { $0.id == "vault-item" },
            "搜索不含保险库"
        )
        XCTAssertNil(
            try catalog.categories(for: member).categories.first { $0.id == MediaType.privateCollection.rawValue },
            "保险库不会变成一个一级分类"
        )
    }

    /// 解锁是这台机器的状态，授权是逐账号的。两者是不同的"进不去"，措辞也不同
    /// ——否则读者会一直去解锁一个已经解锁的保险库。
    func testVaultRequiresAnExplicitGrantEvenWhileUnlocked() throws {
        _ = try vaultFixture()
        let catalog = ServerLibraryCatalog(database: database, vaultUnlockProvider: { true })
        let stranger = vaultMember(granted: false)

        XCTAssertEqual(try catalog.vaultAccess(for: stranger), .notGranted)
        XCTAssertEqual(
            try catalog.browse(ServerLibraryQuery(limit: 24, vaultScope: true), for: stranger).items.map(\.id),
            []
        )
        XCTAssertNil(try catalog.publicAsset(id: "vault-item", for: stranger))
        // 公开内容照旧。
        XCTAssertNotNil(try catalog.publicDetail(id: "public-movie", for: stranger))
    }
}
