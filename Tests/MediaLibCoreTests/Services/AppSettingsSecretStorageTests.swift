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

    func testAsyncSaveStoresSecretsOutsideUserDefaultsBlob() async throws {
        var settings = AppSettings()
        settings.openSubtitlesAPIKey = "opensubtitles-key"
        settings.traktRefreshToken = "trakt-refresh"
        settings.tmdbLanguage = "ja-JP"

        let store = makeStore()
        await store.saveAsync(settings)

        let loaded = store.load()
        XCTAssertEqual(loaded.openSubtitlesAPIKey, "opensubtitles-key")
        XCTAssertEqual(loaded.traktRefreshToken, "trakt-refresh")
        XCTAssertEqual(loaded.tmdbLanguage, "ja-JP")

        let blob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decoded = try JSONDecoder().decode(AppSettings.self, from: blob)
        XCTAssertNil(decoded.openSubtitlesAPIKey)
        XCTAssertNil(decoded.traktRefreshToken)
        XCTAssertEqual(decoded.tmdbLanguage, "ja-JP")

        let storedSecrets = await SecretStore(directory: tempDirectory).loadAsync()
        XCTAssertEqual(storedSecrets["openSubtitlesAPIKey"], "opensubtitles-key")
        XCTAssertEqual(storedSecrets["traktRefreshToken"], "trakt-refresh")
    }

    func testAsyncLoadAppliesStoredSecretsWhenSettingsBlobIsMissing() async {
        let secretStore = SecretStore(directory: tempDirectory)
        await secretStore.saveAsync([
            "tmdbAPIKey": "stored-tmdb",
            "lastfmSessionKey": "stored-lastfm-session"
        ])
        let store = AppSettingsStore(defaults: defaults, secretStore: secretStore)

        let loaded = await store.loadAsync()

        XCTAssertEqual(loaded.tmdbAPIKey, "stored-tmdb")
        XCTAssertEqual(loaded.lastfmSessionKey, "stored-lastfm-session")
        XCTAssertNil(defaults.data(forKey: blobKey))
    }

    func testAsyncLoadMigratesLegacyPlaintextBlobAndScrubsUserDefaults() async throws {
        var legacy = AppSettings()
        legacy.lastfmAPIKey = "legacy-lastfm-key"
        legacy.traktClientSecret = "legacy-trakt-secret"
        legacy.tmdbLanguage = "ko-KR"
        defaults.set(try JSONEncoder().encode(legacy), forKey: blobKey)

        let store = makeStore()
        let loaded = await store.loadAsync()

        XCTAssertEqual(loaded.lastfmAPIKey, "legacy-lastfm-key")
        XCTAssertEqual(loaded.traktClientSecret, "legacy-trakt-secret")
        XCTAssertEqual(loaded.tmdbLanguage, "ko-KR")

        let migratedBlob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decodedBlob = try JSONDecoder().decode(AppSettings.self, from: migratedBlob)
        XCTAssertNil(decodedBlob.lastfmAPIKey)
        XCTAssertNil(decodedBlob.traktClientSecret)
        XCTAssertEqual(decodedBlob.tmdbLanguage, "ko-KR")

        let stored = await SecretStore(directory: tempDirectory).loadAsync()
        XCTAssertEqual(stored["lastfmAPIKey"], "legacy-lastfm-key")
        XCTAssertEqual(stored["traktClientSecret"], "legacy-trakt-secret")
    }

    func testLoadScrubsLegacyPlaintextBlobEvenWhenSecretStoreAlreadyHasValues() throws {
        let secretStore = SecretStore(directory: tempDirectory)
        secretStore.save(["tmdbAPIKey": "stored-tmdb-key"])
        var legacy = AppSettings()
        legacy.tmdbAPIKey = "legacy-tmdb-key"
        legacy.openSubtitlesAPIKey = "legacy-opensubtitles-key"
        legacy.tmdbLanguage = "zh-Hans"
        defaults.set(try JSONEncoder().encode(legacy), forKey: blobKey)

        let store = AppSettingsStore(defaults: defaults, secretStore: secretStore)
        let loaded = store.load()

        XCTAssertEqual(loaded.tmdbAPIKey, "stored-tmdb-key")
        XCTAssertEqual(loaded.openSubtitlesAPIKey, "legacy-opensubtitles-key")
        XCTAssertEqual(loaded.tmdbLanguage, "zh-Hans")

        let scrubbedBlob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decodedBlob = try JSONDecoder().decode(AppSettings.self, from: scrubbedBlob)
        XCTAssertNil(decodedBlob.tmdbAPIKey)
        XCTAssertNil(decodedBlob.openSubtitlesAPIKey)
        XCTAssertEqual(decodedBlob.tmdbLanguage, "zh-Hans")

        let stored = secretStore.load()
        XCTAssertEqual(stored["tmdbAPIKey"], "stored-tmdb-key")
        XCTAssertEqual(stored["openSubtitlesAPIKey"], "legacy-opensubtitles-key")
    }

    func testAsyncLoadScrubsLegacyPlaintextBlobEvenWhenSecretStoreAlreadyHasValues() async throws {
        let secretStore = SecretStore(directory: tempDirectory)
        await secretStore.saveAsync(["traktAccessToken": "stored-trakt-access"])
        var legacy = AppSettings()
        legacy.traktAccessToken = "legacy-trakt-access"
        legacy.traktRefreshToken = "legacy-trakt-refresh"
        legacy.tmdbLanguage = "en-GB"
        defaults.set(try JSONEncoder().encode(legacy), forKey: blobKey)

        let store = AppSettingsStore(defaults: defaults, secretStore: secretStore)
        let loaded = await store.loadAsync()

        XCTAssertEqual(loaded.traktAccessToken, "stored-trakt-access")
        XCTAssertEqual(loaded.traktRefreshToken, "legacy-trakt-refresh")
        XCTAssertEqual(loaded.tmdbLanguage, "en-GB")

        let scrubbedBlob = try XCTUnwrap(defaults.data(forKey: blobKey))
        let decodedBlob = try JSONDecoder().decode(AppSettings.self, from: scrubbedBlob)
        XCTAssertNil(decodedBlob.traktAccessToken)
        XCTAssertNil(decodedBlob.traktRefreshToken)
        XCTAssertEqual(decodedBlob.tmdbLanguage, "en-GB")

        let stored = await secretStore.loadAsync()
        XCTAssertEqual(stored["traktAccessToken"], "stored-trakt-access")
        XCTAssertEqual(stored["traktRefreshToken"], "legacy-trakt-refresh")
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
