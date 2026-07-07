import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级远程同步账号、多用户隔离与冲突仲裁专项】
/// 审计目标：验证 `RemoteConnectorAccountRepository`、`LocalUserProfileRepository`
/// 与 `SyncConflictRepository` 在处理多端同步冲突和本地多账户切换时的数据隔离边界；
/// 确保设置某用户角色为默认 (`isDefault = true`) 时，事务能够原子性把其他所有用户角色置为非默认，
/// 并验证进度冲突（如手机 vs 电脑观看进度不同）在仲裁解决 (`resolve` / `ignore`) 后状态精确流转。
/// 对应报告问题 ID：TC-REMOTE-001 / RISK-03
final class RemoteSyncRepositoryAuditTests: XCTestCase {
    private var tempDir: URL!
    private var dbManager: DatabaseManager!
    private var accountRepo: RemoteConnectorAccountRepository!
    private var profileRepo: LocalUserProfileRepository!
    private var conflictRepo: SyncConflictRepository!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("RemoteSyncAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        dbManager = try DatabaseManager(url: tempDir.appendingPathComponent("audit_remote_sync.sqlite"))
        accountRepo = RemoteConnectorAccountRepository(database: dbManager)
        profileRepo = LocalUserProfileRepository(database: dbManager)
        conflictRepo = SyncConflictRepository(database: dbManager)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试远程账号增删改查及连带源 ID 删除
    func testRemoteConnectorAccountLifecycle() throws {
        try SourceRepository(database: dbManager).save(MediaSource(id: "source-emby-01", name: "Emby Source", path: "emby://emby.home.local"))
        let account = RemoteConnectorAccount(
            id: "acct-emby-01",
            provider: .emby,
            accountLabel: "家庭服务器",
            serverURL: "https://emby.home.local",
            username: "admin",
            sourceID: "source-emby-01",
            connectionMode: .direct,
            syncEnabled: true
        )
        
        try accountRepo.save(account)
        let all = try accountRepo.fetchAll()
        XCTAssertEqual(all.count, 1)
        XCTAssertEqual(all.first?.username, "admin")
        XCTAssertEqual(all.first?.serverURL, "https://emby.home.local")
        
        // 验证按 sourceID 批量级联删除
        try accountRepo.delete(sourceID: "source-emby-01")
        XCTAssertTrue(try accountRepo.fetchAll().isEmpty, "按关联源 ID 删除账号必须闭环清理所有匹配记录")
    }

    /// 测试本地多用户角色设置默认时的事务互斥（只有一个 Default）
    func testLocalUserProfileDefaultMutuallyExclusiveTransaction() throws {
        let p1 = LocalUserProfile(id: "user-1", name: "爸爸", isDefault: true)
        let p2 = LocalUserProfile(id: "user-2", name: "妈妈", isDefault: false)
        let p3 = LocalUserProfile(id: "user-3", name: "宝宝 (儿童模式)", isDefault: false, childMode: true)
        
        try profileRepo.save(p1)
        try profileRepo.save(p2)
        try profileRepo.save(p3)
        
        var profiles = try profileRepo.fetchAll()
        XCTAssertEqual(profiles.first(where: { $0.id == "user-1" })?.isDefault, true)
        XCTAssertEqual(profiles.first(where: { $0.id == "user-2" })?.isDefault, false)
        
        // 此时将妈妈角色置为默认，事务必须自动把爸爸的角色取消默认
        var p2Updated = p2
        p2Updated.isDefault = true
        try profileRepo.save(p2Updated)
        
        profiles = try profileRepo.fetchAll()
        XCTAssertEqual(profiles.first(where: { $0.id == "user-2" })?.isDefault, true, "妈妈应成为唯一默认角色")
        XCTAssertEqual(profiles.first(where: { $0.id == "user-1" })?.isDefault, false, "此前默认的角色在事务中必须被自动降级")
    }

    /// 测试多档案媒体状态保存前会清洗被外部改脏的数值字段
    func testProfileMediaStateSaveSanitizesMutatedNumericValues() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-state", type: .movie, title: "State Movie"))

        var state = ProfileMediaState(
            profileID: "default",
            mediaID: "movie-state",
            playCount: 3,
            playPosition: 42,
            playProgress: 0.4,
            userRating: 4,
            lastPlayedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
        state.playCount = -9
        state.playPosition = Double.nan
        state.playProgress = Double.infinity
        state.userRating = -Double.infinity

        let saved = try profileRepo.saveState(state)
        XCTAssertEqual(saved.playCount, 0)
        XCTAssertEqual(saved.playPosition, 0)
        XCTAssertEqual(saved.playProgress, 0)
        XCTAssertNil(saved.userRating)
        XCTAssertEqual(saved.lastPlayedAt, state.lastPlayedAt)

        let fetched = try XCTUnwrap(profileRepo.state(profileID: "default", mediaID: "movie-state"))
        XCTAssertEqual(fetched.playCount, 0)
        XCTAssertEqual(fetched.playPosition, 0)
        XCTAssertEqual(fetched.playProgress, 0)
        XCTAssertNil(fetched.userRating)
        XCTAssertEqual(fetched.lastPlayedAt, state.lastPlayedAt)
    }

    func testProfileMediaStateSaveDropsFiniteOutOfRangeUserRating() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-rating-state", type: .movie, title: "Rating State"))

        var state = ProfileMediaState(
            profileID: "default",
            mediaID: "movie-rating-state",
            userRating: 4
        )
        state.userRating = 6

        let saved = try profileRepo.saveState(state)
        XCTAssertNil(saved.userRating)

        let fetched = try XCTUnwrap(profileRepo.state(profileID: "default", mediaID: "movie-rating-state"))
        XCTAssertNil(fetched.userRating)
    }

    /// 测试多端同步冲突处理：待办查询、解决仲裁与忽略机制
    func testSyncConflictPendingQueryResolveAndIgnore() throws {
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-abc", type: .movie, title: "Movie ABC"))
        try MediaRepository(database: dbManager).upsert(MediaItem(id: "movie-def", type: .movie, title: "Movie DEF"))
        let c1 = SyncConflict(
            id: "conf-01",
            mediaID: "movie-abc",
            provider: .emby,
            fieldName: "play_progress",
            localValue: "120.5",
            remoteValue: "340.0",
            status: .pending
        )
        let c2 = SyncConflict(
            id: "conf-02",
            mediaID: "movie-def",
            provider: .plex,
            fieldName: "watched",
            localValue: "false",
            remoteValue: "true",
            status: .pending
        )
        
        try conflictRepo.save(c1)
        try conflictRepo.save(c2)
        
        XCTAssertEqual(try conflictRepo.pendingCount(), 2)
        
        // 仲裁冲突 1：采纳本地
        try conflictRepo.resolve(id: "conf-01", resolution: .useLocal)
        // 忽略冲突 2
        try conflictRepo.ignore(id: "conf-02")
        
        XCTAssertEqual(try conflictRepo.pendingCount(), 0, "全部冲突被处理或忽略后，待办队列必须清零")
    }
}
