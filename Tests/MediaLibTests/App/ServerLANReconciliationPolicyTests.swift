import MediaLibCore
import XCTest
@testable import MediaLib

final class ServerLANReconciliationPolicyTests: XCTestCase {
    func testChangedPrivateAddressRefreshesEnabledLANConfiguration() throws {
        let configuration = ServerModeConfiguration(
            isEnabled: true,
            serverID: "server-lan",
            networkAccessMode: .lanHTTPS,
            lanAddress: "192.168.31.100"
        )

        let refreshed = try XCTUnwrap(
            ServerLANReconciliationPolicy.refreshedConfiguration(
                configuration,
                discoveredAddress: "192.168.31.101"
            )
        )

        XCTAssertEqual(refreshed.lanAddress, "192.168.31.101")
        XCTAssertEqual(refreshed.lanHTTPSBaseURL?.absoluteString, "https://192.168.31.101:8098")
    }

    func testUnchangedPublicAndInactiveAddressesDoNotTriggerRefresh() {
        let active = ServerModeConfiguration(
            isEnabled: true,
            serverID: "server-lan",
            networkAccessMode: .lanHTTPS,
            lanAddress: "192.168.31.100"
        )
        XCTAssertNil(ServerLANReconciliationPolicy.refreshedConfiguration(
            active,
            discoveredAddress: "192.168.31.100"
        ))
        XCTAssertNil(ServerLANReconciliationPolicy.refreshedConfiguration(
            active,
            discoveredAddress: "8.8.8.8"
        ))

        var disabled = active
        disabled.isEnabled = false
        XCTAssertNil(ServerLANReconciliationPolicy.refreshedConfiguration(
            disabled,
            discoveredAddress: "192.168.31.101"
        ))
    }

    func testRestartPolicyCoversAddressChangeWakeAndFailedRuntimeWithoutRacingStartup() {
        XCTAssertTrue(ServerLANReconciliationPolicy.shouldRestart(
            status: .running,
            addressChanged: true,
            forceRestart: false
        ))
        XCTAssertTrue(ServerLANReconciliationPolicy.shouldRestart(
            status: .running,
            addressChanged: false,
            forceRestart: true
        ))
        XCTAssertTrue(ServerLANReconciliationPolicy.shouldRestart(
            status: .failed("test"),
            addressChanged: false,
            forceRestart: false
        ))
        XCTAssertFalse(ServerLANReconciliationPolicy.shouldRestart(
            status: .starting,
            addressChanged: true,
            forceRestart: true
        ))
    }
}
