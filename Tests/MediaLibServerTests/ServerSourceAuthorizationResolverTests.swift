import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

/// 授权展开是这套服务端唯一一处"路径前缀决定可见性"的地方，因此它的边界必须
/// 被逐条钉死：多一个字符、少一个斜杠、嵌套一层私密来源，都是可见性事故。
final class ServerSourceAuthorizationResolverTests: XCTestCase {
    private func source(
        _ id: String,
        _ path: String,
        _ mediaType: MediaType = .auto
    ) -> MediaSource {
        MediaSource(id: id, name: id, path: path, mediaType: mediaType)
    }

    private func resolve(
        sources: [MediaSource],
        paths: [String],
        authorized: Set<String>? = nil
    ) -> Set<String> {
        ServerSourceAuthorizationResolver.authorizedSourcePaths(
            sources: sources,
            concreteSourcePaths: paths,
            isAuthorized: { authorized?.contains($0.id) ?? true }
        )
    }

    func testRemoteRootAuthorizesItsOwnLibrarySubtree() {
        let result = resolve(
            sources: [source("emby", "emby://nas.local/src")],
            paths: [
                "emby://nas.local/src/library/a/type/movies/name/%E7%94%B5%E5%BD%B1",
                "emby://nas.local/src/library/b"
            ]
        )
        XCTAssertEqual(result, [
            "emby://nas.local/src",
            "emby://nas.local/src/library/a/type/movies/name/%E7%94%B5%E5%BD%B1",
            "emby://nas.local/src/library/b"
        ])
    }

    /// 斜杠边界：`src` 不得授权 `src2`，也不得授权 `srcX`。
    func testAdjacentAndSuffixSourcesAreNotAuthorized() {
        let result = resolve(
            sources: [source("emby", "emby://nas.local/src")],
            paths: [
                "emby://nas.local/src/library/a",
                "emby://nas.local/src2/library/a",
                "emby://nas.local/srcX",
                "emby://other.local/src/library/a"
            ]
        )
        XCTAssertEqual(result, ["emby://nas.local/src", "emby://nas.local/src/library/a"])
    }

    /// 归属按最长匹配。私密来源嵌套在公开来源之下时，私密子树归私密来源，
    /// 因而整体不可见——"命中任一授权根"的写法会在这里泄露保险库。
    func testLongestMatchAttributionKeepsNestedPrivateSourceHidden() {
        let result = resolve(
            sources: [
                source("public", "plex://nas.local/src"),
                source("vault", "plex://nas.local/src/library/private", .privateCollection)
            ],
            paths: [
                "plex://nas.local/src/library/movies",
                "plex://nas.local/src/library/private",
                "plex://nas.local/src/library/private/sub"
            ]
        )
        XCTAssertEqual(result, ["plex://nas.local/src", "plex://nas.local/src/library/movies"])
    }

    /// 未被授予的来源，其子树同样不可见。
    func testUnauthorizedRootDoesNotExpand() {
        let result = resolve(
            sources: [
                source("granted", "emby://nas.local/a"),
                source("denied", "emby://nas.local/b")
            ],
            paths: ["emby://nas.local/a/library/x", "emby://nas.local/b/library/x"],
            authorized: ["granted"]
        )
        XCTAssertEqual(result, ["emby://nas.local/a", "emby://nas.local/a/library/x"])
    }

    /// 本地来源不展开：这是"对本地行为可证明 no-op"的直接断言。若哪天有人把
    /// 本地 scheme 加进白名单，这条会立刻失败。
    func testLocalSourcesAreNotExpanded() {
        let result = resolve(
            sources: [source("local", "/Volumes/Media", .movie)],
            paths: ["/Volumes/Media", "/Volumes/Media/Nested", "/Volumes/Media2"]
        )
        XCTAssertEqual(result, ["/Volumes/Media"])
    }

    /// 保险库来源自身永远不进授权集合，无论它是不是可展开 scheme。
    func testPrivateSourceIsNeverAuthorized() {
        let result = resolve(
            sources: [source("vault", "emby://nas.local/vault", .privateCollection)],
            paths: ["emby://nas.local/vault/library/a"]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func testExpandableRootRequiresSchemeAndAtLeastOneComponent() {
        XCTAssertTrue(ServerSourceAuthorizationResolver.isExpandableRoot("emby://nas.local/src"))
        XCTAssertTrue(ServerSourceAuthorizationResolver.isExpandableRoot("jellyfin://nas.local/src"))
        XCTAssertTrue(ServerSourceAuthorizationResolver.isExpandableRoot("plex://nas.local/src"))
        // Mlink 的根没有主机名，只有一个来源标识，必须仍然可展开。
        XCTAssertTrue(ServerSourceAuthorizationResolver.isExpandableRoot("mlink://source-id"))
        // 裸 scheme 会把该协议下的一切收进来。
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot("emby://"))
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot("emby:///"))
        // 本地路径与根目录一律不展开。
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot("/"))
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot("/Volumes/Media"))
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot(""))
        XCTAssertFalse(ServerSourceAuthorizationResolver.isExpandableRoot("urlsource://local"))
    }

    /// 根为 `/` 时 `SourcePathPolicy.isSourcePath` 对任何绝对路径返回 true。
    /// 即使它被误加进 scheme 白名单，也不得展开成"整个资料库"。
    func testRootSlashSourceNeverExpandsWholeLibrary() {
        let result = resolve(
            sources: [source("root", "/", .movie)],
            paths: ["/Volumes/A/x", "/Volumes/B/y"]
        )
        XCTAssertEqual(result, ["/"])
    }

    func testTrailingSlashOnRootStillMatchesSubtree() {
        let result = resolve(
            sources: [source("emby", "emby://nas.local/src/")],
            paths: ["emby://nas.local/src/library/a"]
        )
        XCTAssertTrue(result.contains("emby://nas.local/src/library/a"))
    }
}
