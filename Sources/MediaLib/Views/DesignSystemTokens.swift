import SwiftUI

enum AppSpacing {
    static let pageHorizontal: CGFloat = 32
    static let pageVertical: CGFloat = 28
    static let card: CGFloat = 14
    static let controlGroupHorizontal: CGFloat = 24
    static let controlGroupVertical: CGFloat = 11
    static let sheetHorizontal: CGFloat = 24
    static let sheetVertical: CGFloat = 24
    static let sheetContent: CGFloat = 18
    static let sheetFooter: CGFloat = 10
    static let toolbarHorizontal: CGFloat = 10
    static let toolbarVertical: CGFloat = 9
    /// 统一所有页面：大标题栏与其下方条形卡片（筛选/排序控件栏）之间的间距。
    static let headerToControls: CGFloat = 16
}

enum AppRadius {
    static let control: CGFloat = 12
    static let controlGroup: CGFloat = 16
    static let card: CGFloat = 18
    static let panel: CGFloat = 22
    static let hero: CGFloat = 24
    static let sheet: CGFloat = 22
    static let toolbar: CGFloat = 18
    static let informationNote: CGFloat = 10
}

enum AppEffect {
    static let defaultGlassThickness = 1.18
    static let staticGlassThickness = 1.02
    static let controlGlassThickness = 1.22
}

enum AppSheetMetrics {
    static let compactWidth: CGFloat = 430
    static let standardWidth: CGFloat = 560
    static let wideWidth: CGFloat = 620
    static let headerIconSize: CGFloat = 42
}

enum AppControlMetrics {
    static let minMenuWidth: CGFloat = 92
    static let maxMenuWidth: CGFloat = 360
    static let minTouchHeight: CGFloat = 30
    static let defaultButtonHeight: CGFloat = 32
    static let headerButtonHeight: CGFloat = 34
}

enum AppDesignStandard {
    /// 普通页面使用大标题 PageHeader；弹窗使用 AppSheetHeader，避免 sheet 像完整页面一样过重。
    static let pageHeaderTitleSize: CGFloat = 32
    /// 重复列表、网格、设置行优先使用静态玻璃，只有少量页头/主操作控件使用更厚玻璃。
    static let repeatedSurfaceRole = GlassSurfaceRole.repeated
    /// 会打开面板或新流程的按钮文案保留明确动词，必要时使用省略号；即时动作不使用省略号。
    static let actionOpensFollowUpShouldUseEllipsis = true
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
        case .full: return 0.88
        case .balanced: return 0.36
        case .minimal: return 0
        }
    }

    var pointerUpdateInterval: TimeInterval {
        switch self {
        case .full: return 1.0 / 60.0
        case .balanced: return 1.0 / 24.0  // 底部音乐栏存在时，指针采样降至 24Hz 以减少合成压力
        case .minimal: return .infinity
        }
    }

    var pointerMinDistance: CGFloat {
        switch self {
        case .full: return 3.0
        case .balanced: return 8.5
        case .minimal: return .greatestFiniteMagnitude
        }
    }

    var tiltScale: Double {
        switch self {
        case .full: return 0.88
        case .balanced: return 0.28
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
