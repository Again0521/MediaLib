import Foundation
import XCTest
@testable import MediaLibCore

final class ServerUserMediaPreferenceRepositoryTests: XCTestCase {
    private var directory: URL!
    private var database: DatabaseManager!
    private var repository: ServerUserMediaPreferenceRepository!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ServerUserMediaPreference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        database = try DatabaseManager(url: directory.appendingPathComponent("library.sqlite"))
        repository = ServerUserMediaPreferenceRepository(database: database)
        try MediaRepository(database: database).upsert(MediaItem(id: "movie-1", type: .movie, title: "Movie"))
        _ = try ServerIdentityRepository(database: database).createUser(
            id: "member-2", username: "member2", displayName: "Member 2"
        )
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    func testPreferencesAreIsolatedAndIndependentUpdatesPreserveOtherFields() throws {
        let admin = ServerIdentityRepository.initialAdministratorUserID
        _ = try repository.update(userID: admin, mediaID: "movie-1", preference: .favorite(true))
        _ = try repository.update(userID: admin, mediaID: "movie-1", preference: .watchlist(true))
        let rated = try repository.update(userID: admin, mediaID: "movie-1", preference: .rating(4.5))

        XCTAssertTrue(rated.isFavorite)
        XCTAssertTrue(rated.isWatchlist)
        XCTAssertEqual(rated.userRating, 4.5)
        XCTAssertNil(try repository.fetch(userID: "member-2", mediaID: "movie-1"))

        let cleared = try repository.update(userID: admin, mediaID: "movie-1", preference: .rating(nil))
        XCTAssertTrue(cleared.isFavorite)
        XCTAssertTrue(cleared.isWatchlist)
        XCTAssertNil(cleared.userRating)
    }

    func testBoundsBatchReadAndCascadeDeletion() throws {
        let admin = ServerIdentityRepository.initialAdministratorUserID
        _ = try repository.update(userID: admin, mediaID: "movie-1", preference: .favorite(true))
        XCTAssertEqual(Set(try repository.fetch(userID: admin, mediaIDs: ["movie-1", "movie-1"]).keys), ["movie-1"])
        XCTAssertThrowsError(try repository.update(userID: admin, mediaID: "movie-1", preference: .rating(5.1))) {
            XCTAssertEqual($0 as? ServerUserMediaPreferenceRepositoryError, .invalidRating)
        }
        XCTAssertThrowsError(try repository.fetch(userID: admin, mediaIDs: (0...100).map { "id-\($0)" }))
        try database.execute("DELETE FROM media_items WHERE id = ?", bindings: [.text("movie-1")])
        XCTAssertNil(try repository.fetch(userID: admin, mediaID: "movie-1"))
    }
}
