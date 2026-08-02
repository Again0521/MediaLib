import XCTest
@testable import MediaLibCore

final class ServerModeConfigurationTests: XCTestCase {
    func testDefaultsProduceStableLoopbackEndpoint() {
        let configuration = ServerModeConfiguration(serverID: "server-a")

        XCTAssertEqual(configuration.port, 8098)
        XCTAssertEqual(configuration.loopbackBaseURL.absoluteString, "http://127.0.0.1:8098")
        XCTAssertEqual(configuration.serverID, "server-a")
        XCTAssertFalse(configuration.isLightweightMode)
        XCTAssertNil(configuration.publicOrigin)
        XCTAssertTrue(configuration.trustedProxyAddresses.isEmpty)
    }

    func testDecoderMigratesPartialAndInvalidValues() throws {
        let data = Data(#"{"isEnabled":true,"serverID":" ","serverName":"  客厅服务器  ","port":70000}"#.utf8)
        let configuration = try JSONDecoder().decode(ServerModeConfiguration.self, from: data)

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertFalse(configuration.serverID.isEmpty)
        XCTAssertEqual(configuration.serverName, "客厅服务器")
        XCTAssertEqual(configuration.port, 8098)
        XCTAssertFalse(configuration.isLightweightMode)
    }

    func testDecoderRestoresLightweightModeWhenExplicitlyEnabled() throws {
        let data = Data(#"{"isEnabled":true,"serverID":"server-a","serverName":"Server","port":8098,"isLightweightMode":true}"#.utf8)
        let configuration = try JSONDecoder().decode(ServerModeConfiguration.self, from: data)

        XCTAssertTrue(configuration.isEnabled)
        XCTAssertTrue(configuration.isLightweightMode)
    }

    func testNormalizesExplicitHTTPSProxyConfiguration() {
        var configuration = ServerModeConfiguration(
            serverID: "server-a",
            publicOrigin: "https://media.example.test/",
            trustedProxyAddresses: [" 192.168.1.10", "127.0.0.1", "bad", "127.0.0.1"]
        )
        XCTAssertEqual(configuration.publicOrigin, "https://media.example.test")
        XCTAssertEqual(configuration.trustedProxyAddresses, ["127.0.0.1", "192.168.1.10"])

        configuration.updatePublicOrigin("http://media.example.test")
        configuration.updateTrustedProxyAddresses(["10.0.0.1,10.0.0.2"])
        XCTAssertNil(configuration.publicOrigin)
        XCTAssertTrue(configuration.trustedProxyAddresses.isEmpty)

        configuration.updateTrustedProxyAddresses(["127.0.0.1"])
        XCTAssertTrue(configuration.trustedProxyAddresses.isEmpty)
    }

    func testStoreKeepsGeneratedIdentityAcrossLoads() {
        let suiteName = "MediaLibTests.ServerModeConfiguration.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let store = ServerModeSettingsStore(defaults: defaults)

        let first = store.load()
        let second = store.load()

        XCTAssertEqual(second.serverID, first.serverID)
    }
}
