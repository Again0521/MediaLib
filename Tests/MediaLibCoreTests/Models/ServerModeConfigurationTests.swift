import XCTest
@testable import MediaLibCore

final class ServerModeConfigurationTests: XCTestCase {
    func testDefaultsProduceStableLoopbackEndpoint() {
        let configuration = ServerModeConfiguration(serverID: "server-a")

        XCTAssertEqual(configuration.port, 8098)
        XCTAssertEqual(configuration.loopbackBaseURL.absoluteString, "http://127.0.0.1:8098")
        XCTAssertEqual(configuration.serverID, "server-a")
        XCTAssertFalse(configuration.isLightweightMode)
        XCTAssertEqual(configuration.networkAccessMode, .loopbackOnly)
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
        XCTAssertEqual(configuration.networkAccessMode, .loopbackOnly)
    }

    func testNetworkAccessModeRoundTripsAndOldPayloadsRemainLoopback() throws {
        let lan = ServerModeConfiguration(
            serverID: "server-a",
            networkAccessMode: .lanHTTPS,
            lanAddress: "192.168.31.100"
        )
        let encoded = try JSONEncoder().encode(lan)
        let decoded = try JSONDecoder().decode(ServerModeConfiguration.self, from: encoded)
        XCTAssertEqual(decoded.networkAccessMode, .lanHTTPS)
        XCTAssertEqual(decoded.lanAddress, "192.168.31.100")

        let legacy = Data(
            #"{"isEnabled":true,"serverID":"server-a","serverName":"Server","port":8098}"#.utf8
        )
        XCTAssertEqual(
            try JSONDecoder().decode(ServerModeConfiguration.self, from: legacy).networkAccessMode,
            .loopbackOnly
        )
    }

    func testLANHTTPSUsesPrivateAddressAndTracksPortChanges() {
        var configuration = ServerModeConfiguration(
            serverID: "server-a",
            publicOrigin: "https://proxy.example.test",
            trustedProxyAddresses: ["127.0.0.1"]
        )
        XCTAssertFalse(configuration.enableLANHTTPS(address: "8.8.8.8"))
        XCTAssertTrue(configuration.enableLANHTTPS(address: "192.168.31.100"))
        XCTAssertEqual(configuration.networkAccessMode, .lanHTTPS)
        XCTAssertEqual(configuration.lanHTTPSBaseURL?.absoluteString, "https://192.168.31.100:8098")
        XCTAssertEqual(configuration.effectivePublicOrigin, "https://192.168.31.100:8098")
        XCTAssertTrue(configuration.effectiveTrustedProxyAddresses.isEmpty)

        configuration.updatePort(9000)
        XCTAssertEqual(configuration.effectiveBaseURL.absoluteString, "https://192.168.31.100:9000")
        configuration.updateNetworkAccessMode(.loopbackOnly)
        XCTAssertNil(configuration.lanAddress)
        XCTAssertEqual(configuration.effectiveBaseURL.absoluteString, "https://proxy.example.test")
        XCTAssertEqual(configuration.effectiveTrustedProxyAddresses, ["127.0.0.1"])
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
