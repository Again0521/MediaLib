struct VideoTimingAdjustmentProperty: Equatable {
    var name: String
    var value: Double
}

enum VideoTimingAdjustmentPolicy {
    static func properties(
        audioDelay: Double,
        subtitleDelay: Double,
        subtitleScale: Double,
        subtitlePosition: Double
    ) -> [VideoTimingAdjustmentProperty] {
        [
            audioDelayProperty(audioDelay),
            subtitleDelayProperty(subtitleDelay),
            subtitleScaleProperty(subtitleScale),
            subtitlePositionProperty(subtitlePosition),
        ]
    }

    static func audioDelayProperty(_ value: Double) -> VideoTimingAdjustmentProperty {
        VideoTimingAdjustmentProperty(name: "audio-delay", value: value)
    }

    static func subtitleDelayProperty(_ value: Double) -> VideoTimingAdjustmentProperty {
        VideoTimingAdjustmentProperty(name: "sub-delay", value: value)
    }

    static func subtitleScaleProperty(_ value: Double) -> VideoTimingAdjustmentProperty {
        VideoTimingAdjustmentProperty(name: "sub-scale", value: value)
    }

    static func subtitlePositionProperty(_ value: Double) -> VideoTimingAdjustmentProperty {
        VideoTimingAdjustmentProperty(name: "sub-pos", value: value)
    }
}
