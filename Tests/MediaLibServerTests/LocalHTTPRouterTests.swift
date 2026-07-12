import XCTest
@testable import MediaLibServer
import MediaLibServerProtocol

final class LocalHTTPRouterTests: XCTestCase {
    private let router = LocalHTTPRouter(serverID: "server-001", serverName: "客厅服务器")

    func testHealthRouteReturnsJSONHealth() throws {
        let response = router.response(for: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let health = try decoder.decode(ServerHealth.self, from: response.body)

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertEqual(response.contentType, "application/json; charset=utf-8")
        XCTAssertEqual(response.declaredContentLength, response.body.count)
        XCTAssertEqual(health.serverID, "server-001")
        XCTAssertEqual(health.serverName, "客厅服务器")
    }

    func testWellKnownRouteSupportsHeadWithoutBody() {
        let response = router.response(for: "HEAD /.well-known/mlink HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 200)
        XCTAssertTrue(response.body.isEmpty)
        XCTAssertGreaterThan(response.declaredContentLength, 0)
    }

    func testNonProbeRoutesDoNotExposeData() {
        let response = router.response(for: "GET /api/v1/libraries HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 404)
        XCTAssertEqual(String(data: response.body, encoding: .utf8), "{\"error\":\"Not Found\"}")
    }

    func testMutatingMethodsAreRejected() {
        let response = router.response(for: "POST /health HTTP/1.1\r\nHost: localhost\r\n\r\n")

        XCTAssertEqual(response.statusCode, 405)
        XCTAssertTrue(String(data: response.serialized(), encoding: .utf8)?.contains("Allow: GET, HEAD") == true)
    }
}
