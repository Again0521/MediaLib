import Foundation
import XCTest
@testable import MediaLibCore

final class DatabaseChangeRevisionTests: XCTestCase {
    private var directory: URL!
    private var databaseURL: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DatabaseChangeRevisionTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        databaseURL = directory.appendingPathComponent("revision.sqlite")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
        databaseURL = nil
    }

    func testTableRevisionChangesOnlyForSelectedTablesOnTheCurrentConnection() throws {
        let database = try DatabaseManager(url: databaseURL)
        let tables: Set<String> = ["media_items", "media_sources"]
        let initial = try database.changeRevision(forTables: tables)

        _ = try ServerExperienceRepository(database: database).saveJob(ServerJob(kind: "library.scan"))
        XCTAssertEqual(try database.changeRevision(forTables: tables), initial)

        try SourceRepository(database: database).save(MediaSource(
            id: "revision-source", name: "Revision", path: "/Volumes/Revision", mediaType: .movie
        ))
        XCTAssertNotEqual(try database.changeRevision(forTables: tables), initial)
    }

    func testDataVersionDetectsARelevantCommitFromAnotherConnection() throws {
        let reader = try DatabaseManager(url: databaseURL)
        let writer = try DatabaseManager(url: databaseURL)
        let tables: Set<String> = ["media_items", "media_sources"]
        let initial = try reader.changeRevision(forTables: tables)

        try SourceRepository(database: writer).save(MediaSource(
            id: "external-source", name: "External", path: "/Volumes/External", mediaType: .movie
        ))

        XCTAssertNotEqual(try reader.changeRevision(forTables: tables), initial)
    }

    func testScopedRevisionsIsolateUsersAndMutationKinds() throws {
        let database = try DatabaseManager(url: databaseURL)
        XCTAssertEqual(
            database.changeRevision(namespace: .serverNavigationState, identifier: "member-a"),
            0
        )
        database.recordChange(namespace: .serverNavigationState, identifier: "member-a")

        XCTAssertGreaterThan(
            database.changeRevision(namespace: .serverNavigationState, identifier: "member-a"),
            0
        )
        XCTAssertEqual(
            database.changeRevision(namespace: .serverNavigationState, identifier: "member-b"),
            0
        )
        XCTAssertEqual(
            database.changeRevision(namespace: .serverNavigationPolicy, identifier: "member-a"),
            0
        )
    }
}
