import Foundation
import MediaLibCore

/// 内置音乐播放器主题参数的文件化存储（R4）。
///
/// 文件：`~/Library/Application Support/MediaLib/Themes/music-theme.json`
/// —— 一个文件承载 `MusicThemeConfig` 的全部分区（visual / wujie / wujieDesign / shelf）。
///
/// 加载策略（关键）：Swift 合成的 `Decodable` 在缺键时会抛错、并不会回退属性默认值；
/// 因此这里把用户 JSON 在【字典层】深合并到“默认配置编码出的完整字典”之上——
/// 缺的字段自动用默认补齐、用户多余/拼错的键解码时被忽略；再 clamp 掉非有限 / 超量级数值
/// （防止用户填爆值导致视觉或 WindowServer 性能崩坏），最后解码写入全局 `MusicThemeConfig.active`。
///
/// 一键恢复默认：删除文件、重写默认模板、`active` 复位为 `MusicThemeConfig()`。
/// 任意失败都安全回退默认且不抛、不崩。
enum MusicThemeConfigStore {
    struct IO: @unchecked Sendable {
        let resolveFileURL: @Sendable () -> URL?
        let fileExists: @Sendable (URL) -> Bool
        let read: @Sendable (URL) throws -> Data
        let write: @Sendable (Data, URL) throws -> Void
        let remove: @Sendable (URL) throws -> Void

        static let fileSystem = IO(
            resolveFileURL: { MusicThemeConfigStore.fileURL },
            fileExists: { url in
                FileManager.default.fileExists(atPath: url.path)
            },
            read: { url in
                try Data(contentsOf: url)
            },
            write: { data, url in
                try data.write(to: url, options: .atomic)
            },
            remove: { url in
                try FileManager.default.removeItem(at: url)
            }
        )
    }

    static let fileName = "music-theme.json"
    /// 单个数值的安全量级上限（含纳秒级时长 ~1e9，故放宽到 1e11；仅拦截真正离谱的值）。
    private static let magnitudeCap = 1e11
    static var directoryOverrideForTesting: URL?

    static func directory() -> URL? {
        if let directoryOverrideForTesting {
            try? FileManager.default.createDirectory(at: directoryOverrideForTesting, withIntermediateDirectories: true)
            return directoryOverrideForTesting
        }
        guard let base = try? FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) else { return nil }
        let dir = base
            .appendingPathComponent("MediaLib", isDirectory: true)
            .appendingPathComponent("Themes", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static var fileURL: URL? { directory()?.appendingPathComponent(fileName) }

    /// 启动时调用：有文件→加载并应用；无文件→写一份默认模板供用户编辑，active 用默认。
    static func bootstrap() {
        bootstrap(io: .fileSystem)
    }

    static func bootstrap(io: IO) {
        guard let url = io.resolveFileURL() else {
            MusicThemeConfig.active = MusicThemeConfig()
            return
        }
        if io.fileExists(url) {
            MusicThemeConfig.active = loadFromFile(io: io) ?? MusicThemeConfig()
        } else {
            try? writeTemplate(MusicThemeConfig(), io: io)
            MusicThemeConfig.active = MusicThemeConfig()
        }
    }

    /// 重新从文件加载并应用（R5「重新加载」入口）。返回是否成功读到文件。
    @discardableResult
    static func reload() -> Bool {
        reload(io: .fileSystem)
    }

    @discardableResult
    static func reload(io: IO) -> Bool {
        let cfg = loadFromFile(io: io)
        MusicThemeConfig.active = cfg ?? MusicThemeConfig()
        return cfg != nil
    }

    /// 设置页入口：文件读取放到阻塞 I/O 队列，JSON 合并和全局 active 发布回到调用方执行器。
    @discardableResult
    static func reloadAsync() async -> Bool {
        await reloadAsync(io: .fileSystem)
    }

    @discardableResult
    static func reloadAsync(io: IO) async -> Bool {
        let cfg = await loadFromFileAsync(io: io)
        MusicThemeConfig.active = cfg ?? MusicThemeConfig()
        return cfg != nil
    }

    /// 一键恢复默认：删文件、重写默认模板、active 复位。
    static func resetToDefaults() {
        resetToDefaults(io: .fileSystem)
    }

    static func resetToDefaults(io: IO) {
        if let url = io.resolveFileURL() { try? io.remove(url) }
        try? writeTemplate(MusicThemeConfig(), io: io)
        MusicThemeConfig.active = MusicThemeConfig()
    }

    static func resetToDefaultsAsync() async {
        await resetToDefaultsAsync(io: .fileSystem)
    }

    static func resetToDefaultsAsync(io: IO) async {
        let config = MusicThemeConfig()
        let data = try? templateData(for: config)
        await BlockingIOExecutor.run {
            if let url = io.resolveFileURL() {
                try? io.remove(url)
                if let data {
                    try? io.write(data, url)
                }
            }
        }
        MusicThemeConfig.active = config
    }

    /// 把配置写成带全部字段的漂亮 JSON（供用户编辑 / 作为默认模板）。
    static func writeTemplate(_ config: MusicThemeConfig) throws {
        try writeTemplate(config, io: .fileSystem)
    }

    static func writeTemplate(_ config: MusicThemeConfig, io: IO) throws {
        guard let url = io.resolveFileURL() else { return }
        try io.write(templateData(for: config), url)
    }

    static func writeTemplateAsync(_ config: MusicThemeConfig) async throws {
        try await writeTemplateAsync(config, io: .fileSystem)
    }

    static func writeTemplateAsync(_ config: MusicThemeConfig, io: IO) async throws {
        let data = try templateData(for: config)
        try await BlockingIOExecutor.run {
            guard let url = io.resolveFileURL() else { return }
            try io.write(data, url)
        }
    }

    static func loadFromFile() -> MusicThemeConfig? {
        loadFromFile(io: .fileSystem)
    }

    static func loadFromFile(io: IO) -> MusicThemeConfig? {
        guard let url = io.resolveFileURL(),
              let data = try? io.read(url)
        else { return nil }
        return decodeConfig(from: data)
    }

    static func loadFromFileAsync() async -> MusicThemeConfig? {
        await loadFromFileAsync(io: .fileSystem)
    }

    static func loadFromFileAsync(io: IO) async -> MusicThemeConfig? {
        let data = await BlockingIOExecutor.run { () -> Data? in
            guard let url = io.resolveFileURL() else { return nil }
            return try? io.read(url)
        }
        guard let data else { return nil }
        return decodeConfig(from: data)
    }

    static func ensureTemplateFileAsync(_ config: MusicThemeConfig = MusicThemeConfig()) async throws -> URL? {
        try await ensureTemplateFileAsync(config, io: .fileSystem)
    }

    static func ensureTemplateFileAsync(_ config: MusicThemeConfig = MusicThemeConfig(), io: IO) async throws -> URL? {
        let data = try templateData(for: config)
        return try await BlockingIOExecutor.run {
            guard let url = io.resolveFileURL() else { return nil }
            if !io.fileExists(url) {
                try io.write(data, url)
            }
            return url
        }
    }

    // MARK: - 私有

    private static func templateData(for config: MusicThemeConfig) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(config)
    }

    private static func decodeConfig(from data: Data) -> MusicThemeConfig? {
        guard let userObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(MusicThemeConfig()),
              let defaultObject = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
        else { return nil }

        let merged = clampNumbers(deepMerge(base: defaultObject, override: userObject))
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(MusicThemeConfig.self, from: mergedData)
        else { return nil }
        return config
    }

    /// 用户值递归覆盖默认；两边都是对象时深合并，否则用户值整体替换。
    private static func deepMerge(base: [String: Any], override: [String: Any]) -> [String: Any] {
        var result = base
        for (key, value) in override {
            if let baseChild = result[key] as? [String: Any],
               let overrideChild = value as? [String: Any] {
                result[key] = deepMerge(base: baseChild, override: overrideChild)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// 把非有限数值归零、超量级数值夹回 ±magnitudeCap；布尔与嵌套对象原样保留。
    private static func clampNumbers(_ object: [String: Any]) -> [String: Any] {
        var result = object
        for (key, value) in object {
            if let child = value as? [String: Any] {
                result[key] = clampNumbers(child)
            } else if let number = value as? NSNumber,
                      !(number === kCFBooleanTrue || number === kCFBooleanFalse) {
                let d = number.doubleValue
                if !d.isFinite {
                    result[key] = 0
                } else if abs(d) > magnitudeCap {
                    result[key] = d > 0 ? magnitudeCap : -magnitudeCap
                }
            }
        }
        return result
    }
}
