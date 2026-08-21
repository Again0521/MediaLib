import XCTest
@testable import MediaLibCore

/// 桌面 App 与服务进程之间唯一的那条保险库消息。它的每一种"读不到"都必须等于锁定。
final class VaultUnlockSessionStoreTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("VaultUnlockSessionStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        directory = nil
    }

    func testPublishedSessionIsReadableUntilItExpires() {
        let store = VaultUnlockSessionStore(directory: directory)
        let now = Date()

        XCTAssertNil(store.current(now: now), "没有文件就是锁定")
        XCTAssertTrue(store.publish(now: now, lifetime: 60))

        XCTAssertTrue(store.isUnlocked(now: now.addingTimeInterval(59)))
        XCTAssertFalse(store.isUnlocked(now: now.addingTimeInterval(61)), "过期即锁定")
        // App 崩溃时没有人来删这个文件，所以有效期本身就是那道兜底。
        XCTAssertNil(store.current(now: now.addingTimeInterval(3_600)))
    }

    func testClearingLocksImmediately() {
        let store = VaultUnlockSessionStore(directory: directory)
        XCTAssertTrue(store.publish(lifetime: 3_600))
        XCTAssertTrue(store.isUnlocked())

        store.clear()

        XCTAssertFalse(store.isUnlocked(), "上锁、移除口令、退出都要立刻收回可见性")
        // 反复删除不该抛错：退出路径上没有人会去处理这个错误。
        store.clear()
        XCTAssertFalse(store.isUnlocked())
    }

    func testMalformedOrOversizedContentReadsAsLocked() throws {
        let store = VaultUnlockSessionStore(directory: directory)
        for content in ["", "{", "null", "{\"unlockedAt\":\"x\",\"expiresAt\":\"y\"}", "[]"] {
            try Data(content.utf8).write(to: store.fileURL)
            XCTAssertNil(store.current(), content)
        }
        // 一个被撑大的文件同样是"读不懂"，而不是"先读进来再说"。
        try Data(repeating: 0x7B, count: 8_192).write(to: store.fileURL)
        XCTAssertNil(store.current())
    }

    /// 文件里只有两个时间戳——口令、密钥、条目信息一个都不能出现。
    func testSessionFileCarriesNothingButTimestamps() throws {
        let store = VaultUnlockSessionStore(directory: directory)
        XCTAssertTrue(store.publish())

        let raw = String(data: try Data(contentsOf: store.fileURL), encoding: .utf8) ?? ""
        XCTAssertTrue(raw.contains("unlockedAt"))
        XCTAssertTrue(raw.contains("expiresAt"))
        for forbidden in ["pin", "password", "token", "path", "secret"] {
            XCTAssertFalse(raw.lowercased().contains(forbidden), forbidden)
        }
    }

    /// 续期间隔必须真的短于有效期，否则正常使用中也会被误锁。
    func testRefreshIntervalStaysWellInsideTheLifetime() {
        XCTAssertLessThan(
            VaultUnlockSessionStore.refreshInterval * 2,
            VaultUnlockSessionStore.lifetime,
            "漏掉一次续期（睡眠、临时卡顿）也不该让保险库自己锁上"
        )
    }
}
