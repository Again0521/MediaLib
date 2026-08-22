import XCTest
@testable import MediaLibServer

final class ServerLaunchConfigurationTests: XCTestCase {
    func testDefaultsRemainLoopbackWithoutProxyConfiguration() throws {
        let configuration = try ServerLaunchConfiguration.load(environment: [:])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.networkAccessMode, .loopbackOnly)
        XCTAssertNil(configuration.publicOrigin)
        XCTAssertTrue(configuration.trustedProxyAddresses.isEmpty)
        XCTAssertFalse(configuration.lanDirectPlayEnabled)
    }

    func testParsesExplicitLanHTTPSModeAndRejectsUnknownModes() throws {
        let lan = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "lan-https"
        ])
        XCTAssertEqual(lan.networkAccessMode, .lanHTTPS)

        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "public-http"
        ])) { error in
            XCTAssertEqual(
                error as? ServerConfigurationError,
                .invalidNetworkAccessMode("public-http")
            )
        }
    }

    func testRawLoopbackRunFailsClosedForLanHTTPSMode() throws {
        let lan = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "lan-https"
        ])
        let adapter = try LocalLoopbackHTTPServer(configuration: lan)
        XCTAssertThrowsError(try adapter.run()) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .lanHTTPSRuntimeUnavailable)
        }
    }

    /// 局域网直连必须建立在 HTTPS 公开 Origin 与可信反代之上。孤立地打开开关
    /// 只会制造"以为已生效"的错觉，因此直接拒绝启动而不是静默忽略。
    func testLanDirectPlayRequiresTrustedTransportBoundary() throws {
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_LAN_DIRECT_PLAY": "1"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidLanDirectPlayConfiguration)
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "https://media.example.test",
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "127.0.0.1",
            "MEDIALIB_SERVER_LAN_DIRECT_PLAY": "maybe"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidLanDirectPlayConfiguration)
        }

        let configuration = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "https://media.example.test",
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "127.0.0.1",
            "MEDIALIB_SERVER_LAN_DIRECT_PLAY": "1"
        ])
        XCTAssertTrue(configuration.lanDirectPlayEnabled)
    }

    func testAcceptsExplicitHTTPSOriginAndIPv4Proxy() throws {
        let configuration = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "https://media.example.test",
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "127.0.0.1, 192.168.1.10"
        ])
        XCTAssertEqual(configuration.publicOrigin?.absoluteString, "https://media.example.test")
        XCTAssertEqual(configuration.trustedProxyAddresses, ["127.0.0.1", "192.168.1.10"])
    }

    func testRejectsNonHTTPSOriginAndUnpairedProxyList() {
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "http://media.example.test"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidPublicOrigin("http://media.example.test"))
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "127.0.0.1"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidTrustedProxyConfiguration)
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "https://media.example.test",
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "not-an-ip"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidTrustedProxyConfiguration)
        }
    }
}
