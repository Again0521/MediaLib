import XCTest
@testable import MediaLib

final class EmbyServiceResourceURLTests: XCTestCase {
    func testRefreshedResourceURLReplacesTokenWhenHostCaseDiffers() {
        let service = EmbyService()
        let session = EmbySession(
            serverURL: URL(string: "http://Media.EXAMPLE:8096")!,
            username: "user",
            userID: "user-id",
            accessToken: "new-token"
        )

        let refreshed = service.refreshedResourceURLString(
            "http://media.example:8096/Items/1/Images/Primary?API_KEY=old-token&maxWidth=500",
            session: session
        )
        let components = URLComponents(string: refreshed ?? "")

        XCTAssertEqual(queryValue("api_key", in: components), "new-token")
        XCTAssertEqual(queryValue("maxWidth", in: components), "500")
        XCTAssertFalse((components?.queryItems ?? []).contains { $0.value == "old-token" })
    }

    func testRefreshedResourceURLLeavesDifferentHostUntouched() {
        let service = EmbyService()
        let session = EmbySession(
            serverURL: URL(string: "http://media.example:8096")!,
            username: "user",
            userID: "user-id",
            accessToken: "new-token"
        )
        let original = "http://cdn.example:8096/Items/1/Images/Primary?api_key=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLLeavesDifferentPortUntouched() {
        let service = EmbyService()
        let session = EmbySession(
            serverURL: URL(string: "http://media.example:8096")!,
            username: "user",
            userID: "user-id",
            accessToken: "new-token"
        )
        let original = "http://media.example:9000/Items/1/Images/Primary?api_key=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLLeavesDifferentSchemeUntouched() {
        let service = EmbyService()
        let session = EmbySession(
            serverURL: URL(string: "https://media.example:8096")!,
            username: "user",
            userID: "user-id",
            accessToken: "new-token"
        )
        let original = "http://media.example:8096/Items/1/Images/Primary?api_key=old-token"

        XCTAssertEqual(service.refreshedResourceURLString(original, session: session), original)
    }

    func testRefreshedResourceURLTreatsDefaultHTTPPortAsSameOrigin() {
        let service = EmbyService()
        let session = EmbySession(
            serverURL: URL(string: "http://Media.EXAMPLE")!,
            username: "user",
            userID: "user-id",
            accessToken: "new-token"
        )

        let refreshed = service.refreshedResourceURLString(
            "http://media.example:80/Items/1/Images/Primary?api_key=old-token",
            session: session
        )
        let components = URLComponents(string: refreshed ?? "")

        XCTAssertEqual(queryValue("api_key", in: components), "new-token")
    }

    func testRefreshingAPIKeyDoesNotInjectCredentialIntoExternalAbsoluteURL() {
        let original = URL(string: "http://cdn.example/Subtitles/1/Stream.srt?api_key=old-token&format=srt")!

        let refreshed = EmbyService.urlByRefreshingAPIKey(
            original,
            baseURL: URL(string: "http://media.example:8096")!,
            accessToken: "new-token"
        )

        XCTAssertEqual(refreshed, original)
    }

    func testRefreshingAPIKeyReplacesCredentialForSameOriginSubtitleURL() {
        let original = URL(string: "http://media.example:8096/Subtitles/1/Stream.srt?API_KEY=old-token&format=srt")!

        let refreshed = EmbyService.urlByRefreshingAPIKey(
            original,
            baseURL: URL(string: "http://Media.EXAMPLE:8096")!,
            accessToken: "new-token"
        )
        let components = refreshed.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }

        XCTAssertEqual(queryValue("api_key", in: components), "new-token")
        XCTAssertEqual(queryValue("format", in: components), "srt")
        XCTAssertFalse((components?.queryItems ?? []).contains { $0.value == "old-token" })
    }

    private func queryValue(_ name: String, in components: URLComponents?) -> String? {
        components?.queryItems?.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}
