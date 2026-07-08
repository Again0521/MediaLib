import MediaLibCore

struct VideoToneMappingProperty: Equatable {
    var name: String
    var value: String
}

enum VideoToneMappingPolicy {
    static func mpvValue(for mode: VideoToneMappingMode) -> String {
        property(for: mode).value
    }

    static func property(for mode: VideoToneMappingMode) -> VideoToneMappingProperty {
        let value: String
        switch mode {
        case .auto: value = "auto"
        case .bt2390: value = "bt.2390"
        case .hable: value = "hable"
        case .mobius: value = "mobius"
        case .reinhard: value = "reinhard"
        case .clip: value = "clip"
        }
        return VideoToneMappingProperty(name: "tone-mapping", value: value)
    }
}
