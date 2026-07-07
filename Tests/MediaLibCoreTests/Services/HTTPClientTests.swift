import XCTest
@testable import MediaLibCore

private final class MockURLProtocol: URLProtocol {
    struct Stub { let status: Int; let headers: [String: String]; let body: Data }
    static var stubs: [Stub] = []
    static var requestCount = 0

    static func reset() {
        stubs = []
        requestCount = 0
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        // 超出 stub 数量时重复最后一个（便于「持续 5xx」用例）。
        let index = min(MockURLProtocol.requestCount, MockURLProtocol.stubs.count - 1)
        MockURLProtocol.requestCount += 1
        let stub = MockURLProtocol.stubs[max(index, 0)]
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: stub.status,
            httpVersion: nil,
            headerFields: stub.headers
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: stub.body)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class HTTPClientTests: XCTestCase {
    private func makeClient(maxRetries: Int = 2) -> HTTPClient {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: config)
        // 测试用 0 延迟，避免真实退避等待拖慢测试。
        return HTTPClient(session: session, maxRetries: maxRetries, retryDelay: { _, _ in 0 })
    }

    private func getRequest() -> URLRequest {
        URLRequest(url: URL(string: "https://example.com/items")!)
    }

    override func setUp() {
        super.setUp()
        MockURLProtocol.reset()
    }

    func testRetriesOn429ThenSucceeds() async throws {
        MockURLProtocol.stubs = [
            .init(status: 429, headers: ["Retry-After": "0"], body: Data()),
            .init(status: 200, headers: [:], body: Data("ok".utf8))
        ]
        let (data, response) = try await makeClient().data(for: getRequest())
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(String(data: data, encoding: .utf8), "ok")
        XCTAssertEqual(MockURLProtocol.requestCount, 2)
    }

    func testRetriesOn500UpToMaxThenReturnsLast() async throws {
        MockURLProtocol.stubs = [.init(status: 500, headers: [:], body: Data())]
        let (_, response) = try await makeClient(maxRetries: 2).data(for: getRequest())
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
        // maxRetries=2 → 共 3 次尝试
        XCTAssertEqual(MockURLProtocol.requestCount, 3)
    }

    func testDoesNotRetryNonIdempotentPOST() async throws {
        MockURLProtocol.stubs = [
            .init(status: 500, headers: [:], body: Data()),
            .init(status: 200, headers: [:], body: Data())
        ]
        var request = getRequest()
        request.httpMethod = "POST"
        let (_, response) = try await makeClient().data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 500)
        XCTAssertEqual(MockURLProtocol.requestCount, 1) // POST 不自动重试
    }

    func testSuccessIssuesSingleRequest() async throws {
        MockURLProtocol.stubs = [.init(status: 200, headers: [:], body: Data("hi".utf8))]
        let (data, _) = try await makeClient().data(for: getRequest())
        XCTAssertEqual(String(data: data, encoding: .utf8), "hi")
        XCTAssertEqual(MockURLProtocol.requestCount, 1)
    }

    func testDefaultRetryDelayPrefersRetryAfterHeader() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "5"]
        )!
        XCTAssertEqual(HTTPClient.defaultRetryDelay(response, attempt: 0), 5)
    }

    func testDefaultRetryDelayIgnoresNonFiniteRetryAfterHeader() throws {
        let response = HTTPURLResponse(
            url: URL(string: "https://example.com")!,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "NaN"]
        )!

        XCTAssertEqual(HTTPClient.defaultRetryDelay(response, attempt: 1), 2)
    }

    func testDefaultRetryDelayClampsRetryAfterHeaderRange() throws {
        let url = URL(string: "https://example.com")!
        let negativeResponse = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "-5"]
        )!
        let hugeResponse = HTTPURLResponse(
            url: url,
            statusCode: 429,
            httpVersion: nil,
            headerFields: ["Retry-After": "999"]
        )!

        XCTAssertEqual(HTTPClient.defaultRetryDelay(negativeResponse, attempt: 0), 0)
        XCTAssertEqual(HTTPClient.defaultRetryDelay(hugeResponse, attempt: 0), 30)
    }
}
