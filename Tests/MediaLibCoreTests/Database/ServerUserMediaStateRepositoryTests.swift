import Foundation
import XCTest
@testable import MediaLibCore

final class ServerUserMediaStateRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerUserMediaStateRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerUserMediaState-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerUserMediaStateRepository(database: database)
        try MediaRepository(database: database).upsert(MediaItem(id: "movie-1", type: .movie, title: "Movie"))
        _ = try ServerIdentityRepository(database: database).createUser(
            id: "member-2", username: "member2", displayName: "Member 2"
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testStateIsIsolatedByUserAndWatchedIsStickyUntilExplicitReset() throws {
        let admin = ServerIdentityRepository.initialAdministratorUserID
        let started = try repository.update(
            userID: admin, mediaID: "movie-1", event: .started,
            position: 10, duration: 100, at: Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(started.playCount, 1)
        XCTAssertEqual(started.playProgress, 0.1, accuracy: 0.0001)
        XCTAssertFalse(started.isWatched)
        XCTAssertNil(try repository.fetch(userID: "member-2", mediaID: "movie-1"))

        let completed = try repository.update(
            userID: admin, mediaID: "movie-1", event: .progress,
            position: 95, duration: 100, at: Date(timeIntervalSince1970: 200)
        )
        XCTAssertTrue(completed.isWatched)
        XCTAssertEqual(completed.playCount, 1)

        let replay = try repository.update(
            userID: admin, mediaID: "movie-1", event: .started,
            position: 5, duration: 100, at: Date(timeIntervalSince1970: 300)
        )
        XCTAssertTrue(replay.isWatched, "重看开头不能隐式清除已看")
        XCTAssertEqual(replay.playCount, 2)

        let otherUser = try repository.update(
            userID: "member-2", mediaID: "movie-1", event: .progress,
            position: 30, duration: 100, at: Date(timeIntervalSince1970: 400)
        )
        XCTAssertFalse(otherUser.isWatched)
        XCTAssertEqual(otherUser.playProgress, 0.3, accuracy: 0.0001)
        let adminAfterOtherUpdate = try XCTUnwrap(repository.fetch(userID: admin, mediaID: "movie-1"))
        XCTAssertEqual(adminAfterOtherUpdate.playProgress, 0.05, accuracy: 0.0001)

        let reset = try repository.update(
            userID: admin, mediaID: "movie-1", event: .reset,
            position: 9_999, duration: 100, at: Date(timeIntervalSince1970: 500)
        )
        XCTAssertFalse(reset.isWatched)
        XCTAssertEqual(reset.playCount, 0)
        XCTAssertEqual(reset.playPosition, 0)
        XCTAssertNil(reset.lastPlayedAt)
    }

    func testCompletedNormalizesToFullProgressAndMediaDeletionCascadesState() throws {
        let admin = ServerIdentityRepository.initialAdministratorUserID
        let completed = try repository.update(
            userID: admin, mediaID: "movie-1", event: .completed,
            position: 88, duration: nil
        )
        XCTAssertEqual(completed.playProgress, 1)
        XCTAssertTrue(completed.isWatched)

        try database.execute("DELETE FROM media_items WHERE id = ?", bindings: [.text("movie-1")])
        XCTAssertNil(try repository.fetch(userID: admin, mediaID: "movie-1"))
        XCTAssertThrowsError(try repository.update(
            userID: admin, mediaID: "movie-1", event: .progress,
            position: 1, duration: 10
        )) { error in
            XCTAssertEqual(error as? ServerUserMediaStateRepositoryError, .mediaNotFound)
        }
    }

    func testBatchFetchIsBoundedAndIsolatedByAuthenticatedUser() throws {
        let admin = ServerIdentityRepository.initialAdministratorUserID
        try MediaRepository(database: database).upsert(MediaItem(id: "movie-2", type: .movie, title: "Movie 2"))
        _ = try repository.update(userID: admin, mediaID: "movie-1", event: .progress, position: 20, duration: 100)
        _ = try repository.update(userID: admin, mediaID: "movie-2", event: .progress, position: 40, duration: 100)
        _ = try repository.update(userID: "member-2", mediaID: "movie-1", event: .progress, position: 90, duration: 100)

        let states = try repository.fetch(userID: admin, mediaIDs: ["movie-2", "movie-1", "movie-1"])

        XCTAssertEqual(Set(states.keys), ["movie-1", "movie-2"])
        XCTAssertEqual(states["movie-1"]?.playProgress ?? -1, 0.2, accuracy: 0.0001)
        XCTAssertEqual(states["movie-2"]?.playProgress ?? -1, 0.4, accuracy: 0.0001)
        XCTAssertTrue(try repository.fetch(userID: admin, mediaIDs: []).isEmpty)
        XCTAssertThrowsError(try repository.fetch(userID: admin, mediaIDs: (0...100).map { "id-\($0)" }))
    }
}
