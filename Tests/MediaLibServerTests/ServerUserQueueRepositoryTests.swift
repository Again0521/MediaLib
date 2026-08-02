import XCTest
@testable import MediaLibCore

final class ServerUserQueueRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("ServerUserQueueTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("queue.sqlite"))
        let identities = ServerIdentityRepository(database: database)
        _ = try identities.createUser(id: "user-a", username: "alice", displayName: "Alice")
        _ = try identities.createUser(id: "user-b", username: "bob", displayName: "Bob")
        let media = MediaRepository(database: database)
        for id in ["media-a", "media-b", "media-c"] {
            try media.upsert(MediaItem(id: id, type: .movie, title: id, filePath: "/tmp/\(id).mp4"))
        }
    }

    override func tearDownWithError() throws {
        database = nil
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testUsersHaveIsolatedOrderedQueueAndSettings() throws {
        let repository = ServerUserQueueRepository(database: database)
        let initial = try repository.replace(
            userID: "user-a",
            itemIDs: ["media-a", "media-b"],
            repeatMode: .repeatAll,
            shuffleEnabled: true,
            currentPosition: 1
        )
        XCTAssertEqual(initial.itemIDs, ["media-a", "media-b"])
        XCTAssertEqual(initial.repeatMode, .repeatAll)
        XCTAssertTrue(initial.shuffleEnabled)
        XCTAssertEqual(initial.currentPosition, 1)
        XCTAssertTrue(try repository.fetch(userID: "user-b").itemIDs.isEmpty)

        let moved = try repository.mutate(
            userID: "user-a", action: .move, mediaID: nil,
            fromIndex: 1, toIndex: 0, repeatMode: nil,
            shuffleEnabled: nil, currentPosition: nil
        )
        XCTAssertEqual(moved.itemIDs, ["media-b", "media-a"])

        let added = try repository.mutate(
            userID: "user-a", action: .add, mediaID: "media-c",
            fromIndex: nil, toIndex: nil, repeatMode: nil,
            shuffleEnabled: nil, currentPosition: nil
        )
        XCTAssertEqual(added.itemIDs, ["media-b", "media-a", "media-c"])
        XCTAssertEqual(try repository.mutate(userID: "user-a", action: .clear, mediaID: nil, fromIndex: nil, toIndex: nil, repeatMode: nil, shuffleEnabled: nil, currentPosition: nil).itemIDs, [])
    }

    func testQueueRejectsUnknownMediaAndUnboundedInput() throws {
        let repository = ServerUserQueueRepository(database: database)
        XCTAssertThrowsError(try repository.replace(userID: "user-a", itemIDs: ["missing"], repeatMode: .sequential, shuffleEnabled: false, currentPosition: 0)) { error in
            XCTAssertEqual(error as? ServerUserQueueRepositoryError, .mediaNotFound)
        }
        XCTAssertThrowsError(try repository.replace(userID: "user-a", itemIDs: Array(repeating: "media-a", count: 101), repeatMode: .sequential, shuffleEnabled: false, currentPosition: 0)) { error in
            XCTAssertEqual(error as? ServerUserQueueRepositoryError, .tooManyItems)
        }
        XCTAssertThrowsError(try repository.mutate(userID: "user-a", action: .move, mediaID: nil, fromIndex: 0, toIndex: 1, repeatMode: nil, shuffleEnabled: nil, currentPosition: nil)) { error in
            XCTAssertEqual(error as? ServerUserQueueRepositoryError, .invalidPosition)
        }
    }
}
