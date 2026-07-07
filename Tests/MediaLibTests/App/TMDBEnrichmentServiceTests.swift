import XCTest
@testable import MediaLib

final class TMDBEnrichmentServiceTests: XCTestCase {
    func testParseAcceptsMovieAndTVExternalIDs() throws {
        let movie = try XCTUnwrap(TMDBEnrichmentService.parse(externalID: " tmdb:movie:12345\n"))
        XCTAssertEqual(movie.kind, "movie")
        XCTAssertEqual(movie.id, "12345")

        let tv = try XCTUnwrap(TMDBEnrichmentService.parse(externalID: "tmdb:tv:67890"))
        XCTAssertEqual(tv.kind, "tv")
        XCTAssertEqual(tv.id, "67890")
    }

    func testParseRejectsMalformedKindsAndNonPositiveIDs() {
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "imdb:movie:123"))
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "tmdb:person:123"))
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "tmdb:movie:"))
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "tmdb:movie:not-a-number"))
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "tmdb:movie:0"))
        XCTAssertNil(TMDBEnrichmentService.parse(externalID: "tmdb:movie:-1"))
    }

    func testImageLanguageFilterKeepsCurrentLanguageNullAndEnglishWithoutDuplicates() {
        XCTAssertEqual(TMDBEnrichmentService.imageLanguageFilter(for: "zh-Hans"), "zh,null,en")
        XCTAssertEqual(TMDBEnrichmentService.imageLanguageFilter(for: " EN-us "), "en,null")
        XCTAssertEqual(TMDBEnrichmentService.imageLanguageFilter(for: "\n"), "zh,null,en")
    }

    func testTrailerURLPrefersOfficialYouTubeTrailer() {
        let url = TMDBEnrichmentService.trailerURL(from: [
            TMDBVideo(key: "non-youtube", site: "Vimeo", type: "Trailer", official: true),
            TMDBVideo(key: "clip-key", site: "YouTube", type: "Clip", official: true),
            TMDBVideo(key: "official-key", site: "YouTube", type: "Trailer", official: true),
            TMDBVideo(key: "other-trailer", site: "YouTube", type: "Trailer", official: false)
        ])

        XCTAssertEqual(url, "https://www.youtube.com/watch?v=official-key")
    }

    func testTrailerURLFallsBackToTrailerThenAnyYouTubeVideo() {
        XCTAssertEqual(
            TMDBEnrichmentService.trailerURL(from: [
                TMDBVideo(key: "clip-key", site: "YouTube", type: "Clip", official: true),
                TMDBVideo(key: "trailer-key", site: "YouTube", type: "Trailer", official: false)
            ]),
            "https://www.youtube.com/watch?v=trailer-key"
        )
        XCTAssertEqual(
            TMDBEnrichmentService.trailerURL(from: [
                TMDBVideo(key: "featurette-key", site: "YouTube", type: "Featurette", official: false)
            ]),
            "https://www.youtube.com/watch?v=featurette-key"
        )
    }

    func testTrailerURLTrimsCaseAndSkipsBlankKeys() {
        let url = TMDBEnrichmentService.trailerURL(from: [
            TMDBVideo(key: "   ", site: "YouTube", type: "Trailer", official: true),
            TMDBVideo(key: "\ntrimmed-key\t", site: " youtube ", type: " trailer ", official: true)
        ])

        XCTAssertEqual(url, "https://www.youtube.com/watch?v=trimmed-key")
        XCTAssertNil(TMDBEnrichmentService.trailerURL(from: [
            TMDBVideo(key: nil, site: "YouTube", type: "Trailer", official: true),
            TMDBVideo(key: "vimeo-key", site: "Vimeo", type: "Trailer", official: true)
        ]))
    }

    func testYearExtractsFourDigitPrefixOnlyWhenNumeric() {
        XCTAssertEqual(TMDBEnrichmentService.year(from: "1999-12-31"), 1999)
        XCTAssertEqual(TMDBEnrichmentService.year(from: "2026"), 2026)
        XCTAssertNil(TMDBEnrichmentService.year(from: nil))
        XCTAssertNil(TMDBEnrichmentService.year(from: "123"))
        XCTAssertNil(TMDBEnrichmentService.year(from: "20AB-01-01"))
    }

    func testLocalizedJobMapsKnownCrewRolesAndKeepsUnknownRole() {
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Director"), "导演")
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Writer"), "编剧")
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Screenplay"), "编剧")
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Producer"), "制片")
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Original Music Composer"), "配乐")
        XCTAssertEqual(TMDBEnrichmentService.localizedJob("Editor"), "Editor")
    }

    func testRetryDelayClampsRetryAfterAndFallsBackForNonFiniteValues() {
        XCTAssertEqual(TMDBEnrichmentService.retryDelaySeconds(retryAfter: "2.5", attempt: 1), 2.5)
        XCTAssertEqual(TMDBEnrichmentService.retryDelaySeconds(retryAfter: "-1", attempt: 1), 0.5)
        XCTAssertEqual(TMDBEnrichmentService.retryDelaySeconds(retryAfter: "999", attempt: 1), 4)
        XCTAssertEqual(TMDBEnrichmentService.retryDelaySeconds(retryAfter: "NaN", attempt: 2), 2)
        XCTAssertEqual(TMDBEnrichmentService.retryDelaySeconds(retryAfter: nil, attempt: 9), 4)
    }
}
