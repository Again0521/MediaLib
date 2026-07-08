import XCTest
import Foundation
import MediaLibCore
@testable import MediaLib

@MainActor
final class VideoCollectionStoreTests: XCTestCase {
    private var workDir: URL!
    private var dbURL: URL!
    private var database: DatabaseManager!
    private var store: VideoCollectionStore!

    override func setUpWithError() throws {
        workDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("video-collection-store-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workDir, withIntermediateDirectories: true)
        dbURL = workDir.appendingPathComponent("collections.sqlite")
        database = try DatabaseManager(url: dbURL)
        try seedMediaItems(["a", "b", "c", "d"])
        store = VideoCollectionStore(
            smartRepository: VideoSmartCollectionRepository(database: database),
            manualRepository: VideoManualCollectionRepository(database: database)
        )
    }

    override func tearDownWithError() throws {
        store = nil
        database = nil
        if let workDir {
            try? FileManager.default.removeItem(at: workDir)
        }
    }

    func testSaveUpdateAndDeleteSmartCollection() throws {
        var collection = VideoSmartCollection(name: "  高分电影  ", showOnHome: true)

        let first = try XCTUnwrap(try store.saveSmart(collection))
        XCTAssertTrue(first.isNew)
        XCTAssertEqual(first.saved.name, "高分电影")
        XCTAssertEqual(store.smartCollections.count, 1)
        XCTAssertEqual(store.smartCollection(id: first.saved.id)?.showOnHome, true)

        collection = first.saved
        collection.name = "周末看"
        let second = try XCTUnwrap(try store.saveSmart(collection))
        XCTAssertFalse(second.isNew)
        XCTAssertEqual(store.smartCollections.count, 1)
        XCTAssertEqual(store.smartCollections.first?.name, "周末看")

        XCTAssertTrue(try store.deleteSmart(id: second.saved.id))
        XCTAssertTrue(store.smartCollections.isEmpty)
    }

    func testCreateAddRemoveSaveAndDeleteManualCollection() throws {
        let created = try XCTUnwrap(try store.createManual(name: "  周末片单  ", itemIDs: ["a", "b", "a"]))
        XCTAssertEqual(created.name, "周末片单")
        XCTAssertEqual(store.manualCollections.first?.itemIDs, ["a", "b"])

        let added = try XCTUnwrap(try store.addManual(itemIDs: ["c", "a"], toCollectionID: created.id))
        XCTAssertEqual(added.itemIDs, ["a", "b", "c"])

        let removed = try XCTUnwrap(try store.removeManual(itemIDs: ["b"], fromCollectionID: created.id))
        XCTAssertEqual(removed.itemIDs, ["a", "c"])

        var renamed = removed
        renamed.name = "收藏夹"
        let saved = try XCTUnwrap(try store.saveManual(renamed))
        XCTAssertFalse(saved.isNew)
        XCTAssertEqual(store.manualCollection(id: created.id)?.name, "收藏夹")

        XCTAssertEqual(store.manualCollections(containing: "c").map(\.id), [created.id])
        XCTAssertTrue(try store.deleteManual(id: created.id))
        XCTAssertTrue(store.manualCollections.isEmpty)
    }

    func testManualReorderUsesCollectionPolicyAndPersistsResult() throws {
        let collection = try XCTUnwrap(try store.createManual(name: "顺序", itemIDs: ["a", "b", "c", "d"]))

        XCTAssertTrue(store.canReorderManual(itemIDs: ["c"], collectionID: collection.id, operation: .moveToTop))
        let reordered = try XCTUnwrap(try store.reorderManual(
            itemIDs: ["c"],
            collectionID: collection.id,
            operation: .moveToTop
        ))
        XCTAssertEqual(reordered.itemIDs, ["c", "a", "b", "d"])
        XCTAssertEqual(store.manualCollection(id: collection.id)?.itemIDs, ["c", "a", "b", "d"])

        XCTAssertFalse(store.canReorderManual(itemIDs: ["c"], collectionID: collection.id, operation: .moveToTop))
        XCTAssertNil(try store.reorderManual(itemIDs: ["c"], collectionID: collection.id, operation: .moveToTop))
    }

    func testReplaceLoadedPublishesBothCollectionFamilies() {
        let smart = VideoSmartCollection(id: "smart-a", name: "智能")
        let manual = VideoManualCollection(id: "manual-a", name: "手动", itemIDs: ["a"])

        store.replaceLoaded(smartCollections: [smart], manualCollections: [manual])

        XCTAssertEqual(store.smartCollections.map(\.id), ["smart-a"])
        XCTAssertEqual(store.manualCollections.map(\.id), ["manual-a"])
        XCTAssertEqual(store.manualCollections(containing: "a").map(\.id), ["manual-a"])
    }

    func testNilRepositoriesDegradeGracefully() throws {
        let bare = VideoCollectionStore(smartRepository: nil, manualRepository: nil)

        XCTAssertNil(try bare.saveSmart(VideoSmartCollection(name: "无库")))
        XCTAssertFalse(try bare.deleteSmart(id: "missing"))
        XCTAssertNil(try bare.saveManual(VideoManualCollection(name: "无库")))
        XCTAssertNil(try bare.createManual(name: "无库", itemIDs: ["a"]))
        XCTAssertNil(try bare.addManual(itemIDs: ["a"], toCollectionID: "missing"))
        XCTAssertNil(try bare.removeManual(itemIDs: ["a"], fromCollectionID: "missing"))
        XCTAssertNil(try bare.reorderManual(itemIDs: ["a"], collectionID: "missing", operation: .moveToTop))
        XCTAssertFalse(bare.canReorderManual(itemIDs: ["a"], collectionID: "missing", operation: .moveToTop))
    }

    private func seedMediaItems(_ ids: [String]) throws {
        for id in ids {
            try database.execute(
                "INSERT OR IGNORE INTO media_items (id, type, title) VALUES (?, ?, ?)",
                bindings: [.text(id), .text("movie"), .text("Title \(id)")]
            )
        }
    }
}
