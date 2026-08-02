import Foundation
import XCTest
@testable import MediaLib
import MediaLibCore

@MainActor
final class ServerModeProcessControllerTests: XCTestCase {
    private var temporaryDirectory: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLibServerModeProcessTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: temporaryDirectory)
        temporaryDirectory = nil
    }

    func testControllerStartsAndStopsInjectedServerRuntime() async throws {
        let executableURL = try makeLongRunningExecutable()
        let controller = ServerModeProcessController(
            executableURLProvider: { executableURL },
            readinessChecker: { _ in true }
        )

        try controller.start(configuration: ServerModeConfiguration(serverID: "server-test"))
        await waitForRunning(controller)
        XCTAssertEqual(controller.status, .running)

        controller.stop()
        XCTAssertEqual(controller.status, .stopped)
    }

    func testRecoveryStopWaitsUntilInjectedRuntimeActuallyExits() async throws {
        let executableURL = try makeLongRunningExecutable()
        let controller = ServerModeProcessController(
            executableURLProvider: { executableURL },
            readinessChecker: { _ in true }
        )
        try controller.start(configuration: ServerModeConfiguration(serverID: "server-recovery-test"))
        await waitForRunning(controller)

        let stopped = await controller.stopAndWaitForExit(timeout: 3)

        XCTAssertTrue(stopped)
        XCTAssertEqual(controller.status, .stopped)
    }

    func testControllerReportsStartFailureWithoutPersistingRunningState() {
        let controller = ServerModeProcessController(executableURLProvider: {
            throw ServerModeRuntimeTestError.unavailable
        })

        XCTAssertThrowsError(try controller.start(configuration: ServerModeConfiguration(serverID: "server-test")))
        guard case .failed = controller.status else {
            return XCTFail("无法启动服务端时状态必须为 failed")
        }
    }

    func testControllerFailsAndTerminatesWhenHealthCheckDoesNotBecomeReady() async throws {
        let executableURL = try makeLongRunningExecutable()
        let controller = ServerModeProcessController(
            executableURLProvider: { executableURL },
            readinessChecker: { _ in false },
            readinessTimeout: 0.1
        )

        try controller.start(configuration: ServerModeConfiguration(serverID: "server-not-ready"))
        for _ in 0..<30 where controller.status == .starting {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        guard case .failed(let message) = controller.status else {
            return XCTFail("健康检查超时后必须进入 failed 状态")
        }
        XCTAssertTrue(message.contains("健康检查"))
    }

    private func waitForRunning(_ controller: ServerModeProcessController) async {
        for _ in 0..<30 where controller.status == .starting {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    private func makeLongRunningExecutable() throws -> URL {
        let executableURL = temporaryDirectory.appendingPathComponent("server-runtime.sh")
        let contents = "#!/bin/sh\nwhile true; do sleep 1; done\n"
        try Data(contents.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return executableURL
    }
}

private enum ServerModeRuntimeTestError: Error {
    case unavailable
}
