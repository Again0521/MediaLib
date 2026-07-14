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
            policy.validate("POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\nHost: localhost\r\nTransfer-Encoding: chunked\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\nContent-Length: 0\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 12\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .badRequest
        )
        XCTAssertEqual(
            policy.validate("GET /health HTTP/1.1\r\nHost: localhost\r\n\r\nunexpected-body"),
            .badRequest
        )
    }

    func testMutationsRequireCSRFAndSameOrigin() {
        let accepted = "POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\nHost: localhost:8098\r\nOrigin: http://localhost:8098\r\nContent-Length: 0\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"
        XCTAssertNil(policy.validate(accepted))

        XCTAssertEqual(
            policy.validate("POST /api/v1/playback/hls/movie-1 HTTP/1.1\r\nHost: localhost\r\nContent-Length: 0\r\n\r\n"),
            .forbidden
        )
        XCTAssertEqual(
            policy.validate("DELETE /api/v1/hls/session-1 HTTP/1.1\r\nHost: localhost\r\nOrigin: https://attacker.example\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n"),
            .forbidden
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
            policy.validate("POST /api/v1/playback/hls/movie HTTP/1.1\r\nHost: localhost\r\nContent-Type: application/json\r\nContent-Length: 1\r\nX-MediaLIB-CSRF: known-csrf-token\r\n\r\n", bodyLength: 1),
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
            policy.validate("GET /api/v1/hls/session/%2e%2e%2fsecret HTTP/1.1\r\nHost: localhost\r\n\r\n"),
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
