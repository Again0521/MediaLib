import Foundation

/// 一首曲目"有没有歌词"这件事的唯一判定。
///
/// 从前它只活在客户端音乐页里的一个内存缓存里：每次列表刷新都对每条曲目做两次
/// `fileExists`，结果不落盘、退出即丢，服务端更是完全看不到——网页端因此一直
/// 提供不了「有歌词」筛选，只能在文档里写明"有意缺席"。
///
/// 判定包含两个来源，缺一不可：
///
/// * **内嵌歌词**：`AudioMetadataReader` 扫描时已经把 `lyrics` 解析出来了，几乎
///   不额外花钱。客户端那版只看外挂文件，所以一首把歌词写在标签里的曲目会被判
///   成"没有歌词"——播放器明明能显示它。
/// * **外挂歌词**：同目录同名的 `.lrc` / `.txt`。
///
/// 判定结果会随扫描落库（`media_items.has_lyrics`），于是两端读的是同一个值，
/// 列表也不必再为了画一个角标去 stat 整个曲库——那正是 NAS 上最慢的一类操作。
public enum MusicLyricsPresence {
    /// 会被当作外挂歌词的扩展名。顺序即探测顺序。
    public static let sidecarExtensions = ["lrc", "txt"]

    /// 综合内嵌与外挂两个来源。
    ///
    /// - Parameters:
    ///   - embeddedLyrics: 音频标签里的歌词文本，没有则传 `nil`。
    ///   - filePath: 曲目文件路径，用于探测同目录的外挂歌词；`nil` 时只看内嵌。
    public static func hasLyrics(embeddedLyrics: String?, filePath: String?) -> Bool {
        if let embeddedLyrics, !embeddedLyrics.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return true
        }
        guard let filePath else { return false }
        return sidecarExists(filePath: filePath)
    }

    /// 同目录是否存在同名歌词文件。
    ///
    /// 路径拼接走 `NSString`，不构造 `URL`：`URL(fileURLWithPath:)` 会对路径做一次
    /// `stat` 来判断是否目录，在 NAS 上这一下就是几百毫秒，而这里每首曲目都要走一
    /// 遍。真正碰盘的只有下面那两次 `fileExists`。
    public static func sidecarExists(filePath: String) -> Bool {
        let path = filePath as NSString
        let directory = path.deletingLastPathComponent as NSString
        let basename = (path.lastPathComponent as NSString).deletingPathExtension
        guard !basename.isEmpty else { return false }
        return sidecarExtensions.contains { ext in
            FileManager.default.fileExists(atPath: directory.appendingPathComponent("\(basename).\(ext)"))
        }
    }
}
