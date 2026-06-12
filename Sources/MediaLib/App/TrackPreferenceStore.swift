import Foundation
import MediaLibCore

/// A7：按剧集记忆音轨/字幕轨偏好。
/// 用户在某一集手动切换音轨或字幕后，记录其语言（而非轨道号，跨集更稳健）；
/// 同一剧集（以 parentID 归并，电影则以自身 id）的下一集加载完轨道后自动套用记忆。
/// 存储于 UserDefaults，避免引入数据库迁移。
enum TrackPreferenceStore {
    /// 字幕偏好：明确关闭，或指定语言。
    enum SubtitlePreference: Equatable {
        case off
        case language(String)
    }

    private static let prefix = "MediaLib.trackPref"
    private static let offSentinel = "__off__"

    /// 剧集归并键：剧集用 parentID（同一剧的各集共享），电影/单集回落到自身 id。
    private static func seriesKey(for item: MediaItem) -> String {
        if let parentID = item.parentID, !parentID.isEmpty { return parentID }
        return item.id
    }

    private static func audioKey(for item: MediaItem) -> String {
        "\(prefix).\(seriesKey(for: item)).audio"
    }

    private static func rateKey(for item: MediaItem) -> String {
        "\(prefix).\(seriesKey(for: item)).rate"
    }

    private static func subtitleKey(for item: MediaItem) -> String {
        "\(prefix).\(seriesKey(for: item)).sub"
    }

    // MARK: - 音轨

    static func setAudioLanguage(_ language: String?, for item: MediaItem) {
        let key = audioKey(for: item)
        let trimmed = language?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmed, !trimmed.isEmpty {
            UserDefaults.standard.set(trimmed, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func audioLanguage(for item: MediaItem) -> String? {
        let value = UserDefaults.standard.string(forKey: audioKey(for: item))
        return (value?.isEmpty == false) ? value : nil
    }

    // MARK: - 倍速

    /// 记忆该系列/影片的播放倍速；恢复为 1.0 时清掉记忆，回落到全局默认倍速。
    static func setPlaybackRate(_ rate: Double?, for item: MediaItem) {
        let key = rateKey(for: item)
        if let rate, rate.isFinite, rate > 0, abs(rate - 1.0) > 0.001 {
            UserDefaults.standard.set(rate, forKey: key)
        } else {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

    static func playbackRate(for item: MediaItem) -> Double? {
        let value = UserDefaults.standard.double(forKey: rateKey(for: item))
        return value > 0 ? value : nil
    }

    // MARK: - 字幕

    static func setSubtitle(_ preference: SubtitlePreference, for item: MediaItem) {
        let key = subtitleKey(for: item)
        switch preference {
        case .off:
            UserDefaults.standard.set(offSentinel, forKey: key)
        case .language(let language):
            let trimmed = language.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                UserDefaults.standard.removeObject(forKey: key)
                return
            }
            UserDefaults.standard.set(trimmed, forKey: key)
        }
    }

    static func subtitle(for item: MediaItem) -> SubtitlePreference? {
        guard let value = UserDefaults.standard.string(forKey: subtitleKey(for: item)), !value.isEmpty else {
            return nil
        }
        return value == offSentinel ? .off : .language(value)
    }
}
