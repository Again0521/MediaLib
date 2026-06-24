import Foundation

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
    static let fileName = "music-theme.json"
    /// 单个数值的安全量级上限（含纳秒级时长 ~1e9，故放宽到 1e11；仅拦截真正离谱的值）。
    private static let magnitudeCap = 1e11

    static func directory() -> URL? {
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
        guard let url = fileURL else {
            MusicThemeConfig.active = MusicThemeConfig()
            return
        }
        if FileManager.default.fileExists(atPath: url.path) {
            MusicThemeConfig.active = loadFromFile() ?? MusicThemeConfig()
        } else {
            try? writeTemplate(MusicThemeConfig())
            MusicThemeConfig.active = MusicThemeConfig()
        }
    }

    /// 重新从文件加载并应用（R5「重新加载」入口）。返回是否成功读到文件。
    @discardableResult
    static func reload() -> Bool {
        let cfg = loadFromFile()
        MusicThemeConfig.active = cfg ?? MusicThemeConfig()
        return cfg != nil
    }

    /// 一键恢复默认：删文件、重写默认模板、active 复位。
    static func resetToDefaults() {
        if let url = fileURL { try? FileManager.default.removeItem(at: url) }
        try? writeTemplate(MusicThemeConfig())
        MusicThemeConfig.active = MusicThemeConfig()
    }

    /// 把配置写成带全部字段的漂亮 JSON（供用户编辑 / 作为默认模板）。
    static func writeTemplate(_ config: MusicThemeConfig) throws {
        guard let url = fileURL else { return }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(config).write(to: url, options: .atomic)
    }

    static func loadFromFile() -> MusicThemeConfig? {
        guard let url = fileURL,
              let data = try? Data(contentsOf: url),
              let userObject = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let defaultData = try? JSONEncoder().encode(MusicThemeConfig()),
              let defaultObject = (try? JSONSerialization.jsonObject(with: defaultData)) as? [String: Any]
        else { return nil }

        let merged = clampNumbers(deepMerge(base: defaultObject, override: userObject))
        guard let mergedData = try? JSONSerialization.data(withJSONObject: merged),
              let config = try? JSONDecoder().decode(MusicThemeConfig.self, from: mergedData)
        else { return nil }
        return config
    }

    // MARK: - 私有

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
