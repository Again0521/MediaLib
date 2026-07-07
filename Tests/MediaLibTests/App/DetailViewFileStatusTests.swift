import XCTest
@testable import MediaLib

final class DetailViewFileStatusTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testLocalFileExistsReturnsTrueForExistingFileAndFalseForMissingPath() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("movie.mkv")
        try Data([0x01]).write(to: fileURL)
        let missingURL = directory.appendingPathComponent("missing.mkv")

        let existing = await DetailView.localFileExists(atPath: fileURL.path)
        let missing = await DetailView.localFileExists(atPath: missingURL.path)

        XCTAssertTrue(existing)
        XCTAssertFalse(missing)
    }

    func testConcurrentLocalFileExistsChecksRemainStable() async throws {
        let directory = try makeTemporaryDirectory()
        var expected: [String: Bool] = [:]
        for index in 0..<40 {
            let url = directory.appendingPathComponent("item-\(index).dat")
            if index.isMultiple(of: 2) {
                try Data([UInt8(index)]).write(to: url)
                expected[url.path] = true
            } else {
                expected[url.path] = false
            }
        }

        await withTaskGroup(of: (String, Bool).self) { group in
            for path in expected.keys {
                group.addTask {
                    (path, await DetailView.localFileExists(atPath: path))
                }
            }
            for await (path, exists) in group {
                XCTAssertEqual(exists, expected[path])
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DetailViewFileStatusTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }
}
