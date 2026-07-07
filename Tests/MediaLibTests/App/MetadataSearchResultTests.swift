import XCTest
@testable import MediaLib

final class MetadataSearchResultTests: XCTestCase {
    func testMetadataUpdateDropsHTTPArtworkURLsCaseInsensitively() {
        let result = MetadataSearchResult(
            id: "tmdb:1",
            provider: "TMDB",
            title: "Movie",
            posterPath: "HTTP://image.example/poster.jpg",
            backdropPath: "Https://image.example/backdrop.jpg"
        )

        let update = result.metadataUpdate

        XCTAssertNil(update.posterPath)
        XCTAssertNil(update.backdropPath)
    }

    func testMetadataUpdateDropsWhitespacePaddedHTTPArtworkURLs() {
        let result = MetadataSearchResult(
            id: "tmdb:2",
            provider: "TMDB",
            title: "Movie",
            posterPath: " \nhttps://image.example/poster.jpg\t",
            backdropPath: "\tHTTP://image.example/backdrop.jpg\n"
        )

        let update = result.metadataUpdate

        XCTAssertNil(update.posterPath)
        XCTAssertNil(update.backdropPath)
    }

    func testMetadataUpdateDropsBlankArtworkPaths() {
        let result = MetadataSearchResult(
            id: "local:blank",
            provider: "Local",
            title: "Movie",
            posterPath: " \n\t ",
            backdropPath: ""
        )

        let update = result.metadataUpdate

        XCTAssertNil(update.posterPath)
        XCTAssertNil(update.backdropPath)
    }

    func testMetadataUpdatePreservesLocalArtworkPathsContainingHTTPText() {
        let result = MetadataSearchResult(
            id: "local:1",
            provider: "Local",
            title: "Movie",
            posterPath: "/Volumes/Media/http-posters/poster.jpg",
            backdropPath: "http-cache/backdrop.jpg"
        )

        let update = result.metadataUpdate

        XCTAssertEqual(update.posterPath, "/Volumes/Media/http-posters/poster.jpg")
        XCTAssertEqual(update.backdropPath, "http-cache/backdrop.jpg")
    }

    func testMetadataUpdatePreservesNonHTTPArtworkSchemesForMaterializationFallback() {
        let result = MetadataSearchResult(
            id: "custom:1",
            provider: "Custom",
            title: "Movie",
            posterPath: "ftp://assets.example/poster.jpg",
            backdropPath: "smb://nas.local/art/backdrop.jpg"
        )

        let update = result.metadataUpdate

        XCTAssertEqual(update.posterPath, "ftp://assets.example/poster.jpg")
        XCTAssertEqual(update.backdropPath, "smb://nas.local/art/backdrop.jpg")
    }
}
