import XCTest

final class SwiftConflictCopyGuardTests: XCTestCase {
    private var temporaryDirectories: [URL] = []

    override func tearDown() {
        for directory in temporaryDirectories {
            try? FileManager.default.removeItem(at: directory)
        }
        temporaryDirectories.removeAll()
        super.tearDown()
    }

    func testGuardAllowsNormalSwiftSources() throws {
        let root = try makeTemporaryPackage()
        try writeSwiftFile("Sources/MediaLibCore/Database/DatabaseManager.swift", in: root)
        try writeSwiftFile("Tests/MediaLibCoreTests/Database/DatabaseManagerTests.swift", in: root)

        let result = try runGuard(root: root)

        XCTAssertEqual(result.status, 0, result.stderr)
        XCTAssertEqual(result.stderr, "")
    }

    func testGuardRejectsFinderNumberedSwiftCopies() throws {
        let root = try makeTemporaryPackage()
        try writeSwiftFile("Sources/MediaLibCore/Database/DatabaseManager.swift", in: root)
        try writeSwiftFile("Sources/MediaLibCore/Database/DatabaseManager 2.swift", in: root)

        let result = try runGuard(root: root)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("DatabaseManager 2.swift"))
        XCTAssertTrue(result.stderr.contains("Accidental Swift conflict copy detected"))
    }

    func testGuardRejectsCopiedSwiftSources() throws {
        let root = try makeTemporaryPackage()
        try writeSwiftFile("Tests/MediaLibCoreTests/Database/RemoteSyncRepository Copy.swift", in: root)

        let result = try runGuard(root: root)

        XCTAssertNotEqual(result.status, 0)
        XCTAssertTrue(result.stderr.contains("RemoteSyncRepository Copy.swift"))
    }

    func testGuardDoesNotScanOutsideSwiftPackageSourceRoots() throws {
        let root = try makeTemporaryPackage()
        try writeSwiftFile("doc/Examples/DatabaseManager 2.swift", in: root)

        let result = try runGuard(root: root)

        XCTAssertEqual(result.status, 0, result.stderr)
    }

    private func makeTemporaryPackage() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SwiftConflictCopyGuardTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        temporaryDirectories.append(root)
        return root
    }

    private func writeSwiftFile(_ relativePath: String, in root: URL) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try "struct Placeholder {}\n".data(using: .utf8)!.write(to: url)
    }

    private func runGuard(root: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [scriptURL.path, root.path]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        return (
            process.terminationStatus,
            String(data: stdout.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            String(data: stderr.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }

    private var scriptURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("scripts/check_swift_conflict_copies.sh")
    }
}
