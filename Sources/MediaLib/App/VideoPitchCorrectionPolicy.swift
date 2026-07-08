struct VideoPitchCorrectionProperty: Equatable {
    var name: String
    var enabled: Bool
}

enum VideoPitchCorrectionPolicy {
    static func property(enabled: Bool) -> VideoPitchCorrectionProperty {
        VideoPitchCorrectionProperty(name: "audio-pitch-correction", enabled: enabled)
    }
}
