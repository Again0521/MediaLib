import MediaLibCore

struct VideoFilterChainProperty: Equatable {
    var name: String
    var value: String
}

enum VideoFilterChainPolicy {
    static func property(
        baseVideoFilter: String?,
        flipMode: VideoFlipMode,
        sharpenMode: VideoSharpenMode,
        denoiseMode: VideoDenoiseMode
    ) -> VideoFilterChainProperty {
        VideoFilterChainProperty(
            name: "vf",
            value: filter(
                baseVideoFilter: baseVideoFilter,
                flipMode: flipMode,
                sharpenMode: sharpenMode,
                denoiseMode: denoiseMode
            )
        )
    }

    static func filter(
        baseVideoFilter: String?,
        flipMode: VideoFlipMode,
        sharpenMode: VideoSharpenMode,
        denoiseMode: VideoDenoiseMode
    ) -> String {
        var filters: [String] = []
        if let qualityFilter = baseVideoFilter, !qualityFilter.isEmpty {
            filters.append(qualityFilter)
        }
        filters.append(contentsOf: flipFilters(for: flipMode))
        if let sharpen = sharpenFilter(for: sharpenMode) {
            filters.append(sharpen)
        }
        if let denoise = denoiseFilter(for: denoiseMode) {
            filters.append(denoise)
        }
        return filters.joined(separator: ",")
    }

    private static func flipFilters(for mode: VideoFlipMode) -> [String] {
        switch mode {
        case .none: return []
        case .horizontal: return ["hflip"]
        case .vertical: return ["vflip"]
        case .both: return ["hflip", "vflip"]
        }
    }

    private static func sharpenFilter(for mode: VideoSharpenMode) -> String? {
        switch mode {
        case .off: return nil
        case .light: return "unsharp=la=0.4"
        case .medium: return "unsharp=la=0.8"
        case .strong: return "unsharp=la=1.2"
        }
    }

    private static func denoiseFilter(for mode: VideoDenoiseMode) -> String? {
        switch mode {
        case .off: return nil
        case .light: return "hqdn3d=2:1.5:3:2.25"
        case .medium: return "hqdn3d=4:3:6:4.5"
        case .strong: return "hqdn3d=7:5:10:7.5"
        }
    }
}
