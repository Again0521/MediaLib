import Foundation
import XCTest

final class CIAcceptanceWorkflowTests: XCTestCase {
    func testPullRequestWorkflowPinsToolchainAndRunsRequiredFastAndTransportGates() throws {
        let workflow = try contents(".github/workflows/swift.yml")

        XCTAssertTrue(workflow.contains("runs-on: macos-15"))
        XCTAssertTrue(workflow.contains("xcode-version: '26.3'"))
        XCTAssertFalse(workflow.contains("xcode-version: latest-stable"))
        XCTAssertTrue(workflow.contains("bash scripts/check_swift_conflict_copies.sh"))
        XCTAssertTrue(workflow.contains("bash scripts/check_cargon2_vendor.sh"))
        XCTAssertTrue(workflow.contains("python3 scripts/release_metadata.py --check"))
        XCTAssertTrue(workflow.contains("MEDIALIB_REQUIRE_LAN_E2E: '1'"))
        XCTAssertTrue(workflow.contains("swift test --filter ServerModeLANEndToEndTests"))
    }

    func testAcceptanceWorkflowKeepsBrowserReleaseAndMovingToolchainJobsSeparate() throws {
        let workflow = try contents(".github/workflows/acceptance.yml")
        let package = try JSONSerialization.jsonObject(
            with: Data(try contents("package-lock.json").utf8)
        ) as? [String: Any]
        let packages = package?["packages"] as? [String: Any]
        let playwright = packages?["node_modules/playwright"] as? [String: Any]

        XCTAssertTrue(workflow.contains("browser-playback:"))
        XCTAssertTrue(workflow.contains("release-package:"))
        XCTAssertTrue(workflow.contains("toolchain-upgrade:"))
        XCTAssertTrue(workflow.contains("continue-on-error: true"))
        XCTAssertTrue(workflow.contains("scripts/run_web_playback_acceptance.sh"))
        XCTAssertTrue(workflow.contains("scripts/package_dmg.sh"))
        XCTAssertTrue(workflow.contains("uses: actions/upload-artifact@v4"))
        XCTAssertEqual(playwright?["version"] as? String, "1.63.0")
    }

    func testBrowserAcceptanceScriptsAreSyntacticallyValidAndUsePasswordFile() throws {
        let shell = try run("/bin/bash", ["-n", path("scripts/run_web_playback_acceptance.sh")])
        XCTAssertEqual(shell.status, 0, shell.output)
        let node = try run("/usr/bin/env", ["node", "--check", path("scripts/web_playback_baseline.mjs")])
        XCTAssertEqual(node.status, 0, node.output)

        let wrapper = try contents("scripts/run_web_playback_acceptance.sh")
        XCTAssertTrue(wrapper.contains("--password-file \"$PASSWORD_FILE\""))
        XCTAssertFalse(wrapper.contains("--password 'playback matrix fixture password'"))
        XCTAssertTrue(wrapper.contains("ditto \"$ROOT_DIR/.build/repositories\" \"$SCRATCH_PATH/repositories\""))
        XCTAssertTrue(wrapper.contains("SERVER_LOG=\"$FIXTURE_ROOT/server.log\""))
        XCTAssertFalse(wrapper.contains("SERVER_LOG=\"$OUTPUT_DIR/server.log\""))
        XCTAssertTrue(wrapper.contains("--out-dir must be empty to prevent stale or unredacted evidence uploads"))

        let baseline = try contents("scripts/web_playback_baseline.mjs")
        XCTAssertTrue(baseline.contains("workflowFailures.push('hls-cancellation')"))
        XCTAssertTrue(baseline.contains("removedAfterNavigation:removed?.ok === true"))
    }

    private func contents(_ relativePath: String) throws -> String {
        try String(contentsOfFile: path(relativePath), encoding: .utf8)
    }

    private func path(_ relativePath: String) -> String {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
            .path
    }

    private func run(_ executable: String, _ arguments: [String]) throws -> (status: Int32, output: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        process.waitUntilExit()
        return (
            process.terminationStatus,
            String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        )
    }
}
