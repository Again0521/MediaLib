import XCTest
@testable import MediaLib

final class EmbyServicePathPolicyTests: XCTestCase {
    func testMediaServerSourcePathAcceptsMixedCaseRemoteSchemes() {
        XCTAssertTrue(EmbyService.isMediaServerSourcePath("EMBY://server"))
        XCTAssertTrue(EmbyService.isMediaServerSourcePath("Jellyfin://server/library/movies"))
        XCTAssertTrue(EmbyService.isMediaServerSourcePath("Plex://server/source"))

        XCTAssertFalse(EmbyService.isMediaServerSourcePath("urlsource://manual"))
        XCTAssertFalse(EmbyService.isMediaServerSourcePath("/Volumes/Media"))
        XCTAssertFalse(EmbyService.isMediaServerSourcePath(nil))
    }

    func testSourceRootPathPreservesOriginalRootWhileAcceptingMixedCaseSchemeAndLibraryMarker() {
        XCTAssertEqual(
            EmbyService.sourceRootPath(from: "Jellyfin://Media.EXAMPLE/Library/abc/type/movies/name/Movies"),
            "Jellyfin://Media.EXAMPLE"
        )
        XCTAssertEqual(
            EmbyService.sourceRootPath(from: "PLEX://Media.EXAMPLE/source"),
            "PLEX://Media.EXAMPLE/source"
        )
        XCTAssertNil(EmbyService.sourceRootPath(from: "/Volumes/Media/Library/abc"))
        XCTAssertNil(EmbyService.sourceRootPath(from: "/Volumes/Media/library/abc"))
    }

    func testLibraryInfoParsesMixedCaseServerSourcePathAndDecodesMetadata() {
        let info = EmbyService.libraryInfo(
            from: "Jellyfin://Media.EXAMPLE/Library/view-1/type/tvshows/name/Drama%20Shows"
        )

        XCTAssertEqual(info?.id, "view-1")
        XCTAssertEqual(info?.name, "Drama Shows")
        XCTAssertEqual(info?.collectionType, "tvshows")
    }

    func testLibraryInfoKeepsLegacyNameThenIDFallback() {
        let info = EmbyService.libraryInfo(from: "EMBY://server/library/Movies%20Shelf/view-2")

        XCTAssertEqual(info?.id, "view-2")
        XCTAssertEqual(info?.name, "Movies Shelf")
        XCTAssertNil(info?.collectionType)
    }

    func testLibraryInfoRejectsNonServerAndMalformedPaths() {
        XCTAssertNil(EmbyService.libraryInfo(from: "urlsource://manual/library/view-1"))
        XCTAssertNil(EmbyService.libraryInfo(from: "/Volumes/Media/library/view-1"))
        XCTAssertNil(EmbyService.libraryInfo(from: "emby://server/library/"))
    }
}
