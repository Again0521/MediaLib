import Foundation

public final class AppSettingsStore {
    private let key = "MediaLib.AppSettings"
    private let defaults: UserDefaults
    private let secretStore: SecretStore

    /// 需要从 UserDefaults 明文 blob 中剥离、改存到 `SecretStore` 的敏感字段。
    /// 键名仅用于 secret 文件内部，与 `AppSettings` 的 CodingKeys 解耦。
    private static let secretFields: [(key: String, keyPath: WritableKeyPath<AppSettings, String?>)] = [
        ("tmdbAPIKey", \.tmdbAPIKey),
        ("openSubtitlesAPIKey", \.openSubtitlesAPIKey),
        ("lastfmAPIKey", \.lastfmAPIKey),
        ("lastfmSharedSecret", \.lastfmSharedSecret),
        ("lastfmSessionKey", \.lastfmSessionKey),
        ("traktClientSecret", \.traktClientSecret),
        ("traktAccessToken", \.traktAccessToken),
        ("traktRefreshToken", \.traktRefreshToken)
    ]

    public init(defaults: UserDefaults = .standard, secretStore: SecretStore = SecretStore()) {
        self.defaults = defaults
        self.secretStore = secretStore
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            // 无设置 blob（首次启动）：仍尝试覆盖 secret（一般为空）。
            var settings = AppSettings()
            applyStoredSecrets(to: &settings)
            return settings
        }
        var settings = (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()

        // 旧版本把 secret 明文写在 blob 里；先收集，作为迁移来源与覆盖兜底。
        let legacySecrets = collectSecrets(from: settings)
        let storedSecrets = secretStore.load()

        // 以 SecretStore 为权威；store 缺某字段时保留 blob 里的 legacy 值（迁移期）。
        for field in Self.secretFields {
            if let value = storedSecrets[field.key], !value.isEmpty {
                settings[keyPath: field.keyPath] = value
            }
        }

        // 迁移：只要 blob 含明文 secret，就重写「去 secret」的 blob。
        // 若 SecretStore 已有部分字段，以 SecretStore 为权威；store 缺失的 legacy 字段随本次 save 补齐。
        if !legacySecrets.isEmpty {
            save(settings)
        }
        return settings
    }

    public func loadAsync() async -> AppSettings {
        guard let data = defaults.data(forKey: key) else {
            // 无设置 blob（首次启动）：仍尝试覆盖 secret（一般为空）。
            var settings = AppSettings()
            await applyStoredSecretsAsync(to: &settings)
            return settings
        }
        var settings = (try? JSONDecoder().decode(AppSettings.self, from: data)) ?? AppSettings()

        // 旧版本把 secret 明文写在 blob 里；先收集，作为迁移来源与覆盖兜底。
        let legacySecrets = collectSecrets(from: settings)
        let storedSecrets = await secretStore.loadAsync()

        // 以 SecretStore 为权威；store 缺某字段时保留 blob 里的 legacy 值（迁移期）。
        apply(storedSecrets, to: &settings)

        // 迁移：只要 blob 含明文 secret，就重写「去 secret」的 blob。
        // 若 SecretStore 已有部分字段，以 SecretStore 为权威；store 缺失的 legacy 字段随本次 save 补齐。
        if !legacySecrets.isEmpty {
            await saveAsync(settings)
        }
        return settings
    }

    public func save(_ settings: AppSettings) {
        // 1) secret → 独立 0600 文件
        secretStore.save(collectSecrets(from: settings))
        // 2) 去除 secret 的副本 → UserDefaults（不再有明文密钥落入 prefs）
        var stripped = settings
        for field in Self.secretFields {
            stripped[keyPath: field.keyPath] = nil
        }
        guard let data = try? JSONEncoder().encode(stripped) else { return }
        defaults.set(data, forKey: key)
    }

    public func saveAsync(_ settings: AppSettings) async {
        // 1) secret → 独立 0600 文件
        await secretStore.saveAsync(collectSecrets(from: settings))
        // 2) 去除 secret 的副本 → UserDefaults（不再有明文密钥落入 prefs）
        var stripped = settings
        for field in Self.secretFields {
            stripped[keyPath: field.keyPath] = nil
        }
        guard let data = try? JSONEncoder().encode(stripped) else { return }
        defaults.set(data, forKey: key)
    }

    // MARK: - Helpers

    private func collectSecrets(from settings: AppSettings) -> [String: String] {
        var secrets: [String: String] = [:]
        for field in Self.secretFields {
            if let value = settings[keyPath: field.keyPath], !value.isEmpty {
                secrets[field.key] = value
            }
        }
        return secrets
    }

    private func applyStoredSecrets(to settings: inout AppSettings) {
        let stored = secretStore.load()
        apply(stored, to: &settings)
    }

    private func applyStoredSecretsAsync(to settings: inout AppSettings) async {
        let stored = await secretStore.loadAsync()
        apply(stored, to: &settings)
    }

    private func apply(_ stored: [String: String], to settings: inout AppSettings) {
        for field in Self.secretFields {
            if let value = stored[field.key], !value.isEmpty {
                settings[keyPath: field.keyPath] = value
            }
        }
    }
}
