import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerWebPlaybackRouteTests: XCTestCase {
    private let safeDetail = ServerMediaItemDetail(
        id: "movie-1",
        type: "movie",
        title: "标题 <script>alert(1)</script>",
        originalTitle: "Original & Movie",
        year: 2026,
        overview: "简介 </style><script>bad()</script>",
        genres: ["剧情", "科幻"],
        communityRating: 8.5,
        runtimeSeconds: 7_200,
        videoCodec: "h264",
        audioCodec: "aac",
        resolution: "1920x1080",
        artworkAvailable: true,
        backdropAvailable: false,
        browserContentType: "video/mp4",
        canDirectPlay: true,
        canTranscode: true,
        detailExtras: ServerMediaDetailExtras(
            status: "播出中", contentRating: "PG-13", originalLanguage: "ja",
            countries: ["日本"], productionCompanies: ["制作委员会"], networks: ["Tokyo MX"],
            crew: [ServerMediaDetailCredit(id: "crew-1", name: "导演", role: "导演", category: "crew")],
            cast: [ServerMediaDetailCredit(id: "cast-1", name: "演员", role: "主角", category: "cast")],
            related: [ServerMediaDetailRelated(id: "related-1", type: "movie", title: "相似作品", year: 2025, artworkAvailable: true, isSeries: false)]
        ),
        userState: ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 300, progress: 0.5,
            isWatched: false, playCount: 1, lastPlayedAt: nil,
            updatedAt: Date(timeIntervalSince1970: 100)
        )
    )

    /// 详情页请求的每个封面尺寸都必须是缩略图服务真的有的那几档。
    ///
    /// 这条从前被两层漏掉了：设计系统里那条同名检查的路由名单不含详情页，而这个
    /// 文件的 `safeDetail` 又是 `backdropAvailable: false`——偏偏坏掉的分支只在
    /// 有剧照时才走。于是背景和画面前置图对所有带剧照的条目长期返回 400，页面就
    /// 是空的。所以这里必须显式地把"有剧照"这一路也渲染出来。
    func testDetailPageOnlyRequestsArtworkSizesTheThumbnailerServes() throws {
        let expression = try NSRegularExpression(pattern: "/api/v1/images/[^\"?]+\\?size=(\\d+)")
        for hasBackdrop in [true, false] {
            let detail = ServerMediaItemDetail(
                id: "movie-1", type: "movie", title: "封面尺寸", originalTitle: nil, year: 2024,
                overview: "简介", genres: [], communityRating: nil, runtimeSeconds: 3_600,
                videoCodec: nil, audioCodec: nil, resolution: nil, artworkAvailable: true,
                backdropAvailable: hasBackdrop, canDirectPlay: true, canTranscode: false,
                detailExtras: ServerMediaDetailExtras(
                    artwork: [
                        ServerMediaDetailArtwork(id: "a-0", index: 0, kind: "backdrop", aspectRatio: 1.78),
                        ServerMediaDetailArtwork(id: "a-1", index: 1, kind: "poster", aspectRatio: 0.67)
                    ]
                )
            )
            let html = ServerWebMediaDetailPage.render(
                serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false,
                sidebarExtras: .empty
            )
            let range = NSRange(html.startIndex..<html.endIndex, in: html)
            let matches = expression.matches(in: html, range: range)
            XCTAssertFalse(matches.isEmpty, "backdropAvailable=\(hasBackdrop) 时详情页应当请求封面")
            for match in matches {
                guard let digits = Range(match.range(at: 1), in: html), let size = Int(html[digits]) else { continue }
                XCTAssertTrue(
                    ServerArtworkThumbnailer.supportedMaximumPixels.contains(size),
                    "backdropAvailable=\(hasBackdrop) 时请求了不受支持的尺寸 \(size)，图片端点会返回 400"
                )
            }
        }
    }

    func testDetailAPIAndPageRequireAuthenticationAndHideUnknownItems() throws {
        let router = makeRouter()
        let unauthenticated = LocalHTTPRouter(
            serverID: "server", serverName: "Server", mediaDetailProvider: { _, _ in self.safeDetail }
        )

        XCTAssertEqual(unauthenticated.response(
            for: "GET /item/movie-1 HTTP/1.1\r\nHost: localhost\r\n\r\n"
        ).statusCode, 401)
        XCTAssertEqual(router.response(
            for: request("/item/unknown", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/api/v1/items/unknown", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/item/movie-1/extra", token: "viewer")
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: request("/item/movie-1%0Aheader", token: "viewer")
        ).statusCode, 404)

        let api = router.response(for: request("/api/v1/items/movie-1", token: "viewer"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(api.statusCode, 200)
        XCTAssertEqual(try decoder.decode(ServerMediaItemDetail.self, from: api.body), safeDetail)
    }

    /// 播放器的三个真问题，一次钉住：
    ///
    /// * 字幕轨道一直被挂上去，却因为原生控件被关掉、又没有自建菜单而**无法选择**；
    /// * 一整块「技术信息/流列表」面板每次渲染后被字符串手术切掉——不该先生成再删；
    /// * 覆盖控件把 `#ffffff` 和 `rgba(0,0,0,…)` 写死，于是深色主题与
    ///   `prefers-contrast: more` 在这一块上完全不起作用。
    func testEmbeddedPlayerOffersTrackSelectionAndDrawsItselfFromOnMediaTokens() {
        let router = makeRouter()
        let html = String(
            data: router.response(for: request("/item/movie-1", token: "viewer")).body, encoding: .utf8
        ) ?? ""
        let css = ServerWebMediaDetailPage.style
        let script = ServerWebMediaDetailPage.script

        // 字幕与音轨各有自己的入口，且是 <details>——文档级浮层一进原生全屏就
        // 消失，而那正是最需要字幕的时候。
        XCTAssertTrue(html.contains("id=\"subtitle-menu\""))
        XCTAssertTrue(html.contains("id=\"audio-menu\""))
        XCTAssertTrue(script.contains("function buildSubtitleMenu()"))
        XCTAssertTrue(script.contains("function buildAudioMenu()"))
        XCTAssertTrue(script.contains("'关闭字幕'"))
        XCTAssertTrue(css.contains(".player-track-item"))

        // 被切掉的那块面板现在根本不生成。
        XCTAssertFalse(html.contains("id=\"stream-list\""))
        XCTAssertFalse(html.contains("id=\"technical-info\""))
        XCTAssertFalse(html.contains("id=\"user-playback-state\""))
        XCTAssertFalse(script.contains("user-playback-state"))

        // 覆盖控件全部走 on-media 令牌。
        XCTAssertTrue(css.contains("background: var(--media-scrim)"))
        XCTAssertTrue(css.contains("color: var(--text-on-media)"))
        XCTAssertFalse(css.contains("color: #ffffff"))
        XCTAssertFalse(css.contains("rgba(255, 255, 255, 0.16)"))
        // 玻璃浮层是"显形"，不是纯淡入。
        XCTAssertTrue(css.contains("@keyframes player-materialize"))
    }

    /// 音频底栏一直在给 `<body>` 加 `medialib-audio-dock-visible`，但全仓没有任何
    /// 一条规则命中它——播放音乐时 76px 高的底栏会盖住每一页的页尾内容。
    func testAudioDockReservesRoomForItselfInsteadOfCoveringPageContent() {
        XCTAssertTrue(ServerWebShellScript.script.contains("medialib-audio-dock-visible"))
        XCTAssertTrue(
            ServerWebShellStyle.css.contains("body.medialib-audio-dock-visible .app-main"),
            "底栏可见时必须为它留出页尾空间"
        )
    }

    /// 播放器下方的内容要与客户端逐块对应，而且**每一张外部图片都必须走同源
    /// 代理**：把 TMDB 的地址写进 HTML 会让每个访问者的 IP 直接暴露给元数据
    /// 提供方。
    func testDetailPageRendersEveryClientSectionAndProxiesEveryExternalImage() {
        let extras = ServerMediaDetailExtras(
            status: "Ended", contentRating: "TV-14", originalLanguage: "en",
            countries: ["美国"], productionCompanies: ["Marvel Studios"], networks: ["Disney+"],
            crew: [ServerMediaDetailCredit(id: "p-1", name: "导演甲", role: "导演", category: "crew", portraitIndex: 0)],
            cast: [
                ServerMediaDetailCredit(id: "p-2", name: "演员乙", role: "主角", category: "cast", portraitIndex: 1),
                ServerMediaDetailCredit(id: "p-3", name: "演员丙", role: "配角", category: "cast", portraitIndex: nil)
            ],
            related: [ServerMediaDetailRelated(id: "movie-9", type: "movie", title: "库中作品", year: 2024, artworkAvailable: true, isSeries: false)],
            discovery: [ServerMediaDetailDiscovery(id: "d-0", index: 0, title: "未收录作品", year: 2023, artworkAvailable: true)],
            artwork: [
                ServerMediaDetailArtwork(id: "a-0", index: 0, kind: "backdrop", aspectRatio: 1.78),
                ServerMediaDetailArtwork(id: "a-1", index: 1, kind: "poster", aspectRatio: 0.67)
            ],
            links: [ServerMediaDetailLink(id: "imdb", title: "IMDb", url: "https://www.imdb.com/title/tt0000001/")]
        )
        let detail = ServerMediaItemDetail(
            id: "movie-1", type: "movie", title: "详情验收", originalTitle: nil, year: 2024,
            overview: "简介", genres: ["剧情"], communityRating: 8.2, runtimeSeconds: 3_600,
            videoCodec: nil, audioCodec: nil, resolution: nil, artworkAvailable: true,
            backdropAvailable: false, canDirectPlay: true, canTranscode: false,
            detailExtras: extras
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false,
            sidebarExtras: .empty
        )

        // 客户端的每一块都在，且顺序一致。
        for title in ["制作信息", "主创", "演员", "艺术照", "库中相似作品", "更多推荐", "相关链接"] {
            XCTAssertTrue(html.contains(">\(title)</h2>"), "缺少「\(title)」区块")
        }
        let order = ["主创", "演员", "艺术照", "库中相似作品", "更多推荐", "相关链接"]
            .map { html.range(of: ">\($0)</h2>")!.lowerBound }
        XCTAssertEqual(order, order.sorted(), "区块顺序必须与客户端一致")

        // 状态/分级/语言/国家上移到了顶部标签行，而不是留在页面最底下。
        let factsRange = html.range(of: "class=\"facts\"")!
        let facts = String(html[factsRange.lowerBound...].prefix(600))
        XCTAssertTrue(facts.contains("Ended"))
        XCTAssertTrue(facts.contains("TV-14"))
        XCTAssertTrue(facts.contains("美国"))

        // 所有外部图片都是同源代理路径，绝不出现上游主机。
        XCTAssertTrue(html.contains("/api/v1/images/movie-1/portrait/0?size=160"))
        // 缩略图是 320，链接指向同一张图的 1024 版本——浏览器自带的图片查看器
        // 就是查看器，这一页不需要再背一个灯箱脚本。
        XCTAssertTrue(html.contains("/api/v1/images/movie-1/still/0?size=320"))
        XCTAssertTrue(html.contains("href=\"/api/v1/images/movie-1/still/0?size=1024\""))
        XCTAssertTrue(html.contains("/api/v1/images/movie-1/discovery/0?size=320"))
        XCTAssertFalse(html.contains("image.tmdb.org"))
        // 没有已缓存头像的人用姓名首字母，而不是请求一张不存在的图。
        XCTAssertFalse(html.contains("portrait/2"))
        XCTAssertTrue(html.contains(">丙</span>") || html.contains(">演</span>"))
        // 资料库里没有的推荐不是链接。
        XCTAssertTrue(html.contains("class=\"client-detail-related-card is-discovery\""))
        XCTAssertTrue(html.contains("资料库中没有"))
        // 外链不带 referrer。
        XCTAssertTrue(html.contains("rel=\"noopener noreferrer\""))
    }

    /// 外部 ID 直接进 URL 路径，所以它必须先被限制成一个真正的标识符。
    func testDetailLinksRejectIdentifiersThatCouldEscapeTheURLPath() {
        let links = ServerLibraryCatalog.detailLinks(
            title: "标题",
            externalIDs: [
                MediaExternalID(provider: "imdb", value: "tt0000001"),
                MediaExternalID(provider: "imdb", value: "../../evil"),
                MediaExternalID(provider: "tmdb", value: "movie:550"),
                MediaExternalID(provider: "tmdb", value: "movie:../evil"),
                MediaExternalID(provider: "tmdb", value: "person:abc")
            ]
        )
        let urls = links.map(\.url)
        XCTAssertTrue(urls.contains("https://www.imdb.com/title/tt0000001/"))
        XCTAssertTrue(urls.contains("https://www.themoviedb.org/movie/550"))
        XCTAssertFalse(urls.contains { $0.contains("..") })
        XCTAssertFalse(urls.contains { $0.contains("abc") })
    }

    /// 图片代理是一道 SSRF 边界：数据库里的任意字符串不能变成让服务端去访问的地址。
    func testDetailImageProxyOnlyFollowsTheKnownMetadataImageHost() {
        XCTAssertNotNil(ServerLibraryCatalog.approvedRemoteImageURL("https://image.tmdb.org/t/p/w500/a.jpg"))
        for rejected in [
            "http://image.tmdb.org/t/p/w500/a.jpg",          // 明文
            "https://evil.example.com/a.jpg",                 // 主机不在白名单
            "https://image.tmdb.org.evil.com/a.jpg",          // 后缀伪装
            "https://user:pw@image.tmdb.org/a.jpg",           // 带凭据
            "https://image.tmdb.org:8443/a.jpg",              // 非默认端口
            "https://image.tmdb.org/t/p/w500/a.svg",          // 可执行图片格式
            "file:///etc/passwd",
            "http://127.0.0.1:8099/api/v1/admin/users"
        ] {
            XCTAssertNil(ServerLibraryCatalog.approvedRemoteImageURL(rejected), rejected)
        }
    }

    /// 远程条目的详情图来自它自己那台媒体服务器，不是 TMDB。
    ///
    /// 这里从前只认 `image.tmdb.org` + 图片扩展名，而 Emby/Jellyfin 的头像是
    /// `/Items/<id>/Images/Primary?…`、Plex 是 `/photo/:/transcode?…`，两者都不
    /// 带扩展名、主机也不在白名单——于是整台 Emby 在网页上一张演员头像、一张
    /// 剧照都没有。放行的边界与该条目的封面**完全相同**：仅限已连接远程媒体
    /// 服务器上的条目，且字节仍由缩略图管线派生成 JPEG 再发出。
    func testDetailImageProxyFollowsTheItemsOwnRemoteServerButNotArbitraryHosts() {
        let remote = MediaItem(
            id: "remote-1", type: .movie, title: "远程电影",
            sourcePath: "emby://nas.local/src/library/a",
            filePath: "https://nas.local/stream", metadataProvider: "Emby"
        )
        let local = MediaItem(
            id: "local-1", type: .movie, title: "本地电影",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mkv", metadataProvider: "TMDB"
        )

        // 远程：没有扩展名的媒体服务器地址照样放行。
        XCTAssertNotNil(ServerLibraryCatalog.approvedDetailImageURL(
            "https://nas.local/emby/Items/12/Images/Primary?tag=abc", for: remote
        ))
        XCTAssertNotNil(ServerLibraryCatalog.approvedDetailImageURL(
            "https://nas.local/photo/:/transcode?url=%2Flibrary%2F1", for: remote
        ))
        // 本地条目一步都不放宽：它的详情图只可能来自刮削到的图片 CDN。
        XCTAssertNil(ServerLibraryCatalog.approvedDetailImageURL(
            "https://nas.local/emby/Items/12/Images/Primary", for: local
        ))
        XCTAssertNotNil(ServerLibraryCatalog.approvedDetailImageURL(
            "https://image.tmdb.org/t/p/w500/a.jpg", for: local
        ))
        // 远程条目也不是什么都放行：带凭据、带 fragment、非 http(s) 一律拒绝。
        for rejected in [
            "https://user:pw@nas.local/emby/Items/12/Images/Primary",
            "https://nas.local/emby/Items/12/Images/Primary#x",
            "file:///etc/passwd",
            ""
        ] {
            XCTAssertNil(ServerLibraryCatalog.approvedDetailImageURL(rejected, for: remote), rejected)
        }
    }

    func testDetailPageEscapesMetadataAndUsesOnlyExternalSameOriginScript() {
        let response = makeRouter().response(for: request("/item/movie-1", token: "viewer"))
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(html.contains("class=\"media-detail-page\""))
        XCTAssertFalse(html.contains("reference-system.css"))
        XCTAssertTrue(html.contains("标题 &lt;script&gt;alert(1)&lt;/script&gt;"))
        XCTAssertTrue(html.contains("简介 &lt;/style&gt;&lt;script&gt;bad()&lt;/script&gt;"))
        XCTAssertFalse(html.contains("<script>alert(1)</script>"))
        XCTAssertFalse(html.contains("</style><script>bad()</script>"))
        XCTAssertTrue(html.contains("content=\"known-csrf\""))
        XCTAssertTrue(html.contains("src=\"/assets/player.js?v="))
        XCTAssertTrue(html.contains("href=\"/assets/player.css?v="))
        XCTAssertTrue(html.contains("class=\"watch-layout\""))
        XCTAssertTrue(html.contains("class=\"app-page-actions\""))
        XCTAssertTrue(html.contains("class=\"detail-utility-inline\""))
        XCTAssertTrue(html.contains("class=\"rating-stars\""))
        XCTAssertTrue(html.contains("class=\"rating-star\""))
        XCTAssertFalse(html.contains("id=\"user-rating\" type=\"range\""))
        XCTAssertTrue(html.contains("id=\"player-stage\" class=\"player-stage\""))
        XCTAssertTrue(html.contains("id=\"player\" hidden playsinline preload=\"metadata\""))
        XCTAssertTrue(html.contains("class=\"player-landing-art\""))
        XCTAssertFalse(html.contains("<video id=\"player\" controls"))
        XCTAssertTrue(html.contains("id=\"wide-size\""))
        XCTAssertTrue(html.contains("id=\"web-fullscreen\""))
        XCTAssertTrue(html.contains("class=\"episode-panel\""))
        XCTAssertTrue(html.contains("data-item-id=\"movie-1\""))
        XCTAssertTrue(html.contains("data-video-playback-url=\"/play/movie-1#play\""))
        XCTAssertTrue(html.contains("data-media-kind=\"video\""))
        XCTAssertTrue(html.contains("data-browser-content-type=\"video/mp4\""))
        XCTAssertTrue(html.contains("data-resume-position=\"300.0\""))
        XCTAssertFalse(html.contains("id=\"user-playback-state\""))
        XCTAssertFalse(html.contains("id=\"technical-info\""))
        XCTAssertFalse(html.contains("id=\"stream-list\""))
        // `.sr-only` 是这一页私有的第二份实现，已收敛到全局的 `.visually-hidden`。
        XCTAssertTrue(html.contains("id=\"player-status\" class=\"visually-hidden\""), "播放反馈仅供读屏软件读取，不能在播放器下方重新生成可见状态栏")
        XCTAssertTrue(html.contains("class=\"synopsis-copy\""))
        XCTAssertTrue(html.contains("class=\"app-eyebrow\""))
        XCTAssertTrue(html.contains("class=\"detail-backdrop\""), "有海报时详情区必须有可用的艺术照层；没有 backdrop 时安全降级到同源海报")
        XCTAssertTrue(html.contains("id=\"playback-speed\""))
        XCTAssertTrue(html.contains("id=\"transport-controls\""))
        XCTAssertTrue(html.contains("id=\"transport-play\""))
        XCTAssertTrue(html.contains("id=\"seek-backward\""))
        XCTAssertTrue(html.contains("id=\"seek-forward\""))
        XCTAssertTrue(html.contains("id=\"toggle-mute\""))
        XCTAssertTrue(html.contains("id=\"playback-volume\""))
        XCTAssertTrue(html.contains("id=\"playback-time\""))
        XCTAssertTrue(html.contains("id=\"playback-seek\""))
        XCTAssertTrue(html.contains("id=\"fullscreen\""))
        XCTAssertTrue(html.contains("id=\"picture-in-picture\""))
        XCTAssertTrue(html.contains("player-overlay-controls"))
        XCTAssertTrue(ServerWebMediaDetailPage.style.contains(".player-overlay-controls"))
        XCTAssertFalse(html.contains("class=\"player-stage-tools\""))
        XCTAssertFalse(html.contains("class=\"compact-controls\""))
        XCTAssertTrue(html.contains("id=\"toggle-favorite\""))
        XCTAssertTrue(html.contains("id=\"toggle-watchlist\""))
        XCTAssertTrue(html.contains("id=\"user-rating\""))
        XCTAssertTrue(html.contains("制作信息"))
        XCTAssertTrue(html.contains("主创"))
        XCTAssertTrue(html.contains("演员"))
        XCTAssertTrue(html.contains("库中相似作品"))
        XCTAssertTrue(html.contains("href=\"/people/crew-1\""))
        XCTAssertTrue(html.contains("href=\"/item/related-1#play\""))
        XCTAssertTrue(html.contains("data-is-favorite=\"false\""))
        XCTAssertFalse(html.contains("id=\"automatic-next\""), "非剧集或没有已授权下一集时不能显示自动播放控件")
        XCTAssertFalse(html.localizedCaseInsensitiveContains("filePath"))
        XCTAssertFalse(html.contains("/private/"))
    }

    func testVideoPlaybackRouteRemainsAvailableAndMusicUsesPersistentShellBottomBar() {
        let router = makeRouter()
        let videoResponse = router.response(for: request("/play/movie-1", token: "viewer"))
        let videoHTML = String(data: videoResponse.body, encoding: .utf8) ?? ""

        XCTAssertEqual(videoResponse.statusCode, 200)
        XCTAssertTrue(videoHTML.contains("id=\"player-workspace\""))
        XCTAssertTrue(videoHTML.contains("data-media-kind=\"video\""))
        XCTAssertTrue(videoHTML.contains("<video id=\"player\""))
        XCTAssertTrue(videoHTML.contains("href=\"/assets/player.css?v="))
        XCTAssertTrue(videoHTML.contains("src=\"/assets/player.js?v="))
        XCTAssertTrue(videoHTML.contains("id=\"playback-speed\""))
        XCTAssertTrue(videoHTML.contains("id=\"picture-in-picture\""))
        XCTAssertTrue(videoHTML.contains("id=\"web-fullscreen\""))

        let music = ServerMediaItemDetail(
            id: "song-1", type: "music", title: "歌曲", originalTitle: nil, year: nil,
            overview: nil, genres: [], communityRating: nil, runtimeSeconds: 240,
            videoCodec: nil, audioCodec: "aac", resolution: nil, artworkAvailable: false,
            backdropAvailable: false, browserContentType: "audio/mp4", canDirectPlay: true,
            canTranscode: false
        )
        let musicRouter = makeRouter(detail: music)
        let musicResponse = musicRouter.response(for: request("/item/song-1", token: "viewer"))
        let musicHTML = String(data: musicResponse.body, encoding: .utf8) ?? ""

        XCTAssertEqual(musicResponse.statusCode, 200)
        XCTAssertTrue(musicHTML.contains("data-media-kind=\"audio\""))
        XCTAssertTrue(musicHTML.contains("data-video-playback-url=\"/play/song-1#play\""))
        XCTAssertTrue(musicHTML.contains("data-music-play=\"song-1\""))
        XCTAssertTrue(musicHTML.contains("class=\"music-dock-prompt\""))
        XCTAssertFalse(musicHTML.contains("<audio id=\"player\""))
        XCTAssertFalse(musicHTML.contains("<video id=\"player\""))
        XCTAssertFalse(musicHTML.contains("id=\"fullscreen\""))
        XCTAssertFalse(musicHTML.contains("id=\"picture-in-picture\""))
        XCTAssertTrue(musicHTML.contains("class=\"app-sidebar\""))
        let musicPlayerResponse = musicRouter.response(for: request("/play/song-1", token: "viewer"))
        let musicPlayerHTML = String(data: musicPlayerResponse.body, encoding: .utf8) ?? ""
        XCTAssertEqual(musicPlayerResponse.statusCode, 200)
        XCTAssertTrue(musicPlayerHTML.contains("class=\"music-dock-prompt\""))
        XCTAssertTrue(musicPlayerHTML.contains("data-music-play=\"song-1\""))
        XCTAssertFalse(musicPlayerHTML.contains("data-player-kind=\"audio\""))
        XCTAssertFalse(musicPlayerHTML.contains("class=\"music-hero\""))
        XCTAssertFalse(musicPlayerHTML.contains("<video id=\"player\""))
    }

    func testEpisodeDetailUsesAuthorizedSeriesContextForEmbeddedPlayerAndNumberGrid() {
        let episode = ServerMediaItemDetail(
            id: "episode-2", type: "episode", title: "第二集", originalTitle: nil, year: 2026,
            overview: "简介", genres: ["动画"], communityRating: 8.8, runtimeSeconds: 1_440,
            videoCodec: "h264", audioCodec: "aac", resolution: "1920x1080",
            artworkAvailable: false, backdropAvailable: false, browserContentType: "video/mp4",
            canDirectPlay: true, canTranscode: false,
            episodeContext: ServerEpisodePlaybackContext(
                seriesID: "series-1", seriesTitle: "示例剧集", seasonNumber: 2, episodeNumber: 3,
                seasons: [
                    ServerSeriesSeason(id: "season-1", seasonNumber: 1, title: "第 1 季", episodeCount: 12, watchedCount: 2, inProgressCount: 1),
                    ServerSeriesSeason(id: "season-2", seasonNumber: 2, title: "第 2 季", episodeCount: 10, watchedCount: 0, inProgressCount: 1)
                ]
            )
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "Server", detail: episode, csrfToken: "csrf", showAdministration: false,
            sidebarExtras: .empty
        )

        XCTAssertTrue(html.contains("示例剧集"))
        XCTAssertTrue(html.contains("第 2 季"))
        XCTAssertTrue(html.contains("第 3 集"))
        // 剧名 → 季集 → 本集是面包屑，不是塞进 `<h1>` 的一串链接：
        // 那样标题就无法交给会转义文本的共用页头。
        XCTAssertTrue(html.contains("<ol class=\"ui-breadcrumb\""))
        XCTAssertTrue(html.contains("<h1 id=\"item-title\">第二集</h1>"))
        XCTAssertFalse(html.contains("class=\"episode-trail\""))
        XCTAssertTrue(html.contains("data-series-id=\"series-1\""))
        XCTAssertTrue(html.contains("id=\"episode-grid\""))
        XCTAssertTrue(html.contains("class=\"episode-season-tab\""))
        XCTAssertTrue(html.contains("id=\"wide-size\""))
        XCTAssertTrue(html.contains("id=\"web-fullscreen\""))
        XCTAssertTrue(html.contains("id=\"fullscreen\""))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("loadWideEpisodeRows"))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("/api/v1/series/${encodeURIComponent(seriesID)}/episodes"))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("const workerCount = Math.min(4, seasons.length)"))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("Promise.all(Array.from({ length: workerCount }"))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("if (playerLayout !== 'wide' && seriesID) void loadEpisodeSeason"))
        XCTAssertTrue(ServerWebMediaDetailPage.script.contains("player.src = mediaPath('/api/v1/stream/')"))
        XCTAssertFalse(ServerWebMediaDetailPage.script.contains("window.location.assign(videoPlaybackURL)"))
        XCTAssertTrue(ServerWebMediaDetailPage.style.contains(".player-stage.controls-visible"))
        XCTAssertTrue(ServerWebMediaDetailPage.style.contains(".rating-star"))
    }

    /// 舞台与画面只能有一个在定尺寸，选集面板的高度必须跟播放器走。
    ///
    /// 这两条都是"看起来能用、量一下才发现不对"的那类：切换尺寸档时画面四边都有
    /// 黑边（舞台按比例算高、画面又自己钳高度，两个盒子对不上），而选集面板会把
    /// 整行撑高，播放器旁边空出一大条。
    func testPlayerFillsItsStageAndTheEpisodePanelTracksThePlayerHeight() {
        let css = ServerWebMediaDetailPage.style
        let script = ServerWebMediaDetailPage.script

        // 高度预算换算成宽度上限，并且挂在**卡片**上：黑底盒子因此等于画面本身，
        // 舞台保持画面自己的比例并填满卡片。挂在舞台上时，宽屏档里卡片与舞台的
        // 差就是一圈黑边。
        XCTAssertTrue(css.contains("max-width: calc(var(--player-height-budget, min(78dvh, 900px)) * (var(--player-aspect, 16 / 9)))"))
        XCTAssertTrue(css.contains("block-size: 100%"), "画面必须填满舞台")
        // 带分号才是声明；不带的那处是解释这段历史的注释，注释同样会随样式表发出去。
        XCTAssertFalse(
            css.contains("max-block-size: min(78dvh, 900px);"),
            "画面不得再自己钳高度——那正是四边黑边的来源"
        )
        // 全屏下高度不再是预算而是全部，宽度上限必须一并解除。
        XCTAssertTrue(css.contains("max-width: none"))

        // 面板封顶、集号格自己滚，而不是把整行撑高。
        XCTAssertTrue(css.contains("max-height: var(--episode-panel-height, none)"))
        XCTAssertTrue(script.contains("--episode-panel-height"))
        XCTAssertTrue(script.contains("scheduleEpisodePanelHeight"))
        // 高度不够先缩格子，缩到安全下限为止；触摸下不缩。
        XCTAssertTrue(css.contains("--episode-cell: 44px"))
        XCTAssertTrue(css.contains("--episode-cell: 32px"))
        XCTAssertTrue(css.contains("(hover: none), (pointer: coarse)"))
        // 窄屏改成横向一条带子，且不得把横向滚动泄到页面上。
        XCTAssertTrue(css.contains("grid-auto-flow: column"))
        XCTAssertTrue(css.contains("overscroll-behavior-x: contain"))
    }

    func testPlayerStylesheetIsPrivateCacheableAndContainsNoMediaData() throws {
        let router = makeRouter()
        let response = router.response(for: "GET /assets/player.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headResponse = router.response(for: "HEAD /assets/player.css HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""
        let headHeaders = String(data: headResponse.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(headers.contains("Content-Type: text/css; charset=utf-8"))
        XCTAssertTrue(headers.contains("Cache-Control: private, max-age=31536000, immutable"))
        XCTAssertFalse(headers.contains("Cache-Control: no-store"))

        let stylesheet = try XCTUnwrap(String(data: response.body, encoding: .utf8))
        XCTAssertTrue(stylesheet.contains(".player-card"))
        XCTAssertTrue(stylesheet.contains(".transport-controls"))
        XCTAssertTrue(stylesheet.contains(".playback-time"))
        XCTAssertTrue(stylesheet.contains(".player-progress"))
        XCTAssertTrue(stylesheet.contains(".player-control-row"))
        XCTAssertTrue(stylesheet.contains(".player-settings"))
        XCTAssertTrue(stylesheet.contains(".player-stage video"))
        XCTAssertTrue(stylesheet.contains(".player-stage video"))
        XCTAssertTrue(stylesheet.contains(".player-landing-art"))
        XCTAssertTrue(stylesheet.contains(".watch-layout"))
        XCTAssertTrue(stylesheet.contains(".episode-panel"))
        XCTAssertTrue(stylesheet.contains(".music-dock-prompt"))
        XCTAssertTrue(stylesheet.contains("@media (max-width: 719px)"))
        XCTAssertFalse(stylesheet.contains("movie-1"))
        XCTAssertFalse(stylesheet.contains("token"))

        XCTAssertEqual(headResponse.statusCode, 200)
        XCTAssertTrue(headResponse.body.isEmpty)
        XCTAssertEqual(headerValue(named: "Content-Length", in: headHeaders), headerValue(named: "Content-Length", in: headers))
    }

    func testPlayerScriptUsesAuthorizedLifecycleWithoutUnsafeHTMLOrTokenStorage() {
        let asset = makeRouter().response(
            for: "GET /assets/player.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let script = String(data: asset.body, encoding: .utf8) ?? ""

        XCTAssertEqual(asset.statusCode, 200)
        XCTAssertTrue(script.contains("/api/v1/stream/"))
        XCTAssertFalse(script.contains("/api/v1/playback/info/"))
        XCTAssertTrue(script.contains("/api/v1/playback/state/"))
        XCTAssertTrue(script.contains("/api/v1/user-media/preferences/"))
        // 轨道名单现在一次问全（外挂 + 内封 + 来源服务器 + 音轨），而且在**进入
        // 页面时**就问：字幕与音轨的入口属于"先看看有没有中文字幕"这件事，等到
        // 第一帧解码出来才出现太晚；音轨那一侧更是从来没出现过。
        XCTAssertTrue(script.contains("/api/v1/playback/tracks/"))
        XCTAssertTrue(script.contains("/api/v1/subtitles/"))
        XCTAssertTrue(script.contains("/api/v1/playback/sessions/"))
        XCTAssertTrue(script.contains("/api/v1/playback/hls/"))
        XCTAssertTrue(script.contains("document.createElement('div')"))
        XCTAssertTrue(script.contains("parseWebVTT"))
        XCTAssertTrue(script.contains("renderActiveSubtitle"))
        XCTAssertTrue(script.contains("void loadPlaybackTracks();"))
        // 轨道仍须在最终通路选择前完成；若预取尚未结束，iOS 则先同步调用
        // startDirect 保住当前触摸的媒体授权，再等待同一份 single-flight 结果。
        XCTAssertTrue(script.contains("await loadPlaybackTracks();"))
        XCTAssertTrue(script.contains("if (playbackTracksPromise) return playbackTracksPromise"))
        XCTAssertTrue(script.contains("const directAttempt = startDirect({ deferFailure: true })"))
        XCTAssertTrue(script.contains("directPlayHasSound()"))
        XCTAssertTrue(script.contains("method: 'POST'"))
        XCTAssertTrue(script.contains("X-MediaLIB-CSRF"))
        XCTAssertTrue(script.contains("credentials: 'same-origin'"))
        XCTAssertTrue(script.contains("encodeURIComponent(itemID)"))
        XCTAssertTrue(script.contains("pagehide"))
        XCTAssertTrue(script.contains("medialib:pagewillunload"))
        XCTAssertTrue(script.contains("AbortController"))
        XCTAssertTrue(script.contains("lifecycle.signal"))
        XCTAssertTrue(script.contains("timeupdate"))
        XCTAssertTrue(script.contains("scheduleTransportUI"))
        XCTAssertTrue(script.contains("requestAnimationFrame"))
        XCTAssertTrue(script.contains("loadedmetadata"))
        XCTAssertTrue(script.contains("updateTransportUI"))
        XCTAssertTrue(script.contains("formatClock"))
        XCTAssertTrue(script.contains("volumechange"))
        XCTAssertTrue(script.contains("playback-seek"))
        XCTAssertTrue(script.contains("seekToControlPosition"))
        XCTAssertTrue(script.contains("showOverlayControls"))
        XCTAssertTrue(script.contains("overlayHideTimer"))
        XCTAssertTrue(script.contains("seekBy(-10)"))
        XCTAssertTrue(script.contains("seekBy(10)"))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === 'j'"))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === 'l'"))
        XCTAssertTrue(script.contains("event.key.toLowerCase() === 'm'"))
        XCTAssertTrue(script.contains("JSON.stringify({ event, positionSeconds, durationSeconds })"))
        XCTAssertTrue(script.contains("JSON.stringify({ [field]: value })"))
        XCTAssertTrue(script.contains("requestFullscreen"))
        XCTAssertTrue(script.contains("requestPictureInPicture"))
        XCTAssertTrue(script.contains("keydown"))
        XCTAssertTrue(script.contains("看完啦。"))
        XCTAssertTrue(script.contains("已暂停。"))
        XCTAssertTrue(script.contains("#autoplay"))
        XCTAssertTrue(script.contains("window.location.assign"))
        XCTAssertTrue(script.contains("textContent"))
        XCTAssertTrue(script.contains("replaceChildren"))
        XCTAssertTrue(script.contains("browserCanPlay"))
        XCTAssertTrue(script.contains("canPlayType(browserContentType)"))
        XCTAssertTrue(script.contains("浏览器没有声明支持这种格式，实际播放也失败了"))
        XCTAssertFalse(script.contains("innerHTML"))
        XCTAssertFalse(script.contains("insertAdjacentHTML"))
        XCTAssertFalse(script.contains("document.cookie"))
        XCTAssertFalse(script.contains("localStorage"))
        XCTAssertFalse(script.contains("sessionStorage"))
        XCTAssertFalse(script.contains("eval("))
        XCTAssertFalse(script.contains("/api/v1/hls/"))
        // MKV/不兼容编码现在走正式 HLS 会话，而不是未知长度的原始 fMP4 管道。
        //
        // 真正要守住的东西没有变，而且比一个可执行文件的名字更具体：网页不能拿到
        // 服务器上的**路径**。参数怎么拼、二进制在哪儿，全部留在服务端；浏览器只
        // 见到一个媒体 ID 和一个秒数。
        XCTAssertFalse(script.contains("-c:v"), "ffmpeg 参数属于服务端，不进浏览器")
        XCTAssertFalse(script.contains("/usr/bin"))
        XCTAssertFalse(script.contains("/opt/homebrew"))
        XCTAssertFalse(script.contains("mediaPath('/api/v1/transcode/')"))
        XCTAssertTrue(script.contains("currentHLSSessionID"))
        XCTAssertTrue(script.contains("sourceRevision !== playbackSourceRevision"))
        XCTAssertTrue(script.contains("window.Hls.isSupported()"))
        XCTAssertTrue(script.contains("recoverMediaError()"))
        XCTAssertTrue(script.contains("client.startLoad(-1)"))
        XCTAssertTrue(script.contains("currentHLSClient.destroy()"))
        XCTAssertTrue(script.contains("waitForHLSReady"))
    }

    func testHLSJSIsSameOriginPinnedAndLicensed() {
        let router = makeRouter()
        let script = router.response(
            for: "GET /assets/vendor/hls-1.7.1.min.js HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        let license = router.response(
            for: "GET /assets/vendor/hls.js-LICENSE.txt HTTP/1.1\r\nHost: localhost\r\n\r\n"
        )
        XCTAssertEqual(script.statusCode, 200)
        XCTAssertEqual(script.body.count, 618_156)
        XCTAssertTrue(String(decoding: script.body, as: UTF8.self).contains("1.7.1"))
        XCTAssertEqual(license.statusCode, 200)
        XCTAssertTrue(String(decoding: license.body, as: UTF8.self).contains("Apache License"))
        XCTAssertFalse(ServerWebMediaDetailPage.script.contains("cdn"))
    }

    /// 轨道菜单里的条目不能被传输栏那条"每个 button 都是 36×36 图标"的规则压住。
    ///
    /// `.player-overlay-controls button` 的特指度（0,1,1）高于 `.player-track-item`
    /// （0,1,0），于是"关闭字幕"会被挤成一列竖排的单字。这个故障此前看不见，只是
    /// 因为这两个菜单从来没有被填充过——真实浏览器里一填就现形。
    func testTrackMenuItemsOutrankTheIconButtonRule() {
        let style = ServerWebMediaDetailPage.style
        XCTAssertTrue(
            style.contains(".player-track-panel .player-track-item"),
            "选择器必须比 `.player-overlay-controls button` 更具体"
        )
        let itemRule = style.range(of: ".player-track-panel .player-track-item {").map {
            String(style[$0.upperBound...].prefix(while: { $0 != "}" }))
        }
        XCTAssertEqual(itemRule?.contains("width: auto"), true)
        XCTAssertEqual(itemRule?.contains("height: auto"), true)
    }

    /// 音轨/字幕很多时，面板必须在播放器与视口内自己滚动，不能把末尾选项裁到
    /// 屏幕外。高度的精确值由脚本按触发按钮的位置计算，CSS 保留 dvh 回退。
    func testTrackMenusAreViewportBoundedScrollableLists() {
        let style = ServerWebMediaDetailPage.style
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(style.contains("--track-menu-max-height"))
        XCTAssertTrue(style.contains("overflow-y: auto"))
        XCTAssertTrue(style.contains("overscroll-behavior: contain"))
        XCTAssertTrue(style.contains("scrollbar-gutter: stable"))
        XCTAssertTrue(script.contains("syncTrackMenuHeights"))
        XCTAssertTrue(script.contains("trigger.getBoundingClientRect()"))
        XCTAssertTrue(script.contains("boundaryRight - panelRect.width"))
        XCTAssertTrue(script.contains("panel.style.left"))
        XCTAssertTrue(script.contains("menu.addEventListener('toggle'"))
    }

    func testMobileTransportDropsTimeBeforeControlsOverflowAndUsesTapToggle() {
        let style = ServerWebMediaDetailPage.style
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(style.contains("container-type: inline-size"))
        XCTAssertTrue(style.contains("@container (max-width: 520px)"))
        XCTAssertTrue(style.contains("@media (max-width: 559px) { .playback-time { display: none; } }"))
        XCTAssertTrue(script.contains("const coarsePointer = window.matchMedia('(hover: none), (pointer: coarse)')"))
        XCTAssertTrue(script.contains("setOverlayPinnedByTap(!overlayPinnedByTap)"))
        XCTAssertTrue(script.contains("if (!coarsePointer.matches) hideOverlayControls()"))
        XCTAssertTrue(style.contains(".player-shortcut-hint { display: none !important; }"))
        XCTAssertTrue(script.contains("!coarsePointer.matches && !mobileViewport.matches"))
    }

    func testSubtitleSelectionLoadsOneValidatedWebVTTAndClosesMenuFirst() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("credentials: 'same-origin', headers: { 'Accept': 'text/vtt' }"))
        XCTAssertTrue(script.contains("activeSubtitleCues = parseWebVTT(payload)"))
        XCTAssertTrue(script.contains("source.startsWith('WEBVTT')"))
        XCTAssertTrue(script.contains("line.textContent = cue.text"))
        XCTAssertTrue(script.contains("cues.length >= 20000"))
        XCTAssertTrue(script.contains("failedSubtitleTrackIDs.delete(trackID)"))
        XCTAssertTrue(script.contains("上次加载失败，点按重试"))
        XCTAssertTrue(script.contains("releaseActiveSubtitle()"))
        XCTAssertFalse(script.contains("URL.createObjectURL"))
        XCTAssertFalse(script.contains("element.src = subtitlePath(track.id)"))
        let close = script.range(of: "button.closest('details')?.removeAttribute('open');")
        let select = close.flatMap { script.range(of: "onSelect();", range: $0.upperBound..<script.endIndex) }
        XCTAssertNotNil(close)
        XCTAssertNotNil(select)
    }

    func testPreferredSubtitleUsesLanguageAndCommonLabelKeywords() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("简体中文"))
        XCTAssertTrue(script.contains("繁體中文"))
        XCTAssertTrue(script.contains("simplified chinese"))
        XCTAssertTrue(script.contains("traditional chinese"))
        XCTAssertTrue(script.contains("日本語"))
        XCTAssertTrue(script.contains("undesirable"))
        XCTAssertTrue(script.contains("track.isDefault ? 2 : 0"))
    }

    func testPauseAbortDoesNotBecomePlaybackFailure() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("error?.name === 'AbortError'"))
        XCTAssertTrue(script.contains("lastUserPauseAt = window.performance.now()"))
        XCTAssertTrue(script.contains("window.performance.now() - lastUserPauseAt < 2_000"))
    }

    func testIOSMatroskaUsesCompatibilityRemuxWithoutChangingDesktopProbePolicy() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("const isIOSFamily = /iP(?:ad|hone|od)/"))
        XCTAssertTrue(script.contains("!['video/mp4', 'video/quicktime'].includes(browserContentType)"))
        XCTAssertTrue(script.contains("const directPlayNeedsRemux"))
        XCTAssertTrue(script.contains("await startRemux(0, resumeAt, { allowUnprobed: true })"))
        XCTAssertTrue(script.contains("正在为 iPhone / iPad 准备兼容播放流。"))
        XCTAssertFalse(script.contains("if (!browserCanPlay())"))
    }

    /// Loki 这类 MKV 会因为 E-AC-3 自动走分片 MP4 重封装。该流的原生 duration
    /// 是 Infinity；资料库又可能因 AVFoundation 不识别 MKV 而没有时长。轨道接口
    /// 必须把 ffprobe 时长补给统一时间轴，否则剩余时长与拖动会同时失效。
    func testPlayerUsesProbedDurationWhenNativeDurationIsUnavailable() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("var knownDurationSeconds"))
        XCTAssertTrue(script.contains("payload.durationSeconds"))
        XCTAssertTrue(script.contains("knownDurationSeconds = playbackTracks.durationSeconds"))
        XCTAssertTrue(script.contains("const nativeDuration = Number(player.duration)"))
        XCTAssertTrue(script.contains("return knownDurationSeconds > 0 ? knownDurationSeconds : NaN"))
        XCTAssertTrue(script.contains("seekTimeline(Math.min(resumeAt, duration))"))
        XCTAssertTrue(script.contains("if (playbackMode === 'hls' && knownDurationSeconds > 0) return knownDurationSeconds"))
    }

    func testScrubbingKeepsCapturedTargetUntilOneCommittedSeek() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("var scrubState = 'idle'"))
        XCTAssertTrue(script.contains("scrubState = 'scrubbing'"))
        XCTAssertTrue(script.contains("scrubTarget = Number(playbackSeek.value)"))
        XCTAssertTrue(script.contains("const nextPosition = Number.isFinite(scrubTarget) ? scrubTarget"))
        XCTAssertTrue(script.contains("scrubTarget = nextPosition"))
        XCTAssertTrue(script.contains("if (scrubState === 'idle')"))
        XCTAssertTrue(script.contains("const settlePendingSeek = () =>"))
        XCTAssertTrue(script.contains("current + 0.75 < scrubTarget"))
        XCTAssertFalse(script.contains("seekTimeline(nextPosition);\n        scrubState = 'idle';"))
        XCTAssertTrue(script.contains("sourceRevision !== playbackSourceRevision"))
        XCTAssertTrue(script.contains("cancelHLSSession(sessionID)"))
    }

    func testAuthenticatedHLSSessionRoutesBindManifestAndCancellationToPrincipal() throws {
        let sessionID = String(repeating: "a", count: 32)
        let descriptor = ServerHLSPlaybackDescriptor(
            sessionID: sessionID,
            mode: "hlsRemux",
            durationSeconds: 3_600,
            actualStartSeconds: 120,
            reason: "containerOrAudioCompatibility",
            mediaURL: "/api/v1/playback/hls/\(sessionID)/index.m3u8"
        )
        var cancelledBy: String?
        var receivedCapabilities: ServerWebClientCapabilities?
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            hlsSessionProvider: { itemID, request, principal in
                receivedCapabilities = request.capabilities
                return itemID == "movie-1" && request.audioTrackID == 1 && principal.userID == "viewer"
                    ? descriptor : nil
            },
            hlsStatusProvider: { requestedSession, principal in
                requestedSession == sessionID && principal.userID == "viewer" ? descriptor : nil
            },
            hlsResourceProvider: { requestedSession, fileName, principal in
                guard requestedSession == sessionID,
                      fileName == "index.m3u8",
                      principal.userID == "viewer"
                else { return nil }
                return ServerHLSResource(
                    data: Data("#EXTM3U\n#EXT-X-VERSION:6\n".utf8),
                    contentType: "application/vnd.apple.mpegurl"
                )
            },
            hlsCancellationProvider: { _, principal in cancelledBy = principal.userID },
            authenticationProvider: { head in
                let user = head.contains("Bearer viewer") ? "viewer" : (head.contains("Bearer other") ? "other" : nil)
                return user.map {
                    ServerRequestPrincipal(
                        userID: $0, deviceID: "device-\($0)", sessionID: "session-\($0)",
                        permissions: [.viewMedia, .playMedia, .transcodePlayback], libraryGrants: [:]
                    )
                }
            },
            csrfToken: "known-csrf"
        )
        let requestBody = Data(#"{"audioTrackID":1,"startSeconds":120,"durationSeconds":3600}"#.utf8)
        let created = router.response(
            for: mutationRequest("/api/v1/playback/sessions/movie-1", bodyLength: requestBody.count),
            body: requestBody
        )
        XCTAssertEqual(created.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(ServerHLSPlaybackDescriptor.self, from: created.body), descriptor)

        let capabilityBody = Data(#"{"itemID":"movie-1","audioTrackID":1,"startSeconds":120,"durationSeconds":3600,"capabilities":{"nativeHLS":false,"mediaSource":true,"videoCodecs":["h264"],"audioCodecs":["aac"],"screenWidth":1920,"screenHeight":1080,"hdrDisplay":false,"measuredDownlinkMbps":80}}"#.utf8)
        let negotiated = router.response(
            for: mutationRequest("/api/v1/playback/sessions", bodyLength: capabilityBody.count),
            body: capabilityBody
        )
        XCTAssertEqual(negotiated.statusCode, 200)
        XCTAssertEqual(receivedCapabilities?.mediaSource, true)
        XCTAssertEqual(receivedCapabilities?.screenWidth, 1920)

        let unknownCapabilityBody = Data(#"{"itemID":"movie-1","audioTrackID":1,"capabilities":{"nativeHLS":false,"mediaSource":true,"videoCodecs":["h264"],"audioCodecs":["aac"],"screenWidth":1920,"screenHeight":1080,"hdrDisplay":false,"measuredDownlinkMbps":80,"unsafe":true}}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/sessions", bodyLength: unknownCapabilityBody.count),
            body: unknownCapabilityBody
        ).statusCode, 400)

        let statusPath = "/api/v1/playback/sessions/\(sessionID)"
        let status = router.response(for: request(statusPath, token: "viewer"))
        XCTAssertEqual(status.statusCode, 200)
        XCTAssertEqual(try JSONDecoder().decode(ServerHLSPlaybackDescriptor.self, from: status.body), descriptor)
        XCTAssertEqual(router.response(for: request(statusPath, token: "other")).statusCode, 404)

        let manifestPath = "/api/v1/playback/hls/\(sessionID)/index.m3u8"
        let manifest = router.response(for: request(manifestPath, token: "viewer"))
        XCTAssertEqual(manifest.statusCode, 200)
        XCTAssertEqual(manifest.contentType, "application/vnd.apple.mpegurl")
        XCTAssertEqual(router.response(for: request(manifestPath, token: "other")).statusCode, 404)
        XCTAssertEqual(router.response(for: request(
            "/api/v1/playback/hls/\(sessionID)/../secret", token: "viewer"
        )).statusCode, 404)

        let cancel = Data()
        XCTAssertEqual(router.response(
            for: mutationRequest(
                "/api/v1/playback/sessions/\(sessionID)/cancel", bodyLength: cancel.count
            ), body: cancel
        ).statusCode, 204)
        XCTAssertEqual(cancelledBy, "viewer")
        let delete = "DELETE \(statusPath) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\nX-MediaLIB-CSRF: known-csrf\r\nContent-Length: 0\r\n\r\n"
        XCTAssertEqual(router.response(for: delete).statusCode, 204)
    }

    /// 音量不再通过 `slider-vertical` 退回各浏览器不同的系统外观；它与进度、倍速
    /// 共用同一个横向 `.ui-range` primitive。
    func testVolumeUsesTheSharedHorizontalRangePrimitive() {
        let style = ServerWebMediaDetailPage.style
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: safeDetail, csrfToken: "csrf",
            showAdministration: false, sidebarExtras: .empty
        )

        XCTAssertTrue(html.contains("id=\"playback-volume\" class=\"ui-range ui-range-on-media\""))
        XCTAssertFalse(html.contains("orient=\"vertical\""))
        XCTAssertFalse(style.contains("-webkit-appearance: slider-vertical"))
        XCTAssertTrue(style.contains(".volume-control input[type=\"range\"] { width: 100%"))
    }

    /// `canPlayType` 对 MKV 经常是假阴性，不能在尝试播放或音频重封装之前就把按钮
    /// 禁掉。真实失败仍会根据它给出更准确的恢复文案。
    func testBrowserCapabilityProbeIsAdvisoryAndPlaybackProgressClearsStaleUI() {
        let script = ServerWebMediaDetailPage.script

        XCTAssertTrue(script.contains("const browserCanPlay"))
        XCTAssertFalse(script.contains("else if (!browserCanPlay())"))
        XCTAssertTrue(script.contains("player.currentTime > lastAdvancingTime + 0.01"))
        XCTAssertTrue(script.contains("if (playerError && !playerError.hidden) setStatus('正在播放。')"))
        XCTAssertTrue(script.contains("sourceRevision !== playbackSourceRevision"))
    }

    func testDownloadRouteRequiresSeparatePermissionAndUsesGenericAttachmentName() {
        let asset = ServerMediaAsset(
            id: "movie-1",
            fileURL: URL(fileURLWithPath: "/Users/example/Private Title.mkv"),
            byteLength: 42
        )
        let allowed = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaAssetProvider: { itemID, principal, permission in
                guard itemID == "movie-1",
                      permission == .downloadMedia,
                      principal.permissions.contains(.downloadMedia)
                else { return nil }
                return asset
            },
            authenticationProvider: { head in
                head.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia, .playMedia, .downloadMedia], libraryGrants: [:]
                    )
                    : nil
            }
        )
        let response = allowed.response(for: request("/api/v1/download/movie-1", token: "viewer"))
        let headers = String(data: response.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.declaredContentLength, 42)
        XCTAssertTrue(headers.contains("Content-Disposition: attachment; filename=\"MediaLIB-download.mkv\""))
        XCTAssertFalse(headers.contains("Private Title"))

        let denied = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaAssetProvider: { _, principal, permission in
                principal.permissions.contains(.downloadMedia) && permission == .downloadMedia ? asset : nil
            },
            authenticationProvider: { head in
                head.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia, .playMedia], libraryGrants: [:]
                    )
                    : nil
            }
        )
        XCTAssertEqual(denied.response(for: request("/api/v1/download/movie-1", token: "viewer")).statusCode, 404)
    }

    func testUserPolicyNarrowsDirectDownloadRemoteAndHLSSessionAccess() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerPlaybackPolicyTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        _ = try ServerIdentityRepository(database: database).createUser(
            id: "viewer", username: "viewer", displayName: "Viewer"
        )
        let experience = ServerExperienceRepository(database: database)
        var deniedPolicy = ServerUserPolicy()
        deniedPolicy.directPlayAllowed = false
        deniedPolicy.remuxAllowed = false
        deniedPolicy.transcodeAllowed = false
        deniedPolicy.downloadAllowed = false
        _ = try experience.saveUserPolicy(userID: "viewer", value: deniedPolicy, expectedVersion: 0)

        let asset = ServerMediaAsset(
            id: "movie-1", fileURL: directory.appendingPathComponent("movie.mkv"), byteLength: 42
        )
        let sessionID = String(repeating: "a", count: 32)
        let descriptor = ServerHLSPlaybackDescriptor(
            sessionID: sessionID, mode: "hlsRemux", durationSeconds: 60,
            actualStartSeconds: 0, reason: "containerCompatibility",
            mediaURL: "/api/v1/playback/hls/\(sessionID)/index.m3u8"
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaAssetProvider: { _, _, _ in asset },
            hlsSessionProvider: { _, _, _ in descriptor },
            experienceRepository: experience,
            authenticationProvider: { head in
                head.contains("Bearer viewer") ? ServerRequestPrincipal(
                    userID: "viewer", deviceID: "device", sessionID: "session",
                    permissions: [.viewMedia, .playMedia, .downloadMedia, .transcodePlayback],
                    libraryGrants: [:]
                ) : nil
            },
            csrfToken: "known-csrf"
        )
        XCTAssertEqual(router.response(for: request("/api/v1/stream/movie-1", token: "viewer")).statusCode, 404)
        XCTAssertEqual(router.response(for: request("/api/v1/download/movie-1", token: "viewer")).statusCode, 404)
        let hlsBody = Data(#"{"itemID":"movie-1","audioTrackID":0}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/sessions", bodyLength: hlsBody.count), body: hlsBody
        ).statusCode, 403)

        var allowedPolicy = deniedPolicy
        allowedPolicy.directPlayAllowed = true
        allowedPolicy.remuxAllowed = true
        allowedPolicy.downloadAllowed = true
        allowedPolicy.remoteAccessAllowed = false
        _ = try experience.saveUserPolicy(userID: "viewer", value: allowedPolicy, expectedVersion: 1)
        XCTAssertEqual(router.response(for: request("/api/v1/stream/movie-1", token: "viewer")).statusCode, 200)
        XCTAssertEqual(router.response(
            for: request("/api/v1/stream/movie-1", token: "viewer"), clientAddressKey: "192.168.1.20"
        ).statusCode, 404)
        XCTAssertEqual(router.response(for: request("/api/v1/download/movie-1", token: "viewer")).statusCode, 200)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/sessions", bodyLength: hlsBody.count), body: hlsBody
        ).statusCode, 200)
    }

    func testRemoteStreamUsesFull200WithoutRangeAndBounded206WithRange() {
        let bytes = Data((0..<64).map(UInt8.init))
        let fetcher = ServerRemoteAssetFetcher(
            responseOverride: { _, offset, length in
                guard let offset, let length else { return nil }
                return bytes.subdata(in: Int(offset)..<Int(offset + length))
            },
            mediaLengthOverride: { _ in Int64(bytes.count) }
        )
        let asset = ServerMediaAsset(
            id: "remote-1",
            remoteURL: URL(string: "https://nas.local/emby/Videos/1/stream")!,
            byteLength: Int64(bytes.count)
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaAssetProvider: { id, _, permission in
                id == asset.id && permission == .playMedia ? asset : nil
            },
            remoteAssetFetcher: fetcher,
            authenticationProvider: { _ in .testAdministrator() }
        )

        let full = router.response(for: request("/api/v1/stream/remote-1", token: "viewer"))
        XCTAssertEqual(full.statusCode, 200)
        XCTAssertEqual(full.declaredContentLength, bytes.count)
        XCTAssertEqual(full.contentType, "video/mp4")
        if case let .remoteFull(payload) = full.payload {
            var received = Data()
            XCTAssertTrue(payload.stream { received.append($0); return true })
            XCTAssertEqual(received, bytes)
        } else {
            XCTFail("A no-Range remote GET must stay a streamed full entity")
        }

        let partial = router.response(for:
            "GET /api/v1/stream/remote-1 HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer viewer\r\nRange: bytes=8-15\r\n\r\n"
        )
        XCTAssertEqual(partial.statusCode, 206)
        XCTAssertEqual(partial.body, bytes.subdata(in: 8..<16))
    }

    func testEpisodeNavigationControlsUseSafeServerDerivedLinks() {
        let detail = ServerMediaItemDetail(
            id: "episode-2", type: "episode", title: "第二集", originalTitle: nil, year: nil,
            overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil, artworkAvailable: false,
            backdropAvailable: false, canDirectPlay: true, canTranscode: false,
            previousEpisode: ServerEpisodeNavigation(id: "episode-1", title: "<上一集>"),
            nextEpisode: ServerEpisodeNavigation(id: "episode-3", title: "下一集")
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false,
            sidebarExtras: .empty
        )

        // 换集是导航，不是播放控制：传输栏里不再有上一集/下一集按钮，选集留在
        // 右侧面板。自动播放下一集仍然需要目标，它作为同源文档属性传递。
        XCTAssertFalse(html.contains("id=\"previous-episode\""))
        XCTAssertFalse(html.contains("id=\"next-episode\""))
        XCTAssertTrue(html.contains("data-next-episode-path=\"/item/episode-3\""))
        // 播放键两侧是常规的双三角快退/快进，不是"重播 N 秒"的环形箭头。
        XCTAssertTrue(html.contains("id=\"seek-backward\""))
        XCTAssertTrue(html.contains("id=\"seek-forward\""))
        XCTAssertTrue(html.contains("class=\"ui-btn ui-btn-ghost ui-btn-sm app-back\" href=\"/\""))
        XCTAssertFalse(html.contains("<上一集>"))
    }

    func testDetailPageUsesAuthorizedOpaquePosterWhenArtworkExists() {
        let detail = ServerMediaItemDetail(
            id: "movie id+1", type: "movie", title: "海报测试", originalTitle: nil,
            year: nil, overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil,
            artworkAvailable: true, backdropAvailable: false,
            canDirectPlay: true, canTranscode: false
        )
        let html = ServerWebMediaDetailPage.render(
            serverName: "测试服务器", detail: detail, csrfToken: "csrf", showAdministration: false,
            sidebarExtras: .empty
        )

        XCTAssertTrue(html.contains("src=\"/api/v1/images/movie%20id%2B1/poster?size=640\""))
        XCTAssertTrue(html.contains("loading=\"eager\""))
        XCTAssertTrue(html.contains("decoding=\"async\""))
        XCTAssertFalse(html.contains("role=\"img\""))
    }

    func testHomeCardsDeepLinkWithEncodedIdentifierAndEscapedTitle() {
        let detail = ServerMediaItemDetail(
            id: "movie id+1", type: "movie", title: "Movie", originalTitle: nil,
            year: nil, overview: nil, genres: [], communityRating: nil, runtimeSeconds: nil,
            videoCodec: nil, audioCodec: nil, resolution: nil,
            artworkAvailable: false, backdropAvailable: false,
            canDirectPlay: false, canTranscode: false
        )
        let router = makeRouter(detail: detail)
        let response = router.response(for: request("/", token: "viewer"))
        let html = String(data: response.body, encoding: .utf8) ?? ""

        XCTAssertEqual(response.statusCode, 200)
        // 海报即播放：卡片链接直接带上自动开播的锚点。
        XCTAssertTrue(html.contains("href=\"/item/movie%20id%2B1#play\""))
        XCTAssertTrue(html.contains("content=\"known-csrf\""))
        XCTAssertTrue(html.contains("跳到主要内容"))
        let detailHTML = ServerWebMediaDetailPage.render(
            serverName: "Server", detail: detail, csrfToken: "csrf", showAdministration: false,
            sidebarExtras: .empty
        )
        XCTAssertTrue(detailHTML.contains("id=\"retry-source\""))
        XCTAssertTrue(detailHTML.contains("重新检测媒体源"))
    }

    func testDetailHeadOmitsBodyAndProviderFailureIsSafe503() {
        let head = makeRouter().response(for: request("/api/v1/items/movie-1", token: "viewer", method: "HEAD"))
        let failing = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaDetailProvider: { _, _ in throw CocoaError(.fileReadCorruptFile) },
            authenticationProvider: { _ in .testAdministrator() }
        ).response(for: request("/item/movie-1", token: "viewer"))

        XCTAssertEqual(head.statusCode, 200)
        XCTAssertTrue(head.body.isEmpty)
        XCTAssertGreaterThan(head.declaredContentLength, 0)
        XCTAssertEqual(failing.statusCode, 503)
        XCTAssertEqual(String(data: failing.body, encoding: .utf8), "{\"error\":\"Service Unavailable\"}")
    }

    func testPlaybackStateMutationUsesAuthenticatedPrincipalAndRejectsUnknownFields() throws {
        var receivedUserID: String?
        let state = ServerMediaUserState(
            itemID: "movie-1", positionSeconds: 300, progress: 0.5,
            isWatched: false, playCount: 1,
            lastPlayedAt: Date(timeIntervalSince1970: 100),
            updatedAt: Date(timeIntervalSince1970: 101)
        )
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaPlaybackStateUpdater: { itemID, request, principal in
                receivedUserID = principal.userID
                return itemID == "movie-1" && request.event == .progress ? state : nil
            },
            authenticationProvider: { head in
                head.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia, .playMedia], libraryGrants: [:]
                    )
                    : nil
            },
            csrfToken: "known-csrf"
        )
        let validBody = Data(#"{"event":"progress","positionSeconds":300,"durationSeconds":600}"#.utf8)
        let response = router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: validBody.count),
            body: validBody
        )
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(receivedUserID, "viewer")
        XCTAssertEqual(try decoder.decode(ServerMediaUserState.self, from: response.body), state)

        let injected = Data(#"{"event":"progress","positionSeconds":300,"durationSeconds":600,"userID":"admin"}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: injected.count),
            body: injected
        ).statusCode, 400)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/unknown", bodyLength: validBody.count),
            body: validBody
        ).statusCode, 404)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/playback/state/movie-1", bodyLength: validBody.count, token: "missing"),
            body: validBody
        ).statusCode, 401)
    }

    func testMediaPreferenceMutationUsesAuthenticatedPrincipalAndSingleFieldBody() throws {
        var received: (itemID: String, preference: ServerUserMediaPreferenceUpdate, userID: String)?
        let expected = ServerMediaUserPreference(isFavorite: true, isWatchlist: false, rating: nil)
        let router = LocalHTTPRouter(
            serverID: "server", serverName: "Server",
            mediaPreferenceUpdater: { itemID, preference, principal in
                received = (itemID, preference, principal.userID)
                return expected
            },
            authenticationProvider: { requestHead in
                requestHead.contains("Authorization: Bearer viewer")
                    ? ServerRequestPrincipal(
                        userID: "viewer", deviceID: "device", sessionID: "session",
                        permissions: [.viewMedia], libraryGrants: [:]
                    ) : nil
            },
            csrfToken: "known-csrf"
        )
        let body = Data(#"{"favorite":true}"#.utf8)
        let response = router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: body.count),
            body: body
        )

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(received?.itemID, "movie-1")
        XCTAssertEqual(received?.preference, .favorite(true))
        XCTAssertEqual(received?.userID, "viewer")
        XCTAssertEqual(try JSONDecoder().decode(ServerMediaUserPreference.self, from: response.body), expected)

        let combined = Data(#"{"favorite":true,"watchlist":true}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: combined.count),
            body: combined
        ).statusCode, 400)
        let invalidRating = Data(#"{"rating":5.5}"#.utf8)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: invalidRating.count),
            body: invalidRating
        ).statusCode, 400)
        XCTAssertEqual(router.response(
            for: mutationRequest("/api/v1/user-media/preferences/movie-1", bodyLength: body.count, token: "missing"),
            body: body
        ).statusCode, 401)
    }

    private func makeRouter(detail: ServerMediaItemDetail? = nil) -> LocalHTTPRouter {
        let item = detail ?? safeDetail
        let snapshot = ServerLibrarySnapshot(
            summary: ServerLibrarySummary(totalItemCount: 1, countsByType: [item.type: 1]),
            items: ServerLibraryItemsResponse(
                totalItemCount: 1,
                items: [ServerLibraryItem(
                    id: item.id, type: item.type, title: item.title,
                    year: item.year, artworkAvailable: item.artworkAvailable,
                    // 带上播放痕迹，条目才会落进「最近播放」那一排。
                    //
                    // 首页栏目按客户端 `HomeModuleKind.defaultOrder` 对齐之后，网页
                    // 特有的「电影与视频」栏目没有了；真实服务器上这类影片会出现在
                    // 「最近添加」里（首页路由另外查一次），但这个夹具不提供那份数据。
                    // 这条用例要验的是"货架卡片的链接编码与标题转义"，所以让它落进一
                    // 个两端都有的栏目。
                    userState: ServerMediaUserState(
                        itemID: item.id, positionSeconds: 30, progress: 0.2, isWatched: false,
                        playCount: 1, lastPlayedAt: Date(timeIntervalSince1970: 10),
                        updatedAt: Date(timeIntervalSince1970: 10)
                    )
                )]
            )
        )
        return LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            librarySnapshotProvider: { _ in snapshot },
            mediaDetailProvider: { requestedID, _ in requestedID == item.id ? item : nil },
            authenticationProvider: { requestHead in
                guard requestHead.contains("Authorization: Bearer viewer") else { return nil }
                return ServerRequestPrincipal(
                    userID: "viewer", deviceID: "device", sessionID: "session",
                    permissions: [.viewMedia, .playMedia, .transcodePlayback], libraryGrants: [:]
                )
            },
            csrfToken: "known-csrf"
        )
    }

    /// 资源原文。版面这一类断言钉的是 CSS/JS 的契约，页面 HTML 里看不到它们。
    private func asset(_ path: String) -> String {
        let response = makeRouter().response(for: "GET \(path) HTTP/1.1\r\nHost: localhost\r\n\r\n")
        XCTAssertEqual(response.statusCode, 200, path)
        return String(data: response.body, encoding: .utf8) ?? ""
    }

    private func request(_ path: String, token: String, method: String = "GET") -> String {
        "\(method) \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\n\r\n"
    }

    private func mutationRequest(_ path: String, bodyLength: Int, token: String = "viewer") -> String {
        "POST \(path) HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer \(token)\r\nContent-Type: application/json\r\nContent-Length: \(bodyLength)\r\nX-MediaLIB-CSRF: known-csrf\r\n\r\n"
    }

    private func headerValue(named name: String, in headers: String) -> String? {
        headers
            .split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.hasPrefix("\(name): ") }
            .map { String($0.dropFirst(name.count + 2)).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    // MARK: - 播放器版面

    /// 黑底的那个盒子必须和画面一样大，否则宽屏档会露出一圈黑。
    ///
    /// 高度预算从前只钳住舞台，卡片却是整列宽：1855×980 的窗口里，宽屏档实测每边
    /// 41px 纯黑。预算必须挂在**卡片**上，舞台百分百填满卡片。
    func testPlayerCardCarriesTheHeightBudgetSoNoBlackShowsBesideThePicture() {
        let style = asset("/assets/player.css")

        XCTAssertTrue(style.contains("max-width: calc(var(--player-height-budget, min(78dvh, 900px)) * (var(--player-aspect, 16 / 9)))"))
        // 舞台不再自己定宽——两处同时定尺寸正是黑边的来源。
        XCTAssertFalse(
            style.contains("max-width: calc(min(78dvh, 900px) * (var(--player-aspect, 16 / 9)))"),
            "舞台不该再带自己的宽度上限"
        )
        // 宽屏档与"本来就没有选集面板"的页面共用更宽松的预算：它们就是宽屏。
        XCTAssertTrue(style.contains(".watch-layout.is-wide .player-card,"))
        XCTAssertTrue(style.contains(".watch-layout:not(.is-episode-workspace) .player-card { --player-height-budget:"))
        // 比例由脚本挂在工作区上，卡片与舞台都要读得到（自定义属性只向下继承）。
        let script = asset("/assets/player.js")
        XCTAssertTrue(script.contains("(workspace ?? playerStage).style.setProperty("))
    }

    /// 网页全屏必须真的铺满，而不是把正文推到视口之外。
    ///
    /// 外壳的 `.app-main` 写着 `grid-column: 2`（第一列是侧栏）。全屏只把列数改成
    /// 1、却没有改这一句时，正文落进一条宽度 0 的隐式第二列——实测 `{x: 1920, w: 0}`，
    /// 点下去整页什么都没有。
    func testWebFullscreenMovesTheContentColumnBackToTheFirstTrack() {
        let style = asset("/assets/player.css")

        XCTAssertTrue(style.contains("body.is-web-fullscreen .app-main {"))
        XCTAssertTrue(style.contains("grid-column: 1;"))
        XCTAssertTrue(style.contains("max-width: none;"))
        // 选集面板那条 340px 的列在全屏下也要收掉，否则画面右边空出一条。
        XCTAssertTrue(style.contains("body.is-web-fullscreen .watch-layout {"))
        // 播放器之外的页面内容一件都不留。
        XCTAssertTrue(style.contains("body.is-web-fullscreen .client-detail-section { display: none; }"))
    }

    /// 尺寸切换按钮只在"播放器旁边真的坐着一块面板"时出现。
    ///
    /// 只有一集的剧集、电影、音乐会录像本来就是单列：切到宽屏什么都不会变，再切
    /// 回默认同样什么都不会变——那颗按钮点下去没有任何反应。
    func testLayoutToggleHidesItselfWhenThereIsNoSidePanelToTradeAway() {
        let script = asset("/assets/player.js")

        XCTAssertTrue(script.contains("const layoutToggleIsMeaningful = () => Boolean(workspace)"))
        XCTAssertTrue(script.contains("workspace.classList.contains('is-episode-workspace')"))
        XCTAssertTrue(script.contains("defaultSizeButton.hidden = !meaningful || playerLayout === 'default'"))
        XCTAssertTrue(script.contains("wideSizeButton.hidden = !meaningful || playerLayout === 'wide'"))
        // 拖动窗口跨过堆叠断点时，有效性也跟着变。
        XCTAssertTrue(script.contains("window.addEventListener('resize', syncLayoutButtons"))
    }

    /// 选集面板只在"并排"时才对齐播放器高度。
    ///
    /// 宽屏与窄屏堆叠下它都在播放器下方，这时把它撑到播放器那么高，得到的是一张
    /// 几百像素高、里面只有一行内容的空卡片。
    func testEpisodePanelOnlyMatchesThePlayerHeightWhenItSitsBesideIt() {
        let script = asset("/assets/player.js")

        XCTAssertTrue(script.contains("const sideBySide = workspace.classList.contains('is-episode-workspace')"))
        XCTAssertTrue(script.contains("&& !workspace.classList.contains('is-wide')"))
        XCTAssertTrue(script.contains("if (!playerCard || !sideBySide || document.body.classList.contains('is-web-fullscreen'))"))
        // 切换档位是离散动作，直接量而不是排 rAF——页面不可见时 rAF 根本不跑，
        // 排队会把上一档的高度上限留在行内样式里。
        XCTAssertFalse(
            script.contains("document.body.classList.remove('is-web-fullscreen');\n        scheduleEpisodePanelHeight();"),
            "切换尺寸时必须同步量一次"
        )
    }
}
