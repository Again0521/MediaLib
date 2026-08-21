import Foundation
import XCTest
@testable import MediaLibCore
@testable import MediaLibServer

final class ServerRequestRateLimiterTests: XCTestCase {
    func testTokenBucketRejectsBurstAndRefillsWithRetryAfter() {
        let clock = MutableRateLimitClock()
        let limiter = ServerRequestRateLimiter(
            policies: policies(capacity: 2, refillPerSecond: 0.5),
            clock: { clock.now },
            salt: "test-salt"
        )

        XCTAssertTrue(limiter.evaluate(scope: .apiRead, identityComponents: ["alice"]).isAllowed)
        XCTAssertTrue(limiter.evaluate(scope: .apiRead, identityComponents: ["alice"]).isAllowed)
        let denied = limiter.evaluate(scope: .apiRead, identityComponents: ["alice"])
        XCTAssertFalse(denied.isAllowed)
        XCTAssertEqual(denied.retryAfterSeconds, 2)

        clock.advance(by: 2)
        XCTAssertTrue(limiter.evaluate(scope: .apiRead, identityComponents: ["alice"]).isAllowed)
    }

    func testScopesAndHashedIdentitiesAreIsolated() {
        let limiter = ServerRequestRateLimiter(
            policies: policies(capacity: 1, refillPerSecond: 0.01),
            salt: "test-salt"
        )

        XCTAssertTrue(limiter.evaluate(scope: .apiRead, identityComponents: ["alice"]).isAllowed)
        XCTAssertFalse(limiter.evaluate(scope: .apiRead, identityComponents: ["alice"]).isAllowed)
        XCTAssertTrue(limiter.evaluate(scope: .apiRead, identityComponents: ["bob"]).isAllowed)
        XCTAssertTrue(limiter.evaluate(scope: .mediaStream, identityComponents: ["alice"]).isAllowed)
        XCTAssertEqual(limiter.retainedEntryCount, 3)
    }

    func testConcurrentEvaluationNeverExceedsCapacity() {
        let limiter = ServerRequestRateLimiter(
            policies: policies(capacity: 10, refillPerSecond: 0.000_001),
            clock: { 100 },
            salt: "test-salt"
        )
        let counter = LockedAllowedCounter()

        DispatchQueue.concurrentPerform(iterations: 200) { _ in
            if limiter.evaluate(scope: .loginClient, identityComponents: ["same-client"]).isAllowed {
                counter.increment()
            }
        }

        XCTAssertEqual(counter.value, 10)
    }

    func testTTLAndHardEntryLimitPreventIdentityFloodGrowth() {
        let clock = MutableRateLimitClock()
        let limiter = ServerRequestRateLimiter(
            policies: policies(capacity: 1, refillPerSecond: 0.01),
            clock: { clock.now },
            salt: "test-salt",
            entryTTL: 10,
            maximumEntryCount: 100
        )

        for index in 0..<250 {
            _ = limiter.evaluate(scope: .loginIdentity, identityComponents: ["forged-\(index)"])
        }
        XCTAssertLessThanOrEqual(limiter.retainedEntryCount, 100)

        clock.advance(by: 11)
        _ = limiter.evaluate(scope: .loginIdentity, identityComponents: ["fresh"])
        XCTAssertEqual(limiter.retainedEntryCount, 1)
    }

    func testRouterReturnsSafe429AndSamePrincipalCannotBypassByChangingClientAddress() {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.apiRead] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        let limiter = ServerRequestRateLimiter(policies: custom, salt: "test-salt")
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            authenticationProvider: { _ in .testAdministrator() },
            rateLimiter: limiter
        )

        let first = router.response(
            for: "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n",
            clientAddressKey: "192.0.2.10"
        )
        let bypassAttempt = router.response(
            for: "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n",
            clientAddressKey: "192.0.2.11"
        )
        let headers = String(data: bypassAttempt.serializedHeaders(), encoding: .utf8) ?? ""

        XCTAssertEqual(first.statusCode, 200)
        XCTAssertEqual(bypassAttempt.statusCode, 429)
        XCTAssertTrue(headers.contains("Retry-After: "))
        XCTAssertTrue(headers.contains("Content-Security-Policy: default-src 'none'"))
        XCTAssertFalse(headers.contains("192.0.2.11"))
    }

    func testAuthenticatedReadsDoNotConsumeUnauthenticatedBudget() {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.unauthenticated] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            authenticationProvider: { _ in .testAdministrator() },
            rateLimiter: ServerRequestRateLimiter(policies: custom, salt: "authenticated-read-test")
        )
        let request = "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n"

        XCTAssertEqual(router.response(for: request).statusCode, 200)
        XCTAssertEqual(router.response(for: request).statusCode, 200)
    }

    func testUnauthenticatedReadsRemainRateLimitedAfterAuthenticationFails() {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.unauthenticated] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            rateLimiter: ServerRequestRateLimiter(policies: custom, salt: "unauthenticated-read-test")
        )
        let request = "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n"

        XCTAssertEqual(router.response(for: request).statusCode, 401)
        XCTAssertEqual(router.response(for: request).statusCode, 429)
    }

    func testArtworkUsesDedicatedBudgetInsteadOfPageAPIReadBudget() {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.apiRead] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        custom[.artworkRead] = ServerRateLimitPolicy(capacity: 2, refillPerSecond: 0.01)
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            authenticationProvider: { _ in .testAdministrator() },
            rateLimiter: ServerRequestRateLimiter(policies: custom, salt: "artwork-read-test")
        )
        let pageRequest = "GET /api/v1/library/summary HTTP/1.1\r\nHost: localhost\r\n\r\n"
        let artworkRequest = "GET /api/v1/images/missing/poster?size=160 HTTP/1.1\r\nHost: localhost\r\n\r\n"

        XCTAssertEqual(router.response(for: pageRequest).statusCode, 200)
        XCTAssertEqual(router.response(for: artworkRequest).statusCode, 404)
        XCTAssertEqual(router.response(for: artworkRequest).statusCode, 404)
        XCTAssertEqual(router.response(for: artworkRequest).statusCode, 429)
    }

    func testStaticAssetsDoNotConsumePublicProbeBudget() {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.publicProbe] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            rateLimiter: ServerRequestRateLimiter(policies: custom, salt: "static-asset-test")
        )

        XCTAssertEqual(router.response(
            for: "GET /health HTTP/1.1\r\nHost: localhost\r\n\r\n",
            clientAddressKey: "192.0.2.10"
        ).statusCode, 200)
        XCTAssertEqual(router.response(
            for: "GET /assets/app-shell.css HTTP/1.1\r\nHost: localhost\r\n\r\n",
            clientAddressKey: "192.0.2.10"
        ).statusCode, 200)
        XCTAssertEqual(router.response(
            for: "GET /assets/music.css HTTP/1.1\r\nHost: localhost\r\n\r\n",
            clientAddressKey: "192.0.2.10"
        ).statusCode, 200)
    }

    func testLoginIdentityLimitCannotBeBypassedByChangingClientAddress() throws {
        var custom = policies(capacity: 100, refillPerSecond: 1)
        custom[.loginIdentity] = ServerRateLimitPolicy(capacity: 1, refillPerSecond: 0.01)
        let limiter = ServerRequestRateLimiter(policies: custom, salt: "test-salt")
        let router = LocalHTTPRouter(
            serverID: "server",
            serverName: "Server",
            rateLimiter: limiter
        )
        let body = try JSONSerialization.data(withJSONObject: [
            "username": "Alice",
            "password": "password-value",
            "deviceName": "Browser",
            "platform": "Web"
        ])

        let first = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: body,
            clientAddressKey: "192.0.2.10"
        )
        let bypassAttempt = router.response(
            for: "POST /api/v1/auth/login HTTP/1.1\r\nHost: localhost\r\n\r\n",
            body: body,
            clientAddressKey: "192.0.2.11"
        )

        XCTAssertEqual(first.statusCode, 503, "测试未配置认证服务，首个请求应到达认证边界")
        XCTAssertEqual(bypassAttempt.statusCode, 429)
    }

    private func policies(
        capacity: Int,
        refillPerSecond: Double
    ) -> [ServerRateLimitScope: ServerRateLimitPolicy] {
        Dictionary(uniqueKeysWithValues: ServerRateLimitScope.allCases.map {
            ($0, ServerRateLimitPolicy(capacity: capacity, refillPerSecond: refillPerSecond))
        })
    }
}

private final class MutableRateLimitClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TimeInterval = 0

    var now: TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func advance(by interval: TimeInterval) {
        lock.lock()
        value += interval
        lock.unlock()
    }
}

private final class LockedAllowedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}
