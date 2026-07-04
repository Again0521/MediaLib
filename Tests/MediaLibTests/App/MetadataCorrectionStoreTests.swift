import XCTest
import MediaLibCore
@testable import MediaLib

/// MetadataCorrectionStore 集成测试：临时 SQLite + 真实 MetadataCorrectionRepository，覆盖
/// 载入统计 / 计数查询 / 持久化记录与撤销 / 内存反映，以及 repository 缺失降级。
@MainActor
final class MetadataCorrectionStoreTests: XCTestCase {
    private var dbURL: URL!
    private var store: MetadataCorrectionStore!

    override func setUpWithError() throws {
        dbURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("metadata-correction-store-\(UUID().uuidString).sqlite")
        let database = try DatabaseManager(url: dbURL)
        // metadata_correction_history.media_id 是 NOT NULL 外键（→ media_items），先种 m1/m2。
        let media = MediaRepository(database: database)
        try media.upsert(MediaItem(id: "m1", type: .movie, title: "m1"))
        try media.upsert(MediaItem(id: "m2", type: .movie, title: "m2"))
        store = MetadataCorrectionStore(repository: MetadataCorrectionRepository(database: database))
    }

    override func tearDownWithError() throws {
        store = nil
        try? FileManager.default.removeItem(at: dbURL)
    }

    private func change(_ field: MetadataCorrectionField, _ old: String, _ new: String) -> MetadataCorrectionFieldChange {
        MetadataCorrectionFieldChange(field: field, oldValue: old, newValue: new)
    }

    func testPersistRecordThenReloadSurfacesCounts() throws {
        try store.persistRecord(mediaID: "m1", changes: [change(.title, "A", "B"), change(.year, "2000", "2001")], source: "tmdb")
        try store.reload()
        XCTAssertEqual(store.recordCount, 2)
        XCTAssertEqual(store.correctionCount(forMediaID: "m1"), 2)
        XCTAssertEqual(store.batches.count, 1)
    }

    func testNoteRecordedBumpsInMemoryCounts() {
        store.noteRecorded(mediaID: "m1", changeCount: 3)
        store.noteRecorded(mediaID: "m1", changeCount: 2)
        store.noteRecorded(mediaID: "m2", changeCount: 1)
        XCTAssertEqual(store.correctionCount(forMediaID: "m1"), 5)
        XCTAssertEqual(store.correctionCount(forMediaID: "m2"), 1)
        XCTAssertEqual(store.recordCount, 6)
    }

    func testPersistBatchUndoneRemovesFromActiveOnReload() throws {
        try store.persistRecord(mediaID: "m1", changes: [change(.title, "A", "B")], source: "manual")
        try store.reload()
        let batchID = try XCTUnwrap(store.batches.first?.batchID)
        XCTAssertEqual(store.recordCount, 1)

        try store.persistBatchUndone(batchID: batchID)
        try store.reload()
        XCTAssertEqual(store.recordCount, 0)
        XCTAssertTrue(store.batches.isEmpty)
        XCTAssertEqual(store.correctionCount(forMediaID: "m1"), 0)
    }

    func testLatestUndoableBatchReadsRecords() throws {
        try store.persistRecord(mediaID: "m1", changes: [change(.title, "A", "B")], source: "tmdb")
        let records = try store.latestUndoableBatch(mediaID: "m1")
        XCTAssertEqual(records.count, 1)
        XCTAssertEqual(records.first?.oldValue, "A")
    }

    func testNilRepositoryDegradesGracefully() throws {
        let bare = MetadataCorrectionStore(repository: nil)
        XCTAssertFalse(bare.isAvailable)
        try bare.reload()
        try bare.persistRecord(mediaID: "m1", changes: [change(.title, "A", "B")], source: "x")
        try bare.persistBatchUndone(batchID: "b1")
        XCTAssertEqual(try bare.latestUndoableBatch(mediaID: "m1").count, 0)
        XCTAssertEqual(try bare.records(batchID: "b1", mediaID: "m1").count, 0)
        XCTAssertEqual(bare.recordCount, 0)
        XCTAssertTrue(bare.batches.isEmpty)
    }
}
