import XCTest
@testable import MediaLibCore

final class AppSettingsSecretStorageTests: XCTestCase {
    private var tempDirectory: URL!
    private var defaults: UserDefaults!
    private var suiteName: String!
    private let blobKey = "MediaLib.AppSettings"

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SecretStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        suiteName = "AppSettingsSecretStorageTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDownWithError() throws {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makeStore() -> AppSettingsStore {
        AppSettingsStore(defaults: defaults, secretStore: SecretStore(directory: tempDirectory))
    }

    func testSecretsRoundTripButAreNotStoredInUserDefaultsBlob() throws {
        var settings = AppSettings()
        settings.tmdbAPIKey = "tmdb-key"
        settings.traktAccessToken = "trakt-token"
        settings.tmdbLanguage = "en-US" // 非 secret 字段照常进 blob

        let store = makeStore()
        store.save(settings)

        // secret 应能完整读回
        let loaded = store.load()
        XCTAssertEqual(loaded.tmdbAPIKey, "tmdb-key")
        XCTAssertEqual(loaded.traktAccessToken, "trakt-token")
        XCTAssertEqual(loaded.tmdbLanguage, "en-US")

        // UserDefaults 里的 blob 不应再含明文 secret
        let blob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: blob)
        XCTAssertNil(decoded.tmdbAPIKey)
        XCTAssertNil(decoded.traktAccessToken)
        XCTAssertEqual(decoded.tmdbLanguage, "en-US")
    }

    func testLegacyPlaintextBlobIsMigratedAndScrubbed() throws {
        // 模拟旧版本：把含明文 secret 的整个 AppSettings 直接写进 UserDefaults，secret 文件为空。
        var legacy = AppSettings()
        legacy.lastfmSharedSecret = "legacy-secret"
        legacy.openSubtitlesAPIKey = "legacy-os-key"
        let legacyBlob = try JSONEncoder().encode(legacy)
        defaults.set(legacyBlob, forKey: blobKey)

        let store = makeStore()
        // 首次 load 应迁移并返回 secret
        let loaded = store.load()
        XCTAssertEqual(loaded.lastfmSharedSecret, "legacy-secret")
        XCTAssertEqual(loaded.openSubtitlesAPIKey, "legacy-os-key")

        // 迁移后 UserDefaults blob 不应再含明文 secret
        let migratedBlob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: migratedBlob)
        XCTAssertNil(decoded.lastfmSharedSecret)
        XCTAssertNil(decoded.openSubtitlesAPIKey)

        // 独立 secret 文件应已落盘
        let stored = SecretStore(directory: tempDirectory).load()
        XCTAssertEqual(stored["lastfmSharedSecret"], "legacy-secret")
        XCTAssertEqual(stored["openSubtitlesAPIKey"], "legacy-os-key")
    }

    func testEmptySecretsDoNotLingerInBlob() throws {
        let store = makeStore()
        store.save(AppSettings()) // 无 secret
        let loaded = store.load()
        XCTAssertNil(loaded.tmdbAPIKey)
        XCTAssertNil(loaded.lastfmSessionKey)
    }
}
