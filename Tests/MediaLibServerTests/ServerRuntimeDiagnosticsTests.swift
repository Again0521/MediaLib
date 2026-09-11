import XCTest
@testable import MediaLibServer
@testable import MediaLibServerProtocol

final class ServerRuntimeDiagnosticsTests: XCTestCase {
    func testServiceVersionPrefersBundleThenEnvironmentThenGeneratedMetadata() {
        XCTAssertEqual(
            ServerRuntimeDiagnostics.resolveServiceVersion(
                bundleValue: " 2.0.0 ",
                environmentValue: "1.9.0"
            ),
            "2.0.0"
        )
        XCTAssertEqual(
            ServerRuntimeDiagnostics.resolveServiceVersion(
                bundleValue: " \n ",
                environmentValue: " 1.9.0 "
            ),
            "1.9.0"
        )
        XCTAssertEqual(
            ServerRuntimeDiagnostics.resolveServiceVersion(
                bundleValue: nil,
                environmentValue: ""
            ),
            GeneratedReleaseMetadata.productVersion
        )
    }
}
