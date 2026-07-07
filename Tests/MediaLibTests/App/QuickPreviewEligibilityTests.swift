import XCTest
@testable import MediaLib
@testable import MediaLibCore

final class QuickPreviewEligibilityTests: XCTestCase {
    private var tempDirectory: URL?

    override func tearDownWithError() throws {
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
    }

    func testCanPreviewAllowsRemoteResourceWithoutLocalFileCheck() async {
        let item = MediaItem(
            id: "remote",
            type: .movie,
            title: "Remote",
            filePath: "https://media.example.test/movie.mkv"
        )

        let canPreview = await QuickPreviewView.canPreview(item: item)
        XCTAssertTrue(canPreview)
    }

    func testCanPreviewRequiresExistingLocalFileAndRejectsMissingOrNilPath() async throws {
        let directory = try makeTemporaryDirectory()
        let fileURL = directory.appendingPathComponent("movie.mkv")
        try Data([0x01]).write(to: fileURL)

        let existing = await QuickPreviewView.canPreview(item: makeItem(id: "existing", path: fileURL.path))
        let missing = await QuickPreviewView.canPreview(item: makeItem(id: "missing", path: directory.appendingPathComponent("missing.mkv").path))
        let nilPath = await QuickPreviewView.canPreview(item: makeItem(id: "nil", path: nil))

        XCTAssertTrue(existing)
        XCTAssertFalse(missing)
        XCTAssertFalse(nilPath)
    }

    func testConcurrentCanPreviewChecksRemainStable() async throws {
        let directory = try makeTemporaryDirectory()
        let items = try (0..<40).map { index -> (MediaItem, Bool) in
            let url = directory.appendingPathComponent("item-\(index).mp4")
            if index.isMultiple(of: 2) {
                try Data([UInt8(index)]).write(to: url)
                return (makeItem(id: "item-\(index)", path: url.path), true)
            }
            return (makeItem(id: "item-\(index)", path: url.path), false)
        }

        await withTaskGroup(of: (String, Bool).self) { group in
            for (item, _) in items {
                group.addTask {
                    (item.id, await QuickPreviewView.canPreview(item: item))
                }
            }
            let expected = Dictionary(uniqueKeysWithValues: items.map { ($0.0.id, $0.1) })
            for await (id, canPreview) in group {
                XCTAssertEqual(canPreview, expected[id])
            }
        }
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("QuickPreviewEligibilityTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        tempDirectory = directory
        return directory
    }

    private func makeItem(id: String, path: String?) -> MediaItem {
        MediaItem(id: id, type: .movie, title: id, filePath: path)
    }
}
