import Foundation

/// 字幕样式（字体 / 粗体 / 颜色 / 描边 / 背景）。
///
/// 对应 libmpv 的 `sub-font` / `sub-bold` / `sub-color` / `sub-border-size` / `sub-back-color`，
/// 主流播放器（IINA / VLC / PotPlayer）都提供同类自定义。与 `VideoColorAdjustments` 一样
/// 用独立可编码结构承载，避免在 AppSettings 上铺开零散字段。
public struct VideoSubtitleStyle: Codable, Equatable, Hashable {
    /// 字体族名；nil 表示跟随播放器默认（mpv 的 `sans-serif`）。
    public var fontName: String?
    public var bold: Bool
    public var colorPreset: VideoSubtitleColorPreset
    /// 描边粗细，对应 `sub-border-size`，mpv 默认 3。
    public var borderSize: Double
    /// 背景底不透明度 0…0.8，0 表示无背景底。
    public var backgroundOpacity: Double

    public static let borderRange: ClosedRange<Double> = 0...6
    public static let backgroundRange: ClosedRange<Double> = 0...0.8

    /// 播放器默认样式。
    public static let standard = VideoSubtitleStyle()

    public init(
        fontName: String? = nil,
        bold: Bool = false,
        colorPreset: VideoSubtitleColorPreset = .white,
        borderSize: Double = 3,
        backgroundOpacity: Double = 0
    ) {
        self.fontName = fontName
        self.bold = bold
        self.colorPreset = colorPreset
        self.borderSize = Self.clampBorder(borderSize)
        self.backgroundOpacity = Self.clampBackground(backgroundOpacity)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.fontName = try container.decodeIfPresent(String.self, forKey: .fontName)
        self.bold = try container.decodeIfPresent(Bool.self, forKey: .bold) ?? false
        self.colorPreset = try container.decodeIfPresent(VideoSubtitleColorPreset.self, forKey: .colorPreset) ?? .white
        self.borderSize = Self.clampBorder(try container.decodeIfPresent(Double.self, forKey: .borderSize) ?? 3)
        self.backgroundOpacity = Self.clampBackground(try container.decodeIfPresent(Double.self, forKey: .backgroundOpacity) ?? 0)
    }

    public var isStandard: Bool {
        self == .standard
    }

    public static func clampBorder(_ value: Double) -> Double {
        guard value.isFinite else { return 3 }
        return min(max(value, borderRange.lowerBound), borderRange.upperBound)
    }

    public static func clampBackground(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value, backgroundRange.lowerBound), backgroundRange.upperBound)
    }
}

/// 字幕颜色预设。固定一组观影常用色，避免引入取色器交互。
public enum VideoSubtitleColorPreset: String, Codable, CaseIterable, Identifiable, Hashable {
    case white
    case yellow
    case cyan
    case green
    case orange

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .white: return "白色"
        case .yellow: return "黄色"
        case .cyan: return "青色"
        case .green: return "绿色"
        case .orange: return "橙色"
        }
    }

    /// mpv `sub-color` 颜色值（#RRGGBB）。
    public var mpvColor: String {
        switch self {
        case .white: return "#FFFFFF"
        case .yellow: return "#F5D547"
        case .cyan: return "#7FE3E8"
        case .green: return "#8FE388"
        case .orange: return "#F5A14B"
        }
    }
}
