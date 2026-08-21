import XCTest
@testable import MediaLibCore

/// 桌面 App 与服务进程之间关于"首页推荐"的那条消息。它的每一种"读不到"都必须等于
/// "服务端自己算"，而不是"把读到的一半当成全部"。
final class HomeRecommendationSnapshotStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("HomeRecommendationSnapshotStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testPublishedListIsReadableInOrderUntilItExpires() {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        let now = Date()

        XCTAssertNil(store.current(now: now), "没有文件就是没有名单")
        XCTAssertTrue(store.publish(
            entries: [
                .init(section: .banner, itemIDs: ["b1", "b2"]),
                .init(section: .seriesRecommendation, itemIDs: ["s1", "s2", "s3"])
            ],
            now: now,
            lifetime: 60
        ))

        let snapshot = store.current(now: now.addingTimeInterval(59))
        // 顺序就是这条消息的全部内容——乱序等于没传。
        XCTAssertEqual(snapshot?.itemIDs(for: .banner), ["b1", "b2"])
        XCTAssertEqual(snapshot?.itemIDs(for: .seriesRecommendation), ["s1", "s2", "s3"])
        XCTAssertEqual(snapshot?.itemIDs(for: .highRated), [], "没发布的栏目是空的，不是缺省的")

        XCTAssertNil(store.current(now: now.addingTimeInterval(61)), "过期即回落到服务端自己算")
    }

    func testClearingRemovesTheList() {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        XCTAssertTrue(store.publish(entries: [.init(section: .banner, itemIDs: ["b1"])]))
        XCTAssertNotNil(store.current())

        store.clear()

        XCTAssertNil(store.current())
        store.clear()
        XCTAssertNil(store.current(), "反复删除不该抛错：退出路径上没有人处理这个错误")
    }

    func testMalformedOrOversizedContentReadsAsNoList() throws {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        for content in ["", "{", "null", "[]", #"{"generatedAt":"x"}"#] {
            try Data(content.utf8).write(to: store.fileURL)
            XCTAssertNil(store.current(), content)
        }
        try Data(repeating: 0x7B, count: HomeRecommendationSnapshotStore.maximumFileByteCount + 1)
            .write(to: store.fileURL)
        XCTAssertNil(store.current(), "撑大的文件是读不懂，不是先读进来再说")
    }

    /// 同一台机器上的文件不等于可以无条件相信的输入：读进来的 ID 会变成 SQL 绑定
    /// 参数和页面上的卡片，所以条数、单条长度和重复项都要在边界上收掉。
    func testOversizedListIsTrimmedOnBothSides() throws {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        let manyIDs = (0..<80).map { "item-\($0)" }
        XCTAssertTrue(store.publish(entries: [
            .init(section: .banner, itemIDs: manyIDs),
            .init(section: .banner, itemIDs: ["duplicate-section"]),
            .init(section: .highRated, itemIDs: ["a", "a", "", String(repeating: "x", count: 200), "b"]),
            .init(sectionID: "sectionFromANewerApp", itemIDs: ["c"])
        ]))

        let snapshot = try XCTUnwrap(store.current())
        XCTAssertEqual(
            snapshot.itemIDs(for: .banner).count,
            HomeRecommendationSnapshotStore.maximumItemsPerSection
        )
        XCTAssertEqual(snapshot.itemIDs(for: .banner).first, "item-0", "截断保留的是前面的，顺序即优先级")
        XCTAssertEqual(snapshot.itemIDs(for: .highRated), ["a", "b"], "重复、空串与超长 ID 一并剔除")
        XCTAssertEqual(snapshot.entries.count, 2, "同名栏目只留第一条；不认识的栏目名整条丢掉")
    }

    /// 不认识的栏目名只该让**那一条**被忽略。老 App 配新服务端（或反过来）时，
    /// 整份文件解码失败会连带把认识的那几条也丢掉。
    func testUnknownSectionDoesNotDiscardKnownOnes() throws {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        let json = """
        {"generatedAt":"2026-08-19T00:00:00Z","expiresAt":"2126-08-19T00:00:00Z",\
        "entries":[{"section":"somethingNew","itemIDs":["x"]},{"section":"banner","itemIDs":["b1"]}]}
        """
        try Data(json.utf8).write(to: store.fileURL)

        let snapshot = try XCTUnwrap(store.current())
        XCTAssertEqual(snapshot.itemIDs(for: .banner), ["b1"])
        XCTAssertEqual(snapshot.entries.count, 1)
    }

    /// 文件里只能有排好序的 ID 与两个时间戳——标题、路径、封面、痕迹一个都不能出现。
    func testFileCarriesNothingButOrderedIdentifiers() throws {
        let store = HomeRecommendationSnapshotStore(directory: directory)
        XCTAssertTrue(store.publish(entries: [.init(section: .banner, itemIDs: ["b1"])]))

        let raw = try XCTUnwrap(String(data: Data(contentsOf: store.fileURL), encoding: .utf8))
        for forbidden in ["title", "path", "poster", "favorite", "progress", "watched", "userID"] {
            XCTAssertFalse(raw.lowercased().contains(forbidden.lowercased()), forbidden)
        }
        XCTAssertTrue(raw.contains("generatedAt"))
        XCTAssertTrue(raw.contains("b1"))
    }
}
