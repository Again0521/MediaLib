import Foundation
import XCTest
@testable import MediaLib

final class ServerModeCertificateSupportTests: XCTestCase {
    func testPEMCertificateDecodingAndDERExport() throws {
        let bytes = Data([0x30, 0x03, 0x01, 0x02, 0x03])
        let pem = """
        -----BEGIN CERTIFICATE-----
        \(bytes.base64EncodedString())
        -----END CERTIFICATE-----
        """
        XCTAssertEqual(
            try ServerModeCertificateSupport.certificateDERData(fromPEM: Data(pem.utf8)),
            bytes
        )

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLib-Certificate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let source = directory.appendingPathComponent("ca.pem")
        let destination = directory.appendingPathComponent("ca.cer")
        try Data(pem.utf8).write(to: source)
        try ServerModeCertificateSupport.exportCertificate(from: source, to: destination)
        XCTAssertEqual(try Data(contentsOf: destination), bytes)
    }

    func testInvalidPEMIsRejected() {
        XCTAssertThrowsError(
            try ServerModeCertificateSupport.certificateDERData(fromPEM: Data("not a certificate".utf8))
        )
    }
}
