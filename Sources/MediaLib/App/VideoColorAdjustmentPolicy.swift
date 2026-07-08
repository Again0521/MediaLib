import MediaLibCore

struct VideoColorAdjustmentProperty: Equatable {
    var name: String
    var value: Double
}

enum VideoColorAdjustmentPolicy {
    static func properties(for adjustments: VideoColorAdjustments) -> [VideoColorAdjustmentProperty] {
        [
            VideoColorAdjustmentProperty(name: "brightness", value: adjustments.brightness),
            VideoColorAdjustmentProperty(name: "contrast", value: adjustments.contrast),
            VideoColorAdjustmentProperty(name: "saturation", value: adjustments.saturation),
            VideoColorAdjustmentProperty(name: "gamma", value: adjustments.gamma),
            VideoColorAdjustmentProperty(name: "hue", value: adjustments.hue),
        ]
    }
}
