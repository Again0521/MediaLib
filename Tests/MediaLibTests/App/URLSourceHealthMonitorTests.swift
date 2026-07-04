import XCTest
@testable import MediaLib

@MainActor
final class URLSourceHealthMonitorTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    /// 用可注入探测器：按 host 返回固定状态，避免真实网络。
    private func cannedMonitor(_ map: [String: URLItemHealthState]) -> URLSourceHealthMonitor {
        URLSourceHealthMonitor(probe: { url in
            map[url.host ?? ""] ?? .ok
        })
    }

    func testStateDefaultsToUnknown() {
        let monitor = URLSourceHealthMonitor(probe: { _ in .ok })
        XCTAssertEqual(monitor.state(for: "missing"), .unknown)
    }

    func testRefreshPopulatesResultsAndInvokesCallback() async {
        let monitor = cannedMonitor(["good.example": .ok, "bad.example": .unreachable])
        let done = expectation(description: "onUpdated")
        monitor.refresh(
            probeItems: [
                (id: "1", url: url("https://good.example/a.mp4")),
                (id: "2", url: url("https://bad.example/b.mp4"))
            ],
            liveIDs: ["1", "2"],
            onUpdated: { done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(monitor.state(for: "1"), .ok)
        XCTAssertEqual(monitor.state(for: "2"), .unreachable)
    }

    func testRefreshDropsStaleEntriesViaLiveIDs() async {
        let monitor = cannedMonitor(["a.example": .ok])
        let first = expectation(description: "first")
        monitor.refresh(
            probeItems: [(id: "keep", url: url("https://a.example/x.mp4"))],
            liveIDs: ["keep", "stale"],
            onUpdated: { first.fulfill() }
        )
        await fulfillment(of: [first], timeout: 2)

        // 第二次刷新时 "stale" 不在 liveIDs，旧结果应被清掉；空 probeItems → 不回调。
        monitor.refresh(probeItems: [], liveIDs: ["keep"], onUpdated: {
            XCTFail("空 probeItems 不应回调 onUpdated")
        })
        XCTAssertEqual(monitor.state(for: "keep"), .ok)
        XCTAssertEqual(monitor.state(for: "stale"), .unknown)
    }

    func testResetClearsAllResults() async {
        let monitor = cannedMonitor(["a.example": .ok])
        let done = expectation(description: "done")
        monitor.refresh(
            probeItems: [(id: "1", url: url("https://a.example/x.mp4"))],
            liveIDs: ["1"],
            onUpdated: { done.fulfill() }
        )
        await fulfillment(of: [done], timeout: 2)
        XCTAssertEqual(monitor.state(for: "1"), .ok)

        monitor.reset()
        XCTAssertTrue(monitor.healthByID.isEmpty)
        XCTAssertEqual(monitor.state(for: "1"), .unknown)
    }

    // MARK: - classify（搬自 AppState 的逐字逻辑）

    private func httpResponse(status: Int, contentType: String?) -> HTTPURLResponse {
        var headers: [String: String] = [:]
        if let contentType { headers["Content-Type"] = contentType }
        return HTTPURLResponse(url: url("https://x.example"), statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    func testClassifyClientErrorIsUnreachable() {
        XCTAssertEqual(URLSourceHealthMonitor.classify(httpResponse(status: 404, contentType: "video/mp4")), .unreachable)
    }

    func testClassifyHTMLIsUnparseable() {
        XCTAssertEqual(URLSourceHealthMonitor.classify(httpResponse(status: 200, contentType: "text/html; charset=utf-8")), .unparseable)
    }

    func testClassifyVideoIsOK() {
        XCTAssertEqual(URLSourceHealthMonitor.classify(httpResponse(status: 200, contentType: "video/mp4")), .ok)
    }

    func testClassifyNonHTTPResponseIsOK() {
        let response = URLResponse(url: url("https://x.example"), mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        XCTAssertEqual(URLSourceHealthMonitor.classify(response), .ok)
    }
}
