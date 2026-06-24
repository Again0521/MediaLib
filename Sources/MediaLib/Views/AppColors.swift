import AppKit
import CryptoKit
import Foundation
import ImageIO
import OSLog
import SwiftUI

enum AppColors {
    /// 当前生效的用户配色（除音乐展开页外的全局色板都由它派生）。
    /// 由 AppState 在启动与设置变更时写入。didSet 时一次性重算整套派生色并缓存，
    /// 之后各色板属性只做廉价的缓存读取——避免在每帧/每个玻璃面重复做颜色空间转换与混色运算，保证滚动流畅。
    static var activeTheme: ResolvedAppTheme = .classic {
        didSet { resolved = ResolvedColorSet(theme: activeTheme) }
    }
    private static var resolved = ResolvedColorSet(theme: .classic)

    // 各色板：从缓存读取（廉价）。派生数学只在换色时执行一次。
    static var pageBackground: Color { Color(nsColor: resolved.pageBackground) }
    static var surface: Color { Color(nsColor: resolved.surface) }
    static var secondarySurface: Color { Color(nsColor: resolved.secondarySurface) }
    static var glassTint: Color { Color(nsColor: resolved.glassTint) }
    static var cleanPanelFill: Color { Color(nsColor: resolved.cleanPanelFill) }
    static var cleanFieldFill: Color { Color(nsColor: resolved.cleanFieldFill) }
    static var sidebarBlueWash: Color { Color(nsColor: resolved.sidebarBlueWash) }
    static var cardAquaWash: Color { Color(nsColor: resolved.cardAquaWash) }
    static var accentGradient: LinearGradient { resolved.accentGradient }
    static var pointerLightTint: Color { Color(nsColor: resolved.pointerLightTint) }
    static var solarLightTint: Color { Color(nsColor: resolved.solarLightTint) }
    static var solarEdgeTint: Color { Color(nsColor: resolved.solarEdgeTint) }
    static var selectedGlassTint: Color { Color(nsColor: resolved.selectedGlassTint) }
    static var primary: Color { Color(nsColor: resolved.primary) }
    static var secondary: Color { Color(nsColor: resolved.secondary) }
    static var accent: Color { Color(nsColor: resolved.accent) }
    static var background: Color { Color(nsColor: resolved.background) }
    static var elevatedSurface: Color { Color(nsColor: resolved.elevatedSurface) }
    static var border: Color { Color(nsColor: resolved.border) }
    static var textPrimary: Color { Color(nsColor: resolved.textPrimary) }
    static var textSecondary: Color { Color(nsColor: resolved.textSecondary) }
    static var success: Color { Color(nsColor: resolved.success) }
    static var warning: Color { Color(nsColor: resolved.warning) }
    static var error: Color { Color(nsColor: resolved.error) }

    // 与主题无关的中性描边：保留固定取值。
    static var subtleBorder: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.74),
            dark:  NSColor(calibratedWhite: 1.0, alpha: 0.22)
        ))
    }

    static var cleanPanelBorder: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.54, green: 0.50, blue: 0.42, alpha: 0.16),
            dark:  NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.78,  alpha: 0.13)
        ))
    }

    /// 一套从 ResolvedAppTheme 三锚点派生好的最终动态色，换色时构建一次。
    private struct ResolvedColorSet {
        let pageBackground: NSColor
        let surface: NSColor
        let secondarySurface: NSColor
        let glassTint: NSColor
        let cleanPanelFill: NSColor
        let cleanFieldFill: NSColor
        let sidebarBlueWash: NSColor
        let cardAquaWash: NSColor
        let pointerLightTint: NSColor
        let solarLightTint: NSColor
        let solarEdgeTint: NSColor
        let selectedGlassTint: NSColor
        let primary: NSColor
        let secondary: NSColor
        let accent: NSColor
        let background: NSColor
        let elevatedSurface: NSColor
        let border: NSColor
        let textPrimary: NSColor
        let textSecondary: NSColor
        let success: NSColor
        let warning: NSColor
        let error: NSColor
        let accentGradient: LinearGradient
        /// 三段主题图标渐变色（由高亮锚点派生），供 PlayfulSymbolIcon 等图标跟随配色。
        let iconColors: [Color]
        /// 强调按钮（prominent）填充用的三段主题色（由高亮锚点按明度派生，自上而下加深）。
        let accentButtonColors: [Color]

        init(theme: ResolvedAppTheme) {
            // 系统色预设保持 Apple 式中性底：页面大面积区域低饱和，强调色主要出现在选中态、按钮和局部边缘光。
            pageBackground = AppColors.dynamic(
                light: theme.baseLight.appThemeSaturated(by: 0.56).appThemeWithAlpha(0.97),
                dark:  theme.baseDark.appThemeSaturated(by: 0.70).appThemeWithAlpha(0.95))
            surface = AppColors.dynamic(
                light: theme.baseLight.appThemeLightened(by: 0.085).appThemeWithAlpha(0.86),
                dark:  theme.baseDark.appThemeLightened(by: 0.15).appThemeWithAlpha(0.58))
            secondarySurface = AppColors.dynamic(
                light: theme.baseLight.appThemeLightened(by: 0.072).appThemeWithAlpha(0.82),
                dark:  theme.baseDark.appThemeLightened(by: 0.11).appThemeWithAlpha(0.64))
            glassTint = AppColors.dynamic(
                light: theme.lightLight.appThemeWithAlpha(0.32),
                dark:  theme.lightDark.appThemeWithAlpha(0.24))
            // 卡片底色：相对页面底色提亮更多、并提高不透明度，让卡片明确浮在背景之上，
            // 不再因半透明而与底色糊在一起（浅色 +0.085→+0.115 / α0.78→0.90，深色 +0.13→+0.16 / α0.78→0.88）。
            cleanPanelFill = AppColors.dynamic(
                light: theme.baseLight.appThemeLightened(by: 0.115).appThemeWithAlpha(0.90),
                dark:  theme.baseDark.appThemeLightened(by: 0.16).appThemeWithAlpha(0.88))
            cleanFieldFill = AppColors.dynamic(
                light: theme.baseLight.appThemeLightened(by: 0.060).appThemeWithAlpha(0.58),
                dark:  theme.baseDark.appThemeLightened(by: 0.18).appThemeWithAlpha(0.66))
            sidebarBlueWash = AppColors.dynamic(
                light: theme.highlightLight.appThemeLightened(by: 0.50).appThemeWithAlpha(0.12),
                dark:  theme.highlightDark.appThemeWithAlpha(0.18))
            cardAquaWash = AppColors.dynamic(
                light: theme.lightLight.appThemeWithAlpha(0.13),
                dark:  theme.lightDark.appThemeAdjustingBrightness(by: 0.5).appThemeWithAlpha(0.16))
            // Hover / pointer light is part of the selected theme, not a fixed blue wash.
            // Start from the user-controlled top-left light, then gently fold in the
            // highlight color so coral/lime/mica/sand-gold/sea-salt presets keep their own hover tone.
            let pointerLight = theme.lightLight
                .appThemeBlended(toward: theme.highlightLight.appThemeLightened(by: 0.42), fraction: 0.24)
                .appThemeSaturated(by: 0.72)
                .appThemeLightened(by: 0.08)
            let pointerDark = theme.lightDark
                .appThemeBlended(toward: theme.highlightDark.appThemeLightened(by: 0.12), fraction: 0.34)
                .appThemeSaturated(by: 0.96)
                .appThemeAdjustingBrightness(by: 1.08)
            pointerLightTint = AppColors.dynamic(light: pointerLight, dark: pointerDark)
            solarLightTint = AppColors.dynamic(
                light: pointerLight.appThemeLightened(by: 0.18),
                dark:  pointerDark.appThemeLightened(by: 0.08))
            solarEdgeTint = AppColors.dynamic(
                light: pointerLight
                    .appThemeBlended(toward: theme.highlightLight, fraction: 0.18)
                    .appThemeSaturated(by: 0.98)
                    .appThemeAdjustingBrightness(by: 0.96),
                dark:  pointerDark
                    .appThemeBlended(toward: theme.highlightDark, fraction: 0.18)
                    .appThemeSaturated(by: 1.06))
            selectedGlassTint = AppColors.dynamic(light: theme.highlightLight, dark: theme.highlightDark)
            primary = AppColors.dynamic(light: theme.tokens.primary.light, dark: theme.tokens.primary.dark)
            secondary = AppColors.dynamic(light: theme.tokens.secondary.light, dark: theme.tokens.secondary.dark)
            accent = AppColors.dynamic(light: theme.tokens.accent.light, dark: theme.tokens.accent.dark)
            background = AppColors.dynamic(light: theme.tokens.background.light, dark: theme.tokens.background.dark)
            elevatedSurface = AppColors.dynamic(light: theme.tokens.elevatedSurface.light, dark: theme.tokens.elevatedSurface.dark)
            border = AppColors.dynamic(light: theme.tokens.border.light, dark: theme.tokens.border.dark)
            textPrimary = AppColors.dynamic(light: theme.tokens.textPrimary.light, dark: theme.tokens.textPrimary.dark)
            textSecondary = AppColors.dynamic(light: theme.tokens.textSecondary.light, dark: theme.tokens.textSecondary.dark)
            success = AppColors.dynamic(light: theme.tokens.success.light, dark: theme.tokens.success.dark)
            warning = AppColors.dynamic(light: theme.tokens.warning.light, dark: theme.tokens.warning.dark)
            error = AppColors.dynamic(light: theme.tokens.error.light, dark: theme.tokens.error.dark)
            let h = theme.highlightLight
            let stops = [
                Color(nsColor: h.appThemeLightened(by: 0.07)),
                Color(nsColor: h.appThemeAdjustingBrightness(by: 0.96)),
                Color(nsColor: h.appThemeHueRotated(by: -0.035).appThemeAdjustingBrightness(by: 0.90))
            ]
            accentGradient = LinearGradient(colors: stops, startPoint: .topLeading, endPoint: .bottomTrailing)
            iconColors = stops
            // 强调按钮：上端接近系统强调色，下端压暗保证白字对比，避免粉/橙/石墨预设显得发灰或发飘。
            accentButtonColors = [
                Color(nsColor: h.appThemeSaturated(by: 1.02).appThemeAdjustingBrightness(by: 0.98)),
                Color(nsColor: h.appThemeSaturated(by: 1.03).appThemeAdjustingBrightness(by: 0.86)),
                Color(nsColor: h.appThemeSaturated(by: 1.04).appThemeAdjustingBrightness(by: 0.72))
            ]
        }
    }

    /// 主题图标渐变色（缓存读取），供图标跟随配色方案。
    static var themedIconColors: [Color] { resolved.iconColors }
    /// 强调按钮主题填充色（缓存读取）。
    static var accentButtonColors: [Color] { resolved.accentButtonColors }

    // 屏幕外左上角斜射的一道光：左上受光面带暖白/微金色折射，右下只保留暗边。
    // 用于所有液态玻璃卡片/按钮的描边，模拟物理光照染色。
    static func edgeLightStroke(_ colorScheme: ColorScheme, depth: Double = 1, intensity: Double = 1) -> LinearGradient {
        let k = depth * intensity
        let warmWhite = Color(red: 1.0, green: 0.99, blue: 0.95)
        let champagne = Color(red: 1.0, green: 0.90, blue: 0.70)
        return LinearGradient(
            colors: [
                warmWhite.opacity((colorScheme == .dark ? 0.66 : 0.95) * k),
                champagne.opacity((colorScheme == .dark ? 0.22 : 0.34) * k),
                warmWhite.opacity((colorScheme == .dark ? 0.12 : 0.24) * k),
                Color.black.opacity((colorScheme == .dark ? 0.10 : 0.040) * k)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    /// 生成随系统外观（浅/深）自动切换的动态 NSColor。
    /// 线程安全说明：provider 闭包只读取已在调用处（主线程 body 求值时）解析好的 `light`/`dark` 形参，
    /// 不读取 `activeTheme` 静态量，因此即使 AppKit 在后台线程解析颜色也不会与主线程的换色写入竞争。
    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        }
    }
}

enum AppMotion {
    // 弹簧曲线由系统按当前显示器刷新率插值，避免线性匀速感；hover 也保持短弹簧而不是 ease-out。
    // #3 “Q 弹”：通用过渡弹簧统一下调阻尼（更明显的回弹/微过冲）并略放长 response，让切换/出现/
    // 悬停带一点弹性而不是生硬的 ease-out。音乐/歌词弹簧（musicPlayer/lyric/lyricFlow/lyricScroll）
    // 已单独精调过、降阻尼会过冲，保持不动。
    static let hover = Animation.spring(response: 0.22, dampingFraction: 0.80, blendDuration: 0.02)
    static let listHover = Animation.spring(response: 0.20, dampingFraction: 0.81, blendDuration: 0.01)
    static let immediate = Animation.spring(response: 0.26, dampingFraction: 0.86)
    static let fast = Animation.spring(response: 0.30, dampingFraction: 0.79)
    static let standard = Animation.spring(response: 0.40, dampingFraction: 0.80)
    static let page = Animation.spring(response: 0.50, dampingFraction: 0.82)
    static let panel = Animation.spring(response: 0.48, dampingFraction: 0.80, blendDuration: 0.06)
    static let notice = Animation.spring(response: 0.42, dampingFraction: 0.78, blendDuration: 0.04)
    static let sidebar = Animation.spring(response: 0.46, dampingFraction: 0.82)
    static let sidebarSelection = Animation.easeOut(duration: 0.001)
    // #4 音乐展开/收起是重点：把弹簧调得更紧凑（response 0.56→0.46），缩短重合成阶段的时长，
    // 在不改变“弹性展开”观感的前提下，让动画期间需要绘制的总帧数更少、掉帧更不明显。
    static let musicPlayer = Animation.spring(response: 0.40, dampingFraction: 0.90, blendDuration: 0.0)
    static let lyric = Animation.spring(response: 0.74, dampingFraction: 0.91, blendDuration: 0.14)
    // 歌词行级透明度/模糊切换：高阻尼（0.94）接近临界，无明显过冲；response 缩短使切换更利落，
    // 配合 lyricScroll 的长缓动平移，整体呈现平移渐变感而非”抛掷”感。
    static let lyricFlow = Animation.spring(response: 0.50, dampingFraction: 0.94, blendDuration: 0.04)
    // 歌词整列滚动：不用弹簧，改为 Apple Music 式的长缓动平移，避免自动居中时出现“抛过去”的力感。
    static let lyricScroll = Animation.timingCurve(0.20, 0.0, 0.0, 1.0, duration: 0.68)

    static var pageInsertion: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.995, anchor: .top))
    }

    static var floatingBar: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    static var musicPlayerExpansion: AnyTransition {
        // 顶部白条根因之一：插入时用 opacity 渐入，半透明的那几帧会露出底下的 AppKit 标题栏（白条）。
        // 改为插入瞬间出现（identity）——不透明专辑底色第一帧就盖住整窗含标题栏区域，层次变化交给内部入场动画；
        // 收起仍用 opacity 渐出，避免突兀。
        .asymmetric(
            insertion: .identity,
            removal: .opacity
        )
    }
}

struct LiquidPointerContext {
    let globalLocation: CGPoint
    let radius: CGFloat
    let tint: Color
    let intensity: Double
}

private struct LiquidPointerContextKey: EnvironmentKey {
    static let defaultValue: LiquidPointerContext? = nil
}

private struct SuppressPointerHoverDuringScrollKey: EnvironmentKey {
    static let defaultValue = false
}

private struct MainLayoutTransitionActiveKey: EnvironmentKey {
    static let defaultValue = false
}

enum GlassSurfaceRenderMode {
    case material
    case efficient
    /// 仅供明确不需要系统材质的极小重复控件使用。
    case flat
}

/// 重复卡片继续使用系统感的静态玻璃，保留完整阴影、高光和深浅色响应；
/// 少量主表面使用实时系统材质，避免在密集网格中为每格创建模糊采样层。
enum GlassSurfaceRole {
    case rich
    case repeated
    case repeatedHover
    case buttonNoMaterial

    var renderMode: GlassSurfaceRenderMode {
        switch self {
        case .rich:
            return .material
        case .repeated, .repeatedHover, .buttonNoMaterial:
            return .flat
        }
    }
}

enum PointerHoverThrottle {
    static let minInterval: TimeInterval = 1.0 / 60.0
    static let minDistance: CGFloat = 2.0

    static func shouldUpdate(
        from previousLocation: CGPoint?,
        previousUpdate: Date,
        to nextLocation: CGPoint,
        now: Date = Date(),
        minInterval: TimeInterval = Self.minInterval,
        minDistance: CGFloat = Self.minDistance
    ) -> Bool {
        guard let previousLocation else { return true }
        let dx = nextLocation.x - previousLocation.x
        let dy = nextLocation.y - previousLocation.y
        if dx * dx + dy * dy >= minDistance * minDistance {
            return true
        }
        return now.timeIntervalSince(previousUpdate) >= minInterval
    }
}

extension EnvironmentValues {
    var liquidPointerContext: LiquidPointerContext? {
        get { self[LiquidPointerContextKey.self] }
        set { self[LiquidPointerContextKey.self] = newValue }
    }

    var suppressPointerHoverDuringScroll: Bool {
        get { self[SuppressPointerHoverDuringScrollKey.self] }
        set { self[SuppressPointerHoverDuringScrollKey.self] = newValue }
    }

    var mainLayoutTransitionActive: Bool {
        get { self[MainLayoutTransitionActiveKey.self] }
        set { self[MainLayoutTransitionActiveKey.self] = newValue }
    }
}

struct SurfaceBackground: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    var selected = false
    var cornerRadius: CGFloat = 12
    var thickness: Double = AppGlassMetrics.Thickness.surface

    @State private var pointerLocation: CGPoint?
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast
    @State private var globalFrame: CGRect = .zero

    private var pointerContext: LiquidPointerContext? {
        guard let pointerLocation,
              globalFrame.width > 0,
              globalFrame.height > 0 else { return nil }
        let depth = min(max(thickness, 0.7), 2.1)
        let globalLocation = CGPoint(
            x: globalFrame.minX + pointerLocation.x,
            y: globalFrame.minY + pointerLocation.y
        )
        let radius = min(max(max(globalFrame.width, globalFrame.height) * 0.28, 86), 176)
        return LiquidPointerContext(
            globalLocation: globalLocation,
            radius: radius,
            tint: AppColors.pointerLightTint,
            intensity: 1.08 * depth * glassPerformanceMode.pointerIntensityScale
        )
    }

    func body(content: Content) -> some View {
        let samplesPointer = !reduceMotion &&
            !suppressHoverDuringScroll &&
            !preferStaticGlassSurfaces &&
            glassPerformanceMode.allowsPointerSampling
        let efficientSurface = preferStaticGlassSurfaces || glassPerformanceMode.usesEfficientSurfaces

        content
            .environment(\.liquidPointerContext, samplesPointer ? pointerContext : nil)
            .background {
                LiquidGlassSurfaceLayer(
                    selected: selected,
                    cornerRadius: cornerRadius,
                    thickness: thickness,
                    respondsToPointer: samplesPointer,
                    renderMode: efficientSurface ? .efficient : .material
                )
            }
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .onAppear {
                            globalFrame = proxy.frame(in: .global)
                        }
                        .onChange(of: proxy.size) { _ in
                            globalFrame = proxy.frame(in: .global)
                        }
                }
                .allowsHitTesting(false)
            }
            .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .onContinuousHover { phase in
                guard samplesPointer else {
                    pointerLocation = nil
                    lastPointerLocation = nil
                    return
                }
                switch phase {
                case .active(let point):
                    let now = Date()
                    guard PointerHoverThrottle.shouldUpdate(
                        from: lastPointerLocation,
                        previousUpdate: lastPointerUpdate,
                        to: point,
                        now: now,
                        minInterval: glassPerformanceMode.pointerUpdateInterval,
                        minDistance: glassPerformanceMode.pointerMinDistance
                    ) else { return }
                    pointerLocation = point
                    lastPointerLocation = point
                    lastPointerUpdate = now
                case .ended:
                    withAnimation(reduceMotion ? nil : AppMotion.fast) {
                        pointerLocation = nil
                        lastPointerLocation = nil
                    }
                }
            }
    }
}

struct LiquidGlassSurfaceLayer: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var selected = false
    var cornerRadius: CGFloat = 12
    var thickness: Double = AppGlassMetrics.Thickness.surface
    var respondsToPointer = true
    var renderMode: GlassSurfaceRenderMode = .material

    var body: some View {
        if renderMode == .flat {
            flatSurface
        } else {
            richSurface
        }
    }

    /// 列表、网格和设置分组专用的低成本表面。
    /// 视觉保留白玻璃底色、左上柔光渐变和冷灰渐变描边，但不产生离屏渲染通道。
    private var flatSurface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.7), 2.1)
        return shape
            .fill(reduceTransparency ? AppColors.elevatedSurface : AppColors.cleanPanelFill)
            .overlay {
                if selected {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                AppColors.selectedGlassTint.opacity((colorScheme == .dark ? 0.16 : 0.12) * depth),
                                AppColors.pointerLightTint.opacity((colorScheme == .dark ? 0.06 : 0.08) * depth),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                // 浅色模式下 cleanPanelFill 已近纯白，用较低 opacity 以防太白失去层次感
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.14 : 0.16) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.045 : 0.070) * depth),
                            .clear
                        ],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.72, y: 0.7)
                    )
                )
                .allowsHitTesting(false)
            }
            .overlay(alignment: .topLeading) {
                // 玻璃描边：左上明亮高光，向右下快速淡出为透明，模拟光源折射质感。
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.60 : 0.90) * depth),
                            .white.opacity((colorScheme == .dark ? 0.24 : 0.50) * depth),
                            .white.opacity((colorScheme == .dark ? 0.08 : 0.18) * depth),
                            Color.clear
                        ],
                        startPoint: .topLeading,
                        endPoint: UnitPoint(x: 0.72, y: 0.80)
                    ),
                    lineWidth: selected ? AppGlassMetrics.Stroke.selected : 0.85
                )
                .allowsHitTesting(false)
            }
            .overlay {
                // 方向性玻璃染色描边：受光面在左上，右下只留暗边。
                shape.strokeBorder(
                    AppColors.edgeLightStroke(colorScheme, depth: depth, intensity: 0.92),
                    lineWidth: AppGlassMetrics.Stroke.surface
                )
            }
            .clipShape(shape)
            // 左上冷光投影：保留方向性，强度略提，让卡片像被屏外左上光源轻轻托起。
            .shadow(
                color: AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.030 : 0.045) * depth),
                radius: 8 * depth,
                x: -2,
                y: -1
            )
            // 主环境投影：在“有厚度”和“不发黑”之间取平衡——较前一版降一档不透明度、
            // 加大模糊半径让投影更柔和扩散（柔光而非硬黑边），仍保留卡片从底色浮起的层次。
            .shadow(
                color: .black.opacity((colorScheme == .dark ? 0.13 : 0.050) * depth),
                radius: 14 * depth,
                y: 5
            )
            // 紧贴卡片下沿的接触投影：降不透明度并略放大半径，使下沿暗边更柔、不再像硬黑线，
            // 仍提供必要的“落地”厚度感（去掉则卡片会像贴纸一样平铺在背景上）。
            .shadow(
                color: .black.opacity((colorScheme == .dark ? 0.10 : 0.038) * depth),
                radius: 3.5,
                y: 1.5
            )
    }

    @ViewBuilder
    private var richSurface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.7), 2.1)
        let isEfficient = renderMode == .efficient
        let usesDirectCompositing = isEfficient || reduceTransparency

        // efficient 模式：去掉所有 blendMode(.screen) overlay，用等效直接 opacity 替代。
        // 对于浅色玻璃底色，screen blend 与直接 opacity 视觉效果几乎相同（两者都趋近于1），
        // 但消除 blendMode 可以省去每张卡片 3 个独立的 WindowServer compositing group，
        // 大幅降低海报网格滚动时的 GPU 合成压力。
        let surface = ZStack {
                if usesDirectCompositing {
                    shape.fill(reduceTransparency ? AppColors.elevatedSurface : AppColors.cleanPanelFill)
                } else {
                    shape.fill(.regularMaterial)
                    shape.fill(AppColors.cleanPanelFill)
                }

                if selected {
                    shape.fill(
                        LinearGradient(
                            colors: [
                                AppColors.selectedGlassTint.opacity((colorScheme == .dark ? 0.16 : 0.12) * depth),
                                AppColors.pointerLightTint.opacity((colorScheme == .dark ? 0.06 : 0.08) * depth),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }

                // 浅色：cleanPanelFill 已近纯白，对角渐变减少白色 stops 以避免过曝；
                // 深色：卡片本身色调更深，渐变强度维持原值保持光泽感。
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.14 : 0.28) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.060 : 0.085) * depth),
                            AppColors.cardAquaWash.opacity((colorScheme == .dark ? 0.28 : 0.30) * depth),
                            .white.opacity((colorScheme == .dark ? 0.04 : 0.12) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .clipShape(shape)
            .overlay(alignment: .topLeading) {
                if usesDirectCompositing {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity((colorScheme == .dark ? 0.15 : 0.20) * depth),
                                    AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.045 : 0.072) * depth),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: UnitPoint(x: 0.72, y: 0.68)
                            )
                        )
                        .allowsHitTesting(false)
                } else {
                    shape
                        .fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity((colorScheme == .dark ? 0.12 : 0.16) * depth),
                                    AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.040 : 0.068) * depth),
                                    .clear
                                ],
                                startPoint: .topLeading,
                                endPoint: UnitPoint(x: 0.72, y: 0.68)
                            )
                        )
                        .blendMode(.screen)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .topLeading) {
                if !usesDirectCompositing {
                    shape
                        .strokeBorder(.white.opacity((colorScheme == .dark ? 0.20 : 0.58) * depth), lineWidth: 0.85)
                        .blendMode(.screen)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                shape
                    .strokeBorder(Color.black.opacity((colorScheme == .dark ? 0.19 : 0.044) * depth), lineWidth: 0.75)
            }
            .overlay {
                // 方向性玻璃染色描边：左上暖白强高光 → 右下冷蓝折射，模拟屏外左上角斜射的光。
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? 0.46 : 0.92) * depth),
                            .white.opacity((colorScheme == .dark ? 0.18 : 0.42) * depth),
                            AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.14 : 0.18) * depth),
                            selected ? AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.34 : 0.30) : Color.black.opacity((colorScheme == .dark ? 0.12 : 0.045) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: AppGlassMetrics.Stroke.surface
                )
            }
            .overlay(alignment: .topLeading) {
                if usesDirectCompositing {
                    shape
                        .stroke(.white.opacity((colorScheme == .dark ? 0.13 : 0.46) * depth), lineWidth: 0.55)
                } else {
                    shape
                        .stroke(.white.opacity((colorScheme == .dark ? 0.11 : 0.38) * depth), lineWidth: 0.55)
                        .blendMode(.screen)
                }
            }
            .shadow(color: AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.030 : 0.044) * depth), radius: (usesDirectCompositing ? 7 : 11) * depth, x: -2, y: -1)
            // 主表面环境投影：与 flatSurface 同步降档 + 加大模糊，更柔和扩散、不发黑，仍保层次。
            .shadow(
                color: .black.opacity((colorScheme == .dark ? 0.12 : 0.046) * depth),
                radius: (usesDirectCompositing ? 10 : AppGlassMetrics.Shadow.surfaceRadius + 4) * depth,
                y: usesDirectCompositing ? 4 : AppGlassMetrics.Shadow.surfaceY
            )
            // 接触投影：贴近下沿的暗边，降不透明度并略放大半径使其更柔，保留主表面卡片的落地厚度感。
            .shadow(
                color: .black.opacity((colorScheme == .dark ? 0.095 : 0.034) * depth),
                radius: 3.5,
                y: 1.5
            )

        if respondsToPointer {
            surface.pointerLiquidLight(cornerRadius: cornerRadius, intensity: 1.30 * depth)
        } else {
            surface
        }
    }
}

private struct PointerLiquidLightModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    let cornerRadius: CGFloat
    let tint: Color
    let intensity: Double
    @State private var pointerLocation: CGPoint?
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let clampedIntensity = min(max(intensity * glassPerformanceMode.pointerIntensityScale, 0), 2.2)

        if reduceMotion || suppressHoverDuringScroll || preferStaticGlassSurfaces || !glassPerformanceMode.allowsPointerSampling || clampedIntensity <= 0.001 {
            content
        } else {

        content
            .background {
                GeometryReader { proxy in
                    if let pointerLocation, proxy.size.width > 0, proxy.size.height > 0 {
                        let x = min(max(pointerLocation.x / proxy.size.width, 0), 1)
                        let y = min(max(pointerLocation.y / proxy.size.height, 0), 1)
                        let lightPoint = UnitPoint(x: x, y: y)

                        shape
                            .fill(
                                RadialGradient(
                                    colors: [
                                        .white.opacity((colorScheme == .dark ? 0.30 : 0.66) * clampedIntensity),
                                        tint.opacity((colorScheme == .dark ? 0.135 : 0.235) * clampedIntensity),
                                        .clear
                                    ],
                                    center: lightPoint,
                                    startRadius: 0,
                                    endRadius: max(proxy.size.width, proxy.size.height) * 0.56
                                )
                            )
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                    }
                }
            }
            .overlay {
                GeometryReader { proxy in
                    if let pointerLocation, proxy.size.width > 0, proxy.size.height > 0 {
                        let x = min(max(pointerLocation.x / proxy.size.width, 0), 1)
                        let y = min(max(pointerLocation.y / proxy.size.height, 0), 1)
                        let lightPoint = UnitPoint(x: x, y: y)
                        let oppositePoint = UnitPoint(x: 1 - x, y: 1 - y)
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                            .white.opacity((colorScheme == .dark ? 0.54 : 1.0) * clampedIntensity),
                                            tint.opacity((colorScheme == .dark ? 0.18 : 0.30) * clampedIntensity),
                                            .black.opacity((colorScheme == .dark ? 0.16 : 0.045) * clampedIntensity)
                                    ],
                                    startPoint: lightPoint,
                                    endPoint: oppositePoint
                                ),
                                lineWidth: 1.22
                            )
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                    }
                }
            }
            .shadow(
                color: tint.opacity(pointerLocation == nil ? 0 : (colorScheme == .dark ? 0.095 : 0.088) * clampedIntensity),
                radius: pointerLocation == nil ? 0 : 13,
                x: 0,
                y: 4
            )
            .onContinuousHover { phase in
                guard !reduceMotion else {
                    pointerLocation = nil
                    lastPointerLocation = nil
                    return
                }
                switch phase {
                case .active(let point):
                    let now = Date()
                    guard PointerHoverThrottle.shouldUpdate(
                        from: lastPointerLocation,
                        previousUpdate: lastPointerUpdate,
                        to: point,
                        now: now,
                        minInterval: glassPerformanceMode.pointerUpdateInterval,
                        minDistance: glassPerformanceMode.pointerMinDistance
                    ) else { return }
                    pointerLocation = point
                    lastPointerLocation = point
                    lastPointerUpdate = now
                case .ended:
                    withAnimation(reduceMotion ? nil : AppMotion.fast) {
                        pointerLocation = nil
                        lastPointerLocation = nil
                    }
                }
            }
    }
}

}

private struct RepeatedSurfaceHoverModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let active: Bool
    let cornerRadius: CGFloat
    let tint: Color
    let intensity: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let strength = active ? min(max(intensity, 0), 1.6) : 0

        content
            .overlay(alignment: .topLeading) {
                shape
                    .fill(
                        LinearGradient(
                            colors: [
                                .white.opacity((colorScheme == .dark ? 0.13 : 0.38) * strength),
                                tint.opacity((colorScheme == .dark ? 0.040 : 0.070) * strength),
                                .clear
                            ],
                            startPoint: .topLeading,
                            endPoint: UnitPoint(x: 0.78, y: 0.74)
                        )
                    )
                    .allowsHitTesting(false)
            }
            .overlay(alignment: .leading) {
                Capsule()
                    .fill(tint.opacity((colorScheme == .dark ? 0.24 : 0.34) * strength))
                    .frame(width: 3, height: 38)
                    .padding(.leading, 3)
                    .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.18 : 0.46) * strength),
                            tint.opacity((colorScheme == .dark ? 0.13 : 0.18) * strength),
                            .white.opacity((colorScheme == .dark ? 0.06 : 0.18) * strength)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
                .allowsHitTesting(false)
            }
            .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
    }
}

private struct RepeatedCardChromeModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let active: Bool
    let cornerRadius: CGFloat
    let tint: Color

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        content
            .overlay(alignment: .top) {
                LinearGradient(
                    colors: [
                        .clear,
                        .white.opacity(colorScheme == .dark ? 0.16 : 0.48),
                        tint.opacity(colorScheme == .dark ? 0.055 : 0.09),
                        .clear
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(height: active ? 1.15 : 0.8)
                .padding(.horizontal, cornerRadius * 0.72)
                .allowsHitTesting(false)
            }
            .overlay {
                shape
                    .inset(by: 1.2)
                    .strokeBorder(
                        LinearGradient(
                            colors: [
                                .white.opacity(colorScheme == .dark ? (active ? 0.12 : 0.07) : (active ? 0.26 : 0.16)),
                                .clear,
                                tint.opacity(colorScheme == .dark ? 0.035 : 0.055)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.65
                    )
                    .allowsHitTesting(false)
            }
    }
}

private struct PointerEdgeLightModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.liquidPointerContext) private var inheritedPointerContext
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    let cornerRadius: CGFloat
    let tint: Color
    let intensity: Double
    @State private var pointerLocation: CGPoint?
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let clampedIntensity = min(max(intensity * glassPerformanceMode.pointerIntensityScale, 0), 2.0)

        if reduceMotion || suppressHoverDuringScroll || preferStaticGlassSurfaces || !glassPerformanceMode.allowsPointerSampling || clampedIntensity <= 0.001 {
            content
        } else {
            let surface = content
                .overlay {
                    GeometryReader { proxy in
                        if let edgeLight = edgeLight(in: proxy, baseIntensity: clampedIntensity),
                           proxy.size.width > 0,
                           proxy.size.height > 0 {
                            shape
                                .strokeBorder(
                                    LinearGradient(
                                        colors: [
                                            .white.opacity((colorScheme == .dark ? 0.56 : 0.98) * edgeLight.strength),
                                            edgeLight.tint.opacity((colorScheme == .dark ? 0.22 : 0.32) * edgeLight.strength),
                                            .white.opacity((colorScheme == .dark ? 0.18 : 0.48) * edgeLight.strength)
                                        ],
                                        startPoint: UnitPoint(x: edgeLight.x, y: edgeLight.y),
                                        endPoint: UnitPoint(x: 1 - edgeLight.x, y: 1 - edgeLight.y)
                                    ),
                                    lineWidth: 1.1 + CGFloat(edgeLight.strength) * 0.45
                                )
                                .blendMode(.screen)
                                .shadow(color: edgeLight.tint.opacity((colorScheme == .dark ? 0.14 : 0.11) * edgeLight.strength), radius: 7 + 7 * edgeLight.strength, x: 0, y: 2)
                                .allowsHitTesting(false)
                        }
                    }
                }

            if inheritedPointerContext != nil {
                surface
            } else {
                surface
                    .onContinuousHover { phase in
                        switch phase {
                        case .active(let point):
                            let now = Date()
                            guard PointerHoverThrottle.shouldUpdate(
                                from: lastPointerLocation,
                                previousUpdate: lastPointerUpdate,
                                to: point,
                                now: now,
                                minInterval: glassPerformanceMode.pointerUpdateInterval,
                                minDistance: glassPerformanceMode.pointerMinDistance
                            ) else { return }
                            pointerLocation = point
                            lastPointerLocation = point
                            lastPointerUpdate = now
                        case .ended:
                            withAnimation(AppMotion.fast) {
                                pointerLocation = nil
                                lastPointerLocation = nil
                            }
                        }
                    }
            }
        }
    }

    private func edgeLight(in proxy: GeometryProxy, baseIntensity: Double) -> (x: CGFloat, y: CGFloat, strength: Double, tint: Color)? {
        if let pointerLocation,
           proxy.size.width > 0,
           proxy.size.height > 0 {
            return (
                x: clamped(pointerLocation.x / proxy.size.width),
                y: clamped(pointerLocation.y / proxy.size.height),
                strength: baseIntensity,
                tint: tint
            )
        }

        guard let inheritedPointerContext,
              proxy.size.width > 0,
              proxy.size.height > 0 else { return nil }
        let frame = proxy.frame(in: .global)
        guard frame.width > 0, frame.height > 0 else { return nil }

        let pointer = inheritedPointerContext.globalLocation
        let dx = max(frame.minX - pointer.x, 0, pointer.x - frame.maxX)
        let dy = max(frame.minY - pointer.y, 0, pointer.y - frame.maxY)
        let distance = sqrt(dx * dx + dy * dy)
        let radius = max(inheritedPointerContext.radius, 1)
        guard distance < radius else { return nil }

        let falloff = pow(1 - Double(distance / radius), 1.45)
        let strength = min(baseIntensity * inheritedPointerContext.intensity * falloff * 0.92, 1.8)
        guard strength > 0.04 else { return nil }

        return (
            x: clamped((pointer.x - frame.minX) / frame.width),
            y: clamped((pointer.y - frame.minY) / frame.height),
            strength: strength,
            tint: inheritedPointerContext.tint
        )
    }

    private func clamped(_ value: CGFloat) -> CGFloat {
        min(max(value, 0), 1)
    }
}

private struct PointerInspectTiltModifier: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    let enabled: Bool
    let cornerRadius: CGFloat
    @State private var pointerLocation: CGPoint?
    @State private var lastPointerLocation: CGPoint?
    @State private var lastPointerUpdate = Date.distantPast
    @State private var containerSize: CGSize = .zero

    func body(content: Content) -> some View {
        if enabled && !reduceMotion && !suppressHoverDuringScroll && !preferStaticGlassSurfaces && glassPerformanceMode.allowsPointerSampling && glassPerformanceMode.tiltScale > 0 {
            let hasPointer = pointerLocation != nil && containerSize.width > 0 && containerSize.height > 0
            let normalizedX = hasPointer ? min(max((pointerLocation?.x ?? 0) / containerSize.width, 0), 1) - 0.5 : 0
            let normalizedY = hasPointer ? min(max((pointerLocation?.y ?? 0) / containerSize.height, 0), 1) - 0.5 : 0
            let tiltScale = CGFloat(glassPerformanceMode.tiltScale)
            let tiltDegrees = 5.2 * glassPerformanceMode.tiltScale
            let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

            content
                .overlay {
                    GeometryReader { proxy in
                        Color.clear
                            .onAppear {
                                containerSize = proxy.size
                            }
                            .onChange(of: proxy.size) { newSize in
                                containerSize = newSize
                            }
                    }
                    .allowsHitTesting(false)
                }
                .overlay {
                    if hasPointer {
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(0.30),
                                        .clear,
                                        .black.opacity(0.10)
                                    ],
                                    startPoint: UnitPoint(x: normalizedX + 0.5, y: normalizedY + 0.5),
                                    endPoint: UnitPoint(x: 0.5 - normalizedX, y: 0.5 - normalizedY)
                                )
                            )
                            .blendMode(.screen)
                            .allowsHitTesting(false)
                    }
                }
                .rotation3DEffect(
                    .degrees(Double(-normalizedY) * tiltDegrees),
                    axis: (x: 1, y: 0, z: 0),
                    anchor: .center,
                    perspective: 0.72
                )
                .rotation3DEffect(
                    .degrees(Double(normalizedX) * tiltDegrees),
                    axis: (x: 0, y: 1, z: 0),
                    anchor: .center,
                    perspective: 0.72
                )
                .shadow(
                    color: .black.opacity(hasPointer ? 0.10 * glassPerformanceMode.tiltScale : 0.0),
                    radius: hasPointer ? 12 * tiltScale : 0,
                    x: normalizedX * -4 * tiltScale,
                    y: hasPointer ? 6 * tiltScale : 0
                )
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let point):
                        let now = Date()
                        guard PointerHoverThrottle.shouldUpdate(
                            from: lastPointerLocation,
                            previousUpdate: lastPointerUpdate,
                            to: point,
                            now: now,
                            minInterval: glassPerformanceMode.pointerUpdateInterval,
                            minDistance: glassPerformanceMode.pointerMinDistance
                        ) else { return }
                        pointerLocation = point
                        lastPointerLocation = point
                        lastPointerUpdate = now
                    case .ended:
                        withAnimation(AppMotion.hover) {
                            pointerLocation = nil
                            lastPointerLocation = nil
                        }
                    }
                }
        } else {
            content
        }
    }
}

private struct PointerScrollActivityMonitor: NSViewRepresentable {
    let onScroll: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: (() -> Void)?
        private var scrollMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
        }

        private func startMonitoring() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window else {
                    return event
                }
                let point = convert(event.locationInWindow, from: nil)
                if bounds.contains(point) {
                    onScroll?()
                }
                return event
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

/// SwiftUI 的横向 ScrollView 会吞掉其范围内的纵向触控板滚动。
/// 该桥只把“纵向占优”的滚轮事件交给外层 List/ScrollView，横向滑动仍留给当前条带。
private struct NestedHorizontalVerticalScrollPassthrough: NSViewRepresentable {
    func makeNSView(context: Context) -> MonitorView {
        MonitorView(frame: .zero)
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {}

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        private var scrollMonitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            if let scrollMonitor {
                NSEvent.removeMonitor(scrollMonitor)
                self.scrollMonitor = nil
            }
        }

        private func startMonitoring() {
            guard scrollMonitor == nil else { return }
            scrollMonitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window,
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      event.scrollingDeltaY != 0 else {
                    return event
                }
                let point = convert(event.locationInWindow, from: nil)
                guard bounds.contains(point),
                      let outerScrollView = verticalAncestorScrollView(windowPoint: event.locationInWindow) else {
                    return event
                }
                outerScrollView.scrollWheel(with: event)
                return nil
            }
        }

        /// 找到应当接管纵向滚动的外层竖向 `NSScrollView`。
        /// 关键点：本视图是横向条带的 `.background`（allowsHitTesting=false），它**不一定**位于
        /// 横向 `NSScrollView` 内部——SwiftUI 常把背景层放在横向滚动视图的同级/外层。
        /// 因此不能像旧实现那样从 `enclosingScrollView` 的上一层开始找（那样起点已经是页面列表，
        /// 再往上根本找不到第二个竖向滚动视图，passthrough 整体失效）。
        /// 正确做法：从自身向上遍历祖先，跳过只能横向滚动的滚动视图，返回第一个可竖向滚动的滚动视图；
        /// 若祖先链上找不到（背景层被放在横向滚动视图之外），再回退到窗口树里按命中点几何查找。
        private func verticalAncestorScrollView(windowPoint: CGPoint) -> NSScrollView? {
            var view: NSView? = superview
            while let current = view {
                if let scrollView = current as? NSScrollView,
                   Self.canScrollVertically(scrollView) {
                    return scrollView
                }
                view = current.superview
            }
            return verticalScrollViewInWindow(containing: windowPoint)
        }

        /// 祖先链不可用时的兜底：在窗口内收集所有竖向 `NSScrollView`，取包含命中点且最贴合的一个。
        private func verticalScrollViewInWindow(containing windowPoint: CGPoint) -> NSScrollView? {
            guard let contentView = window?.contentView else { return nil }
            var scrollViews: [NSScrollView] = []
            Self.collectScrollViews(in: contentView, into: &scrollViews)
            return scrollViews
                .filter { Self.canScrollVertically($0) }
                .filter { $0.convert($0.bounds, to: nil).contains(windowPoint) }
                // 命中多层嵌套时取可视面积最小（最内层）的竖向滚动视图。
                .min { lhs, rhs in
                    let l = lhs.convert(lhs.bounds, to: nil)
                    let r = rhs.convert(rhs.bounds, to: nil)
                    return l.width * l.height < r.width * r.height
                }
        }

        private static func canScrollVertically(_ scrollView: NSScrollView) -> Bool {
            guard let documentView = scrollView.documentView else { return false }
            return documentView.bounds.height > scrollView.contentView.bounds.height + 1
        }

        private static func collectScrollViews(in view: NSView, into result: inout [NSScrollView]) {
            if let scrollView = view as? NSScrollView {
                result.append(scrollView)
            }
            for subview in view.subviews {
                collectScrollViews(in: subview, into: &result)
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private struct HorizontalMouseDragScrollMonitor: NSViewRepresentable {
    let onDraggingChanged: (Bool) -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onDraggingChanged = onDraggingChanged
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onDraggingChanged = onDraggingChanged
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onDraggingChanged: ((Bool) -> Void)?
        private var mouseDownMonitor: Any?
        private var mouseDraggedMonitor: Any?
        private var mouseUpMonitor: Any?
        private weak var activeScrollView: NSScrollView?
        private var dragStartLocation: CGPoint?
        private var dragStartOrigin: CGPoint = .zero
        private var didCrossDragThreshold = false

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil {
                stopMonitoring()
            } else {
                startMonitoring()
            }
        }

        func stopMonitoring() {
            for monitor in [mouseDownMonitor, mouseDraggedMonitor, mouseUpMonitor].compactMap({ $0 }) {
                NSEvent.removeMonitor(monitor)
            }
            mouseDownMonitor = nil
            mouseDraggedMonitor = nil
            mouseUpMonitor = nil
            finishDrag()
        }

        private func startMonitoring() {
            guard mouseDownMonitor == nil else { return }
            mouseDownMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
                self?.beginDragIfNeeded(with: event)
                return event
            }
            mouseDraggedMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDragged]) { [weak self] event in
                let consumed = self?.updateDrag(with: event) ?? false
                return consumed ? nil : event
            }
            mouseUpMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
                let consumed = self?.finishDrag() ?? false
                return consumed ? nil : event
            }
        }

        private func beginDragIfNeeded(with event: NSEvent) {
            guard let window,
                  event.window === window,
                  bounds.width > 1,
                  bounds.height > 1 else { return }
            let localPoint = convert(event.locationInWindow, from: nil)
            guard bounds.contains(localPoint),
                  let scrollView = horizontalScrollView(containingWindowPoint: event.locationInWindow),
                  scrollView.documentView != nil else { return }
            activeScrollView = scrollView
            dragStartLocation = event.locationInWindow
            dragStartOrigin = scrollView.contentView.bounds.origin
            didCrossDragThreshold = false
        }

        private func updateDrag(with event: NSEvent) -> Bool {
            guard let scrollView = activeScrollView,
                  let dragStartLocation else { return false }
            let deltaX = event.locationInWindow.x - dragStartLocation.x
            guard abs(deltaX) > 1 else { return false }
            if !didCrossDragThreshold, abs(deltaX) > 4 {
                didCrossDragThreshold = true
                onDraggingChanged?(true)
            }

            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            let visibleWidth = scrollView.contentView.bounds.width
            let maxX = max(documentWidth - visibleWidth, 0)
            let nextX = min(max(dragStartOrigin.x - deltaX, 0), maxX)
            guard nextX != scrollView.contentView.bounds.origin.x else { return didCrossDragThreshold }
            scrollView.contentView.scroll(to: CGPoint(x: nextX, y: scrollView.contentView.bounds.origin.y))
            scrollView.reflectScrolledClipView(scrollView.contentView)
            return didCrossDragThreshold
        }

        @discardableResult
        private func finishDrag() -> Bool {
            let consumed = didCrossDragThreshold
            if didCrossDragThreshold {
                onDraggingChanged?(false)
            }
            activeScrollView = nil
            dragStartLocation = nil
            didCrossDragThreshold = false
            return consumed
        }

        private func horizontalScrollView(containingWindowPoint point: CGPoint) -> NSScrollView? {
            if let direct = enclosingHorizontalScrollView() {
                return direct
            }
            guard let window,
                  let contentView = window.contentView else { return nil }

            let anchorFrame = convert(bounds, to: nil)
            var scrollViews: [NSScrollView] = []
            collectScrollViews(in: contentView, into: &scrollViews)

            return scrollViews
                .filter { scrollView in
                    guard canScrollHorizontally(scrollView) else { return false }
                    let frame = scrollView.convert(scrollView.bounds, to: nil)
                    return frame.contains(point) || frame.intersects(anchorFrame)
                }
                .max { lhs, rhs in
                    candidateScore(for: lhs, anchorFrame: anchorFrame) < candidateScore(for: rhs, anchorFrame: anchorFrame)
                }
        }

        private func enclosingHorizontalScrollView() -> NSScrollView? {
            var view: NSView? = self
            while let current = view {
                if let scrollView = current as? NSScrollView,
                   canScrollHorizontally(scrollView) {
                    return scrollView
                }
                view = current.superview
            }
            guard let scrollView = enclosingScrollView,
                  canScrollHorizontally(scrollView) else { return nil }
            return scrollView
        }

        private func canScrollHorizontally(_ scrollView: NSScrollView) -> Bool {
            let documentWidth = scrollView.documentView?.bounds.width ?? 0
            let visibleWidth = scrollView.contentView.bounds.width
            return scrollView.hasHorizontalScroller ||
                scrollView.horizontalScroller != nil ||
                documentWidth > visibleWidth + 1
        }

        private func candidateScore(for scrollView: NSScrollView, anchorFrame: CGRect) -> CGFloat {
            let frame = scrollView.convert(scrollView.bounds, to: nil)
            let overlap = frame.intersection(anchorFrame)
            let overlapArea = max(overlap.width, 0) * max(overlap.height, 0)
            let centerDistance = abs(frame.midX - anchorFrame.midX) + abs(frame.midY - anchorFrame.midY)
            let visibleArea = max(frame.width, 1) * max(frame.height, 1)
            return overlapArea / visibleArea - centerDistance / 10_000
        }

        private func collectScrollViews(in view: NSView, into result: inout [NSScrollView]) {
            if let scrollView = view as? NSScrollView {
                result.append(scrollView)
            }
            for subview in view.subviews {
                collectScrollViews(in: subview, into: &result)
            }
        }

        deinit {
            stopMonitoring()
        }
    }
}

private struct HorizontalMouseDragScrollModifier: ViewModifier {
    let enabled: Bool
    let onDraggingChanged: (Bool) -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if enabled {
            content.background {
                HorizontalMouseDragScrollMonitor(onDraggingChanged: onDraggingChanged)
                    .allowsHitTesting(false)
            }
        } else {
            content
        }
    }
}

private struct ListHighlightSuppressor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        // 表视图可能在 SwiftUI 布局之后才创建/重建，且属性会被重置；分多次延迟重试确保命中并保持。
        for delay in [0.0, 0.05, 0.20, 0.6] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak view] in
                guard let view else { return }
                Self.configure(from: view)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // 更新时只做一次轻量重应用（数据变化后 SwiftUI 可能重置表视图属性）。
        DispatchQueue.main.async { [weak nsView] in
            guard let nsView else { return }
            Self.configure(from: nsView)
        }
    }

    private static func configure(from anchor: NSView) {
        // 用"窗口坐标系下的帧包含关系"精确定位 suppressor 所附着的那个 List 的 NSScrollView：
        // 锚视图（`.background` 内容）填满本 List 的区域，其中心点必然落在本 List 的 scrollView 内，
        // 而不会落在侧栏列表里——因此既能可靠命中本列表，又不会误伤需要保留高亮的侧栏。
        guard let window = anchor.window, let contentView = window.contentView else { return }
        let anchorFrame = anchor.convert(anchor.bounds, to: nil)
        guard anchorFrame.width > 1, anchorFrame.height > 1 else { return }
        let center = CGPoint(x: anchorFrame.midX, y: anchorFrame.midY)

        var scrollViews: [NSScrollView] = []
        collectScrollViews(in: contentView, into: &scrollViews)
        guard !scrollViews.isEmpty else { return }

        // 只配置帧包含锚点中心的 scrollView（= 本列表/网格）。绝不回退到"全部"，否则会误关侧栏高亮。
        // 若几何尚未就绪导致暂时无命中，交由后续延迟重试处理。
        for scrollView in scrollViews where scrollView.convert(scrollView.bounds, to: nil).contains(center) {
            apply(to: scrollView)
        }
    }

    // 收集所有 NSScrollView（含 List 的表格滚动视图与普通 ScrollView），统一设为覆盖式滚动条；
    // selection 高亮只对表格视图关闭。
    private static func collectScrollViews(in view: NSView, into result: inout [NSScrollView]) {
        if let scrollView = view as? NSScrollView {
            result.append(scrollView)
        }
        for sub in view.subviews {
            collectScrollViews(in: sub, into: &result)
        }
    }

    private static func apply(to scrollView: NSScrollView) {
        if let tableView = scrollView.documentView as? NSTableView {
            // 去掉右键/选中时的蓝色高亮方框与焦点环，使右键能精确命中单个条目而不是整行。
            tableView.selectionHighlightStyle = .none
            tableView.focusRingType = .none
            tableView.allowsTypeSelect = false
        }
        scrollView.focusRingType = .none
        // 覆盖式滚动条：不占布局宽度，使海报网格左右边界都与上方卡片栏对齐、切换筛选时宽度恒定。
        scrollView.scrollerStyle = .overlay
        scrollView.autohidesScrollers = true
    }
}

private struct SuppressHoverDuringScrollModifier: ViewModifier {
    @State private var isScrolling = false
    @State private var resetTask: Task<Void, Never>?
    @State private var lastScrollEventAt = Date.distantPast

    func body(content: Content) -> some View {
        content
            .environment(\.suppressPointerHoverDuringScroll, isScrolling)
            .background {
                PointerScrollActivityMonitor {
                    markScrolling()
                }
                .allowsHitTesting(false)
            }
            .onDisappear {
                resetTask?.cancel()
                resetTask = nil
            }
    }

    private func markScrolling() {
        lastScrollEventAt = Date()
        if !isScrolling {
            isScrolling = true
        }
        guard resetTask == nil else { return }
        resetTask = Task { @MainActor in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(nanoseconds: 220_000_000)
                } catch {
                    return
                }
                if Date().timeIntervalSince(lastScrollEventAt) >= 0.20 {
                    isScrolling = false
                    resetTask = nil
                    return
                }
            }
        }
    }
}

struct SidebarGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        ZStack {
            if reduceTransparency {
                Rectangle()
                    .fill(AppColors.background)
            } else {
                Rectangle()
                    .fill(.ultraThinMaterial)
            }
            // 主蓝调渐变：与更深的页面底色协调，侧边栏呈蓝冰色
            LinearGradient(
                colors: [
                    AppColors.sidebarBlueWash.opacity(colorScheme == .dark ? 0.62 : 0.34),
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.10 : 0.16),
                    AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.055 : 0.090),
                    .white.opacity(colorScheme == .dark ? 0.020 : 0.16),
                    .white.opacity(colorScheme == .dark ? 0.014 : 0.22)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            // 左上角太阳光入射斜向渐变
            LinearGradient(
                colors: [
                    .white.opacity(colorScheme == .dark ? 0.08 : 0.28),
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.060 : 0.13),
                    AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.034 : 0.070),
                    .clear,
                    Color.black.opacity(colorScheme == .dark ? 0.020 : 0.012)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            Rectangle()
                .fill(.white.opacity(colorScheme == .dark ? 0.008 : 0.022))
        }
        .ignoresSafeArea()
    }
}

extension View {
    func surfaceBackground(
        selected: Bool = false,
        cornerRadius: CGFloat = AppRadius.control,
        thickness: Double = AppGlassMetrics.Thickness.surface
    ) -> some View {
        modifier(SurfaceBackground(selected: selected, cornerRadius: cornerRadius, thickness: thickness))
    }

    func staticSurfaceBackground(
        selected: Bool = false,
        cornerRadius: CGFloat = AppRadius.control,
        thickness: Double = AppGlassMetrics.Thickness.surface
    ) -> some View {
        background {
            LiquidGlassSurfaceLayer(selected: selected, cornerRadius: cornerRadius, thickness: thickness, respondsToPointer: false, renderMode: GlassSurfaceRole.repeated.renderMode)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func repeatedSurfaceHover(_ active: Bool, cornerRadius: CGFloat = 12, tint: Color = AppColors.pointerLightTint, intensity: Double = 1) -> some View {
        modifier(RepeatedSurfaceHoverModifier(active: active, cornerRadius: cornerRadius, tint: tint, intensity: intensity))
    }

    func repeatedCardChrome(_ active: Bool = false, cornerRadius: CGFloat = AppCardMetrics.repeatedCornerRadius, tint: Color = AppColors.pointerLightTint) -> some View {
        modifier(RepeatedCardChromeModifier(active: active, cornerRadius: cornerRadius, tint: tint))
    }

    func liquidGlass(
        cornerRadius: CGFloat = 14,
        selected: Bool = false,
        thickness: Double = AppGlassMetrics.Thickness.surface
    ) -> some View {
        modifier(SurfaceBackground(selected: selected, cornerRadius: cornerRadius, thickness: thickness))
    }

    func pointerLiquidLight(cornerRadius: CGFloat = 14, tint: Color = AppColors.pointerLightTint, intensity: Double = 1) -> some View {
        modifier(PointerLiquidLightModifier(cornerRadius: cornerRadius, tint: tint, intensity: intensity))
    }

    func pointerLiquidEdge(cornerRadius: CGFloat = 14, tint: Color = AppColors.pointerLightTint, intensity: Double = 1) -> some View {
        modifier(PointerEdgeLightModifier(cornerRadius: cornerRadius, tint: tint, intensity: intensity))
    }

    func pointerInspectTilt(enabled: Bool = true, cornerRadius: CGFloat = 10) -> some View {
        modifier(PointerInspectTiltModifier(enabled: enabled, cornerRadius: cornerRadius))
    }

    func pageContainer(horizontal: CGFloat = AppSpacing.pageHorizontal, vertical: CGFloat = AppSpacing.pageVertical) -> some View {
        self
            .padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    func pageTransition() -> some View {
        self.transition(AppMotion.pageInsertion)
    }

    func suppressHoverEffectsDuringScroll() -> some View {
        modifier(SuppressHoverDuringScrollModifier())
    }

    func verticalScrollPassthroughFromNestedHorizontal() -> some View {
        background {
            NestedHorizontalVerticalScrollPassthrough()
                .allowsHitTesting(false)
        }
    }

    func horizontalMouseDragScroll(
        enabled: Bool = true,
        onDraggingChanged: @escaping (Bool) -> Void = { _ in }
    ) -> some View {
        modifier(HorizontalMouseDragScrollModifier(enabled: enabled, onDraggingChanged: onDraggingChanged))
    }

    func suppressListHighlight() -> some View {
        background(ListHighlightSuppressor())
    }

    func appSheetChrome(
        width: CGFloat = AppSheetMetrics.standardWidth,
        minHeight: CGFloat? = nil,
        maxHeight: CGFloat? = nil
    ) -> some View {
        modifier(AppSheetChromeModifier(width: width, minHeight: minHeight, maxHeight: maxHeight))
    }
}

private struct GlassFocusRingModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let active: Bool
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        content
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(
                            AppColors.selectedGlassTint.opacity(
                                colorScheme == .dark
                                    ? AppGlassMetrics.Focus.innerOpacityDark
                                    : AppGlassMetrics.Focus.innerOpacityLight
                            ),
                            lineWidth: AppGlassMetrics.Stroke.focusInner
                        )
                        .allowsHitTesting(false)
                }
            }
            .overlay {
                if active {
                    RoundedRectangle(
                        cornerRadius: cornerRadius + AppGlassMetrics.Focus.outerPadding,
                        style: .continuous
                    )
                    .strokeBorder(
                        AppColors.pointerLightTint.opacity(
                            colorScheme == .dark
                                ? AppGlassMetrics.Focus.outerOpacityDark
                                : AppGlassMetrics.Focus.outerOpacityLight
                        ),
                        lineWidth: AppGlassMetrics.Stroke.focusOuter
                    )
                    .padding(-AppGlassMetrics.Focus.outerPadding)
                    .allowsHitTesting(false)
                }
            }
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = AppControlMetrics.defaultButtonHeight
    var prominent = false
    var thickness: Double = AppGlassMetrics.Thickness.control

    func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonStyleBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight,
            prominent: prominent,
            thickness: thickness
        )
    }
}

private struct LiquidGlassButtonStyleBody: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let minHeight: CGFloat
    let prominent: Bool
    let thickness: Double
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.75), 2.0)
        let pressed = configuration.isPressed
        let active = isEnabled && (isHovering || pressed || isFocused)

        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white.opacity(0.96) : Color.primary.opacity(active ? 0.88 : 0.78))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background {
                ZStack {
                    if prominent {
                        shape.fill(
                            LinearGradient(
                                colors: AppColors.accentButtonColors,
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    } else {
                        // 非强调按钮：暖白半透明底，避免按钮底部露出冷蓝直角色块。
                        shape.fill(
                            reduceTransparency
                                ? AppColors.elevatedSurface
                                : AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.40 : 0.66)
                        )
                    }
                    if !prominent {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                .white.opacity((colorScheme == .dark ? 0.22 : 0.46) * depth),
                                AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.070 : 0.105) * depth),
                                AppColors.cardAquaWash.opacity(colorScheme == .dark ? 0.12 : 0.14),
                                AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.46 : 0.56)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                    }
                    if pressed {
                        shape.fill(
                            prominent
                                ? Color.black.opacity(colorScheme == .dark ? 0.20 : 0.16)
                                : AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.18 : 0.12)
                        )
                    } else if isHovering, isEnabled {
                        shape.fill(
                            prominent
                                ? Color.white.opacity(colorScheme == .dark ? 0.090 : 0.12)
                                : AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.16 : 0.12)
                        )
                    }
                }
                .clipShape(shape)
            }
            .overlay(alignment: .topLeading) {
                if prominent {
                    EmptyView()
                } else {
                    shape
                        .strokeBorder(.white.opacity((colorScheme == .dark ? 0.25 : 0.50) * depth), lineWidth: 0.95)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if prominent {
                    EmptyView()
                } else {
                    shape
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.17 : 0.070), lineWidth: 0.75)
                }
            }
            .overlay {
                if prominent {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity(colorScheme == .dark ? (active ? 0.42 : 0.32) : (active ? 0.58 : 0.46)),
                                Color.white.opacity(colorScheme == .dark ? 0.14 : 0.22),
                                Color.black.opacity(colorScheme == .dark ? 0.18 : 0.13)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 0.9
                    )
                } else {
                    shape.strokeBorder(
                        LinearGradient(
                            colors: [
                                Color.white.opacity((colorScheme == .dark ? (active ? 0.48 : 0.36) : (active ? 0.62 : 0.50)) * depth),
                                AppColors.solarLightTint.opacity((colorScheme == .dark ? (active ? 0.18 : 0.12) : (active ? 0.30 : 0.22)) * depth),
                                AppColors.solarEdgeTint.opacity((colorScheme == .dark ? (active ? 0.20 : 0.12) : (active ? 0.28 : 0.18)) * depth),
                                Color.black.opacity((colorScheme == .dark ? (active ? 0.16 : 0.12) : (active ? 0.070 : 0.045)) * depth)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
                }
            }
            .clipShape(shape)
            .modifier(GlassFocusRingModifier(active: isEnabled && isFocused, cornerRadius: cornerRadius))
            // 按钮底部色块根因是外投影带 y 偏移：在暖白玻璃面上会被看成按钮下方的独立托盘。
            // 这里不再给普通/强调按钮画任何向下偏移的外影，层级改由内高光、描边和边缘光表达。
            .shadow(
                color: prominent
                    ? AppColors.selectedGlassTint.opacity(colorScheme == .dark ? (active ? 0.13 : 0.075) : (active ? 0.12 : 0.070))
                    : .clear,
                radius: prominent ? (active ? 5 : 3.5) : 0,
                y: 0.5
            )
            .shadow(
                color: prominent ? Color.black.opacity(colorScheme == .dark ? 0.22 : 0.075) : .clear,
                radius: prominent ? 1.4 : 0,
                y: prominent ? 0.5 : 0
            )
            .pointerLiquidEdge(
                cornerRadius: cornerRadius,
                tint: prominent ? AppColors.selectedGlassTint : AppColors.pointerLightTint,
                intensity: (prominent ? (active ? 0.24 : 0.14) : (active ? 1.06 : 0.72)) * depth
            )
            .opacity(isEnabled ? (pressed ? 0.86 : 1) : AppControlMetrics.disabledControlOpacity)
            .brightness(isHovering && isEnabled && !pressed ? (prominent ? 0.018 : 0.010) : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: pressed)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
    }
}

struct RepeatedGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = AppControlMetrics.defaultButtonHeight
    var thickness: Double = AppGlassMetrics.Thickness.repeated

    func makeBody(configuration: Configuration) -> some View {
        RepeatedGlassButtonStyleBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight,
            thickness: thickness
        )
    }
}

private struct RepeatedGlassButtonStyleBody: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let minHeight: CGFloat
    let thickness: Double
    @State private var isHovering = false

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.75), 1.6)
        let pressed = configuration.isPressed
        let active = isEnabled && (isHovering || pressed || isFocused)

        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(Color.primary.opacity(active ? 0.88 : 0.76))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background {
                ZStack {
                    if reduceTransparency {
                        shape.fill(AppColors.elevatedSurface)
                    }
                    shape.fill(
                        LinearGradient(
                            colors: [
                                .white.opacity((colorScheme == .dark ? (active ? 0.22 : 0.14) : (active ? 0.50 : 0.36)) * depth),
                                AppColors.solarLightTint.opacity((colorScheme == .dark ? (active ? 0.10 : 0.060) : (active ? 0.14 : 0.085)) * depth),
                                AppColors.cleanFieldFill.opacity(colorScheme == .dark ? (active ? 0.48 : 0.40) : (active ? 0.62 : 0.54))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? (active ? 0.34 : 0.24) : (active ? 0.72 : 0.56)) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? (active ? 0.16 : 0.10) : (active ? 0.27 : 0.20)) * depth),
                            AppColors.solarEdgeTint.opacity((colorScheme == .dark ? (active ? 0.22 : 0.14) : (active ? 0.28 : 0.18)) * depth),
                            Color.black.opacity((colorScheme == .dark ? (active ? 0.15 : 0.11) : (active ? 0.060 : 0.038)) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .clipShape(shape)
            .contentShape(shape)
            .modifier(GlassFocusRingModifier(active: isEnabled && isFocused, cornerRadius: cornerRadius))
            .overlay {
                if pressed {
                    shape
                        .fill(AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.18 : 0.12))
                        .allowsHitTesting(false)
                } else if isHovering, isEnabled {
                    shape
                        .fill(AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.12 : 0.08))
                        .allowsHitTesting(false)
                }
            }
            .pointerLiquidEdge(cornerRadius: cornerRadius, intensity: (active ? 1.08 : 0.82) * depth)
            .opacity(isEnabled ? (pressed ? 0.84 : 1) : AppControlMetrics.disabledControlOpacity)
            .brightness(isHovering && isEnabled && !pressed ? 0.010 : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: pressed)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
    }
}

struct SubtleIconButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var minSize: CGFloat = 22

    func makeBody(configuration: Configuration) -> some View {
        SubtleIconButtonStyleBody(
            configuration: configuration,
            minSize: minSize
        )
    }
}

private struct SubtleIconButtonStyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    let minSize: CGFloat
    @State private var isHovering = false

    var body: some View {
        let active = isEnabled && (isHovering || configuration.isPressed)
        configuration.label
            .frame(minWidth: minSize, minHeight: minSize)
            .contentShape(Rectangle())
            .modifier(GlassFocusRingModifier(active: isEnabled && isFocused, cornerRadius: min(7, minSize * 0.28)))
            .opacity(configuration.isPressed ? 0.72 : (isEnabled ? 1 : AppControlMetrics.disabledControlOpacity))
            .brightness(active ? (configuration.isPressed ? -0.018 : 0.018) : 0)
            .saturation(active ? 1.08 : 1.0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: configuration.isPressed)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
    }
}

private struct HeaderControlGlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let cornerRadius: CGFloat
    var highlighted = false
    var focused = false
    var accent: Color = AppColors.solarEdgeTint
    var enabled = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let enabledOpacity = enabled ? 1.0 : AppControlMetrics.disabledControlOpacity

        content
            .background {
                if reduceTransparency {
                    shape.fill(AppColors.elevatedSurface)
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .background {
                shape.fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.54 : 0.76))
            }
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.22 : 0.56),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.11 : 0.20),
                            AppColors.cardAquaWash.opacity(colorScheme == .dark ? 0.16 : 0.21),
                            Color.black.opacity(colorScheme == .dark ? 0.035 : 0.018)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.fill(
                    RadialGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.13 : (focused ? 0.34 : 0.26)),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.07 : (focused ? 0.16 : 0.11)),
                            .clear
                        ],
                        center: UnitPoint(x: -0.08, y: -0.14),
                        startRadius: 0,
                        endRadius: 260
                    )
                )
                .allowsHitTesting(false)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.42 : 0.88),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.18 : 0.34),
                            focused ? AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.36 : 0.34) : AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.20 : 0.30),
                            Color.black.opacity(colorScheme == .dark ? 0.12 : 0.055)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? 1.25 : 1.0
                )
            }
            .clipShape(shape)
            .modifier(GlassFocusRingModifier(active: focused && enabled, cornerRadius: cornerRadius))
            .shadow(color: .white.opacity(colorScheme == .dark ? 0.020 : 0.20), radius: 1, y: -0.5)
            .shadow(color: AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.052 : (focused ? 0.082 : 0.062)), radius: highlighted ? 5 : 7, y: 0)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.085 : 0.040), radius: 5, y: 1)
            .opacity(enabledOpacity * (highlighted ? 0.92 : 1))
            .contentShape(shape)
    }
}

struct HeaderActionGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 13
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = AppControlMetrics.headerButtonHeight

    func makeBody(configuration: Configuration) -> some View {
        HeaderActionGlassButtonStyleBody(
            configuration: configuration,
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight
        )
    }
}

private struct HeaderActionGlassButtonStyleBody: View {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.isFocused) private var isFocused
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let configuration: ButtonStyle.Configuration
    let cornerRadius: CGFloat
    let horizontalPadding: CGFloat
    let minHeight: CGFloat
    @State private var isHovering = false

    var body: some View {
        let pressed = configuration.isPressed
        let active = isEnabled && (isHovering || pressed || isFocused)

        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color.primary.opacity(isEnabled ? (active ? 0.90 : 0.74) : 0.42))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .modifier(HeaderControlGlassBackground(
                cornerRadius: cornerRadius,
                highlighted: active,
                focused: isFocused,
                accent: AppColors.solarEdgeTint,
                enabled: isEnabled
            ))
            .overlay {
                if active {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(AppColors.pointerLightTint.opacity(pressed ? 0.42 : 0.28), lineWidth: pressed ? 1.35 : 1.05)
                        .allowsHitTesting(false)
                }
            }
            .pointerLiquidEdge(cornerRadius: cornerRadius, intensity: active ? 1.46 : 1.18)
            .opacity(pressed ? 0.84 : 1)
            .brightness(isHovering && isEnabled && !pressed ? 0.012 : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: pressed)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
    }
}

struct GlassCapsuleControl<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.isEnabled) private var isEnabled
    var isSelected: Bool
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 12
    var font: Font = .caption.weight(.semibold)
    // 默认用主题高亮色而非系统 .accentColor：后者不随自定义配色变化，会让筛选胶囊高光一直是蓝色。
    var tint: Color = AppColors.selectedGlassTint
    /// 禁用后不挂 onContinuousHover，适用于大量并排出现的筛选胶囊，降低指针事件订阅数量。
    var enablePointerEdge: Bool = true
    @ViewBuilder var content: Content
    @State private var isHovering = false

    init(
        isSelected: Bool,
        height: CGFloat = 28,
        horizontalPadding: CGFloat = 12,
        font: Font = .caption.weight(.semibold),
        tint: Color = AppColors.selectedGlassTint,
        enablePointerEdge: Bool = true,
        @ViewBuilder content: () -> Content
    ) {
        self.isSelected = isSelected
        self.height = height
        self.horizontalPadding = horizontalPadding
        self.font = font
        self.tint = tint
        self.enablePointerEdge = enablePointerEdge
        self.content = content()
    }

    var body: some View {
        let active = isEnabled && (isSelected || isHovering)
        content
            .font(font)
            .lineLimit(1)
            .foregroundStyle(isSelected ? tint : Color.primary.opacity(isEnabled ? (isHovering ? 0.86 : 0.70) : 0.42))
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            // 在更深底色上，未选中胶囊白色填充稍加浓，视觉区分度提高。
            .background(
                Capsule()
                    .fill(
                        reduceTransparency
                            ? AppColors.elevatedSurface
                            : (isSelected
                                ? Color.white.opacity(colorScheme == .dark ? 0.30 : 0.76)
                                : Color.white.opacity(colorScheme == .dark ? (isHovering ? 0.24 : 0.17) : (isHovering ? 0.70 : 0.58)))
                    )
            )
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.99, blue: 0.95).opacity(colorScheme == .dark ? (active ? 0.42 : 0.32) : (active ? 0.96 : 0.82)),
                                AppColors.solarLightTint.opacity(colorScheme == .dark ? (active ? 0.18 : 0.12) : (active ? 0.32 : 0.24)),
                                isSelected ? tint.opacity(colorScheme == .dark ? 0.24 : 0.30) : AppColors.solarEdgeTint.opacity(colorScheme == .dark ? (isHovering ? 0.22 : 0.14) : (isHovering ? 0.30 : 0.18)),
                                Color.black.opacity(colorScheme == .dark ? (active ? 0.14 : 0.10) : (active ? 0.055 : 0.036))
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: tint.opacity(isSelected ? (colorScheme == .dark ? 0.08 : 0.06) : (isHovering ? (colorScheme == .dark ? 0.045 : 0.030) : 0)), radius: isHovering ? 9 : 8, y: 2)
            .modifier(CapsulePointerEdgeModifier(enabled: enablePointerEdge, cornerRadius: height / 2, tint: tint, isSelected: isSelected || isHovering))
            .brightness(isHovering && !isSelected && isEnabled ? 0.008 : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isSelected)
    }
}

private struct CapsulePointerEdgeModifier: ViewModifier {
    let enabled: Bool
    let cornerRadius: CGFloat
    let tint: Color
    let isSelected: Bool

    func body(content: Content) -> some View {
        if enabled {
            content.pointerLiquidEdge(cornerRadius: cornerRadius, tint: tint, intensity: isSelected ? 0.92 : 0.68)
        } else {
            content
        }
    }
}

struct AppPageBackground: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var includeDirectionalLight = true

    var body: some View {
        ZStack {
            // 开启“降低透明度”时用不透明窗口底色，避免桌面透出；否则用原半透明白玻璃底色。
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                AppColors.pageBackground
            }
            // 降低透明度模式下省去环境光与 screen 混合，只保留实色底，同时减少页面级合成组。
            if includeDirectionalLight && !reduceTransparency {
                // 太阳光从左上柔和射入：恢复方向性受光——把高光收得更靠近左上角并提一档强度，
                // 让“光源在左上”的方向感清晰可读，同时过渡范围仍足够柔和，不形成刺眼亮斑。
                RadialGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.11 : 0.24),
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.15 : 0.22),
                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.075 : 0.12),
                        .white.opacity(colorScheme == .dark ? 0.022 : 0.060),
                        .clear
                    ],
                    center: UnitPoint(x: -0.14, y: -0.20),
                    startRadius: 0,
                    endRadius: 1480
                )
                LinearGradient(
                    colors: [
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.095 : 0.140),
                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.055 : 0.085),
                        .white.opacity(colorScheme == .dark ? 0.018 : 0.050),
                        .clear,
                        .clear
                    ],
                    startPoint: UnitPoint(x: -0.06, y: -0.10),
                    endPoint: UnitPoint(x: 1.02, y: 0.78)
                )
                .blendMode(.screen)
                LinearGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.045 : 0.150),
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.060 : 0.100),
                        .clear
                    ],
                    startPoint: UnitPoint(x: 0.02, y: -0.12),
                    endPoint: UnitPoint(x: 0.82, y: 0.96)
                )
                .blendMode(.screen)
            }
            LinearGradient(
                colors: [
                    .white.opacity(colorScheme == .dark ? 0.035 : 0.15),
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.024 : 0.046),
                    Color.clear,
                    Color.black.opacity(colorScheme == .dark ? 0.018 : 0.012)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
        .ignoresSafeArea()
    }
}

private struct PageHeaderActionsWidthPreferenceKey: PreferenceKey {
    static var defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

struct PageHeader<Actions: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @State private var measuredActionsContentWidth: CGFloat = 0
    let title: String
    let subtitle: String?
    let systemImage: String?
    let hasActions: Bool
    @ViewBuilder var actions: Actions

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil,
        @ViewBuilder actions: () -> Actions
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hasActions = true
        self.actions = actions()
    }

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String? = nil
    ) where Actions == EmptyView {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.hasActions = false
        self.actions = EmptyView()
    }

    var body: some View {
        Group {
            if hasActions {
                compactLayout
            } else {
                titleCluster
                    .padding(.vertical, 2)
            }
        }
        .padding(.horizontal, AppSpacing.pageHeaderHorizontal)
        .padding(.vertical, AppSpacing.pageHeaderVertical)
        .overlay(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.22 : 0.30),
                    AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.11 : 0.16),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 168, height: 0.8)
            .offset(x: systemImage == nil ? 0 : 58, y: 1)
            .allowsHitTesting(false)
        }
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var titleCluster: some View {
        HStack(alignment: .center, spacing: AppSpacing.pageHeaderIconToText) {
            if let systemImage {
                PlayfulSymbolIcon(systemImage: systemImage, size: 42)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: AppDesignStandard.pageHeaderTitleSize, weight: .semibold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.86)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .lineSpacing(1)
                        .frame(maxWidth: AppDesignStandard.pageHeaderSubtitleMaxWidth, alignment: .leading)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsCluster: some View {
        ScrollViewReader { proxy in
            GeometryReader { viewport in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                        Spacer(minLength: 0)

                        HStack(spacing: AppSpacing.pageHeaderActionGap) {
                            actions
                        }
                        // 滚动定位锚点放成 trailing 叠层，不占布局空间——否则它与按钮之间的
                        // pageHeaderActionGap 会把最右按钮整体往左挤约 10pt，导致按钮右缘与下方卡片不齐。
                        .overlay(alignment: .trailing) {
                            Color.clear
                                .frame(width: 1, height: 1)
                                .id("page-header-actions-trailing-anchor")
                        }
                        .buttonStyle(HeaderActionGlassButtonStyle(
                            cornerRadius: 13,
                            horizontalPadding: 12,
                            minHeight: AppControlMetrics.headerButtonHeight
                        ))
                        .fixedSize(horizontal: true, vertical: false)
                        .background {
                            GeometryReader { contentProxy in
                                Color.clear.preference(
                                    key: PageHeaderActionsWidthPreferenceKey.self,
                                    value: contentProxy.size.width
                                )
                            }
                        }
                    }
                    .frame(
                        minWidth: max(
                            viewport.size.width - AppGlassMetrics.Focus.outerPadding * 2,
                            0
                        ),
                        alignment: .trailing
                    )
                    .padding(.horizontal, AppGlassMetrics.Focus.outerPadding)
                    .padding(.vertical, 3)
                }
                .verticalScrollPassthroughFromNestedHorizontal()
                .onAppear {
                    scrollActionsToTrailingEdge(proxy)
                }
                .onChange(of: viewport.size.width) { _ in
                    scrollActionsToTrailingEdge(proxy)
                }
            }
        }
        .onPreferenceChange(PageHeaderActionsWidthPreferenceKey.self) { width in
            guard width > 0, abs(measuredActionsContentWidth - width) > 0.5 else { return }
            measuredActionsContentWidth = width
        }
        .accessibilityElement(children: .contain)
    }

    private var compactLayout: some View {
        GeometryReader { proxy in
            let availableWidth = max(proxy.size.width, 1)
            let maximumActionsWidth = max(
                180,
                availableWidth - AppDesignStandard.pageHeaderMinimumTitleWidth - 20
            )
            let intrinsicActionsWidth = measuredActionsContentWidth > 0
                ? measuredActionsContentWidth + AppGlassMetrics.Focus.outerPadding * 2
                : AppDesignStandard.pageHeaderActionsIdealWidth
            let preferredActionsWidth = min(
                AppDesignStandard.pageHeaderActionsMaxWidth,
                max(180, intrinsicActionsWidth)
            )
            let actionsWidth = min(preferredActionsWidth, maximumActionsWidth)

            HStack(alignment: .bottom, spacing: 20) {
                titleCluster
                    .frame(
                        width: max(availableWidth - actionsWidth - 20, 1),
                        alignment: .leading
                    )

                actionsCluster
                    .frame(width: actionsWidth, alignment: .trailing)
                    .clipped()
            }
            .frame(width: availableWidth, height: 62, alignment: .bottomLeading)
        }
        .frame(height: 62)
    }

    private func scrollActionsToTrailingEdge(_ proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            proxy.scrollTo("page-header-actions-trailing-anchor", anchor: .trailing)
        }
    }
}

struct AppSheetHeader: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let subtitle: String?
    let systemImage: String
    var subtitleLineLimit = 2
    var truncationMode: Text.TruncationMode = .tail

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        subtitleLineLimit: Int = 2,
        truncationMode: Text.TruncationMode = .tail
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.subtitleLineLimit = subtitleLineLimit
        self.truncationMode = truncationMode
    }

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.48 : 0.76))
                    .overlay {
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        .white.opacity(colorScheme == .dark ? 0.24 : 0.74),
                                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.10 : 0.20),
                                        AppColors.cleanPanelBorder.opacity(0.48)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.9
                            )
                    }

                PlayfulSymbolIcon(systemImage: systemImage, size: AppSheetMetrics.headerIconSize)
            }
            .frame(width: AppSheetMetrics.headerIconContainerSize, height: AppSheetMetrics.headerIconContainerSize)
            .fixedSize()
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.title3.weight(.semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(subtitleLineLimit)
                        .truncationMode(truncationMode)
                        .fixedSize(horizontal: false, vertical: subtitleLineLimit > 1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 13)
        .overlay(alignment: .bottomLeading) {
            LinearGradient(
                colors: [
                    AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.30 : 0.44),
                    AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.12 : 0.20),
                    AppColors.cleanPanelBorder.opacity(0.34),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 210, height: 0.8)
            .padding(.leading, AppSheetMetrics.headerIconContainerSize + 12)
            .allowsHitTesting(false)
        }
    }
}

struct AppInfoNote: View {
    @Environment(\.colorScheme) private var colorScheme
    let text: String
    var systemImage: String?

    var body: some View {
        HStack(alignment: .center, spacing: 9) {
            if let systemImage {
                ZStack {
                    Circle()
                        .fill(AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.12 : 0.09))
                    Image(systemName: systemImage)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
                }
                .frame(width: 24, height: 24)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: AppRadius.informationNote, thickness: 0.86)
    }
}

struct AppSheetSection<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let title: String
    let systemImage: String
    var subtitle: String?
    @ViewBuilder var content: Content

    init(
        title: String,
        systemImage: String,
        subtitle: String? = nil,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.systemImage = systemImage
        self.subtitle = subtitle
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack(alignment: .center, spacing: 9) {
                PlayfulSymbolIcon(systemImage: systemImage, size: 24)
                    .fixedSize()
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                Spacer(minLength: 0)
            }

            content
        }
        .padding(AppSheetMetrics.sectionContentPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .staticSurfaceBackground(cornerRadius: AppSheetMetrics.sectionCornerRadius)
        .repeatedCardChrome(false, cornerRadius: AppSheetMetrics.sectionCornerRadius)
        .overlay(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.11 : 0.18),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: 96, height: 1)
            .padding(.leading, 16)
            .padding(.top, 1.5)
            .allowsHitTesting(false)
        }
    }
}

struct AppInlineNoticeLabel: View {
    let text: String
    let systemImage: String
    var font: Font = .caption
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: systemImage)
                .font(font.weight(.semibold))
                .foregroundStyle(AppColors.selectedGlassTint.opacity(0.88))
            Text(text)
                .font(font)
                .foregroundStyle(.secondary)
                .lineLimit(lineLimit)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

struct AppSectionHeading: View {
    let title: String
    let subtitle: String?
    let systemImage: String
    var badgeText: String?

    init(
        title: String,
        subtitle: String? = nil,
        systemImage: String,
        badgeText: String? = nil
    ) {
        self.title = title
        self.subtitle = subtitle
        self.systemImage = systemImage
        self.badgeText = badgeText
    }

    var body: some View {
        HStack(alignment: .center, spacing: 11) {
            PlayfulSymbolIcon(systemImage: systemImage, size: 30)
                .fixedSize()
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 8)

            if let badgeText {
                Text(badgeText)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppColors.selectedGlassTint.opacity(0.92))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(AppColors.selectedGlassTint.opacity(0.09), in: Capsule())
                    .overlay {
                        Capsule()
                            .strokeBorder(AppColors.cleanPanelBorder.opacity(0.82), lineWidth: 0.75)
                    }
                    .fixedSize()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }
}

struct AppStatusBadge: View {
    let title: String
    let systemImage: String
    var tint: Color = AppColors.selectedGlassTint

    var body: some View {
        Label(title, systemImage: systemImage)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(tint.opacity(0.92))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(AppColors.cleanFieldFill.opacity(0.76), in: Capsule())
            .overlay {
                Capsule()
                    .strokeBorder(tint.opacity(0.20), lineWidth: 0.7)
            }
            .fixedSize()
            .accessibilityElement(children: .combine)
    }
}

struct AppSurfaceToolbar<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    let thickness: Double
    @ViewBuilder var content: Content

    init(
        cornerRadius: CGFloat = AppRadius.toolbar,
        thickness: Double = AppEffect.staticGlassThickness,
        @ViewBuilder content: () -> Content
    ) {
        self.cornerRadius = cornerRadius
        self.thickness = thickness
        self.content = content()
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                content
            }
            .padding(.horizontal, AppSpacing.toolbarHorizontal)
            .padding(.vertical, AppSpacing.toolbarVertical)
            .frame(minHeight: AppControlMetrics.defaultButtonHeight)
            .fixedSize(horizontal: true, vertical: false)
        }
        .verticalScrollPassthroughFromNestedHorizontal()
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipShape(shape)
        .staticSurfaceBackground(cornerRadius: cornerRadius, thickness: thickness)
        .overlay {
            shape.strokeBorder(
                AppColors.edgeLightStroke(colorScheme, depth: thickness, intensity: 0.72),
                lineWidth: 0.8
            )
        }
        .overlay(alignment: .topLeading) {
            LinearGradient(
                colors: [
                    .white.opacity(colorScheme == .dark ? 0.34 : 0.72),
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.12 : 0.24),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.8)
            .padding(.horizontal, cornerRadius * 0.72)
            .padding(.top, 1.5)
            .allowsHitTesting(false)
        }
    }
}

struct AppAdaptiveControlBar<Leading: View, Trailing: View>: View {
    let cornerRadius: CGFloat
    let thickness: Double
    @ViewBuilder var leading: Leading
    @ViewBuilder var trailing: Trailing

    init(
        cornerRadius: CGFloat = AppRadius.controlGroup,
        thickness: Double = 1.04,
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) {
        self.cornerRadius = cornerRadius
        self.thickness = thickness
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                leading
                Spacer(minLength: 18)
                trailing
            }

            VStack(alignment: .leading, spacing: 10) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 10) {
                        leading
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.horizontal, 1)
                }
                .verticalScrollPassthroughFromNestedHorizontal()
                .frame(maxWidth: .infinity, alignment: .leading)

                HStack(spacing: 10) {
                    Spacer(minLength: 0)
                    trailing
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, AppSpacing.controlGroupHorizontal)
        .padding(.vertical, AppSpacing.controlGroupVertical)
        .frame(maxWidth: .infinity)
        .staticSurfaceBackground(cornerRadius: cornerRadius, thickness: thickness)
        .repeatedCardChrome(false, cornerRadius: cornerRadius)
    }
}

struct AppSheetActionFooter<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ViewBuilder var content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: AppSpacing.sheetFooter) {
            Spacer(minLength: 0)
            content
        }
        .padding(.top, 10)
        .overlay(alignment: .top) {
            LinearGradient(
                colors: [
                    .clear,
                    AppColors.cleanPanelBorder.opacity(colorScheme == .dark ? 0.46 : 0.62),
                    AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.16 : 0.22),
                    .clear
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(height: 0.7)
            .allowsHitTesting(false)
        }
    }
}

private struct AppSheetChromeModifier: ViewModifier {
    let width: CGFloat
    let minHeight: CGFloat?
    let maxHeight: CGFloat?

    func body(content: Content) -> some View {
        content
            .padding(.horizontal, AppSpacing.sheetHorizontal)
            .padding(.vertical, AppSpacing.sheetVertical)
            .frame(width: width)
            .frame(minHeight: minHeight, maxHeight: maxHeight)
            .background(AppPageBackground())
    }
}

struct PlayfulSymbolIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    var size: CGFloat = 40
    /// 所在行被选中时图标转白：避免与（同样跟随主题的）选中高亮底色融在一起。
    var selected: Bool = false

    private var visual: MediaIconVisual {
        MediaIconVisual(systemImage: systemImage)
    }

    // 图标主色渐变跟随配色方案（取主题图标色）；选中行转为白色与高亮底形成对比。
    private var symbolGradient: LinearGradient {
        if selected {
            return LinearGradient(colors: [.white, .white.opacity(0.94)], startPoint: .topLeading, endPoint: .bottomTrailing)
        }
        let c = AppColors.themedIconColors
        return LinearGradient(
            colors: [c.first ?? .accentColor, (c.count > 1 ? c[1] : .accentColor)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var accessoryGradient: LinearGradient {
        let c = AppColors.themedIconColors
        return LinearGradient(
            colors: [
                (c.count > 1 ? c[1] : .accentColor).opacity(0.70),
                (c.count > 2 ? c[2] : .accentColor).opacity(0.62)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    var body: some View {
        Group {
            if size <= 26 {
                Image(systemName: visual.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.68, weight: .semibold))
                    .foregroundStyle(symbolGradient)
                    .frame(width: size, height: size, alignment: .center)
            } else {
                ZStack {
                    if let accessory = visual.accessory, size >= 30 {
                        Image(systemName: accessory)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: size * 0.32, weight: .semibold))
                            .foregroundStyle(accessoryGradient)
                            .offset(x: size * 0.20, y: size * 0.20)
                    }
                    Image(systemName: visual.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(symbolGradient)
                        .shadow(color: (AppColors.themedIconColors.first ?? .accentColor).opacity(colorScheme == .dark ? 0.18 : 0.12), radius: size * 0.08, y: size * 0.03)
                        .offset(visual.symbolOffset)

                    if visual.family == .video {
                        SchemeOneWave()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        (AppColors.themedIconColors.first ?? AppColors.selectedGlassTint).opacity(0.48),
                                        (AppColors.themedIconColors.dropFirst().first ?? AppColors.selectedGlassTint).opacity(0.18)
                                    ],
                                    startPoint: .leading,
                                    endPoint: .trailing
                                ),
                                lineWidth: max(1, size * 0.045)
                            )
                            .frame(width: size * 0.92, height: size * 0.24)
                            .offset(y: size * 0.29)
                    }
                }
            }
        }
        .frame(width: size, height: size)
        .transaction { transaction in
            transaction.disablesAnimations = true
            transaction.animation = nil
        }
    }

    @ViewBuilder
    private var iconBase: some View {
        let gradient = LinearGradient(colors: visual.colors, startPoint: .topLeading, endPoint: .bottomTrailing)

        switch visual.shape {
        case .squircle:
            PlayfulBlobShape()
                .fill(gradient)
                .frame(width: size * 0.92, height: size * 0.88)
                .rotationEffect(.degrees(visual.rotation))
        case .circle:
            Circle()
                .fill(gradient)
                .frame(width: size * 0.84, height: size * 0.84)
        case .capsule:
            Capsule()
                .fill(gradient)
                .frame(width: size * 0.92, height: size * 0.60)
                .rotationEffect(.degrees(visual.rotation))
        case .diamond:
            RoundedRectangle(cornerRadius: size * 0.16, style: .continuous)
                .fill(gradient)
                .frame(width: size * 0.70, height: size * 0.70)
                .rotationEffect(.degrees(45 + visual.rotation))
        }
    }

    @ViewBuilder
    private var iconDecoration: some View {
        switch visual.family {
        case .video:
            RoundedRectangle(cornerRadius: size * 0.08, style: .continuous)
                .stroke(.white.opacity(0.36), lineWidth: max(1, size * 0.025))
                .frame(width: size * 0.54, height: size * 0.36)
                .offset(y: -size * 0.01)
            VStack(spacing: size * 0.045) {
                ForEach(0..<4, id: \.self) { _ in
                    RoundedRectangle(cornerRadius: size * 0.014, style: .continuous)
                        .fill(.white.opacity(0.78))
                        .frame(width: size * 0.045, height: size * 0.045)
                }
            }
            .offset(x: -size * 0.24)
            SchemeOneWave()
                .fill(.white.opacity(0.24))
                .frame(width: size * 0.84, height: size * 0.24)
                .offset(y: size * 0.24)
        case .music:
            Circle()
                .stroke(.white.opacity(0.36), lineWidth: max(1, size * 0.035))
                .frame(width: size * 0.56, height: size * 0.56)
            Circle()
                .fill(.white.opacity(0.38))
                .frame(width: size * 0.13, height: size * 0.13)
        case .source:
            HStack(spacing: size * 0.05) {
                ForEach(0..<3, id: \.self) { index in
                    Circle()
                        .fill(.white.opacity(index == 1 ? 0.86 : 0.48))
                        .frame(width: size * 0.07, height: size * 0.07)
                }
            }
            .offset(y: size * 0.24)
        case .vault:
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .stroke(.white.opacity(0.34), lineWidth: max(1, size * 0.028))
                .frame(width: size * 0.44, height: size * 0.36)
                .offset(y: size * 0.08)
            Circle()
                .trim(from: 0.05, to: 0.95)
                .stroke(.white.opacity(0.34), lineWidth: max(1, size * 0.025))
                .frame(width: size * 0.34, height: size * 0.34)
                .offset(y: -size * 0.10)
        case .settings:
            ForEach(0..<5, id: \.self) { index in
                Circle()
                    .fill(.white.opacity(index == 0 ? 0.56 : 0.30))
                    .frame(width: size * 0.065, height: size * 0.065)
                    .offset(
                        x: cos(Double(index) * 1.256) * size * 0.32,
                        y: sin(Double(index) * 1.256) * size * 0.30
                    )
            }
        case .status:
            Circle()
                .stroke(.white.opacity(0.28), lineWidth: max(1, size * 0.025))
                .frame(width: size * 0.68, height: size * 0.68)
            Circle()
                .fill(.white.opacity(0.64))
                .frame(width: size * 0.08, height: size * 0.08)
                .offset(x: size * 0.31, y: -size * 0.18)
        case .metadata:
            RoundedRectangle(cornerRadius: size * 0.07, style: .continuous)
                .fill(.white.opacity(0.20))
                .frame(width: size * 0.56, height: size * 0.40)
                .offset(x: size * 0.03, y: size * 0.05)
            Image(systemName: "sparkle")
                .font(.system(size: size * 0.16, weight: .bold))
                .foregroundStyle(.white.opacity(0.70))
                .offset(x: -size * 0.28, y: -size * 0.24)
        case .general:
            Circle()
                .fill(.white.opacity(0.18))
                .frame(width: size * 0.72, height: size * 0.72)
                .offset(x: size * 0.08, y: -size * 0.03)
        }
    }
}

private struct MediaIconVisual {
    enum Family { case video, music, source, vault, settings, status, metadata, general }
    enum Shape { case squircle, circle, capsule, diamond }

    let family: Family
    let shape: Shape
    let symbol: String
    let accessory: String?
    let colors: [Color]
    let accessoryColors: [Color]
    let symbolScale: CGFloat
    let symbolOffset: CGSize
    let rotation: Double

    init(systemImage: String) {
        let key = systemImage.lowercased()

        if key.contains("music") || key.contains("speaker") || key.contains("waveform") {
            self = Self(
                family: .music,
                shape: .circle,
                symbol: key.contains("speaker") ? systemImage : "music.note",
                accessory: key.contains("list") ? "text.line.first.and.arrowtriangle.forward" : "waveform",
                colors: Self.palette(.music),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.36,
                symbolOffset: CGSize(width: -2, height: 0),
                rotation: -6
            )
        } else if key.contains("lock") || key.contains("shield") || key.contains("touchid") || key.contains("key") || key.contains("number") {
            self = Self(
                family: .vault,
                shape: .diamond,
                symbol: key.contains("touchid") ? "touchid" : "lock.fill",
                accessory: key.contains("key") ? "key.fill" : "shield.fill",
                colors: Self.palette(.vault),
                accessoryColors: Self.palette(.gold),
                symbolScale: 0.35,
                symbolOffset: CGSize(width: 0, height: 1),
                rotation: -6
            )
        } else if key.contains("externaldrive") || key.contains("folder") || key.contains("server") || key.contains("network") || key.contains("app.badge") {
            self = Self(
                family: .source,
                shape: .capsule,
                symbol: key.contains("network") ? "point.3.connected.trianglepath.dotted" : (key.contains("server") ? "server.rack" : "externaldrive.fill"),
                accessory: key.contains("folder") ? "folder.fill" : "link",
                colors: Self.palette(.source),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.32,
                symbolOffset: CGSize(width: 0, height: -1),
                rotation: -4
            )
        } else if key.contains("gear") || key.contains("wrench") || key.contains("paintbrush") || key.contains("slider") || key.contains("cpu") {
            self = Self(
                family: .settings,
                shape: .squircle,
                symbol: key.contains("paintbrush") ? "paintbrush.pointed.fill" : (key.contains("cpu") ? "cpu.fill" : "gearshape.fill"),
                accessory: key.contains("wrench") ? "wrench.fill" : "slider.horizontal.3",
                colors: Self.palette(.settings),
                accessoryColors: Self.palette(.gold),
                symbolScale: 0.34,
                symbolOffset: CGSize(width: 0, height: 0),
                rotation: 8
            )
        } else if key.contains("photo") || key.contains("sparkle") || key.contains("globe") || key.contains("calendar") || key.contains("magnifyingglass") {
            self = Self(
                family: .metadata,
                shape: .squircle,
                symbol: key.contains("globe") ? "globe" : (key.contains("calendar") ? "calendar" : (key.contains("magnifyingglass") ? "magnifyingglass" : "photo.fill")),
                accessory: "sparkles",
                colors: Self.palette(.metadata),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.32,
                symbolOffset: CGSize(width: 0, height: 0),
                rotation: -7
            )
        } else if key.contains("heart") || key.contains("eye") || key.contains("clock") || key.contains("star") || key.contains("checkmark") {
            self = Self(
                family: .status,
                shape: .circle,
                symbol: systemImage,
                accessory: key.contains("heart") ? "sparkle" : nil,
                colors: Self.palette(.status),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.34,
                symbolOffset: CGSize(width: 0, height: 0),
                rotation: 0
            )
        } else if key.contains("film") || key.contains("tv") || key.contains("play") || key.contains("rectangle") || key.contains("display") {
            self = Self(
                family: .video,
                shape: .squircle,
                symbol: key.contains("tv") ? "tv.fill" : (key.contains("rectangle.stack") ? "rectangle.stack.fill" : "play.fill"),
                accessory: key.contains("tv") ? "sparkles" : nil,
                colors: Self.palette(.video),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.35,
                symbolOffset: CGSize(width: key.contains("play") ? 1.5 : 0, height: 0),
                rotation: -5
            )
        } else {
            self = Self(
                family: .general,
                shape: .squircle,
                symbol: systemImage,
                accessory: nil,
                colors: Self.palette(.video),
                accessoryColors: Self.palette(.warm),
                symbolScale: 0.32,
                symbolOffset: CGSize(width: 0, height: 0),
                rotation: -4
            )
        }
    }

    private init(
        family: Family,
        shape: Shape,
        symbol: String,
        accessory: String?,
        colors: [Color],
        accessoryColors: [Color],
        symbolScale: CGFloat,
        symbolOffset: CGSize,
        rotation: Double
    ) {
        self.family = family
        self.shape = shape
        self.symbol = symbol
        self.accessory = accessory
        self.colors = colors
        self.accessoryColors = accessoryColors
        self.symbolScale = symbolScale
        self.symbolOffset = symbolOffset
        self.rotation = rotation
    }

    private enum Palette { case video, music, source, vault, settings, metadata, status, warm, gold }

    private static func palette(_ palette: Palette) -> [Color] {
        let themed = AppColors.themedIconColors
        let primary = themed.first ?? AppColors.selectedGlassTint
        let secondary = themed.dropFirst().first ?? AppColors.solarEdgeTint
        let tertiary = themed.dropFirst(2).first ?? AppColors.solarLightTint

        switch palette {
        case .video:
            return [secondary, primary, tertiary]
        case .music:
            return [primary, secondary, AppColors.solarLightTint]
        case .source:
            return [secondary, AppColors.solarEdgeTint, tertiary]
        case .vault:
            return [tertiary, primary, secondary]
        case .settings:
            return [primary, AppColors.solarEdgeTint, secondary]
        case .metadata:
            return [secondary, AppColors.solarLightTint, tertiary]
        case .status:
            return [primary, secondary, tertiary]
        case .warm:
            return [AppColors.solarLightTint, secondary, primary]
        case .gold:
            return [AppColors.solarLightTint, tertiary, secondary]
        }
    }
}

private struct SchemeOnePlayTriangle: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        path.closeSubpath()
        return path
    }
}

private struct SchemeOneWave: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + h * 0.54))
        path.addCurve(
            to: CGPoint(x: rect.maxX, y: rect.minY + h * 0.32),
            control1: CGPoint(x: rect.minX + w * 0.28, y: rect.maxY + h * 0.26),
            control2: CGPoint(x: rect.minX + w * 0.66, y: rect.minY - h * 0.08)
        )
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
        path.closeSubpath()
        return path
    }
}

struct PlayfulBlobShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let w = rect.width
        let h = rect.height
        path.move(to: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.04))
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.86, y: rect.minY + h * 0.14),
            control1: CGPoint(x: rect.minX + w * 0.52, y: rect.minY - h * 0.05),
            control2: CGPoint(x: rect.minX + w * 0.78, y: rect.minY + h * 0.00)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.96, y: rect.minY + h * 0.68),
            control1: CGPoint(x: rect.minX + w * 0.98, y: rect.minY + h * 0.28),
            control2: CGPoint(x: rect.minX + w * 1.00, y: rect.minY + h * 0.50)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.56, y: rect.minY + h * 0.98),
            control1: CGPoint(x: rect.minX + w * 0.90, y: rect.minY + h * 0.90),
            control2: CGPoint(x: rect.minX + w * 0.75, y: rect.minY + h * 1.02)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.08, y: rect.minY + h * 0.78),
            control1: CGPoint(x: rect.minX + w * 0.32, y: rect.minY + h * 0.95),
            control2: CGPoint(x: rect.minX + w * 0.10, y: rect.minY + h * 0.96)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + w * 0.28, y: rect.minY + h * 0.04),
            control1: CGPoint(x: rect.minX - w * 0.04, y: rect.minY + h * 0.48),
            control2: CGPoint(x: rect.minX + w * 0.02, y: rect.minY + h * 0.14)
        )
        path.closeSubpath()
        return path
    }
}

private struct TransparentSearchTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    @Binding var isFocused: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, isFocused: $isFocused)
    }

    func makeNSView(context: Context) -> NSTextField {
        let textField = ClearBackgroundTextField(frame: .zero)
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.backgroundColor = .clear
        textField.wantsLayer = true
        textField.layer?.backgroundColor = NSColor.clear.cgColor
        textField.focusRingType = .none
        textField.lineBreakMode = .byTruncatingTail
        textField.usesSingleLineMode = true
        textField.cell?.isScrollable = true
        (textField.cell as? NSTextFieldCell)?.drawsBackground = false
        (textField.cell as? NSTextFieldCell)?.backgroundColor = .clear
        textField.font = .systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        textField.textColor = .labelColor
        textField.placeholderAttributedString = placeholderString(placeholder)
        textField.setAccessibilityLabel(placeholder)
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        if textField.stringValue != text {
            textField.stringValue = text
        }
        textField.placeholderAttributedString = placeholderString(placeholder)
        textField.backgroundColor = .clear
        textField.drawsBackground = false
        textField.layer?.backgroundColor = NSColor.clear.cgColor
        (textField.cell as? NSTextFieldCell)?.drawsBackground = false
        (textField.cell as? NSTextFieldCell)?.backgroundColor = .clear
        textField.textColor = .labelColor
        textField.setAccessibilityLabel(placeholder)
    }

    private func placeholderString(_ value: String) -> NSAttributedString {
        NSAttributedString(
            string: value,
            attributes: [
                .foregroundColor: NSColor.placeholderTextColor,
                .font: NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
            ]
        )
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        @Binding var isFocused: Bool

        init(text: Binding<String>, isFocused: Binding<Bool>) {
            _text = text
            _isFocused = isFocused
        }

        func controlTextDidBeginEditing(_ obj: Notification) {
            isFocused = true
            clearFieldEditor(from: obj)
        }

        func controlTextDidEndEditing(_ obj: Notification) {
            isFocused = false
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            clearFieldEditor(from: obj)
            text = field.stringValue
        }

        private func clearFieldEditor(from obj: Notification) {
            guard let field = obj.object as? NSTextField,
                  let editor = field.currentEditor() as? NSTextView else { return }
            editor.drawsBackground = false
            editor.backgroundColor = .clear
        }
    }

    final class ClearBackgroundTextField: NSTextField {
        override var isOpaque: Bool { false }

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if let editor = currentEditor() as? NSTextView {
                editor.drawsBackground = false
                editor.backgroundColor = .clear
                editor.layer?.backgroundColor = NSColor.clear.cgColor
            }
            return result
        }

        override func draw(_ dirtyRect: NSRect) {
            drawsBackground = false
            backgroundColor = .clear
            layer?.backgroundColor = NSColor.clear.cgColor
            super.draw(dirtyRect)
        }
    }
}

struct GlassSearchField: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isFocused = false
    let placeholder: String
    @Binding var text: String
    var thickness: Double = AppGlassMetrics.Thickness.headerControl
    var minWidth: CGFloat = 170
    var maxWidth: CGFloat = 260

    var body: some View {
        let depth = min(max(thickness, 0.8), 2.0)
        let width = adaptiveSearchWidth
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(isFocused ? AppColors.selectedGlassTint.opacity(0.92) : Color.primary.opacity(0.56))
                .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
            TransparentSearchTextField(placeholder: placeholder, text: $text, isFocused: $isFocused)
                .frame(height: 20)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(SubtleIconButtonStyle(minSize: 20))
                .accessibilityLabel("清除搜索")
                .help("清除搜索")
            }
        }
        .padding(.horizontal, 13)
        .frame(height: AppControlMetrics.searchFieldHeight)
        .frame(width: width)
        .modifier(HeaderControlGlassBackground(
            cornerRadius: 18,
            focused: isFocused,
            accent: AppColors.solarEdgeTint,
            enabled: true
        ))
        .pointerLiquidEdge(cornerRadius: 18, intensity: (isFocused ? 1.22 : 1.04) * depth)
        .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
    }

    private var adaptiveSearchWidth: CGFloat {
        let displayText = text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? placeholder : text
        let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        let measured = (displayText as NSString).size(withAttributes: [.font: font]).width + 86
        return min(max(ceil(measured), minWidth), maxWidth)
    }
}

private struct GlassFormFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @FocusState private var isFocused: Bool
    let cornerRadius: CGFloat
    let thickness: Double

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.8), 2.0)

        content
            .textFieldStyle(.plain)
            .focused($isFocused)
            .padding(.horizontal, 12)
            .frame(minHeight: AppControlMetrics.defaultButtonHeight)
            // 表单输入会在设置/弹层里重复出现，用静态玻璃填充保留观感并避免实时采样。
            .background(
                shape.fill(
                    reduceTransparency
                        ? AppColors.elevatedSurface
                        : AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.86 : 0.78)
                )
            )
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.20 : 0.48) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.10 : 0.13) * depth),
                            AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.70 : 0.76),
                            .white.opacity((colorScheme == .dark ? 0.08 : 0.20) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity((colorScheme == .dark ? 0.18 : 0.46) * depth), lineWidth: 1.0)
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.30 : 0.60) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.14 : 0.18) * depth),
                            AppColors.selectedGlassTint.opacity(isFocused ? (colorScheme == .dark ? 0.24 : 0.20) : 0),
                            AppColors.cleanPanelBorder
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: isFocused ? 1.15 : 1
                )
            }
            .clipShape(shape)
            .modifier(GlassFocusRingModifier(active: isFocused, cornerRadius: cornerRadius))
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.095 : 0.046) * depth), radius: 5.5, y: 3)
            .pointerLiquidEdge(cornerRadius: cornerRadius, intensity: (isFocused ? 1.16 : 0.86) * depth)
            .animation(reduceMotion ? nil : AppMotion.fast, value: isFocused)
            .onChange(of: isFocused) { focused in
                guard focused else { return }
                DispatchQueue.main.async {
                    if let editor = NSApp.keyWindow?.firstResponder as? NSTextView {
                        editor.drawsBackground = false
                        editor.backgroundColor = .clear
                        editor.layer?.backgroundColor = NSColor.clear.cgColor
                    }
                }
            }
    }
}

extension View {
    func glassFormField(cornerRadius: CGFloat = 10, thickness: Double = 1.12) -> some View {
        modifier(GlassFormFieldModifier(cornerRadius: cornerRadius, thickness: thickness))
    }
}

struct GlassMenuButton<MenuItems: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let title: String
    var width: CGFloat?
    var thickness: Double = AppGlassMetrics.Thickness.control
    @ViewBuilder var menuItems: MenuItems
    @State private var isHovering = false

    init(
        title: String,
        width: CGFloat? = nil,
        thickness: Double = AppGlassMetrics.Thickness.control,
        @ViewBuilder menuItems: () -> MenuItems
    ) {
        self.title = title
        self.width = width
        self.thickness = thickness
        self.menuItems = menuItems()
    }

    var body: some View {
        Menu {
            menuItems
        } label: {
            let shape = RoundedRectangle(cornerRadius: 9, style: .continuous)
            let depth = min(max(thickness, 0.8), 2.0)
            HStack(spacing: 8) {
                Text(title)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .font(.callout.weight(.medium))
            .padding(.horizontal, 12)
            .frame(width: width ?? adaptiveMenuControlWidth(for: title), height: AppControlMetrics.defaultButtonHeight)
            // 菜单按钮会在页头和来源行重复出现，这里避免创建实时 material 层。
            .background(
                shape.fill(
                    reduceTransparency
                        ? AppColors.elevatedSurface
                        : AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.86 : 0.78)
                )
            )
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? (isHovering ? 0.32 : 0.24) : (isHovering ? 0.62 : 0.50)) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? (isHovering ? 0.12 : 0.08) : (isHovering ? 0.18 : 0.12)) * depth),
                            AppColors.cleanFieldFill.opacity(colorScheme == .dark ? (isHovering ? 0.66 : 0.58) : (isHovering ? 0.80 : 0.72)),
                            .white.opacity((colorScheme == .dark ? (isHovering ? 0.10 : 0.07) : (isHovering ? 0.32 : 0.24)) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            )
            .overlay(alignment: .topLeading) {
                shape
                    .strokeBorder(.white.opacity((colorScheme == .dark ? 0.18 : 0.44) * depth), lineWidth: 1.0)
            }
            .overlay {
                shape.stroke(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? (isHovering ? 0.42 : 0.32) : (isHovering ? 1.0 : 0.88)) * depth),
                            .white.opacity((colorScheme == .dark ? (isHovering ? 0.20 : 0.14) : (isHovering ? 0.42 : 0.30)) * depth),
                            AppColors.solarEdgeTint.opacity((colorScheme == .dark ? (isHovering ? 0.24 : 0.14) : (isHovering ? 0.30 : 0.18)) * depth),
                            Color.black.opacity((colorScheme == .dark ? (isHovering ? 0.16 : 0.12) : (isHovering ? 0.064 : 0.044)) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity((colorScheme == .dark ? (isHovering ? 0.13 : 0.10) : (isHovering ? 0.045 : 0.030)) * depth), radius: (isHovering ? 7 : 6) * depth, y: 2)
            .pointerLiquidEdge(cornerRadius: 9, intensity: (isHovering ? 1.26 : 1.04) * depth)
            .brightness(isHovering ? 0.010 : 0)
            .onHover { hovering in
                isHovering = hovering
            }
            .animation(reduceMotion ? nil : AppMotion.fast, value: isHovering)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

func adaptiveMenuControlWidth(
    for title: String,
    minWidth: CGFloat = 76,
    maxWidth: CGFloat = 360,
    // 玻璃下拉的实际外框宽度 = 文字宽 + 左右内边距(24) + 间隔 + 雪佛龙 + 安全余量。
    // 既贴合当前选项（不再按最长选项或固定 chrome 留大片空白），又留足余量避免边界处把
    // "English"/"Clear blue" 这类标题截断成 "Engli…"。
    horizontalChrome: CGFloat = 64
) -> CGFloat {
    let font = NSFont.systemFont(ofSize: NSFont.systemFontSize, weight: .semibold)
    let measured = (title as NSString).size(withAttributes: [.font: font]).width + horizontalChrome
    return min(max(ceil(measured), minWidth), maxWidth)
}

extension View {
    /// 把任意 `Picker` 收进统一的玻璃下拉外壳：标题宽度随**当前选项**自适应，
    /// 选项列表用 inline 样式直接挂在玻璃菜单里。这样设置页的原生 Picker 与
    /// 媒体库/音乐的筛选下拉视觉统一，且不再按最长选项撑宽留白。
    func adaptiveMenuControl(
        selectedTitle: String,
        minWidth: CGFloat = 92,
        maxWidth: CGFloat = 360
    ) -> some View {
        GlassMenuButton(
            title: selectedTitle,
            width: adaptiveMenuControlWidth(for: selectedTitle, minWidth: minWidth, maxWidth: maxWidth)
        ) {
            self
                .labelsHidden()
                .pickerStyle(.inline)
        }
    }
}

private enum PosterPerformanceTelemetry {
    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "MediaLib",
        category: "PosterPerformance"
    )
    private static let lock = NSLock()
    private static var memoryHits = 0
    private static var memoryMisses = 0
    private static var diskHits = 0
    private static var diskMisses = 0
    private static var diskMilliseconds = 0.0
    private static var decodeCount = 0
    private static var decodeMilliseconds = 0.0
    private static var maxDecodeMilliseconds = 0.0
    private static var didLogConfiguration = false

    static func noteConfiguration() {
        lock.lock()
        guard !didLogConfiguration else {
            lock.unlock()
            return
        }
        didLogConfiguration = true
        lock.unlock()
        logger.info("Poster cache configured: shared 300x450 point bucket, 256 MiB decoded memory cache")
    }

    static func recordMemoryLookup(hit: Bool) {
        lock.lock()
        if hit {
            memoryHits += 1
        } else {
            memoryMisses += 1
        }
        let total = memoryHits + memoryMisses
        let shouldLog = total.isMultiple(of: 250)
        let hits = memoryHits
        let misses = memoryMisses
        lock.unlock()
        if shouldLog {
            logger.debug("Poster memory cache: hits=\(hits) misses=\(misses)")
        }
    }

    static func recordDiskRead(hit: Bool, milliseconds: Double) {
        lock.lock()
        if hit {
            diskHits += 1
        } else {
            diskMisses += 1
        }
        diskMilliseconds += milliseconds
        let total = diskHits + diskMisses
        let shouldLog = total.isMultiple(of: 100)
        let hits = diskHits
        let misses = diskMisses
        let average = diskMilliseconds / Double(max(total, 1))
        lock.unlock()
        if shouldLog {
            logger.debug("Poster disk cache: hits=\(hits) misses=\(misses) avgMs=\(average, format: .fixed(precision: 2))")
        }
    }

    static func recordDecode(milliseconds: Double) {
        lock.lock()
        decodeCount += 1
        decodeMilliseconds += milliseconds
        maxDecodeMilliseconds = max(maxDecodeMilliseconds, milliseconds)
        let shouldLog = decodeCount.isMultiple(of: 100)
        let count = decodeCount
        let average = decodeMilliseconds / Double(max(count, 1))
        let maximum = maxDecodeMilliseconds
        lock.unlock()
        if shouldLog {
            logger.debug("Poster decode: count=\(count) avgMs=\(average, format: .fixed(precision: 2)) maxMs=\(maximum, format: .fixed(precision: 2))")
        }
    }
}

enum ArtworkImageCache {
    /// 海报墙与远程封面预热共用同一尺寸档，避免“已预热”却因缓存键不同重新解码。
    static let posterGridTargetSize = CGSize(width: 300, height: 450)
    private static let cache = NSCache<NSString, NSImage>()
    private static let remoteStore = ArtworkRemoteImageStore(
        maxConcurrentFetches: 4,
        maxDiskCacheBytes: 512 * 1024 * 1024,
        maxDiskCacheFiles: 6000
    )
    private static let decodeCoordinator = ArtworkDecodeCoordinator(maxConcurrentDecodes: 3)
    private static var missingPaths: [String: MissingArtworkEntry] = [:]
    private static var aspectRatios: [String: CGFloat] = [:]
    private static var missingAccessOrder: [String] = []
    private static var aspectAccessOrder: [String] = []
    private static let lock = NSLock()
    private static let localMissingCacheLifetime: TimeInterval = 8
    private static let remoteMissingInitialBackoff: TimeInterval = 30
    private static let remoteMissingMaxBackoff: TimeInterval = 10 * 60
    private static let remoteFetchTimeout: TimeInterval = 14
    private static let maxRemoteImageBytes = 24 * 1024 * 1024
    private static let maxMissingPaths = 600
    private static let maxAspectRatios = 1200
    private static let defaultTargetSize = CGSize(width: 420, height: 420)

    static func configureIfNeeded() {
        PosterPerformanceTelemetry.noteConfiguration()
        // 提高缓存上限，减少滚动时封面被驱逐后重新解码导致的掉帧与闪烁。
        // Emby 等大体量库（数百~上千海报）滚动时尤其依赖更大的常驻缓存避免反复驱逐→闪烁。
        cache.countLimit = 1200
        cache.totalCostLimit = 256 * 1024 * 1024
    }

    static func cachedImage(path: String?, targetSize: CGSize? = nil) -> NSImage? {
        configureIfNeeded()
        guard let path else { return nil }
        lock.lock()
        let isMissing = cachedMissingPathIsFresh(path)
        lock.unlock()
        guard !isMissing else { return nil }
        let image = cache.object(forKey: cacheKey(path: path, targetSize: targetSize))
        PosterPerformanceTelemetry.recordMemoryLookup(hit: image != nil)
        return image
    }

    static func cachedAspectRatio(path: String?) -> CGFloat? {
        configureIfNeeded()
        guard let path else { return nil }
        lock.lock()
        if let ratio = aspectRatios[path] {
            markAspectRecentlyUsedLocked(path)
            lock.unlock()
            return ratio
        }
        lock.unlock()
        return nil
    }

    static func image(path: String?, targetSize: CGSize? = nil) -> NSImage? {
        configureIfNeeded()
        guard let path else { return nil }
#if DEBUG
        if let debugCover = MusicPlayerVisualDebugFixtures.coverImage(
            forPath: path,
            size: Int(max(targetSize?.width ?? defaultTargetSize.width, targetSize?.height ?? defaultTargetSize.height))
        ) {
            return debugCover
        }
        if path == MusicPlayerVisualDebugFixtures.quadrantCoverPath {
            let side = Int(max(targetSize?.width ?? defaultTargetSize.width, targetSize?.height ?? defaultTargetSize.height))
            return MusicPlayerVisualDebugFixtures.quadrantCoverImage(size: side)
        }
#endif
        if let remoteURL = remoteURL(from: path) {
            return remoteImage(url: remoteURL, targetSize: targetSize)
        }
        lock.lock()
        let isMissing = cachedMissingPathIsFresh(path)
        lock.unlock()
        if isMissing {
            return nil
        }
        let key = cacheKey(path: path, targetSize: targetSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        let decodeStart = CFAbsoluteTimeGetCurrent()
        guard FileManager.default.fileExists(atPath: path),
              let image = downsampledImage(path: path, targetSize: targetSize ?? defaultTargetSize) else {
            lock.lock()
            storeMissingPathLocked(path, isRemote: false)
            lock.unlock()
            return nil
        }
        PosterPerformanceTelemetry.recordDecode(
            milliseconds: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1_000
        )
        let pixelCost = image.pixelCost
        cache.setObject(image, forKey: key, cost: pixelCost)
        lock.lock()
        storeAspectRatioLocked(normalizedAspectRatio(for: image), path: path)
        lock.unlock()
        return image
    }

    static func localImageAsync(path: String, targetSize: CGSize? = nil) async -> NSImage? {
        configureIfNeeded()
#if DEBUG
        if let debugCover = MusicPlayerVisualDebugFixtures.coverImage(
            forPath: path,
            size: Int(max(targetSize?.width ?? defaultTargetSize.width, targetSize?.height ?? defaultTargetSize.height))
        ) {
            return debugCover
        }
        if path == MusicPlayerVisualDebugFixtures.quadrantCoverPath {
            let side = Int(max(targetSize?.width ?? defaultTargetSize.width, targetSize?.height ?? defaultTargetSize.height))
            return MusicPlayerVisualDebugFixtures.quadrantCoverImage(size: side)
        }
#endif
        if let remoteURL = remoteURL(from: path) {
            return await remoteImageAsync(url: remoteURL, targetSize: targetSize)
        }
        if cachedMissingPath(path) {
            return nil
        }

        let resolvedTargetSize = targetSize ?? defaultTargetSize
        let key = cacheKey(path: path, targetSize: resolvedTargetSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let decoded = await decodeCoordinator.decode(key: key as String) {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            guard FileManager.default.fileExists(atPath: path) else {
                return SendableArtworkImage(nil)
            }
            let image = downsampledImage(path: path, targetSize: resolvedTargetSize)
            PosterPerformanceTelemetry.recordDecode(
                milliseconds: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1_000
            )
            return SendableArtworkImage(image)
        }
        guard let decoded else {
            if !Task.isCancelled {
                storeMissingPath(path, isRemote: false)
            }
            return nil
        }
        cache.setObject(decoded, forKey: key, cost: decoded.pixelCost)
        storeAspectRatio(normalizedAspectRatio(for: decoded), path: path)
        return decoded
    }

    static func remoteImage(url: URL, targetSize: CGSize? = nil) -> NSImage? {
        configureIfNeeded()
        let path = url.absoluteString
        lock.lock()
        let isMissing = cachedMissingPathIsFresh(path)
        lock.unlock()
        if isMissing {
            return nil
        }
        let key = cacheKey(path: path, targetSize: targetSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }
        return nil
    }

    static func remoteImageAsync(url: URL, targetSize: CGSize? = nil) async -> NSImage? {
        configureIfNeeded()
        let path = url.absoluteString
        if cachedMissingPath(path) {
            return nil
        }

        let resolvedTargetSize = targetSize ?? defaultTargetSize
        let key = cacheKey(path: path, targetSize: resolvedTargetSize)
        if let cached = cache.object(forKey: key) {
            return cached
        }

        let cacheID = remoteDiskCacheID(for: path)
        guard let data = await remoteStore.data(
            for: cacheID,
            url: url,
            timeout: remoteFetchTimeout,
            maxBytes: maxRemoteImageBytes
        ) else {
            if !Task.isCancelled {
                storeMissingPath(path, isRemote: true)
            }
            return nil
        }

        guard !Task.isCancelled else { return nil }
        guard let image = await decodeRemoteImage(data: data, path: path, key: key, targetSize: resolvedTargetSize) else {
            await remoteStore.remove(cacheID: cacheID)
            if !Task.isCancelled {
                storeMissingPath(path, isRemote: true)
            }
            return nil
        }
        return image
    }

    @discardableResult
    static func prewarmRemoteImage(url: URL, targetSize: CGSize? = nil) async -> Bool {
        await remoteImageAsync(url: url, targetSize: targetSize) != nil
    }

    static func invalidateMissing(path: String?) {
        guard let path else { return }
        lock.lock()
        missingPaths.removeValue(forKey: path)
        missingAccessOrder.removeAll { $0 == path }
        lock.unlock()
    }

    static func invalidateMissingPaths() {
        lock.lock()
        missingPaths.removeAll()
        missingAccessOrder.removeAll()
        lock.unlock()
    }

    /// 版本升级维护使用：清理旧尺寸/旧策略留下的远程封面与解码缓存。
    /// 本地扫描生成的封面文件不在这里删除，避免破坏媒体条目保存的本地路径。
    static func clearRemotePrebakedArtwork() async {
        clearMemoryCaches()
        await decodeCoordinator.cancelAll()
        await remoteStore.removeAll()
    }

    private static func clearMemoryCaches() {
        cache.removeAllObjects()
        lock.lock()
        missingPaths.removeAll()
        aspectRatios.removeAll()
        missingAccessOrder.removeAll()
        aspectAccessOrder.removeAll()
        lock.unlock()
    }

    private static func cachedMissingPathIsFresh(_ path: String) -> Bool {
        guard let entry = missingPaths[path] else { return false }
        if Date() < entry.retryAfter {
            markMissingRecentlyUsedLocked(path)
            return true
        }
        missingPaths.removeValue(forKey: path)
        missingAccessOrder.removeAll { $0 == path }
        return false
    }

    private static func storeMissingPathLocked(_ path: String, isRemote: Bool) {
        let now = Date()
        let previousFailures = missingPaths[path]?.failureCount ?? 0
        let failureCount = isRemote ? min(previousFailures + 1, 8) : 1
        let retryDelay: TimeInterval
        if isRemote {
            retryDelay = min(remoteMissingInitialBackoff * pow(2, Double(failureCount - 1)), remoteMissingMaxBackoff)
        } else {
            retryDelay = localMissingCacheLifetime
        }
        missingPaths[path] = MissingArtworkEntry(retryAfter: now.addingTimeInterval(retryDelay), failureCount: failureCount)
        markMissingRecentlyUsedLocked(path)
        while missingPaths.count > maxMissingPaths, let oldestPath = missingAccessOrder.first {
            missingAccessOrder.removeFirst()
            missingPaths.removeValue(forKey: oldestPath)
        }
    }

    private static func storeAspectRatioLocked(_ ratio: CGFloat, path: String) {
        aspectRatios[path] = ratio
        markAspectRecentlyUsedLocked(path)
        while aspectRatios.count > maxAspectRatios, let oldestPath = aspectAccessOrder.first {
            aspectAccessOrder.removeFirst()
            aspectRatios.removeValue(forKey: oldestPath)
        }
    }

    private static func markMissingRecentlyUsedLocked(_ path: String) {
        missingAccessOrder.removeAll { $0 == path }
        missingAccessOrder.append(path)
    }

    private static func markAspectRecentlyUsedLocked(_ path: String) {
        aspectAccessOrder.removeAll { $0 == path }
        aspectAccessOrder.append(path)
    }

    private static func normalizedAspectRatio(for image: NSImage) -> CGFloat {
        guard image.size.width > 0, image.size.height > 0 else {
            return 2.0 / 3.0
        }
        return min(max(image.size.width / image.size.height, 0.68), 1.78)
    }

    private static func cacheKey(path: String, targetSize: CGSize?) -> NSString {
        let pixelSize = roundedPixelSize(for: targetSize ?? defaultTargetSize)
        return "\(path)#\(Int(pixelSize.width))x\(Int(pixelSize.height))" as NSString
    }

    private static func remoteURL(from path: String) -> URL? {
        guard let url = URL(string: path),
              let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme) else {
            return nil
        }
        return url
    }

    private static func decodeRemoteImage(data: Data, path: String, key: NSString, targetSize: CGSize) async -> NSImage? {
        let decoded = await decodeCoordinator.decode(key: key as String) {
            let decodeStart = CFAbsoluteTimeGetCurrent()
            let image = downsampledImage(data: data, targetSize: targetSize)
            PosterPerformanceTelemetry.recordDecode(
                milliseconds: (CFAbsoluteTimeGetCurrent() - decodeStart) * 1_000
            )
            return SendableArtworkImage(image)
        }
        guard let decoded else { return nil }
        cache.setObject(decoded, forKey: key, cost: decoded.pixelCost)
        storeAspectRatio(normalizedAspectRatio(for: decoded), path: path)
        return decoded
    }

    private static func remoteDiskCacheID(for path: String) -> String {
        let digest = SHA256.hash(data: Data(path.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    private static func cachedMissingPath(_ path: String) -> Bool {
        lock.lock()
        let isMissing = cachedMissingPathIsFresh(path)
        lock.unlock()
        return isMissing
    }

    private static func storeMissingPath(_ path: String, isRemote: Bool) {
        lock.lock()
        storeMissingPathLocked(path, isRemote: isRemote)
        lock.unlock()
    }

    private static func storeAspectRatio(_ ratio: CGFloat, path: String) {
        lock.lock()
        storeAspectRatioLocked(ratio, path: path)
        lock.unlock()
    }

    private static func roundedPixelSize(for targetSize: CGSize) -> CGSize {
        let scale: CGFloat = 2
        let width = max(targetSize.width, 1) * scale
        let height = max(targetSize.height, 1) * scale
        let bucket: CGFloat = 64
        return CGSize(
            width: min(max(ceil(width / bucket) * bucket, 96), 960),
            height: min(max(ceil(height / bucket) * bucket, 96), 960)
        )
    }

    private static func downsampledImage(path: String, targetSize: CGSize) -> NSImage? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        return downsampledImage(source: source, aspectRatioKey: path, targetSize: targetSize)
    }

    private static func downsampledImage(data: Data, targetSize: CGSize) -> NSImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [
            kCGImageSourceShouldCache: false
        ] as CFDictionary) else {
            return nil
        }

        return downsampledImage(source: source, aspectRatioKey: nil, targetSize: targetSize)
    }

    private static func downsampledImage(source: CGImageSource, aspectRatioKey: String?, targetSize: CGSize) -> NSImage? {
        if let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let pixelWidth = pixelDimension(properties[kCGImagePropertyPixelWidth]),
           let pixelHeight = pixelDimension(properties[kCGImagePropertyPixelHeight]),
           pixelWidth > 0,
            pixelHeight > 0 {
            if let aspectRatioKey {
                lock.lock()
                storeAspectRatioLocked(min(max(pixelWidth / pixelHeight, 0.68), 1.78), path: aspectRatioKey)
                lock.unlock()
            }
        }

        let pixelSize = roundedPixelSize(for: targetSize)
        let maxPixelSize = Int(max(pixelSize.width, pixelSize.height))
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize
        ]

        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let scale: CGFloat = 2
        return NSImage(
            cgImage: cgImage,
            size: CGSize(width: CGFloat(cgImage.width) / scale, height: CGFloat(cgImage.height) / scale)
        )
    }

    private static func pixelDimension(_ value: Any?) -> CGFloat? {
        if let value = value as? CGFloat {
            return value
        }
        if let value = value as? NSNumber {
            return CGFloat(truncating: value)
        }
        if let value = value as? Int {
            return CGFloat(value)
        }
        if let value = value as? Double {
            return CGFloat(value)
        }
        return nil
    }
}

private struct MissingArtworkEntry {
    let retryAfter: Date
    let failureCount: Int
}

private actor ArtworkDecodeCoordinator {
    private let maxConcurrentDecodes: Int
    private var activeDecodes = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlight: [String: (id: UUID, task: Task<SendableArtworkImage, Never>)] = [:]

    init(maxConcurrentDecodes: Int) {
        self.maxConcurrentDecodes = max(1, maxConcurrentDecodes)
    }

    func cancelAll() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
    }

    func decode(
        key: String,
        operation: @escaping @Sendable () -> SendableArtworkImage
    ) async -> NSImage? {
        if let entry = inFlight[key] {
            return await entry.task.value.image
        }

        let requestID = UUID()
        let task = Task<SendableArtworkImage, Never> { [weak self] in
            guard let self else { return SendableArtworkImage(nil) }
            return await self.runWithPermit(operation)
        }
        inFlight[key] = (requestID, task)
        let result = await task.value
        if inFlight[key]?.id == requestID {
            inFlight.removeValue(forKey: key)
        }
        return result.image
    }

    private func runWithPermit(
        _ operation: @escaping @Sendable () -> SendableArtworkImage
    ) async -> SendableArtworkImage {
        await acquire()
        guard !Task.isCancelled else {
            release()
            return SendableArtworkImage(nil)
        }
        let result = await Task.detached(priority: .utility, operation: operation).value
        release()
        return result
    }

    private func acquire() async {
        if activeDecodes < maxConcurrentDecodes {
            activeDecodes += 1
            return
        }
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeDecodes = max(activeDecodes - 1, 0)
        } else {
            waiters.removeFirst().resume()
        }
    }
}

private actor ArtworkRemoteImageStore {
    private let maxConcurrentFetches: Int
    private let maxDiskCacheBytes: Int
    private let maxDiskCacheFiles: Int
    private let cacheDirectory: URL?
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightRequests: [String: (id: UUID, task: Task<Data?, Never>)] = [:]
    private var writesSinceLastPrune = 0
    private var lastPruneAt = Date.distantPast
    private var cacheGeneration = 0

    init(maxConcurrentFetches: Int, maxDiskCacheBytes: Int, maxDiskCacheFiles: Int) {
        self.maxConcurrentFetches = max(1, maxConcurrentFetches)
        self.maxDiskCacheBytes = maxDiskCacheBytes
        self.maxDiskCacheFiles = maxDiskCacheFiles
        if let cacheBase = try? FileManager.default.url(
            for: .cachesDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ) {
            let directory = cacheBase
                .appendingPathComponent("MediaLib", isDirectory: true)
                .appendingPathComponent("RemoteArtwork", isDirectory: true)
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            self.cacheDirectory = directory
        } else {
            self.cacheDirectory = nil
        }
    }

    func data(for cacheID: String, url: URL, timeout: TimeInterval, maxBytes: Int) async -> Data? {
        if let entry = inFlightRequests[cacheID] {
            return await entry.task.value
        }

        let cacheURL = cacheFileURL(cacheID: cacheID)
        let generation = cacheGeneration
        let requestID = UUID()
        let task = Task<Data?, Never> { [weak self] in
            if let cacheURL,
               let cached = await Self.readDiskData(url: cacheURL, maxBytes: maxBytes) {
                return cached
            }
            guard let self else { return nil }
            return await self.fetchWithPermit(
                cacheID: cacheID,
                url: url,
                timeout: timeout,
                maxBytes: maxBytes,
                generation: generation
            )
        }
        inFlightRequests[cacheID] = (requestID, task)
        let data = await task.value
        if inFlightRequests[cacheID]?.id == requestID {
            inFlightRequests.removeValue(forKey: cacheID)
        }
        return data
    }

    func remove(cacheID: String) {
        guard let url = cacheFileURL(cacheID: cacheID) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    func removeAll() async {
        cacheGeneration &+= 1
        inFlightRequests.values.forEach { $0.task.cancel() }
        inFlightRequests.removeAll()
        writesSinceLastPrune = 0
        lastPruneAt = .distantPast
        guard let cacheDirectory else { return }
        await Task.detached(priority: .utility) {
            let fileManager = FileManager.default
            guard let urls = try? fileManager.contentsOfDirectory(
                at: cacheDirectory,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return }
            for url in urls where url.pathExtension == "img" {
                try? fileManager.removeItem(at: url)
            }
        }.value
    }

    private func acquire() async {
        if activeFetches < maxConcurrentFetches {
            activeFetches += 1
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    private func release() {
        if waiters.isEmpty {
            activeFetches = max(activeFetches - 1, 0)
        } else {
            waiters.removeFirst().resume()
        }
    }

    private func fetchWithPermit(
        cacheID: String,
        url: URL,
        timeout: TimeInterval,
        maxBytes: Int,
        generation: Int
    ) async -> Data? {
        await acquire()
        defer { release() }
        if Task.isCancelled { return nil }
        return await fetchAndStore(
            cacheID: cacheID,
            url: url,
            timeout: timeout,
            maxBytes: maxBytes,
            generation: generation
        )
    }

    private nonisolated static func readDiskData(url: URL, maxBytes: Int) async -> Data? {
        let start = CFAbsoluteTimeGetCurrent()
        let task = Task.detached(priority: .utility) { () -> Data? in
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey]),
                  let fileSize = values.fileSize,
                  fileSize > 0,
                  fileSize <= maxBytes else {
                return nil
            }
            // 不在每次滚动命中时写 modificationDate；该写操作会把纯读取变成串行磁盘写热点。
            return try? Data(contentsOf: url, options: [.mappedIfSafe])
        }
        let data = await task.value
        PosterPerformanceTelemetry.recordDiskRead(
            hit: data != nil,
            milliseconds: (CFAbsoluteTimeGetCurrent() - start) * 1_000
        )
        return data
    }

    private func fetchAndStore(
        cacheID: String,
        url: URL,
        timeout: TimeInterval,
        maxBytes: Int,
        generation: Int
    ) async -> Data? {
        var request = URLRequest(url: url, cachePolicy: .returnCacheDataElseLoad, timeoutInterval: timeout)
        request.setValue("MediaLIB/1.0 local macOS media library", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled else { return nil }
            if let httpResponse = response as? HTTPURLResponse,
               !(200..<300).contains(httpResponse.statusCode) {
                return nil
            }
            guard data.count > 0, data.count <= maxBytes else {
                return nil
            }

            if generation == cacheGeneration, let fileURL = cacheFileURL(cacheID: cacheID) {
                try? data.write(to: fileURL, options: [.atomic])
                pruneDiskCacheAfterWriteIfNeeded()
            }
            return data
        } catch {
            return nil
        }
    }

    private func cacheFileURL(cacheID: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(cacheID).img", isDirectory: false)
    }

    private func pruneDiskCacheAfterWriteIfNeeded() {
        writesSinceLastPrune += 1
        let now = Date()
        guard writesSinceLastPrune >= 32 || now.timeIntervalSince(lastPruneAt) >= 60 else {
            return
        }
        writesSinceLastPrune = 0
        lastPruneAt = now
        pruneDiskCacheIfNeeded()
    }

    private func pruneDiskCacheIfNeeded() {
        guard let cacheDirectory else { return }
        let fileManager = FileManager.default
        guard let urls = try? fileManager.contentsOfDirectory(
            at: cacheDirectory,
            includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var entries: [(url: URL, modified: Date, size: Int)] = []
        var totalSize = 0
        for url in urls {
            guard url.pathExtension == "img" else { continue }
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
            let size = values?.fileSize ?? 0
            guard size > 0 else {
                try? fileManager.removeItem(at: url)
                continue
            }
            totalSize += size
            entries.append((url, values?.contentModificationDate ?? .distantPast, size))
        }

        guard totalSize > maxDiskCacheBytes || entries.count > maxDiskCacheFiles else { return }
        entries.sort { $0.modified < $1.modified }
        while (totalSize > maxDiskCacheBytes || entries.count > maxDiskCacheFiles), !entries.isEmpty {
            let entry = entries.removeFirst()
            try? fileManager.removeItem(at: entry.url)
            totalSize -= entry.size
        }
    }
}

private struct SendableArtworkImage: @unchecked Sendable {
    let image: NSImage?

    init(_ image: NSImage?) {
        self.image = image
    }
}

private extension NSImage {
    var pixelCost: Int {
        if let cgImage = cgImage(forProposedRect: nil, context: nil, hints: nil) {
            return max(1, cgImage.bytesPerRow * cgImage.height)
        }
        return max(1, Int(size.width * size.height * 4))
    }
}
