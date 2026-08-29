import Foundation
import XCTest
@testable import MediaLibServer

final class ServerBoundedProcessTests: XCTestCase {
    func testCancellationBeforeBindingPreventsProcessLaunch() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("MediaLIB-BoundedProcess-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let cancellation = ServerBoundedProcess.Cancellation()
        cancellation.cancel()

        let result = ServerBoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/touch"),
            arguments: [marker.path],
            maximumOutputByteLength: 1_024,
            timeout: 2,
            cancellation: cancellation
        )

        XCTAssertNil(result)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testExplicitCancellationForceStopsProcessThatIgnoresSIGTERM() {
        let cancellation = ServerBoundedProcess.Cancellation()
        let completed = expectation(description: "bounded process returned after cancellation")
        let startedAt = ProcessInfo.processInfo.systemUptime
        var result: Data?

        DispatchQueue.global(qos: .userInitiated).async {
            result = ServerBoundedProcess.run(
                executableURL: URL(fileURLWithPath: "/bin/sh"),
                arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"],
                maximumOutputByteLength: 1_024,
                timeout: 30,
                cancellation: cancellation
            )
            completed.fulfill()
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
            cancellation.cancel()
        }

        wait(for: [completed], timeout: 4)
        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3)
    }

    func testTimeoutForceStopsProcessThatIgnoresSIGTERM() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = ServerBoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", "trap '' TERM; printf ready; while :; do :; done"],
            maximumOutputByteLength: 1_024,
            timeout: 0.1
        )

        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3)
    }

    func testOutputOverflowStopsProducerWithoutWaitingForTimeout() {
        let startedAt = ProcessInfo.processInfo.systemUptime
        let result = ServerBoundedProcess.run(
            executableURL: URL(fileURLWithPath: "/usr/bin/yes"),
            arguments: [],
            maximumOutputByteLength: 1_024,
            timeout: 10
        )

        XCTAssertNil(result)
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - startedAt, 3)
    }
}
