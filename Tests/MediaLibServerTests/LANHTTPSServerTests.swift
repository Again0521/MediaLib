import Foundation
import MediaLibCore
import XCTest
@testable import MediaLibServer

final class LANHTTPSServerTests: XCTestCase {
    func testLANAddressPolicyAllowsOnlyPrivateAndLoopbackIPv4() {
        for address in ["127.0.0.1", "10.1.2.3", "172.16.0.1", "172.31.255.254", "192.168.31.100", "169.254.1.2"] {
            XCTAssertTrue(LANIPv4AddressPolicy.isPrivateOrLoopback(address), address)
        }
        for address in ["8.8.8.8", "172.15.0.1", "172.32.0.1", "192.0.2.1", "::1", "not-an-address"] {
            XCTAssertFalse(LANIPv4AddressPolicy.isPrivateOrLoopback(address), address)
        }
    }

    func testTLSIdentityStoreCreatesStableCAAndPrivateKeyPermissions() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let store = LANTLSIdentityStore(directory: root)
        let first = try store.loadOrCreate(serverName: "MediaLIB Test", addresses: ["192.168.31.100"])
        let firstCA = try Data(contentsOf: first.certificateAuthority)
        let second = try store.loadOrCreate(serverName: "MediaLIB Test", addresses: ["192.168.31.100"])

        XCTAssertEqual(try Data(contentsOf: second.certificateAuthority), firstCA)
        XCTAssertTrue(try String(contentsOf: second.certificate).contains("BEGIN CERTIFICATE"))
        let attributes = try FileManager.default.attributesOfItem(atPath: second.privateKey.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testTLSIdentityStoreRejectsPublicAddress() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertThrowsError(
            try LANTLSIdentityStore(directory: root)
                .loadOrCreate(serverName: "MediaLIB Test", addresses: ["8.8.8.8"])
        )
    }

    func testTLSIdentityStoreKeepsCAWhileRenewingLeafForChangedAddress() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-LAN-TLS-Renewal-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = LANTLSIdentityStore(directory: root)

        let first = try store.loadOrCreate(
            serverName: "MediaLIB Test",
            addresses: ["192.168.31.100"]
        )
        let caBefore = try Data(contentsOf: first.certificateAuthority)
        let leafBefore = try Data(contentsOf: first.certificate)
        XCTAssertTrue(try certificateDescription(at: first.certificate).contains("IP Address:192.168.31.100"))

        let second = try store.loadOrCreate(
            serverName: "MediaLIB Test",
            addresses: ["192.168.31.101"]
        )
        let caAfter = try Data(contentsOf: second.certificateAuthority)
        let leafAfter = try Data(contentsOf: second.certificate)
        let secondDescription = try certificateDescription(at: second.certificate)

        XCTAssertEqual(caAfter, caBefore, "客户端已信任的 CA 不能随 DHCP 地址变化而轮换")
        XCTAssertNotEqual(leafAfter, leafBefore, "地址变化必须续签叶证书")
        XCTAssertTrue(secondDescription.contains("IP Address:192.168.31.101"))
        XCTAssertFalse(secondDescription.contains("IP Address:192.168.31.100"))
        XCTAssertEqual(try verify(certificate: second.certificate, using: second.certificateAuthority), "OK")
    }

    private func certificateDescription(at url: URL) throws -> String {
        try runOpenSSL(["x509", "-in", url.path, "-noout", "-text"])
    }

    private func verify(certificate: URL, using certificateAuthority: URL) throws -> String {
        let output = try runOpenSSL([
            "verify", "-CAfile", certificateAuthority.path, certificate.path
        ])
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
            .hasSuffix(": OK") ? "OK" : output
    }

    private func runOpenSSL(_ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/openssl")
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        guard process.terminationStatus == 0,
              let value = String(data: data, encoding: .utf8)
        else { throw LANHTTPSServerTestError.opensslFailed }
        return value
    }
}

private enum LANHTTPSServerTestError: Error {
    case opensslFailed
}
