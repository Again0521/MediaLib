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
        XCTAssertTrue(detail.canTranscode)
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
        XCTAssertNil(try catalog.publicDetail(id: "state-item", for: principalB)?.userState)
        XCTAssertNil(try catalog.updatePlaybackState(id: "state-item", request: request, for: denied))
        XCTAssertNil(try catalog.publicDetail(id: "missing", for: principalA))
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
        _ = try ServerUserMediaStateRepository(database: database).update(
            userID: ServerIdentityRepository.initialAdministratorUserID,
            mediaID: "movie-3", event: .progress, position: 30, duration: 100
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

        XCTAssertEqual(categories.categories.first(where: { $0.id == "movie" })?.itemCount, 5)
        XCTAssertEqual(categories.categories.first(where: { $0.id == "episode" })?.itemCount, 1)
        XCTAssertEqual(firstPage.totalItemCount, 5)
        XCTAssertEqual(firstPage.items.map(\.year), [2024, 2023])
        XCTAssertTrue(firstPage.hasMore)
        XCTAssertEqual(search.items.map(\.id), ["movie-3"])
        XCTAssertEqual(search.items.first?.userState?.progress ?? -1, 0.3, accuracy: 0.0001)
        XCTAssertEqual(episodes.items.map(\.id), ["episode-1"])
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
