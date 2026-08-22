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

    func testUnexpectedServerExitRestartsRequestedServerMode() async throws {
        let executableURL = try makeCrashOnceThenLongRunningExecutable()
        let controller = ServerModeProcessController(
            executableURLProvider: { executableURL },
            readinessChecker: { _ in true }
        )

        try controller.start(configuration: ServerModeConfiguration(serverID: "server-self-recover"))
        // The first runtime reports ready then exits immediately. Wait past the
        // one-second recovery delay so a green initial readiness race cannot
        // masquerade as a successful self-restart.
        try? await Task.sleep(nanoseconds: 1_200_000_000)
        for _ in 0..<80 where controller.status != .running {
            try? await Task.sleep(nanoseconds: 25_000_000)
        }

        XCTAssertEqual(controller.status, .running)
        controller.stop()
    }

    func testLANEnvironmentUsesDerivedHTTPSOriginAndNeverTrustsProxyHeaders() {
        let configuration = ServerModeConfiguration(
            serverID: "server-lan",
            port: 8098,
            networkAccessMode: .lanHTTPS,
            lanAddress: "192.168.31.100",
            publicOrigin: "https://proxy.example.test",
            trustedProxyAddresses: ["127.0.0.1"]
        )
        let environment = ServerModeProcessController.processEnvironment(
            configuration: configuration,
            base: ["UNCHANGED": "yes", "MEDIALIB_SERVER_TRUSTED_PROXIES": "stale"]
        )

        XCTAssertEqual(environment["UNCHANGED"], "yes")
        XCTAssertEqual(environment["MEDIALIB_SERVER_NETWORK_ACCESS_MODE"], "lan-https")
        XCTAssertEqual(environment["MEDIALIB_SERVER_PUBLIC_ORIGIN"], "https://192.168.31.100:8098")
        XCTAssertNil(environment["MEDIALIB_SERVER_TRUSTED_PROXIES"])
    }

    func testRealLANRuntimePassesPinnedCAHealthCheck() async throws {
        guard let address = LANNetworkAddressResolver.preferredPrivateIPv4Address() else {
            throw XCTSkip("当前测试机没有私有 IPv4 地址")
        }
        let executable = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(".build/debug/MediaLibServer")
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw XCTSkip("MediaLibServer 测试运行时尚未构建")
        }
        let configuration = ServerModeConfiguration(
            serverID: "server-live-lan",
            port: 18_198,
            networkAccessMode: .lanHTTPS,
            lanAddress: address
        )
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--serve"]
        var environment = ServerModeProcessController.processEnvironment(configuration: configuration)
        environment["MEDIALIB_SERVER_DATA_DIR"] = temporaryDirectory.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { process.terminate() }
            process.waitUntilExit()
        }

        let certificate = ServerModeCertificateSupport.certificateAuthorityURL(
            applicationSupport: temporaryDirectory
        )
        var ready = false
        for _ in 0..<80 where !ready && process.isRunning {
            ready = await ServerModeProcessController.checkLANHTTPSReadiness(
                configuration,
                certificateAuthorityURL: certificate
            )
            if !ready { try? await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertTrue(ready, "真实 LAN TLS 服务必须通过本机 CA 锚定健康检查")
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

    private func makeCrashOnceThenLongRunningExecutable() throws -> URL {
        let markerURL = temporaryDirectory.appendingPathComponent("did-crash-once")
        let executableURL = temporaryDirectory.appendingPathComponent("server-recovery-runtime.sh")
        let contents = "#!/bin/sh\nif [ ! -f '\(markerURL.path)' ]; then touch '\(markerURL.path)'; exit 17; fi\nwhile true; do sleep 1; done\n"
        try Data(contents.utf8).write(to: executableURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executableURL.path)
        return executableURL
    }
}

private enum ServerModeRuntimeTestError: Error {
    case unavailable
}
