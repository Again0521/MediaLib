import XCTest
@testable import MediaLibServerProtocol

final class ServerProtocolModelsTests: XCTestCase {
    func testHealthRoundTripsWithStableAPIVersion() throws {
        let health = ServerHealth(
            serverID: "server-001",
            serverName: "客厅服务器",
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let data = try JSONEncoder().encode(health)
        let decoded = try JSONDecoder().decode(ServerHealth.self, from: data)

        XCTAssertEqual(decoded, health)
        XCTAssertEqual(decoded.status, "ok")
        XCTAssertEqual(decoded.apiVersion, MlinkProtocol.currentAPIVersion)
    }

    func testDescriptorNormalizesCapabilityOrder() {
        let descriptor = MlinkServerDescriptor(
            serverID: "server-001",
            serverName: "客厅服务器",
            capabilities: ["server-discovery", "health"]
        )

        XCTAssertEqual(descriptor.capabilities, ["health", "server-discovery"])
        XCTAssertEqual(descriptor.apiVersion, MlinkProtocol.currentAPIVersion)
    }
}
