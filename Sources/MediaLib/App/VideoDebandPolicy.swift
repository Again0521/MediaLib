import MediaLibCore

struct VideoDebandProperties: Equatable {
    var enabled: Bool
    var threshold: Double
    var range: Double
    var grain: Double
}

enum VideoDebandProperty: Equatable {
    case flag(name: String, value: Bool)
    case double(name: String, value: Double)
}

enum VideoDebandPolicy {
    static func properties(for mode: VideoDebandMode) -> VideoDebandProperties {
        switch mode {
        case .off:
            return VideoDebandProperties(enabled: false, threshold: 64, range: 16, grain: 48)
        case .light:
            return VideoDebandProperties(enabled: true, threshold: 32, range: 12, grain: 24)
        case .strong:
            return VideoDebandProperties(enabled: true, threshold: 48, range: 18, grain: 36)
        }
    }

    static func playbackProperties(for mode: VideoDebandMode) -> [VideoDebandProperty] {
        let properties = properties(for: mode)
        return [
            .flag(name: "deband", value: properties.enabled),
            .double(name: "deband-threshold", value: properties.threshold),
            .double(name: "deband-range", value: properties.range),
            .double(name: "deband-grain", value: properties.grain),
        ]
    }
}
