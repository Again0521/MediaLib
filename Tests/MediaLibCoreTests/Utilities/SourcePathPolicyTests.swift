import XCTest
@testable import MediaLibCore

final class SourcePathPolicyTests: XCTestCase {
    func testLocalPathMatchingRequiresDirectoryBoundary() {
        XCTAssertTrue(SourcePathPolicy.isSourcePath("/Media/Movies", inside: "/Media/Movies"))
        XCTAssertTrue(SourcePathPolicy.isSourcePath("/Media/Movies/Film.mkv", inside: "/Media/Movies"))
        XCTAssertTrue(SourcePathPolicy.isSourcePath("/Media/Movies/Film.mkv", inside: "/Media/Movies/"))

        XCTAssertFalse(SourcePathPolicy.isSourcePath("/Media/Movies2/Film.mkv", inside: "/Media/Movies"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("/Media/Anime/Film.mkv", inside: "/Media/A"))
    }

    func testRootSourceMatchesOnlyAbsoluteCandidates() {
        XCTAssertTrue(SourcePathPolicy.isSourcePath("/Media/Movies", inside: "/"))
        XCTAssertTrue(SourcePathPolicy.isSourcePath("/", inside: "/"))

        XCTAssertFalse(SourcePathPolicy.isSourcePath("relative/Movies", inside: "/"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath(nil, inside: "/"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("/Media/Movies", inside: ""))
    }

    func testRemoteSourcePathMatchingUsesSameBoundaryRules() {
        XCTAssertTrue(SourcePathPolicy.isSourcePath("emby://server/library/movies/item-1", inside: "emby://server/library/movies"))
        XCTAssertTrue(SourcePathPolicy.isSourcePath("plex://server/source/item-1", inside: "plex://server/source/"))

        XCTAssertFalse(SourcePathPolicy.isSourcePath("emby://server/library/movies2/item-1", inside: "emby://server/library/movies"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("jellyfin://server/source-b/item-1", inside: "jellyfin://server/source"))
    }

    func testRemoteSourcePathMatchingIgnoresSchemeAndHostCaseOnly() {
        XCTAssertTrue(SourcePathPolicy.isSourcePath("Jellyfin://MEDIA.Example/Library/item-1", inside: "jellyfin://media.example/Library"))
        XCTAssertTrue(SourcePathPolicy.isSourcePath("PLEX://Server.Local/source/item-1", inside: "plex://server.local/source"))
        XCTAssertTrue(SourcePathPolicy.isExcluded("EMBY://Server.Local/library/item-1", in: ["emby://server.local/library"]))

        XCTAssertFalse(SourcePathPolicy.isSourcePath("jellyfin://media.example/Library2/item-1", inside: "jellyfin://media.example/Library"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("jellyfin://media.example/library/item-1", inside: "jellyfin://media.example/Library"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("/media/movies/Film.mkv", inside: "/Media/Movies"))
    }

    func testRemoteSourcePathMatchingPreservesUserInfoCaseWhileNormalizingHost() {
        XCTAssertTrue(SourcePathPolicy.isSourcePath("smb://User:Secret@NAS.Local/Share/Movie.mkv", inside: "SMB://User:Secret@nas.local/Share"))
        XCTAssertFalse(SourcePathPolicy.isSourcePath("smb://user:Secret@NAS.Local/Share/Movie.mkv", inside: "SMB://User:Secret@nas.local/Share"))
    }

    func testTrailingSlashNormalizationPreservesSchemeOnlyRoots() {
        XCTAssertEqual(SourcePathPolicy.normalizedSourceRoot("/Media/Movies///"), "/Media/Movies")
        XCTAssertEqual(SourcePathPolicy.normalizedSourceRoot("emby://server/source///"), "emby://server/source")
        XCTAssertEqual(SourcePathPolicy.normalizedSourceRoot("emby://"), "emby://")
    }

    func testExclusionHonorsNestedSourceBoundaries() {
        XCTAssertTrue(SourcePathPolicy.isExcluded("/Media/Movies/Film.mkv", in: ["/Media/Movies"]))
        XCTAssertTrue(SourcePathPolicy.isExcluded("emby://server/library/movies/item-1", in: ["emby://server/library/movies"]))

        XCTAssertFalse(SourcePathPolicy.isExcluded("/Media/Movies2/Film.mkv", in: ["/Media/Movies"]))
        XCTAssertFalse(SourcePathPolicy.isExcluded("/Media/Movies/Film.mkv", in: []))
        XCTAssertFalse(SourcePathPolicy.isExcluded(nil, in: ["/Media/Movies"]))
    }
}
