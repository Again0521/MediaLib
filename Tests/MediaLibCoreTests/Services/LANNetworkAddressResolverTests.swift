import XCTest
@testable import MediaLibCore

final class LANNetworkAddressResolverTests: XCTestCase {
    func testPrivateAddressPolicyRejectsPublicMalformedAndLoopbackAddresses() {
        for value in ["10.0.0.1", "172.16.0.1", "172.31.255.254", "192.168.31.100", "169.254.2.3"] {
            XCTAssertTrue(LANIPv4AddressPolicy.isPrivate(value), value)
        }
        for value in ["127.0.0.1", "8.8.8.8", "172.15.0.1", "172.32.0.1", "192.0.2.1", "1.2.3", "bad"] {
            XCTAssertFalse(LANIPv4AddressPolicy.isPrivate(value), value)
        }
    }

    func testCandidateSortingPrefersPhysicalThenBridgeInterfaces() {
        let sorted = LANNetworkAddressResolver.sortedCandidates([
            .init(interfaceName: "bridge0", address: "192.168.50.2"),
            .init(interfaceName: "en1", address: "192.168.31.101"),
            .init(interfaceName: "en0", address: "192.168.31.100"),
            .init(interfaceName: "pdp_ip0", address: "10.0.0.2")
        ])
        XCTAssertEqual(sorted.map(\.interfaceName), ["en0", "en1", "bridge0", "pdp_ip0"])
    }

    func testLiveDiscoveryNeverReturnsAPublicAddress() {
        XCTAssertTrue(
            LANNetworkAddressResolver.privateIPv4Addresses().allSatisfy {
                LANIPv4AddressPolicy.isPrivate($0.address)
            }
        )
    }
}
