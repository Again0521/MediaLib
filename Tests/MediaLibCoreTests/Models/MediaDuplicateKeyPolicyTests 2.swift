import XCTest
@testable import MediaLibCore

final class MediaDuplicateKeyPolicyTests: XCTestCase {
    func testDuplicateKeyIgnoresCaseWhitespaceAndPunctuationInTitle() {
        let lhs = mediaItem(title: "Movie: Title!", type: .movie, year: 2026)
        let rhs = mediaItem(title: "movie title", type: .movie, year: 2026)

        XCTAssertEqual(
            MediaDuplicateKeyPolicy.duplicateKey(for: lhs),
            MediaDuplicateKeyPolicy.duplicateKey(for: rhs)
        )
    }

    func testDuplicateKeyKeepsMediaTypeAndYearBoundaries() {
        let movie = mediaItem(title: "Shared Title", type: .movie, year: 2026)
        let series = mediaItem(title: "Shared Title", type: .tvShow, year: 2026)
        let olderMovie = mediaItem(title: "Shared Title", type: .movie, year: 2025)

        XCTAssertNotEqual(
            MediaDuplicateKeyPolicy.duplicateKey(for: movie),
            MediaDuplicateKeyPolicy.duplicateKey(for: series)
        )
        XCTAssertNotEqual(
            MediaDuplicateKeyPolicy.duplicateKey(for: movie),
            MediaDuplicateKeyPolicy.duplicateKey(for: olderMovie)
        )
    }

    func testDuplicateKeyUsesUnknownYearSentinelForMissingYear() {
        let item = mediaItem(title: "No Year", type: .documentary, year: nil)

        XCTAssertEqual(
            MediaDuplicateKeyPolicy.duplicateKey(for: item),
            "documentary-noyear-unknown"
        )
    }

    func testDuplicateKeyPreservesNonLatinAlphanumericCharacters() {
        let item = mediaItem(title: "电影：标题 01", type: .movie, year: 2026)

        XCTAssertEqual(
            MediaDuplicateKeyPolicy.duplicateKey(for: item),
            "movie-电影标题01-2026"
        )
    }

    func testDuplicateTitleGroupsGroupsOnlyMatchingDuplicateKeys() {
        let alphaA = mediaItem(id: "alpha-a", title: "Alpha Movie", type: .movie, year: 2026)
        let alphaB = mediaItem(id: "alpha-b", title: "alpha-movie", type: .movie, year: 2026)
        let differentYear = mediaItem(id: "alpha-2025", title: "Alpha Movie", type: .movie, year: 2025)
        let differentType = mediaItem(id: "alpha-series", title: "Alpha Movie", type: .tvShow, year: 2026)
        let unique = mediaItem(id: "unique", title: "Unique", type: .movie, year: 2026)

        let groups = MediaDuplicateKeyPolicy.duplicateTitleGroups(
            in: [alphaA, differentYear, differentType, unique, alphaB],
            excludingSourcePaths: []
        )

        XCTAssertEqual(groups.map { $0.map(\.id) }, [["alpha-a", "alpha-b"]])
    }

    func testDuplicateTitleGroupsSortsGroupsByFirstTitle() {
        let zetaA = mediaItem(id: "zeta-a", title: "Zeta", type: .movie, year: 2026)
        let alphaA = mediaItem(id: "alpha-a", title: "Alpha", type: .movie, year: 2026)
        let zetaB = mediaItem(id: "zeta-b", title: "zeta", type: .movie, year: 2026)
        let alphaB = mediaItem(id: "alpha-b", title: "alpha", type: .movie, year: 2026)

        let groups = MediaDuplicateKeyPolicy.duplicateTitleGroups(
            in: [zetaA, alphaA, zetaB, alphaB],
            excludingSourcePaths: []
        )

        XCTAssertEqual(groups.map { $0.map(\.id) }, [["alpha-a", "alpha-b"], ["zeta-a", "zeta-b"]])
    }

    func testDuplicateTitleGroupsExcludesConfiguredSourceRootsWithPathBoundaries() {
        let keptA = mediaItem(
            id: "kept-a",
            title: "Shared",
            type: .movie,
            year: 2026,
            sourcePath: "/Media/Keep/movie-a.mkv"
        )
        let keptB = mediaItem(
            id: "kept-b",
            title: "shared",
            type: .movie,
            year: 2026,
            sourcePath: "/Media/Keep/movie-b.mkv"
        )
        let excluded = mediaItem(
            id: "excluded",
            title: "Shared",
            type: .movie,
            year: 2026,
            sourcePath: "/Media/Excluded/movie-c.mkv"
        )
        let boundarySibling = mediaItem(
            id: "boundary",
            title: "Shared",
            type: .movie,
            year: 2026,
            sourcePath: "/Media/Excluded2/movie-d.mkv"
        )

        let groups = MediaDuplicateKeyPolicy.duplicateTitleGroups(
            in: [keptA, excluded, keptB, boundarySibling],
            excludingSourcePaths: ["/Media/Excluded"]
        )

        XCTAssertEqual(groups.map { $0.map(\.id) }, [["kept-a", "kept-b", "boundary"]])
    }

    private func mediaItem(
        id: String = UUID().uuidString,
        title: String,
        type: MediaType,
        year: Int?,
        sourcePath: String? = nil
    ) -> MediaItem {
        MediaItem(
            id: id,
            type: type,
            title: title,
            year: year,
            sourcePath: sourcePath
        )
    }
}
