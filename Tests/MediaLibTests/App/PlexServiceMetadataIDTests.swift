import XCTest
@testable import MediaLib

final class PlexServiceMetadataIDTests: XCTestCase {
    func testProviderIDsAcceptMixedCaseGuidSchemes() {
        let ids = PlexService.providerIDs(
            guidValues: [
                "TMDB://12345?lang=en",
                "ImDb://tt7654321"
            ],
            legacyGUID: nil
        )

        XCTAssertEqual(ids.tmdbID, "12345")
        XCTAssertEqual(ids.imdbID, "tt7654321")
    }

    func testProviderIDsUseMixedCaseLegacyGuidFallbackForIMDB() {
        let ids = PlexService.providerIDs(
            guidValues: ["local://library/abc"],
            legacyGUID: "IMDB://tt1234567?source=plex"
        )

        XCTAssertNil(ids.tmdbID)
        XCTAssertEqual(ids.imdbID, "tt1234567")
    }

    func testProviderIDsPreferGuidChildOverLegacyGuidFallback() {
        let ids = PlexService.providerIDs(
            guidValues: ["imdb://ttchild"],
            legacyGUID: "IMDB://ttlegacy"
        )

        XCTAssertEqual(ids.imdbID, "ttchild")
    }

    func testProviderIDRejectsNonMatchingPrefixesAndKeepsPathSuffixCase() {
        XCTAssertNil(PlexService.providerID(prefix: "tmdb://", in: ["plex://movie/123", "x-tmdb://456"]))
        XCTAssertEqual(
            PlexService.providerID(prefix: "tmdb://", in: ["TmDb://Collection/ABC?foo=bar"]),
            "Collection/ABC"
        )
    }

    func testRefreshedResourceURLReplacesTokenWhenHostCaseDiffers() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://Plex.EXAMPLE:32400")!,
            accessToken: "new-token"
        )

        let refreshed = service.refreshedResourceURLString(
            "http://plex.example:32400/library/metadata/1/thumb?x-plex-token=old-token&width=300",
            session: session
        )
        let components = URLComponents(string: refreshed ?? "")

        XCTAssertEqual(queryValue("X-Plex-Token", in: components), "new-token")
        XCTAssertEqual(queryValue("width", in: components), "300")
        XCTAssertFalse((components?.queryItems ?? []).contains { $0.value == "old-token" })
    }

    func testRefreshedResourceURLLeavesDifferentHostUntouched() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://plex.example:32400")!,
            accessToken: "new-token"
        )
        let original = "http://cdn.example:32400/library/metadata/1/thumb?X-Plex-Token=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLLeavesDifferentPortUntouched() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://plex.example:32400")!,
            accessToken: "new-token"
        )
        let original = "http://plex.example:8080/library/metadata/1/thumb?X-Plex-Token=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLLeavesDifferentSchemeUntouched() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "https://plex.example:32400")!,
            accessToken: "new-token"
        )
        let original = "http://plex.example:32400/library/metadata/1/thumb?X-Plex-Token=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLTreatsDefaultHTTPSPortAsSameOrigin() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "https://Plex.EXAMPLE")!,
            accessToken: "new-token"
        )

        let refreshed = service.refreshedResourceURLString(
            "https://plex.example:443/library/metadata/1/thumb?X-Plex-Token=old-token",
            session: session
        )
        let components = URLComponents(string: refreshed ?? "")

        XCTAssertEqual(queryValue("X-Plex-Token", in: components), "new-token")
    }

    func testMediaURLAddsTokenForRelativeSameOriginPath() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://plex.example:32400")!,
            accessToken: "new-token"
        )

        let value = service.mediaURL(relativeOrAbsolutePath: "/library/metadata/1/thumb?width=300", session: session)
        let components = URLComponents(string: value ?? "")

        XCTAssertEqual(components?.host, "plex.example")
        XCTAssertEqual(queryValue("X-Plex-Token", in: components), "new-token")
        XCTAssertEqual(queryValue("width", in: components), "300")
    }

    func testMediaURLDoesNotInjectTokenIntoExternalAbsoluteURL() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://plex.example:32400")!,
            accessToken: "new-token"
        )

        let value = service.mediaURL(
            relativeOrAbsolutePath: "http://cdn.example:32400/library/metadata/1/thumb?X-Plex-Token=old-token&width=300",
            session: session
        )
        let components = URLComponents(string: value ?? "")

        XCTAssertEqual(components?.host, "cdn.example")
        XCTAssertEqual(queryValue("X-Plex-Token", in: components), "old-token")
        XCTAssertFalse((components?.queryItems ?? []).contains { $0.value == "new-token" })
    }

    func testMediaURLReplacesTokenForSameOriginAbsoluteURL() {
        let service = PlexService()
        let session = PlexSession(
            serverURL: URL(string: "http://Plex.EXAMPLE:32400")!,
            accessToken: "new-token"
        )

        let value = service.mediaURL(
            relativeOrAbsolutePath: "http://plex.example:32400/library/metadata/1/thumb?x-plex-token=old-token&width=300",
            session: session
        )
        let components = URLComponents(string: value ?? "")

        XCTAssertEqual(queryValue("X-Plex-Token", in: components), "new-token")
        XCTAssertEqual(queryValue("width", in: components), "300")
        XCTAssertFalse((components?.queryItems ?? []).contains { $0.value == "old-token" })
    }

    private func queryValue(_ name: String, in components: URLComponents?) -> String? {
        components?.queryItems?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
