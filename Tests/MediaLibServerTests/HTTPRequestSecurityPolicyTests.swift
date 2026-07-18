import XCTest
@testable import MediaLibServer

final class HTTPRequestSecurityPolicyTests: XCTestCase {
    private let policy = HTTPRequestSecurityPolicy(
        allowedHosts: ["127.0.0.1", "localhost"],
        allowedPort: 8098,
        csrfToken: "known-csrf-token"
    )

    func testAcceptsStrictSameOriginProbe() {
        XCTAssertNil(policy.validate("GET /health HTTP/1.1\r\nHost: localhost:8098\r\n\r\n"))
    }

    func testRejectsDNSRebindingAndDuplicateHostHeaders() {
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: attacker.example\r\n\r\n"),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\nHost: 127.0.0.1\r\n\r\n"),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost:9999\r\n\r\n"),
            .forbidden
        )
    }

    func testRejectsRequestSmugglingHeadersAndBodies() {
        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\nunexpected-body"),
            .badRequest
        )
    }

    func testMutationsRequireCSRFAndSameOrigin() {
        let accepted = "POST /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Length: 0\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(accepted))

        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate("DELETE /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost\r\nOrigin: https://attacker.example\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .badRequest
        )
    }

    func testAdministrationSessionRevocationKeepsTheSameCSRFBoundary() {
        let accepted = "POST /api/v1/admin/sessions/session-1/revoke HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Length: 0\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(accepted))
        XCTAssertEqual(
            policy.validate(accepted.replacingOccurrences(of: "Origin: http://localhost:8098\r\n", with: "Origin: http://attacker.example\r\n")),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate(accepted.replacingOccurrences(of: "X-MediaLIB-CSRF: known-csrf-token\r\n", with: "")),
            .forbidden
        )
    }

    func testMemberCreationJSONKeepsTheSameCSRFAndContentTypeBoundary() {
        let request = "POST /api/v1/admin/users HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 128\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(request, bodyLength: 128))
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "Content-Type: application/json\r\n", with: ""), bodyLength: 128),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "X-MediaLIB-CSRF: known-csrf-token\r\n", with: ""), bodyLength: 128),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "/api/v1/admin/users", with: "/api/v1/admin/users/unknown"), bodyLength: 128),
            .badRequest
        )
    }

    func testCurrentUserPasswordChangeJSONKeepsTheSameCSRFAndContentTypeBoundary() {
        let request = "POST /api/v1/auth/password HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 128\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(request, bodyLength: 128))
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "Origin: http://localhost:8098\r\n", with: "Origin: http://attacker.example\r\n"), bodyLength: 128),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "Content-Type: application/json\r\n", with: ""), bodyLength: 128),
            .badRequest
        )
    }

    func testAllowsBoundedSameOriginJSONLoginBodyAndRejectsAmbiguousCredentials() {
        let login = "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 32\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(login, bodyLength: 32))
        XCTAssertEqual(policy.validate(login, bodyLength: 31), .badRequest)
        XCTAssertEqual(
            policy.validate("GET /api/v1/library/items HTTP/1.1\r\nHost: localhost\r\nAuthorization: Bearer one\r\nAuthorization: Bearer two\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/status/movie HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 1\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n", bodyLength: 1),
            .badRequest
        )
    }

    func testAllowsOnlyCSRFProtectedPlaybackStateJSONAtTheDynamicItemRoute() {
        let request = "POST /api/v1/playback/state/movie-1 HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 64\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(request, bodyLength: 64))
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "X-MediaLIB-CSRF: known-csrf-token\r\n", with: ""), bodyLength: 64),
            .forbidden
        )
        let unrelated = request.replacingOccurrences(of: "/api/v1/playback/state/movie-1", with: "/api/v1/items/movie-1")
        XCTAssertEqual(policy.validate(unrelated, bodyLength: 64), .badRequest)
    }

    func testAllowsOnlyCSRFProtectedPreferenceJSONAtTheDynamicItemRoute() {
        let request = "POST /api/v1/user-media/preferences/movie-1 HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 17\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(request, bodyLength: 17))
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "Content-Type: application/json\r\n", with: ""), bodyLength: 17),
            .badRequest
        )
        let unrelated = request.replacingOccurrences(of: "/api/v1/user-media/preferences/movie-1", with: "/api/v1/user-media/preference/movie-1")
        XCTAssertEqual(policy.validate(unrelated, bodyLength: 17), .badRequest)
    }

    func testNativeMlinkMutationNeedsItsMarkerAndCannotCarryBrowserState() {
        let request = "POST /api/v1/user-media/preferences/movie-1 HTTP/1.1\r\nHost: localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 17\r\nAuthorization: Bearer native-token\r\nX-MediaLIB-Client: mlink-native/1\r\n\r\n"
        XCTAssertNil(policy.validate(request, bodyLength: 17))
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "X-MediaLIB-Client: mlink-native/1\r\n", with: ""), bodyLength: 17),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nCookie: sid=browser\r\n\r\n"), bodyLength: 17),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate(request.replacingOccurrences(of: "\r\n\r\n", with: "\r\nOrigin: http://localhost:8098\r\n\r\n"), bodyLength: 17),
            .forbidden
        )
        let passwordChange = request
            .replacingOccurrences(of: "/api/v1/user-media/preferences/movie-1", with: "/api/v1/auth/password")
        XCTAssertEqual(policy.validate(passwordChange, bodyLength: 17), .forbidden)
        let nestedPath = request
            .replacingOccurrences(of: "/api/v1/user-media/preferences/movie-1", with: "/api/v1/user-media/preferences/movie-1/future-action")
        XCTAssertEqual(policy.validate(nestedPath, bodyLength: 17), .forbidden)
    }

    func testRejectsAnyAttemptToSendPasswordRecoveryJSONOverHTTP() {
        let recovery = "POST /api/v1/auth/recover HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Type: application/json\r\nContent-Length: 32\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertEqual(policy.validate(recovery, bodyLength: 32), .badRequest)
    }

    func testRejectsCrossSiteFetchesAndEncodedPathSeparators() {
        XCTAssertEqual(
            policy.validate("GET /api/v1/playback/info/movie-1 HTTP/1.1\r\nHost: localhost\r\nSec-Fetch-Site: cross-site\r\n\r\n"),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate("GET /api/v1/stream/%2e%2e%2fsecret HTTP/1.1\r\nHost: localhost\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /api/v1/items/%ZZ HTTP/1.1\r\nHost: localhost\r\n\r\n"),
            .badRequest
        )
    }

    func testRejectsObsoleteHeaderFoldingAndControlCharacters() {
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\n continuation\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: local\u{0001}host\r\n\r\n"),
            .badRequest
        )
    }
}
