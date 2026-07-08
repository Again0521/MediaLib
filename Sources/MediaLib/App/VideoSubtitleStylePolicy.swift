import Foundation
import MediaLibCore

struct VideoSubtitleStyleProperties: Equatable {
    var fontName: String
    var bold: Bool
    var color: String
    var borderSize: Double
    var backgroundColor: String
}

enum VideoSubtitleStyleProperty: Equatable {
    case string(name: String, value: String)
    case flag(name: String, value: Bool)
    case double(name: String, value: Double)
}

enum VideoSubtitleStylePolicy {
    static func properties(for style: VideoSubtitleStyle) -> VideoSubtitleStyleProperties {
        let backgroundAlpha = Int((VideoSubtitleStyle.clampBackground(style.backgroundOpacity) * 255).rounded())
        return VideoSubtitleStyleProperties(
            fontName: style.fontName ?? "sans-serif",
            bold: style.bold,
            color: colorValue(for: style.colorPreset),
            borderSize: style.borderSize,
            backgroundColor: String(format: "#%02X000000", backgroundAlpha)
        )
    }

    static func playbackProperties(for style: VideoSubtitleStyle) -> [VideoSubtitleStyleProperty] {
        let properties = properties(for: style)
        return [
            .string(name: "sub-font", value: properties.fontName),
            .flag(name: "sub-bold", value: properties.bold),
            .string(name: "sub-color", value: properties.color),
            .double(name: "sub-border-size", value: properties.borderSize),
            .string(name: "sub-back-color", value: properties.backgroundColor),
        ]
    }

    static func colorValue(for preset: VideoSubtitleColorPreset) -> String {
        switch preset {
        case .white: return "#FFFFFF"
        case .yellow: return "#F5D547"
        case .cyan: return "#7FE3E8"
        case .green: return "#8FE388"
        case .orange: return "#F5A14B"
        }
    }
}
