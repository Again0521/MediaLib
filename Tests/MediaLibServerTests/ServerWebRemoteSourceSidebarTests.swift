import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
import MediaLibServerProtocol

/// 远程来源（Emby/Jellyfin/Plex/Mlink）在网页端的可见性。
///
/// 这一族用例存在的理由：目录层的分组、计数与授权早就被 `ServerLibraryCatalogTests`
/// 钉死了，而**页面层与路由层**一条都没钉。于是 `/`、`/category/*`、`/search` 等十几
/// 个渲染点漏传 `sidebarExtras`，侧栏里一个远程分组都不画——测试全绿，浏览器里
/// 「Emby 目录不见了」。断言的对象因此是**响应体**，不是目录层的返回值。
final class ServerWebRemoteSourceSidebarTests: XCTestCase {
    private static let embyGroup = ServerRemoteSourceGroup(
        id: "aabbccdd",
        title: "客厅 Emby",
        kind: .emby,
        itemCount: 42,
        libraries: [
            ServerRemoteLibraryEntry(id: "11223344", title: "电影库", itemCount: 30),
            ServerRemoteLibraryEntry(id: "55667788", title: "剧集库", itemCount: 12)
        ]
    )

    private static let categories = [
        ServerLibraryCategory(id: "movie", title: "电影", itemCount: 12),
        ServerLibraryCategory(id: "music", title: "音乐", itemCount: 5),
        ServerLibraryCategory(id: "homeVideo", title: "录像", itemCount: 3)
    ]

    private func makeRouter() -> LocalHTTPRouter {
        LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            remoteSourceGroupsProvider: { _ in [Self.embyGroup] },
            librarySnapshotProvider: { _ in
                ServerLibrarySnapshot(
                    summary: ServerLibrarySummary(
                        totalItemCount: 20, countsByType: ["movie": 12, "music": 5, "homeVideo": 3]
                    ),
                    items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
                )
            },
            libraryCategoriesProvider: { _ in
                ServerLibraryCategoriesResponse(categories: Self.categories, videoGroupItemCount: 9)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
    }

    private func html(_ router: LocalHTTPRouter, _ path: String) -> String {
        let response = router.response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(response.statusCode, 200, path)
        return String(data: response.body, encoding: .utf8) ?? ""
    }

    /// 播放系统侧栏能到达的每一个已认证页面都必须画出远程分组。
    ///
    /// 逐条列出而不是抽查：漏传 `sidebarExtras` 是一处一处漏的，抽查会漏掉下一处。
    func testEveryAuthenticatedPageRendersRemoteSourceGroupsInTheSidebar() {
        let router = makeRouter()
        let pages = [
            "/", "/index.html", "/category/video", "/category/movie", "/search",
            "/watching", "/history", "/favorites", "/watchlist", "/watched",
            "/unwatched", "/ratings", "/albums", "/photos", "/queue", "/people",
            "/collections", "/music/songs", "/music/albums", "/account",
            "/vault", "/remote/aabbccdd"
        ]
        for path in pages {
            let markup = html(router, path)
            XCTAssertTrue(
                markup.contains("href=\"/remote/aabbccdd\""),
                "\(path) 的侧栏缺少远程来源分组入口"
            )
            XCTAssertTrue(markup.contains("客厅 Emby"), "\(path) 的侧栏缺少远程来源名称")
            XCTAssertTrue(
                markup.contains("href=\"/remote/11223344\""),
                "\(path) 的侧栏缺少远程资料库入口"
            )
        }
    }

    /// 首页的一级分类必须与 `libraryCategoriesProvider` 同源。
    ///
    /// 首页从前自己从（含远程的）快照里推导分类：数字比其它页面大，而只存在于
    /// 远程的类型还会长出一个 `/category/<type>` 会 404 的入口。
    func testHomeSidebarCategoriesComeFromTheCategoriesProviderOnly() {
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            remoteSourceGroupsProvider: { _ in [Self.embyGroup] },
            librarySnapshotProvider: { _ in
                // 快照里故意混进一个分类响应里没有的类型（模拟"只有远程才有剧集"）。
                ServerLibrarySnapshot(
                    summary: ServerLibrarySummary(
                        totalItemCount: 999, countsByType: ["movie": 812, "tvShow": 300]
                    ),
                    items: ServerLibraryItemsResponse(totalItemCount: 0, items: [])
                )
            },
            libraryCategoriesProvider: { _ in
                ServerLibraryCategoriesResponse(
                    categories: [ServerLibraryCategory(id: "movie", title: "电影", itemCount: 12)],
                    videoGroupItemCount: 12
                )
            },
            authenticationProvider: { _ in .testAdministrator() }
        )
        let markup = html(router, "/")

        XCTAssertTrue(markup.contains("href=\"/category/movie\""))
        XCTAssertFalse(
            markup.contains("href=\"/category/tvShow\""),
            "本地没有的分类不得出现在侧栏——那个链接点进去是 404"
        )
        XCTAssertFalse(
            markup.contains("<span class=\"nav-count\">812</span>"),
            "首页分类计数不得来自含远程的快照"
        )
    }

    /// 「视频」徽标数来自服务端按浏览同谓词算出的数，而不是各分类计数之和。
    func testVideoGroupBadgeUsesTheServerComputedBrowsableCount() {
        let markup = html(makeRouter(), "/")

        // 分类计数之和是 12 + 3 = 15（音乐不算），而可浏览的顶层条目是 9。
        XCTAssertTrue(markup.contains("<span class=\"nav-count\">9</span>"), "视频徽标应为可浏览条数")
        XCTAssertFalse(markup.contains("<span class=\"nav-count\">15</span>"), "不得用分类计数求和")
    }

    /// 录像只挂在「相册」下面，不再同时算进「视频」。
    func testHomeVideoCategoryBelongsToTheAlbumGroupOnly() {
        let markup = html(makeRouter(), "/")
        let videoSection = markup.components(separatedBy: ">视频<").dropFirst().first ?? ""
        let videoGroupMarkup = videoSection.components(separatedBy: "</details>").first ?? ""

        XCTAssertFalse(
            videoGroupMarkup.contains("href=\"/category/homeVideo\""),
            "录像归相册，不该在视频分组里再出现一次"
        )
        XCTAssertTrue(markup.contains("href=\"/category/homeVideo\""), "录像入口仍要在相册分组里")
    }

    /// 远程作用域页在页面与脚本两侧都必须被认成一个正当路由。
    ///
    /// `/remote/{id}` 曾经既不在渐进导航白名单里，也不在 `library.js` 的路由白名单里：
    /// 前者让每次点击整页重载，后者让地址栏被改写成 `/search?…`——刷新就落到空搜索页。
    func testRemoteScopeIsARecognisedRouteInBothNavigationAndLibraryScripts() {
        let router = makeRouter()
        let shell = String(
            data: router.response(
                for: "GET /assets/app-shell.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
            ).body,
            encoding: .utf8
        ) ?? ""
        let library = String(
            data: router.response(
                for: "GET /assets/library.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
            ).body,
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(shell.contains("const scopedCatalogRoute"))
        XCTAssertTrue(shell.contains(#"/^\/remote\/[0-9a-f]{1,64}$/"#))
        XCTAssertTrue(shell.contains("scopedCatalogRoute(pathname) || progressiveRoutes.has(pathname)"))
        XCTAssertTrue(shell.contains("params.set('remoteScope', scopedRemote[1])"))
        XCTAssertTrue(library.contains(#"/^\/remote\/[0-9a-f]{1,64}$/.test(declaredRoute)"#))

        let page = html(router, "/remote/aabbccdd")
        XCTAssertTrue(page.contains("data-page-route=\"/remote/aabbccdd\""))
        XCTAssertTrue(page.contains("data-remote-scope=\"aabbccdd\""))
    }

    /// 渐进导航必须能把新增的侧栏条目搬进来，而不是只更新两份里都有的链接。
    ///
    /// 只更新已有链接时，一份在落地页画少了的侧栏在整个会话里再也修不回来——
    /// 正文换了、侧栏没换，看起来就是"刷新之后本地数据正常，Emby 目录还是不出现"。
    func testShellReconcilesSidebarStructureInsteadOfOnlyPatchingExistingLinks() {
        let shell = String(
            data: makeRouter().response(
                for: "GET /assets/app-shell.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
            ).body,
            encoding: .utf8
        ) ?? ""

        XCTAssertTrue(shell.contains("const sidebarSignature"))
        XCTAssertTrue(shell.contains("sidebarSignature(liveSidebar) === sidebarSignature(incomingSidebar)"))
        // 结构不同时采用新侧栏，但读者展开过的分组与滚动位置要搬回去——这份状态
        // 描述与整页加载后恢复用的是同一个，不再各写一套。
        XCTAssertTrue(shell.contains("applySidebarState(incomingSidebar, sidebarState);"))
        XCTAssertTrue(shell.contains("if (state.opened?.includes(key)) details.open = true;"))
        XCTAssertTrue(shell.contains("settledSidebar.scrollTop = sidebarState.scrollTop"))
    }

    /// 没有远程来源时，侧栏不该凭空多出一个分组。
    func testSidebarHasNoRemoteGroupWhenNoRemoteSourceIsConnected() {
        let router = LocalHTTPRouter(
            serverID: "server-001",
            serverName: "客厅服务器",
            libraryCategoriesProvider: { _ in
                ServerLibraryCategoriesResponse(categories: Self.categories, videoGroupItemCount: 9)
            },
            authenticationProvider: { _ in .testAdministrator() }
        )

        XCTAssertFalse(html(router, "/").contains("href=\"/remote/"))
    }
}
