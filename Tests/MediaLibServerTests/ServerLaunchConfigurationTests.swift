import XCTest
@testable import MediaLibServer

final class ServerLaunchConfigurationTests: XCTestCase {
    func testDefaultsRemainLoopbackWithoutProxyConfiguration() throws {
        let configuration = try ServerLaunchConfiguration.load(environment: [:])
        XCTAssertEqual(configuration.host, "127.0.0.1")
        XCTAssertNil(configuration.publicOrigin)
        XCTAssertTrue(configuration.trustedProxyAddresses.isEmpty)
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
