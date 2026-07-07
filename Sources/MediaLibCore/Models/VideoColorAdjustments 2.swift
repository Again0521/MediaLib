import Foundation

/// 画面色彩微调（亮度 / 对比度 / 饱和度 / 伽马 / 色相）。
///
/// 对应 libmpv 的 `brightness` / `contrast` / `saturation` / `gamma` / `hue` 五个属性，
/// 取值范围均为 -100…100，0 表示原始画面。主流播放器（VLC / PotPlayer / IINA）都提供
/// 类似的「视频均衡器」，这里以一个独立可编码结构承载，避免在 AppSettings 上铺开五个零散字段。
public struct VideoColorAdjustments: Codable, Equatable, Hashable {
    public var brightness: Double
    public var contrast: Double
    public var saturation: Double
    public var gamma: Double
    public var hue: Double

    public static let range: ClosedRange<Double> = -100...100

    /// 原始画面（全部为 0）。
    public static let neutral = VideoColorAdjustments(
        brightness: 0,
        contrast: 0,
        saturation: 0,
        gamma: 0,
        hue: 0
    )

    public init(
        brightness: Double = 0,
        contrast: Double = 0,
        saturation: Double = 0,
        gamma: Double = 0,
        hue: Double = 0
    ) {
        self.brightness = Self.clamp(brightness)
        self.contrast = Self.clamp(contrast)
        self.saturation = Self.clamp(saturation)
        self.gamma = Self.clamp(gamma)
        self.hue = Self.clamp(hue)
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.brightness = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .brightness) ?? 0)
        self.contrast = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .contrast) ?? 0)
        self.saturation = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .saturation) ?? 0)
        self.gamma = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .gamma) ?? 0)
        self.hue = Self.clamp(try container.decodeIfPresent(Double.self, forKey: .hue) ?? 0)
    }

    /// 是否为原始画面（无任何调整）。
    public var isNeutral: Bool {
        brightness == 0 && contrast == 0 && saturation == 0 && gamma == 0 && hue == 0
    }

    /// 将单个分量限制在合法范围内，并取整（libmpv 这些属性接受整数）。
    public static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0 }
        return min(max(value.rounded(), range.lowerBound), range.upperBound)
    }
}
