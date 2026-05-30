import SwiftUI

enum AppSpacing {
    static let pageHorizontal: CGFloat = 32
    static let pageVertical: CGFloat = 28
    static let card: CGFloat = 14
    static let controlGroupHorizontal: CGFloat = 24
    static let controlGroupVertical: CGFloat = 11
    /// 统一所有页面：大标题栏与其下方条形卡片（筛选/排序控件栏）之间的间距。
    static let headerToControls: CGFloat = 16
}

enum AppRadius {
    static let control: CGFloat = 12
    static let controlGroup: CGFloat = 16
    static let card: CGFloat = 18
    static let panel: CGFloat = 22
    static let hero: CGFloat = 24
}

enum AppEffect {
    static let defaultGlassThickness = 1.18
    static let staticGlassThickness = 1.02
    static let controlGlassThickness = 1.22
}

enum GlassPerformanceMode: Equatable {
    case full
    case balanced
    case minimal

    var allowsPointerSampling: Bool {
        self != .minimal
    }

    var usesEfficientSurfaces: Bool {
        self != .full
    }

    var pointerIntensityScale: Double {
        switch self {
        case .full: return 1.0
        case .balanced: return 0.52
        case .minimal: return 0
        }
    }

    var pointerUpdateInterval: TimeInterval {
        switch self {
        case .full: return 1.0 / 60.0
        case .balanced: return 1.0 / 30.0  // 底部音乐栏存在时，指针采样降至 30Hz 以减少合成压力
        case .minimal: return .infinity
        }
    }

    var pointerMinDistance: CGFloat {
        switch self {
        case .full: return 2.0
        case .balanced: return 5.0
        case .minimal: return .greatestFiniteMagnitude
        }
    }

    var tiltScale: Double {
        switch self {
        case .full: return 1.0
        case .balanced: return 0.45
        case .minimal: return 0
        }
    }
}

private struct GlassPerformanceModeKey: EnvironmentKey {
    static let defaultValue: GlassPerformanceMode = .full
}

private struct PreferStaticGlassSurfacesKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var glassPerformanceMode: GlassPerformanceMode {
        get { self[GlassPerformanceModeKey.self] }
        set { self[GlassPerformanceModeKey.self] = newValue }
    }

    var preferStaticGlassSurfaces: Bool {
        get { self[PreferStaticGlassSurfacesKey.self] }
        set { self[PreferStaticGlassSurfacesKey.self] = newValue }
    }
}

extension View {
    func glassPerformanceMode(_ mode: GlassPerformanceMode) -> some View {
        environment(\.glassPerformanceMode, mode)
    }

    func preferStaticGlassSurfaces(_ enabled: Bool = true) -> some View {
        environment(\.preferStaticGlassSurfaces, enabled)
    }
}
