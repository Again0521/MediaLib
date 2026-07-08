import XCTest
@testable import MediaLib

final class SourcePathMatchingTests: XCTestCase {
    func testLocalPathMatchingRequiresDirectoryBoundary() {
        XCTAssertTrue(AppState.isSourcePath("/Media/Movies", inside: "/Media/Movies"))
        XCTAssertTrue(AppState.isSourcePath("/Media/Movies/Film.mkv", inside: "/Media/Movies"))
        XCTAssertTrue(AppState.isSourcePath("/Media/Movies/Film.mkv", inside: "/Media/Movies/"))

        XCTAssertFalse(AppState.isSourcePath("/Media/Movies2/Film.mkv", inside: "/Media/Movies"))
        XCTAssertFalse(AppState.isSourcePath("/Media/Anime/Film.mkv", inside: "/Media/A"))
    }

    func testRootSourceMatchesOnlyAbsolutePaths() {
        XCTAssertTrue(AppState.isSourcePath("/Media/Movies", inside: "/"))
        XCTAssertFalse(AppState.isSourcePath("relative/Movies", inside: "/"))
        XCTAssertFalse(AppState.isSourcePath("/Media/Movies", inside: ""))
    }

    func testRemoteSourcePathMatchingUsesSameBoundaryRules() {
        XCTAssertTrue(AppState.isSourcePath("emby://server/library/movies/item-1", inside: "emby://server/library/movies"))
        XCTAssertTrue(AppState.isSourcePath("plex://server/source/item-1", inside: "plex://server/source/"))

        XCTAssertFalse(AppState.isSourcePath("emby://server/library/movies2/item-1", inside: "emby://server/library/movies"))
        XCTAssertFalse(AppState.isSourcePath("jellyfin://server/source-b/item-1", inside: "jellyfin://server/source"))
    }

    func testSourcePathExcludedHonorsNestedSourceBoundaries() {
        XCTAssertTrue(AppState.sourcePathExcluded("/Media/Movies/Film.mkv", in: ["/Media/Movies"]))
        XCTAssertTrue(AppState.sourcePathExcluded("emby://server/library/movies/item-1", in: ["emby://server/library/movies"]))

        XCTAssertFalse(AppState.sourcePathExcluded("/Media/Movies2/Film.mkv", in: ["/Media/Movies"]))
        XCTAssertFalse(AppState.sourcePathExcluded("/Media/Movies/Film.mkv", in: []))
        XCTAssertFalse(AppState.sourcePathExcluded(nil, in: ["/Media/Movies"]))
    }
}
