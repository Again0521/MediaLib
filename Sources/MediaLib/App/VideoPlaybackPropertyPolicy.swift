import MediaLibCore

struct VideoPlaybackStringProperty: Equatable {
    var name: String
    var value: String
}

struct VideoPlaybackDoubleProperty: Equatable {
    var name: String
    var value: Double
}

enum VideoPlaybackProperty: Equatable {
    case string(VideoPlaybackStringProperty)
    case double(VideoPlaybackDoubleProperty)
}

enum VideoPlaybackPropertyPolicy {
    static func aspectOverrideValue(for mode: VideoAspectOverride) -> String {
        aspectOverrideProperty(for: mode).value
    }

    static func panscanValue(for mode: VideoCropMode) -> Double {
        cropPanscanProperty(for: mode).value
    }

    static func deinterlaceValue(for mode: VideoDeinterlaceMode) -> String {
        deinterlaceProperty(for: mode).value
    }

    static func rotationValue(for mode: VideoRotationMode) -> String {
        rotationProperty(for: mode).value
    }

    static func hardwareDecodingValue(for mode: VideoHardwareDecodingMode) -> String {
        hardwareDecodingProperty(for: mode).value
    }

    static func playbackProperties(
        aspectOverride: VideoAspectOverride,
        cropMode: VideoCropMode,
        deinterlaceMode: VideoDeinterlaceMode,
        rotationMode: VideoRotationMode,
        hardwareDecodingMode: VideoHardwareDecodingMode
    ) -> [VideoPlaybackProperty] {
        [
            .string(aspectOverrideProperty(for: aspectOverride)),
            .double(cropPanscanProperty(for: cropMode)),
            .string(deinterlaceProperty(for: deinterlaceMode)),
            .string(rotationProperty(for: rotationMode)),
            .string(hardwareDecodingProperty(for: hardwareDecodingMode)),
        ]
    }

    static func aspectOverrideProperty(for mode: VideoAspectOverride) -> VideoPlaybackStringProperty {
        let value: String
        switch mode {
        case .source: value = "no"
        case .square: value = "1:1"
        case .fourByThree: value = "4:3"
        case .sixteenByNine: value = "16:9"
        case .sixteenByTen: value = "16:10"
        case .twentyOneByNine: value = "21:9"
        case .cinemaScope: value = "2.39:1"
        }
        return VideoPlaybackStringProperty(name: "video-aspect-override", value: value)
    }

    static func cropPanscanProperty(for mode: VideoCropMode) -> VideoPlaybackDoubleProperty {
        let value: Double
        switch mode {
        case .none: value = 0
        case .gentle: value = 0.18
        case .balanced: value = 0.42
        case .fill: value = 1
        }
        return VideoPlaybackDoubleProperty(name: "panscan", value: value)
    }

    static func deinterlaceProperty(for mode: VideoDeinterlaceMode) -> VideoPlaybackStringProperty {
        let value: String
        switch mode {
        case .off: value = "no"
        case .auto: value = "auto"
        case .on: value = "yes"
        }
        return VideoPlaybackStringProperty(name: "deinterlace", value: value)
    }

    static func rotationProperty(for mode: VideoRotationMode) -> VideoPlaybackStringProperty {
        let value: String
        switch mode {
        // mpv 的 `no` 会明确忽略文件旋转元数据；`0` 才是保留源旋转并不追加额外角度。
        case .source: value = "0"
        case .clockwise90: value = "90"
        case .rotate180: value = "180"
        case .counterclockwise90: value = "270"
        }
        return VideoPlaybackStringProperty(name: "video-rotate", value: value)
    }

    static func hardwareDecodingProperty(for mode: VideoHardwareDecodingMode) -> VideoPlaybackStringProperty {
        let value: String
        switch mode {
        case .safe: value = "auto-safe"
        case .automatic: value = "auto"
        case .off: value = "no"
        }
        return VideoPlaybackStringProperty(name: "hwdec", value: value)
    }
}
