import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P1级敏感凭据存储与文件权限专项】
/// 审计目标：验证 `SecretStore` 在进行 API Key 和 Token 存储时，
/// 能否正确将落盘文件权限设置为严格的 0600（仅属主读写），并且在遭遇文件损坏或恶意篡改时安全兜底。
/// 对应报告问题 ID：TC-SEC-002 / RISK-06
final class SecretStoreAuditTests: XCTestCase {
    private var tempDir: URL!

    override func setUpWithError() throws {
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretStoreAudit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
    }

    /// 测试保存凭据后，落地文件的 POSIX 访问权限必须严格收敛为 0600
    func testSecretStoreFilePermissionsAreStrictly600() throws {
        let store = SecretStore(directory: tempDir)
        let secrets = ["tmdb_api_key": "secret-token-12345", "trakt_client_id": "oauth-client-id-999"]
        
        store.save(secrets)
        
        let fileURL = tempDir.appendingPathComponent("AppSecrets.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path), "凭据文件应该成功写入落盘")
        
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        let permissions = attributes[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600, "为防止本地提权或跨账户窥探，敏感凭据文件的权限必须被严格限制为 0600 (-rw-------)")
        
        let reloaded = store.load()
        XCTAssertEqual(reloaded["tmdb_api_key"], "secret-token-12345")
        XCTAssertEqual(reloaded["trakt_client_id"], "oauth-client-id-999")
    }

    /// 测试凭据文件被截断或损坏为非法 JSON 时，读取能够安全降级自愈，绝不崩溃
    func testSecretStoreSurvivesCorruptedOrMalformedJSONFile() throws {
        let store = SecretStore(directory: tempDir)
        let fileURL = tempDir.appendingPathComponent("AppSecrets.json")
        
        // 模拟断电导致文件写入一半或被非法修改
        let corruptedData = Data("{\"tmdb_api_key\": \"broken-json...".utf8)
        try corruptedData.write(to: fileURL)
        
        let loaded = store.load()
        XCTAssertTrue(loaded.isEmpty, "当凭据文件损坏或格式解析失败时，必须静默兜底返回空字典，绝对不能导致 App 闪退或死锁")
    }
}
