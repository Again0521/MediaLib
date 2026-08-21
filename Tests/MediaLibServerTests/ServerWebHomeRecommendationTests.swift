import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

/// 网页首页的推荐栏目：**顺序来自客户端，可见性与痕迹来自请求者自己**。
///
/// 这两半必须同时成立才算对。只要第一半，网页会把机主看得到的东西摆给每一个登录
/// 用户；只要第二半，同一个资料库在 App 与网页上就是两份片单——这正是从前的状态。
final class ServerWebHomeRecommendationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerWebHomeRecommendationTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("home.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    private func seedLibrary() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "open", name: "公开", path: "/Volumes/Open", mediaType: .tvShow))
        try sourceRepository.save(MediaSource(id: "closed", name: "未授权", path: "/Volumes/Closed", mediaType: .tvShow))
        try sourceRepository.save(MediaSource(id: "vault", name: "保险库", path: "/Volumes/Vault", mediaType: .privateCollection))
        for identifier in ["series-a", "series-b", "series-c"] {
            try mediaRepository.upsert(MediaItem(
                id: identifier, type: .tvShow, title: "剧集 \(identifier)",
                sourcePath: "/Volumes/Open", filePath: "/Volumes/Open/\(identifier).mp4"
            ))
        }
        try mediaRepository.upsert(MediaItem(
            id: "closed-series", type: .tvShow, title: "未授权剧集",
            sourcePath: "/Volumes/Closed", filePath: "/Volumes/Closed/x.mp4"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "vault-item", type: .privateCollection, title: "保险库条目",
            sourcePath: "/Volumes/Vault", filePath: "/Volumes/Vault/x.mp4"
        ))
    }

    private func catalog(publishing entries: [HomeRecommendationSnapshot.Entry]) -> ServerLibraryCatalog {
        let snapshot = HomeRecommendationSnapshot(
            generatedAt: Date(),
            expiresAt: Date().addingTimeInterval(3_600),
            entries: entries
        )
        return ServerLibraryCatalog(
            database: database,
            homeRecommendationProvider: { snapshot }
        )
    }

    /// 客户端给的是**顺序**。数据库返回的顺序没有意义，重排就等于把客户端算的那份
    /// 推荐扔掉、换成"随便什么顺序"。
    func testClientOrderIsPreserved() throws {
        try seedLibrary()
        let catalog = catalog(publishing: [
            .init(section: .seriesRecommendation, itemIDs: ["series-c", "series-a", "series-b"]),
            .init(section: .banner, itemIDs: ["series-b"])
        ])

        let recommendations = try catalog.homeRecommendations(for: .testAdministrator())

        XCTAssertEqual(recommendations.series.map(\.id), ["series-c", "series-a", "series-b"])
        XCTAssertEqual(recommendations.banner.map(\.id), ["series-b"])
        XCTAssertEqual(recommendations.highRated, [], "没发布的栏目为空，首页据此回落")
        XCTAssertNotNil(recommendations.generatedAt)
    }

    /// 名单不是可见性凭证。机主的首页当然看得见未授权资料库与保险库里的东西——
    /// 但那份名单落到网页上时，仍要逐条过这个账号自己的授权。
    func testUnauthorizedAndVaultIdentifiersAreDroppedNotRendered() throws {
        try seedLibrary()
        let grant = ServerLibraryGrant(
            userID: "member", libraryID: "open", canView: true, canPlay: true, canDownload: false
        )
        let member = ServerRequestPrincipal(
            userID: "member", deviceID: "device", sessionID: "session",
            permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant]
        )
        let catalog = catalog(publishing: [
            .init(
                section: .seriesRecommendation,
                itemIDs: ["closed-series", "series-a", "vault-item", "does-not-exist"]
            )
        ])

        let recommendations = try catalog.homeRecommendations(for: member)

        XCTAssertEqual(recommendations.series.map(\.id), ["series-a"])
    }

    /// 痕迹是逐用户的，与名单无关：同一份推荐，两个人看到的是各自的进度。
    func testTracesComeFromTheRequestingUserNotTheDesktopOwner() throws {
        try seedLibrary()
        // 机主在桌面上把 series-a 看完并收藏了——这些列就写在 `media_items` 上。
        let mediaRepository = MediaRepository(database: database)
        var owned = try XCTUnwrap(mediaRepository.fetchAll().first { $0.id == "series-a" })
        owned.watched = true
        owned.favorite = true
        owned.playProgress = 1
        owned.playCount = 9
        try mediaRepository.upsert(owned)

        // 逐用户痕迹表对 `server_users` 有外键：先有账号，才谈得上"他的"痕迹。
        let identities = ServerIdentityRepository(database: database)
        _ = try identities.createUser(id: "viewer-one", username: "one", displayName: "读者一")
        _ = try identities.createUser(id: "viewer-two", username: "two", displayName: "读者二")
        let stateRepository = ServerUserMediaStateRepository(database: database)
        try stateRepository.update(
            userID: "viewer-one", mediaID: "series-a", event: .progress, position: 30, duration: 100
        )
        let catalog = catalog(publishing: [.init(section: .seriesRecommendation, itemIDs: ["series-a"])])

        func principal(_ userID: String) -> ServerRequestPrincipal {
            let grant = ServerLibraryGrant(
                userID: userID, libraryID: "open", canView: true, canPlay: true, canDownload: false
            )
            return ServerRequestPrincipal(
                userID: userID, deviceID: "device", sessionID: "session-\(userID)",
                permissions: [.viewMedia, .playMedia], libraryGrants: [grant.libraryID: grant]
            )
        }
        let one = try XCTUnwrap(catalog.homeRecommendations(for: principal("viewer-one")).series.first)
        let two = try XCTUnwrap(catalog.homeRecommendations(for: principal("viewer-two")).series.first)

        XCTAssertEqual(one.userState?.progress, 0.3)
        XCTAssertEqual(one.userState?.isWatched, false)
        XCTAssertNil(two.userState, "另一个账号没有自己的痕迹，就该什么都没有")
        // 机主的 watched / favorite / playCount 一个都不能渗过来。
        XCTAssertEqual(two.userPreference, .empty)
        XCTAssertNotEqual(one.userState?.playCount, 9)
    }

    /// App 写文件 → 服务进程读文件，这条通路本身。
    ///
    /// 前面几条用的都是注入的名单，验的是取材逻辑；这一条验的是两个进程之间真正
    /// 的那一跳：同一个目录、同一个文件名、同一套编解码。目录或文件名对不上时，
    /// 前面每一条仍然全绿，而网页首页会永远停在"服务端自己算"的那份。
    func testListWrittenByTheAppIsReadBackByTheServerProcess() throws {
        try seedLibrary()
        // 客户端那一侧（`AppState.publishHomeRecommendations`）写的就是这一句。
        let published = HomeRecommendationSnapshotStore(directory: temporaryDirectory)
        XCTAssertTrue(published.publish(entries: [
            .init(section: .seriesRecommendation, itemIDs: ["series-b", "series-a"])
        ]))

        // 服务进程那一侧（`MediaLibServerEntry`）读的就是这一句。
        let store = HomeRecommendationSnapshotStore(directory: temporaryDirectory)
        let catalog = ServerLibraryCatalog(
            database: database,
            homeRecommendationProvider: { store.current() }
        )

        let recommendations = try catalog.homeRecommendations(for: .testAdministrator())
        XCTAssertEqual(recommendations.series.map(\.id), ["series-b", "series-a"])

        // App 退出/名单过期之后不该留下一份永远陈旧的片单。
        published.clear()
        XCTAssertTrue(try catalog.homeRecommendations(for: .testAdministrator()).isEmpty)
    }

    /// 没有客户端（Docker 部署、App 没运行、名单过期）时，首页仍然要有内容。
    func testNoPublishedListMeansServerDerivedHome() throws {
        try seedLibrary()

        let recommendations = try ServerLibraryCatalog(database: database)
            .homeRecommendations(for: .testAdministrator())

        XCTAssertTrue(recommendations.isEmpty)
        XCTAssertNil(recommendations.generatedAt)
    }

    /// 没有 `viewMedia` 的会话拿不到名单——授权检查在读文件之后、查条目之前那一道
    /// 不够，它必须是第一道。
    func testPrincipalWithoutViewPermissionGetsNothing() throws {
        try seedLibrary()
        let catalog = catalog(publishing: [.init(section: .seriesRecommendation, itemIDs: ["series-a"])])
        let principal = ServerRequestPrincipal(
            userID: "no-view", deviceID: "device", sessionID: "session",
            permissions: [], libraryGrants: [:]
        )

        XCTAssertTrue(try catalog.homeRecommendations(for: principal).isEmpty)
    }

    /// 首页那条路由：名单在的时候，排序查询根本不该发出去。
    ///
    /// "避免重复计算"不是一句注释里的愿望——它要么能在这里数出来，要么就没发生。
    func testHomeRouteSkipsSortQueriesWhenTheClientListIsPresent() throws {
        final class Counter: @unchecked Sendable {
            private let lock = NSLock()
            private(set) var value = 0
            func increment() {
                lock.lock()
                defer { lock.unlock() }
                value += 1
            }
        }
        let browseCalls = Counter()
        let clientItem = ServerLibraryItem(
            id: "client-series", type: "tvShow", title: "客户端推荐剧集", year: nil,
            artworkAvailable: false, isSeries: true
        )
        func router(recommendations: ServerHomeRecommendations) -> LocalHTTPRouter {
            LocalHTTPRouter(
                serverID: "server-001",
                serverName: "客厅服务器",
                librarySnapshotProvider: { _ in
                    ServerLibrarySnapshot(
                        summary: ServerLibrarySummary(totalItemCount: 0, countsByType: [:]),
                        items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
                    )
                },
                libraryBrowseProvider: { query, _ in
                    browseCalls.increment()
                    return ServerLibraryItemsPage(
                        totalItemCount: 0, offset: query.offset, limit: query.limit, items: []
                    )
                },
                homeRecommendationsProvider: { _ in recommendations },
                authenticationProvider: { _ in .testAdministrator() }
            )
        }

        let withoutList = router(recommendations: .empty)
            .response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(withoutList.statusCode, 200)
        XCTAssertEqual(browseCalls.value, 2, "没有名单时仍要各查一次「最近添加」和「高分精选」")

        let withList = router(
            recommendations: ServerHomeRecommendations(recentSeries: [clientItem], highRated: [clientItem])
        ).response(for: "GET / HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(withList.statusCode, 200)
        XCTAssertEqual(browseCalls.value, 2, "名单在时那两次全库排序查询不该再发出去")
        XCTAssertTrue(
            String(decoding: withList.body, as: UTF8.self).contains("客户端推荐剧集"),
            "省掉查询不能以少画一栏为代价"
        )
    }

    /// 首页渲染：有名单就按名单，没有就回落。两条路径都要真的画出内容来。
    func testHomePagePrefersClientListAndFallsBackWithoutIt() {
        let snapshotItem = ServerLibraryItem(
            id: "snapshot-series", type: "tvShow", title: "快照推导剧集", year: nil,
            artworkAvailable: false, backdropAvailable: false, isSeries: true
        )
        let clientItem = ServerLibraryItem(
            id: "client-series", type: "tvShow", title: "客户端推荐剧集", year: nil,
            artworkAvailable: false, backdropAvailable: false, isSeries: true
        )
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 1, countsByType: ["tvShow": 1]),
            items: ServerLibraryItemsResponse(totalItemCount: 1, items: [snapshotItem])
        )

        let fallback = ServerWebHomePage.render(
            serverName: "测试", snapshot: snapshot, csrfToken: "token",
            recommendations: .empty, sidebarExtras: .empty
        )
        XCTAssertTrue(fallback.contains("快照推导剧集"))
        XCTAssertFalse(fallback.contains("客户端推荐剧集"))

        let preferred = ServerWebHomePage.render(
            serverName: "测试", snapshot: snapshot, csrfToken: "token",
            recommendations: ServerHomeRecommendations(banner: [clientItem], series: [clientItem]),
            sidebarExtras: .empty
        )
        XCTAssertTrue(preferred.contains("客户端推荐剧集"))
        XCTAssertFalse(preferred.contains("快照推导剧集"), "同一栏不该两份片单并排出现")
    }
}
