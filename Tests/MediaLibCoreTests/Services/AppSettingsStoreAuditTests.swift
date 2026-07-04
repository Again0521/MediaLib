import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级设置凭据迁移与明文剥离专项】
/// 审计目标：验证 `AppSettingsStore` 在进行 AppSettings 持久化与旧版本兼容读取时，
/// 能否将 8 个核心敏感凭据（如 TMDB API Key, Last.fm Secret, Trakt Token）从 UserDefaults
/// 的全局可读 JSON blob 中彻底剥离并清零，防止明文配置随 iCloud 同步或备份外泄；
/// 同时验证迁移逻辑能够平滑自愈，将旧明文安全迁移到 0600 的独立 `SecretStore` 中。
/// 对应报告问题 ID：TC-SEC-004 / RISK-06 / RISK-04
final class AppSettingsStoreAuditTests: XCTestCase {
    private var tempDir: URL!
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppSettingsStoreAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        
        suiteName = "AppSettingsStoreAuditSuite-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        if let suiteName {
            UserDefaults().removePersistentDomain(forName: suiteName)
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试 AppSettings 保存到 UserDefaults 时，8 个敏感字段必须在 JSON Blob 中被强制抹除为 nil
    func testSaveStripsAllEightSensitiveSecretsFromUserDefaultsBlob() throws {
        let secretStore = SecretStore(directory: tempDir)
        let store = AppSettingsStore(defaults: defaults, secretStore: secretStore)
        
        var settings = AppSettings()
        settings.tmdbAPIKey = "tmdb-key-secret"
        settings.openSubtitlesAPIKey = "sub-key-secret"
        settings.lastfmAPIKey = "lastfm-key-secret"
        settings.lastfmSharedSecret = "lastfm-shared-secret"
        settings.lastfmSessionKey = "lastfm-session-key"
        settings.traktClientSecret = "trakt-client-secret"
        settings.traktAccessToken = "trakt-access-token"
        settings.traktRefreshToken = "trakt-refresh-token"
        
        store.save(settings)
        
        // 1. 验证 UserDefaults 中落盘的 JSON blob 绝对不含这 8 个敏感值
        let rawData = defaults.data(forKey: "MediaLib.AppSettings")
        XCTAssertNotNil(rawData, "设置 blob 应该已成功写入 UserDefaults")
        
        let strippedBlob = try JSONDecoder().decode(AppSettings.self, from: rawData!)
        XCTAssertNil(strippedBlob.tmdbAPIKey, "UserDefaults Blob 中 TMDB API Key 必须为空！")
        XCTAssertNil(strippedBlob.openSubtitlesAPIKey)
        XCTAssertNil(strippedBlob.lastfmAPIKey)
        XCTAssertNil(strippedBlob.lastfmSharedSecret)
        XCTAssertNil(strippedBlob.lastfmSessionKey)
        XCTAssertNil(strippedBlob.traktClientSecret)
        XCTAssertNil(strippedBlob.traktAccessToken)
        XCTAssertNil(strippedBlob.traktRefreshToken, "所有 8 个敏感字段必须被剥离，绝不外泄！")
        
        // 2. 验证通过 store.load() 能够从 0600 的 SecretStore 完整、精准地复原各字段
        let reloaded = store.load()
        XCTAssertEqual(reloaded.tmdbAPIKey, "tmdb-key-secret")
        XCTAssertEqual(reloaded.traktRefreshToken, "trakt-refresh-token")
    }

    /// 测试当存在旧版本遗留在 UserDefaults 中的明文凭据时，读取操作触发自动洗白与转存迁移
    func testLegacyPlaintextSecretsInUserDefaultsAreAutomaticallyMigratedAndStripped() throws {
        let secretStore = SecretStore(directory: tempDir)
        let store = AppSettingsStore(defaults: defaults, secretStore: secretStore)
        
        // 人为模拟旧版本：把明文凭据写进 UserDefaults
        var legacySettings = AppSettings()
        legacySettings.tmdbAPIKey = "legacy-tmdb-key"
        let legacyData = try JSONEncoder().encode(legacySettings)
        defaults.set(legacyData, forKey: "MediaLib.AppSettings")
        
        // 触发读取：应该自动把旧凭据吸收到 SecretStore 并重写洗白 UserDefaults
        let loaded = store.load()
        XCTAssertEqual(loaded.tmdbAPIKey, "legacy-tmdb-key", "读取到的对象应正确吸收旧明文")
        
        // 验证 SecretStore 已经收录了该值
        let storedSecrets = secretStore.load()
        XCTAssertEqual(storedSecrets["tmdbAPIKey"], "legacy-tmdb-key", "独立凭据库应已安全接管 legacy 凭据")
        
        // 再次检查 UserDefaults：明文必须已经被自动洗白抹除！
        let newBlobData = defaults.data(forKey: "MediaLib.AppSettings")!
        let newBlob = try JSONDecoder().decode(AppSettings.self, from: newBlobData)
        XCTAssertNil(newBlob.tmdbAPIKey, "旧版遗留明文必须在首次 load 时被自动迁移剥离并清零！")
    }
}
