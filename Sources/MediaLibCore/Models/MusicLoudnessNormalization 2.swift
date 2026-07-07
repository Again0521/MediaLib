import Foundation

public enum MusicLoudnessNormalization: String, Codable, CaseIterable, Identifiable {
    case off
    case track
    case album

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .off: return "关闭"
        case .track: return "单曲均衡"
        case .album: return "专辑均衡"
        }
    }
}

public enum MusicTransitionMode: String, Codable, CaseIterable, Identifiable {
    case immediate
    case softFade

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .immediate: return "即时衔接"
        case .softFade: return "柔和淡入"
        }
    }
}

public enum MusicLoudnessGain {
    /// AVPlayer 的 volume 上限为 1；增益同时受峰值约束，避免均衡后削波。
    public static func linearGain(
        mode: MusicLoudnessNormalization,
        trackGainDB: Double?,
        albumGainDB: Double?,
        trackPeak: Double?,
        albumPeak: Double?
    ) -> Float {
        guard mode != .off else { return 1 }

        let gainDB: Double?
        let peak: Double?
        switch mode {
        case .off:
            return 1
        case .track:
            gainDB = trackGainDB ?? albumGainDB
            peak = trackPeak ?? albumPeak
        case .album:
            gainDB = albumGainDB ?? trackGainDB
            peak = albumPeak ?? trackPeak
        }

        guard let gainDB, gainDB.isFinite else { return 1 }
        let requested = pow(10, gainDB / 20)
        let peakLimit = peak.flatMap { value in
            value.isFinite && value > 0 ? 1 / value : nil
        } ?? min(requested, 1)
        return Float(min(max(requested, 0), peakLimit, 4))
    }
}
