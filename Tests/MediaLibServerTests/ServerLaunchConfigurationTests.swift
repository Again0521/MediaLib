import XCTest
@testable import MediaLibServer

final class ServerLaunchConfigurationTests: XCTestCase {
    func testDefaultsRemainLoopbackWithoutProxyConfiguration() throws {
        let configuration = try ServerLaunchConfiguration.load(environment: [:])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertEqual(configuration.listenAddresses, ["127.0.0.1"])
        XCTAssertEqual(configuration.networkAccessMode, .loopbackOnly)
        XCTAssertNil(configuration.publicOrigin)
        XCTAssertEqual(configuration.trustedProxyAddresses, ["127.0.0.1", "::1"])
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

    func testAdvancedHTTPListenersKeepLoopbackAndRejectInvalidOrLegacyTLSSettings() throws {
        let multiple = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_LISTEN_ADDRESSES": "::1, 192.0.2.10, ::1"
        ])
        XCTAssertEqual(multiple.listenAddresses, ["127.0.0.1", "::1", "192.0.2.10"])
        let wildcard = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_LISTEN_ADDRESSES": "127.0.0.1,0.0.0.0,::1,::"
        ])
        XCTAssertEqual(wildcard.listenAddresses, ["0.0.0.0", "::"])
        for value in ["", "localhost", "127.0.0.1,", "127.0.0.1,evil.example"] {
            XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
                "MEDIALIB_SERVER_LISTEN_ADDRESSES": value
            ]))
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "lan-https",
            "MEDIALIB_SERVER_LISTEN_ADDRESSES": "127.0.0.1"
        ]))
    }

    func testLegacyTLSCanExposeSeparateLoopbackWebsiteWithoutPortCollision() throws {
        let configuration = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "lan-https",
            "MEDIALIB_SERVER_PORT": "8098",
            "MEDIALIB_SERVER_WEBSITE_PORT": "8099"
        ])
        XCTAssertEqual(configuration.port, 8098)
        XCTAssertEqual(configuration.websitePort, 8099)
        for invalid in ["8098", "0", "65536", "invalid"] {
            XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
                "MEDIALIB_SERVER_NETWORK_ACCESS_MODE": "lan-https",
                "MEDIALIB_SERVER_WEBSITE_PORT": invalid
            ]))
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_WEBSITE_PORT": "8099"
        ]))
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

    func testProxyTrustDoesNotRequireAnAdvertisedOriginAndEmptyDisablesTrust() throws {
        let proxy = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "127.0.0.1, ::1"
        ])
        XCTAssertNil(proxy.publicOrigin)
        XCTAssertEqual(proxy.trustedProxyAddresses, ["127.0.0.1", "::1"])
        let disabled = try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_TRUSTED_PROXIES": ""
        ])
        XCTAssertTrue(disabled.trustedProxyAddresses.isEmpty)
        let validation = ServerRuntimeConfigurationValidator.validate(.init(
            currentPassword: nil, serverName: "Server", port: 8098,
            networkAccessMode: .loopbackOnly, publicOrigin: nil,
            trustedProxyAddresses: ["127.0.0.1", "::1"]), hostControlAvailable: true)
        XCTAssertTrue(validation.valid, "\(validation.issueCodes)")
        XCTAssertEqual(validation.normalizedTrustedProxyAddresses, ["127.0.0.1", "::1"])
    }

    func testRejectsNonHTTPSOriginAndInvalidProxyList() {
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "http://media.example.test"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidPublicOrigin("http://media.example.test"))
        }
        XCTAssertThrowsError(try ServerLaunchConfiguration.load(environment: [
            "MEDIALIB_SERVER_PUBLIC_ORIGIN": "https://media.example.test",
            "MEDIALIB_SERVER_TRUSTED_PROXIES": "not-an-ip"
        ])) { error in
            XCTAssertEqual(error as? ServerConfigurationError, .invalidTrustedProxyConfiguration)
        }
    }
}
