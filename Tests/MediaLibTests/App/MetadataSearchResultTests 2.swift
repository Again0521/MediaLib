import XCTest
@testable import MediaLib

final class MetadataSearchResultTests: XCTestCase {
    func testProviderRatingIsNormalizedAtConstruction() throws {
        for rating in [Double.nan, .infinity, -.infinity, -1, 0, 10.1] {
            let result = MetadataSearchResult(
                id: "tmdb:invalid:\(rating)",
                provider: "TMDB",
                title: "Movie",
                rating: rating
            )

            XCTAssertNil(result.rating, "rating \(rating) should be dropped before entering search result state")
            XCTAssertNil(result.metadataUpdate.rating)
        }

        let lowBoundary = MetadataSearchResult(
            id: "tmdb:low",
            provider: "TMDB",
            title: "Movie",
            rating: 0.1
        )
        XCTAssertEqual(try XCTUnwrap(lowBoundary.rating), 0.1, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(lowBoundary.metadataUpdate.rating), 0.1, accuracy: 0.0001)

        let highBoundary = MetadataSearchResult(
            id: "tmdb:high",
            provider: "TMDB",
            title: "Movie",
            rating: 10
        )
        XCTAssertEqual(try XCTUnwrap(highBoundary.rating), 10, accuracy: 0.0001)
        XCTAssertEqual(try XCTUnwrap(highBoundary.metadataUpdate.rating), 10, accuracy: 0.0001)
    }

    func testMetadataUpdateRechecksMutatedProviderRating() {
        var result = MetadataSearchResult(
            id: "tmdb:mutated",
            provider: "TMDB",
            title: "Movie",
            rating: 8.5
        )

        result.rating = .infinity

        XCTAssertNil(result.metadataUpdate.rating)
    }

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
