import SwiftUI

enum AppSpacing {
    static let pageHorizontal: CGFloat = 32
    static let pageVertical: CGFloat = 28
    static let pageHeaderHorizontal: CGFloat = 4
    static let pageHeaderVertical: CGFloat = 6
    static let pageHeaderIconToText: CGFloat = 8
    static let pageHeaderIconSafeSlot: CGFloat = 62
    static let pageHeaderIconSafeHeight: CGFloat = 68
    /// 右侧操作区优先按副标题真实底边测量对齐；该值只作为首次测量前的短暂 fallback。
    static let pageHeaderActionSubtitleBottomFallbackLift: CGFloat = 6
    static let pageHeaderActionGap: CGFloat = 10
    static let card: CGFloat = 14
    static let settingsSectionHeaderToCard: CGFloat = 12
    static let settingsSectionContentLeading: CGFloat = 50
    static let settingsSectionOuterLeading: CGFloat = 28
    static let controlGroupHorizontal: CGFloat = 26
    static let controlGroupVertical: CGFloat = 14
    static let sheetHorizontal: CGFloat = 24
    static let sheetVertical: CGFloat = 24
    static let sheetContent: CGFloat = 18
    static let sheetFooter: CGFloat = 10
    static let toolbarHorizontal: CGFloat = 22
    static let toolbarVertical: CGFloat = 14
    /// 统一所有页面：大标题栏与其下方条形卡片（筛选/排序控件栏）之间的间距。
    static let headerToControls: CGFloat = 16
}

enum AppRadius {
    // 控件/控制栏/卡片半径以 `MediaLIB 系统页面.html` 歌曲页实测为准：
    // 控制栏与筛选卡 16、通用卡片 16、控件 12，统一“卡边”几何语言。
    static let control: CGFloat = 12
    static let controlGroup: CGFloat = 16
    static let card: CGFloat = 16
    static let panel: CGFloat = 22
    static let hero: CGFloat = 24
    static let sheet: CGFloat = 22
    static let toolbar: CGFloat = 16
    static let informationNote: CGFloat = 10
}

enum AppEffect {
    static let defaultGlassThickness = AppGlassMetrics.Thickness.surface
    static let staticGlassThickness = AppGlassMetrics.Thickness.repeated
    static let controlGlassThickness = AppGlassMetrics.Thickness.control
}

/// 普通页面共享玻璃的视觉层级刻度。
///
/// 播放器和音乐展开页继续使用各自的专用视觉 token；这里仅约束普通页面、弹窗、
/// 工具条、表单与重复卡片，避免在各组件中继续散落近似但不一致的描边和阴影参数。
enum AppGlassMetrics {
    enum Thickness {
        static let repeated = 1.02
        static let surface = 1.18
        static let control = 1.22
        static let headerControl = 1.28
        static let elevated = 1.36
    }

    enum Stroke {
        static let hairline: CGFloat = 0.75
        static let surface: CGFloat = 1.0
        static let selected: CGFloat = 1.15
        static let focusInner: CGFloat = 1.35
        static let focusOuter: CGFloat = 3.0
    }

    enum Shadow {
        static let repeatedRadius: CGFloat = 8
        static let repeatedY: CGFloat = 4
        static let surfaceRadius: CGFloat = 10
        static let surfaceY: CGFloat = 5
        static let controlRadius: CGFloat = 5
        static let controlY: CGFloat = 1
    }

    enum Focus {
        static let outerPadding: CGFloat = 2
        static let outerOpacityLight = 0.18
        static let outerOpacityDark = 0.24
        static let innerOpacityLight = 0.48
        static let innerOpacityDark = 0.56
    }
}

enum AppSheetMetrics {
    static let compactWidth: CGFloat = 430
    static let standardWidth: CGFloat = 560
    static let wideWidth: CGFloat = 620
    static let headerIconSize: CGFloat = 42
    static let headerIconContainerSize: CGFloat = 52
    static let sectionCornerRadius: CGFloat = 18
    static let sectionContentPadding: CGFloat = 16
}

enum AppControlMetrics {
    static let minMenuWidth: CGFloat = 92
    static let maxMenuWidth: CGFloat = 360
    static let minTouchHeight: CGFloat = 30
    static let defaultButtonHeight: CGFloat = 38
    static let prominentButtonHeight: CGFloat = 41
    static let headerButtonHeight: CGFloat = 41
    static let searchFieldHeight: CGFloat = 41
    static let settingsRowHeight: CGFloat = 36
    /// 统一的禁用态不透明度：所有自定义控件在 isEnabled == false 时整控件降到此值，
    /// 让禁用态在按钮 / 图标 / 页头 / 输入外壳之间观感一致（启用态不受影响）。
    static let disabledControlOpacity: Double = 0.5
}

enum AppCardMetrics {
    static let repeatedCornerRadius: CGFloat = 16
    static let posterCoverCornerRadius: CGFloat = 12
    static let compactArtworkCornerRadius: CGFloat = 9
    static let repeatedContentPadding: CGFloat = 14
    static let musicRowHeight: CGFloat = 60
    static let emptyStateMinimumHeight: CGFloat = 236
    static let emptyStateTextWidth: CGFloat = 520
}

/// 活力色彩专用刻度：Hero 焦点卡、多色统计磁贴、区块标题彩条与入场节奏。
///
/// 这些刻度供首页与全局语义色彩组件统一读取，避免在各处散落近似但不一致的尺寸。
/// `touchTargetMin` 为 iOS / iPadOS 移植预备：新交互组件的命中区不得低于该值。
enum AppAuroraMetrics {
    static let heroCornerRadius: CGFloat = AppRadius.hero        // 24
    static let heroMinHeight: CGFloat = 240
    static let heroContentPadding: CGFloat = 28
    static let statTileCornerRadius: CGFloat = 18
    static let statTileIconChipSize: CGFloat = 44
    static let statTileMinWidth: CGFloat = 150
    static let sectionAccentBarWidth: CGFloat = 5
    static let sectionAccentBarHeight: CGFloat = 20
    static let sectionAccentBarCornerRadius: CGFloat = 2
    /// 轮播左右切换箭头：精致小玻璃钮（hover 显示）。
    static let carouselArrowSize: CGFloat = 28
    static let carouselArrowIcon: CGFloat = 11
    /// 推荐行：竖版/方形海报卡的最小宽度，决定窗口缩放时单行能放下的张数。
    static let recommendPortraitMinWidth: CGFloat = 132
    static let recommendSquareMinWidth: CGFloat = 138
    static let recommendRowSpacing: CGFloat = 14
    static let recommendMaxCount: Int = 8
    /// 相册墙缩略图边长。
    static let albumWallThumbSide: CGFloat = 92
    /// 区块 / 列表逐项入场的单步延时（秒）。建议对前若干项生效后封顶，避免长列表整体延迟。
    static let blockStaggerStep: Double = 0.04
    static let blockStaggerMaxItems: Int = 8
    /// iOS / iPadOS 触控命中区下限（pt）。
    static let touchTargetMin: CGFloat = 44
}

enum AppDesignStandard {
    /// 普通页面使用大标题 PageHeader；弹窗使用 AppSheetHeader，避免 sheet 像完整页面一样过重。
    static let pageHeaderTitleSize: CGFloat = 30
    static let pageHeaderSubtitleMaxWidth: CGFloat = 680
    static let pageHeaderMinimumTitleWidth: CGFloat = 220
    static let pageHeaderActionsIdealWidth: CGFloat = 360
    static let pageHeaderActionsMaxWidth: CGFloat = 760
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
