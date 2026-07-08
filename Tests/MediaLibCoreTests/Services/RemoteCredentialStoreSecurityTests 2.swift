import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P0级凭据存储安全与防敏感数据外泄专项】
/// 审计目标：验证第三方 API 密钥及 Token (`SecretStore`) 能够准确写入独立隔离空间，
/// 防止以明文 plist 形式暴露于全局 UserDefaults；并验证修改与抹除操作能彻底清除文件残留。
/// 对应报告问题 ID：TC-PRIVACY-001 / RISK-04
final class RemoteCredentialStoreSecurityTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhiteBoxAudit-Secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试 API Key 与 Token 保存到独立隔离文件且不污染 UserDefaults
    func testSecretStoreIsolatesSensitiveDataFromUserDefaults() throws {
        let store = SecretStore(directory: tempDir)
        let tmdbKey = "tmdb_secret_key_888888"
        let traktToken = "trakt_oauth_token_999999"

        // 写入机密凭据
        var secrets = store.load()
        secrets["tmdb_api_key"] = tmdbKey
        secrets["trakt_access_token"] = traktToken
        store.save(secrets)

        // 1. 验证通过 SecretStore 能够正常读取
        let reloaded = store.load()
        XCTAssertEqual(reloaded["tmdb_api_key"], tmdbKey)
        XCTAssertEqual(reloaded["trakt_access_token"], traktToken)

        // 2. 验证全局 UserDefaults 完全不受污染，绝对不可查到任何敏感字段
        let prefsDump = UserDefaults.standard.dictionaryRepresentation()
        for (_, val) in prefsDump {
            if let strVal = val as? String {
                XCTAssertFalse(strVal.contains(tmdbKey), "极其严重：TMDB API Key 泄漏到了全局 UserDefaults 中！")
                XCTAssertFalse(strVal.contains(traktToken), "极其严重：Trakt Token 泄漏到了全局 UserDefaults 中！")
            }
        }

        // 3. 验证执行退出登录或清空时，机密能够被彻底抹除
        store.save([:])
        let emptyReload = store.load()
        XCTAssertTrue(emptyReload.isEmpty, "抹除机密后必须返回空，不准留存前任用户的 Token 残迹")
    }
}
