import XCTest
@testable import MediaLibCore

final class MusicQueueRepositoryAuditTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("MusicQueueRepositoryAuditTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("queue.sqlite")
    }

    override func tearDownWithError() throws {
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    func testSaveTrimsDropsBlankAndDeduplicatesQueueItemIDs() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db, ids: ["track-1", "track-2", "track-3"])
        let repo = MusicQueueRepository(database: db)

        try repo.save(
            MusicQueueSnapshot(
                itemIDs: [" track-1 ", "\n\t", "track-2", "track-1", " track-3\n", "track-2"],
                repeatModeRawValue: "repeatAll",
                shuffleEnabled: true
            )
        )

        let fetched = try repo.fetch()
        XCTAssertEqual(fetched.itemIDs, ["track-1", "track-2", "track-3"])
        XCTAssertEqual(fetched.repeatModeRawValue, "repeatAll")
        XCTAssertTrue(fetched.shuffleEnabled)

        let persisted = try db.query(
            "SELECT media_id FROM music_queue_items ORDER BY position ASC"
        ) { row in
            row.string(0) ?? ""
        }
        XCTAssertEqual(persisted, ["track-1", "track-2", "track-3"])
    }

    func testFetchNormalizesLegacyDirtyQueueRows() throws {
        let db = try DatabaseManager(url: dbURL)
        try seedMediaItems(db, ids: [" track-1 ", "track-1", " \n\t ", " track-2\n", "track-2"])
        try db.execute(
            """
            INSERT INTO music_queue_items (media_id, position, added_at)
            VALUES (?, ?, ?), (?, ?, ?), (?, ?, ?), (?, ?, ?)
            """,
            bindings: [
                .text(" track-1 "), .int(0), .optionalDate(nil),
                .text("track-1"), .int(1), .optionalDate(nil),
                .text(" \n\t "), .int(2), .optionalDate(nil),
                .text(" track-2\n"), .int(3), .optionalDate(nil)
            ]
        )

        let fetched = try MusicQueueRepository(database: db).fetch()

        XCTAssertEqual(fetched.itemIDs, ["track-1", "track-2"])
    }

    private func seedMediaItems(_ db: DatabaseManager, ids: [String]) throws {
        for id in ids {
            try db.execute(
                "INSERT OR IGNORE INTO media_items (id, type, title) VALUES (?, ?, ?)",
                bindings: [.text(id), .text("music"), .text("Track \(id)")]
            )
        }
    }
}
