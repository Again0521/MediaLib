import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer
@testable import MediaLibServerProtocol

/// 「侧栏上的数字」与「点进去看到的条数」必须是同一个数。
///
/// 三处不一致都以同一种方式暴露给用户——数字偏大、点进去内容对不上：
///   1. 远程分组徽标数了全部行（含分集），而作用域页只列顶层；
///   2. 作用域 ID 一边按归一化键取摘要、一边按原始路径取摘要，写法不一致的条目
///      直接落在作用域之外；
///   3. 本地分类页的题材下拉来自含远程的集合，选中即空网格。
final class ServerRemoteScopeConsistencyTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibRemoteScopeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: temporaryDirectory.appendingPathComponent("catalog.sqlite"))
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    /// 徽标 == 该作用域 `browse` 的总数。分集不能把徽标顶上去。
    func testRemoteGroupBadgeEqualsWhatTheScopedPageActuallyLists() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        let libraryPath = "emby://nas/emby-1/library/v1/type/tvshows/name/%E5%89%A7%E9%9B%86"
        try mediaRepository.upsert(MediaItem(
            id: "series-1", type: .tvShow, title: "某剧",
            sourcePath: libraryPath, filePath: "https://nas/series.mp4"
        ))
        // 二十集：它们在库里是真实存在的行，但作用域页一集都不列。
        for index in 1...20 {
            try mediaRepository.upsert(MediaItem(
                id: "episode-\(index)", type: .episode, title: "第 \(index) 集",
                sourcePath: libraryPath, parentID: "series-1",
                filePath: "https://nas/e\(index).mp4"
            ))
        }

        let catalog = ServerLibraryCatalog(database: database)
        let group = try XCTUnwrap(catalog.remoteSourceGroups(for: .testAdministrator()).first)
        let page = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 100, remoteScopeID: group.id), for: .testAdministrator()
        )

        XCTAssertEqual(group.itemCount, page.totalItemCount, "分组徽标与作用域页总数必须相等")
        XCTAssertEqual(group.itemCount, 1, "二十集不该把徽标顶成 21")
        XCTAssertEqual(group.libraries.first?.itemCount, 1, "资料库行的徽标同理")
    }

    /// 路径写法不一致时，「全部」仍要取到该服务器的全部条目。
    ///
    /// 分组按 `canonicalKey` 聚合，而作用域解析曾经按原始路径取摘要：`EMBY://Host/x`
    /// 下的条目算出来的 ID 与侧栏发出的 ID 对不上，徽标说 3、页面只有 2。
    func testWholeServerScopeResolvesAcrossPathCaseAndTrailingSlash() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        for (id, path) in [
            ("a", "emby://nas/emby-1/library/v1"),
            ("b", "EMBY://NAS/emby-1/library/v2"),
            ("c", "emby://nas/emby-1/")
        ] {
            try mediaRepository.upsert(MediaItem(
                id: id, type: .movie, title: id.uppercased(),
                sourcePath: path, filePath: "https://nas/\(id).mp4"
            ))
        }

        let catalog = ServerLibraryCatalog(database: database)
        let groups = try catalog.remoteSourceGroups(for: .testAdministrator())
        let group = try XCTUnwrap(groups.first)
        let page = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 100, remoteScopeID: group.id), for: .testAdministrator()
        )

        XCTAssertEqual(groups.count, 1, "同一台服务器只能有一个分组")
        XCTAssertEqual(group.itemCount, 3)
        XCTAssertEqual(page.items.map(\.id).sorted(), ["a", "b", "c"], "写法不一致的条目不得掉出作用域")
        XCTAssertEqual(group.itemCount, page.totalItemCount)
    }

    /// 逐资料库入口在路径写法不一致时同样要解析得到。
    func testPerLibraryScopeResolvesRegardlessOfPathCase() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "movie", type: .movie, title: "电影",
            sourcePath: "EMBY://NAS/emby-1/library/v1/type/movies/name/%E7%94%B5%E5%BD%B1",
            filePath: "https://nas/m.mp4"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let group = try XCTUnwrap(catalog.remoteSourceGroups(for: .testAdministrator()).first)
        let library = try XCTUnwrap(group.libraries.first)
        let page = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 100, remoteScopeID: library.id), for: .testAdministrator()
        )

        XCTAssertEqual(library.itemCount, page.totalItemCount)
        XCTAssertEqual(page.items.map(\.id), ["movie"])
    }

    /// 本地分类页的题材下拉不得列出只存在于远程条目的题材。
    func testLocalFacetsExcludeGenresThatOnlyExistOnRemoteItems() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "local", name: "本地", path: "/Volumes/M", mediaType: .movie))
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "local-movie", type: .movie, title: "本地电影",
            sourcePath: "/Volumes/M", filePath: "/Volumes/M/a.mp4", genre: "剧情"
        ))
        try mediaRepository.upsert(MediaItem(
            id: "remote-movie", type: .movie, title: "远程电影",
            sourcePath: "emby://nas/emby-1/library/v1", filePath: "https://nas/b.mp4",
            metadataProvider: "Emby", genre: "只有远程才有的题材"
        ))

        let facets = try ServerLibraryCatalog(database: database)
            .facets(type: "movie", group: nil, for: .testAdministrator())

        XCTAssertTrue(facets.genres.contains("剧情"))
        XCTAssertFalse(
            facets.genres.contains("只有远程才有的题材"),
            "选中它必然筛出空网格——本地分类页不该提供这个选项"
        )
    }

    /// Mlink 条目要被当成远程来源：能拿到封面代理地址，也要带来源角标。
    ///
    /// `isTrustedRemoteItem` 曾经手抄 scheme 列表并漏了 `mlink://`，于是整台 Mlink
    /// 服务器的内容在网页上没有封面。
    func testMlinkItemsAreTreatedAsRemoteSourceForArtworkAndBadge() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "mlink-1", name: "书房 Mlink", path: "mlink://mlink-1"))
        try mediaRepository.upsert(MediaItem(
            id: "mlink-movie", type: .movie, title: "远端电影",
            posterPath: "https://peer.local/api/v1/images/x/poster",
            sourcePath: "mlink://mlink-1/library/v1", filePath: "https://peer.local/stream.mp4",
            metadataProvider: "Mlink"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let group = try XCTUnwrap(catalog.remoteSourceGroups(for: .testAdministrator()).first)
        let page = try catalog.browse(
            ServerLibraryQuery(offset: 0, limit: 24, remoteScopeID: group.id), for: .testAdministrator()
        )
        let card = try XCTUnwrap(page.items.first)
        let artwork = try catalog.publicArtwork(id: "mlink-movie", kind: .poster, for: .testAdministrator())

        XCTAssertEqual(group.kind, .mlink)
        XCTAssertTrue(card.isRemoteSource, "Mlink 条目必须标成远程来源")
        XCTAssertEqual(card.remoteSourceKind, .mlink)
        XCTAssertEqual(artwork?.remoteURL?.host, "peer.local", "Mlink 封面必须能经服务端代理")
    }

    /// 远程封面地址没有文件扩展名，不能因此被挡掉。
    ///
    /// Emby/Jellyfin 的海报地址是 `/Items/<id>/Images/Primary?…`，Plex 是
    /// `/photo/:/transcode?…` —— **两者的 `pathExtension` 都是空的**。而
    /// `publicArtwork` 对远程地址也要求扩展名落在图片白名单里，于是每一个远程条目
    /// 的封面请求都在授权层返回 nil、路由回 404：网页上整台 Emby 一张封面都不显示。
    /// 那份白名单是给"要不要打开这个本地文件"用的守卫；远程字节的安全性由
    /// "只代理已连接远程服务器的地址" + "一律由服务端派生成 JPEG 再发出"保证。
    func testRemoteArtworkURLsWithoutFileExtensionAreStillServed() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        try sourceRepository.save(MediaSource(id: "emby-1", name: "客厅 Emby", path: "emby://nas/emby-1"))
        try mediaRepository.upsert(MediaItem(
            id: "emby-movie", type: .movie, title: "远程电影",
            posterPath: "https://nas.local:8096/Items/abc123/Images/Primary?maxWidth=700&quality=90&api_key=tok",
            backdropPath: "https://nas.local:32400/photo/:/transcode?width=320",
            sourcePath: "emby://nas/emby-1/library/v1", filePath: "https://nas.local:8096/stream.mp4",
            metadataProvider: "Emby"
        ))

        let catalog = ServerLibraryCatalog(database: database)
        let poster = try catalog.publicArtwork(id: "emby-movie", kind: .poster, for: .testAdministrator())
        let backdrop = try catalog.publicArtwork(id: "emby-movie", kind: .backdrop, for: .testAdministrator())

        XCTAssertEqual(poster?.remoteURL?.host, "nas.local", "Emby 海报地址本来就没有扩展名")
        XCTAssertEqual(backdrop?.remoteURL?.host, "nas.local", "Plex 的转码图片路由同样没有扩展名")
        // 远端声明的长度一律不信，字节数由服务端的有界读取决定。
        XCTAssertEqual(poster?.byteLength, 0)
    }

    /// 本地封面仍然只认图片扩展名——那份白名单守的是"要不要打开这个本地文件"。
    func testLocalArtworkStillRequiresAnImageFileExtension() throws {
        let sourceRepository = SourceRepository(database: database)
        let mediaRepository = MediaRepository(database: database)
        let directory = temporaryDirectory.appendingPathComponent("art", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let disguised = directory.appendingPathComponent("secret.sqlite")
        try Data("not an image".utf8).write(to: disguised)
        try sourceRepository.save(MediaSource(id: "local", name: "本地", path: directory.path, mediaType: .movie))
        try mediaRepository.upsert(MediaItem(
            id: "local-movie", type: .movie, title: "本地电影",
            posterPath: disguised.path, sourcePath: directory.path,
            filePath: directory.appendingPathComponent("a.mp4").path
        ))

        XCTAssertNil(
            try ServerLibraryCatalog(database: database)
                .publicArtwork(id: "local-movie", kind: .poster, for: .testAdministrator())
        )
    }

    /// 远程来源的 scheme 列表只能有一份。
    func testExpandableSchemesReuseTheSharedRemotePathPolicy() {
        XCTAssertEqual(
            ServerSourceAuthorizationResolver.expandableSchemes,
            RemoteLibraryPathPolicy.mediaServerSchemes
        )
    }
}
