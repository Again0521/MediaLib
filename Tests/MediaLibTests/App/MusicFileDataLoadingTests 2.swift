import XCTest
@testable import MediaLib

final class MusicFileDataLoadingTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testLoadMusicFileDataReturnsExactFileBytes() async throws {
        let url = try temporaryFileURL("track.bin")
        let expected = Data([0x00, 0x10, 0x20, 0xFF])
        try expected.write(to: url)

        let loaded = try await MpvPlayerController.loadMusicFileData(fileURL: url)

        XCTAssertEqual(loaded, expected)
    }

    func testLoadMusicFileDataThrowsForMissingFile() async throws {
        let url = try temporaryFileURL("missing.bin")

        do {
            _ = try await MpvPlayerController.loadMusicFileData(fileURL: url)
            XCTFail("Expected missing local music file read to throw")
        } catch {
            XCTAssertFalse("\(error)".isEmpty)
        }
    }

    func testConcurrentMusicFileDataLoadsRemainStable() async throws {
        let url = try temporaryFileURL("concurrent.bin")
        let expected = Data((0..<128).map { UInt8($0) })
        try expected.write(to: url)

        let results = try await withThrowingTaskGroup(of: Data.self, returning: [Data].self) { group in
            for _ in 0..<32 {
                group.addTask {
                    try await MpvPlayerController.loadMusicFileData(fileURL: url)
                }
            }

            var values: [Data] = []
            for try await value in group {
                values.append(value)
            }
            return values
        }

        XCTAssertEqual(results.count, 32)
        XCTAssertTrue(results.allSatisfy { $0 == expected })
    }

    private func temporaryFileURL(_ name: String) throws -> URL {
        if tempDirectory == nil {
            let root = FileManager.default.temporaryDirectory
                .appendingPathComponent("MusicFileDataLoadingTests-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            tempDirectory = root
        }
        return tempDirectory!.appendingPathComponent(name)
    }
}
