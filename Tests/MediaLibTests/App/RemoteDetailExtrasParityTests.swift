import XCTest
@testable import MediaLib
@testable import MediaLibCore

/// 远程来源之间的一致性：Emby 之外的连接器要么走自己的接口，要么明说没有，
/// 绝不能悄悄落进别人的分支。
final class RemoteDetailExtrasParityTests: XCTestCase {
    /// 仓库里每一处 `if plex { plexService } else { embyService }` 都有同一个缺口：
    /// **Mlink 也会落进 Emby 分支**。它说的是 Mlink 契约，那个请求只会失败，然后
    /// 在日志里留下一条「Mlink 详情扩展加载失败」，而读者看到的是详情栏永远空着。
    func testEveryRemoteKindRoutesToItsOwnDetailAPIOrToNone() {
        XCTAssertEqual(AppState.detailExtrasAPI(for: .emby), .embyCompatible)
        XCTAssertEqual(AppState.detailExtrasAPI(for: .jellyfin), .embyCompatible)
        XCTAssertEqual(AppState.detailExtrasAPI(for: .plex), .plex)
        XCTAssertNil(AppState.detailExtrasAPI(for: .mlink), "Mlink 不说 Emby 协议")
        for kind in [MediaSourceKind.local, .smb, .ftp, .url] {
            XCTAssertNil(AppState.detailExtrasAPI(for: kind), kind.rawValue)
        }
    }

    /// 制作信息此前**只**认 TMDB：没有配 TMDB key 的 Emby 库，详情页的「制作」
    /// 一栏永远空着，而这些字段服务器一直都在返回。
    func testServerProductionMetadataFillsInWhenTMDBHasNone() throws {
        let server = EmbyDetailExtras(
            cast: [TMDBPerson(
                id: 1, stableID: "emby-person-1", name: "某演员", role: "主角",
                profileURL: "https://nas.local/emby/Items/9/Images/Primary", category: "cast",
                department: "Acting"
            )],
            crew: [],
            images: [],
            tmdbID: nil,
            tmdbKind: nil,
            imdbID: nil,
            status: "Continuing",
            contentRating: "TV-14",
            countries: ["美国"],
            productionCompanies: ["某制片厂"]
        )

        let merged = try XCTUnwrap(AppState.mergedDetailEnrichment(server: server, tmdb: nil, provider: "Emby"))

        XCTAssertEqual(merged.status, "Continuing")
        XCTAssertEqual(merged.contentRating, "TV-14")
        XCTAssertEqual(merged.countries, ["美国"])
        XCTAssertEqual(merged.productionCompanies, ["某制片厂"])
        // 头像地址原样带下去：它由服务端在取图时授权与代理，不进网页。
        XCTAssertEqual(merged.cast.first?.profileURL, "https://nas.local/emby/Items/9/Images/Primary")
    }

    /// TMDB 有值时以它为准：更完整，而且已经按用户选的语言本地化过。
    func testTMDBMetadataStillWinsWhenBothSidesHaveIt() throws {
        let server = EmbyDetailExtras(
            cast: [], crew: [], images: [], tmdbID: "603", tmdbKind: "movie", imdbID: nil,
            status: "Continuing", contentRating: "TV-14",
            countries: ["美国"], productionCompanies: ["Emby 给的制片厂"]
        )
        let tmdb = TMDBEnrichment(
            title: "黑客帝国", cast: [], crew: [], similar: [], images: [],
            status: "Released", contentRating: "R",
            countries: ["美国", "澳大利亚"], productionCompanies: ["Warner Bros."]
        )

        let merged = try XCTUnwrap(AppState.mergedDetailEnrichment(server: server, tmdb: tmdb, provider: "Emby"))

        XCTAssertEqual(merged.status, "Released")
        XCTAssertEqual(merged.contentRating, "R")
        XCTAssertEqual(merged.countries, ["美国", "澳大利亚"])
        XCTAssertEqual(merged.productionCompanies, ["Warner Bros."])
    }
}
