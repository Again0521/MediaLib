import AppKit
import CryptoKit
import Foundation
import ImageIO
import SwiftUI

enum AppColors {
    // ── 层级1：页面底色 ─────────────────────────────────────────────────────────
    // 浅色：偏 Apple Music 的暖珍珠底，避免整页泛冷蓝；
    // 深色：中性石墨底，减少蓝紫偏色。
    static var pageBackground: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.940, green: 0.938, blue: 0.928, alpha: 0.96),
            dark:  NSColor(calibratedRed: 0.110, green: 0.110, blue: 0.116, alpha: 0.95)
        ))
    }

    // ── 层级2：主卡片 / 浮层（rich surface）─────────────────────────────────────
    // 浅色：近乎暖白；深色：中性玻璃灰。与底色形成清透层级。
    static var surface: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.998, green: 0.994, blue: 0.982, alpha: 0.86),
            dark:  NSColor(calibratedRed: 0.260, green: 0.260, blue: 0.278, alpha: 0.58)
        ))
    }

    static var secondarySurface: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.988, green: 0.986, blue: 0.972, alpha: 0.82),
            dark:  NSColor(calibratedRed: 0.210, green: 0.210, blue: 0.228, alpha: 0.64)
        ))
    }

    static var subtleBorder: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedWhite: 1.0, alpha: 0.74),
            dark:  NSColor(calibratedWhite: 1.0, alpha: 0.22)
        ))
    }

    static var glassTint: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 1.000, green: 0.976, blue: 0.910, alpha: 0.40),
            dark:  NSColor(calibratedRed: 0.340, green: 0.320, blue: 0.286, alpha: 0.30)
        ))
    }

    // ── 层级2：卡片填充（flat & efficient surface）─────────────────────────────
    // 普通页面统一走暖白玻璃，不再让搜索、列表和卡片带大面积冷蓝底色。
    static var cleanPanelFill: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.992, green: 0.990, blue: 0.976, alpha: 0.78),
            dark:  NSColor(calibratedRed: 0.230, green: 0.230, blue: 0.246, alpha: 0.78)
        ))
    }

    static var cleanPanelBorder: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.54, green: 0.50, blue: 0.42, alpha: 0.16),
            dark:  NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.78,  alpha: 0.13)
        ))
    }

    // ── 层级3：输入框 / 控件填充 ────────────────────────────────────────────────
    // 搜索框和菜单控件使用更像系统控件的低彩度珍珠玻璃。
    static var cleanFieldFill: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.974, green: 0.972, blue: 0.956, alpha: 0.58),
            dark:  NSColor(calibratedRed: 0.285, green: 0.280, blue: 0.292, alpha: 0.66)
        ))
    }

    // ── 装饰 / 辅助色 ──────────────────────────────────────────────────────────
    static var sidebarBlueWash: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.70, green: 0.86, blue: 0.92, alpha: 0.14),
            dark:  NSColor(calibratedRed: 0.18, green: 0.32, blue: 0.46, alpha: 0.22)
        ))
    }

    static var cardAquaWash: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 1.0, green: 0.966, blue: 0.880, alpha: 0.18),
            dark:  NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.30, alpha: 0.20)
        ))
    }

    static var accentGradient: LinearGradient {
        LinearGradient(
            colors: [
                Color(nsColor: NSColor.systemBlue),
                Color(nsColor: NSColor.systemCyan),
                Color(nsColor: NSColor.systemTeal)
            ],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    static var pointerLightTint: Color {
        Color(nsColor: dynamic(light: NSColor(calibratedRed: 1.0, green: 0.965, blue: 0.875, alpha: 1), dark: NSColor(calibratedRed: 0.92, green: 0.88, blue: 0.78, alpha: 1)))
    }

    static var solarLightTint: Color {
        Color(nsColor: dynamic(light: NSColor(calibratedRed: 1.0, green: 0.982, blue: 0.920, alpha: 1), dark: NSColor(calibratedRed: 0.86, green: 0.82, blue: 0.72, alpha: 1)))
    }

    static var solarEdgeTint: Color {
        Color(nsColor: dynamic(light: NSColor(calibratedRed: 1.0, green: 0.900, blue: 0.700, alpha: 1), dark: NSColor(calibratedRed: 0.96, green: 0.82, blue: 0.58, alpha: 1)))
    }

    static var selectedGlassTint: Color {
        Color(nsColor: dynamic(
            light: NSColor(calibratedRed: 0.38, green: 0.58, blue: 0.90, alpha: 1),
            dark:  NSColor(calibratedRed: 0.52, green: 0.68, blue: 1.0, alpha: 1)
        ))
    }

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

    private static func dynamic(light: NSColor, dark: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            let best = appearance.bestMatch(from: [.darkAqua, .aqua])
            return best == .darkAqua ? dark : light
        }
    }
}

enum AppMotion {
    // 弹簧曲线由系统按当前显示器刷新率插值，避免线性匀速感；hover 也保持短弹簧而不是 ease-out。
    static let hover = Animation.spring(response: 0.20, dampingFraction: 0.82, blendDuration: 0.02)
    static let listHover = Animation.spring(response: 0.18, dampingFraction: 0.84, blendDuration: 0.01)
    static let immediate = Animation.spring(response: 0.26, dampingFraction: 0.86)
    static let fast = Animation.spring(response: 0.32, dampingFraction: 0.85)
    static let standard = Animation.spring(response: 0.42, dampingFraction: 0.87)
    static let page = Animation.spring(response: 0.48, dampingFraction: 0.89)
    static let panel = Animation.spring(response: 0.46, dampingFraction: 0.88, blendDuration: 0.06)
    static let sidebar = Animation.spring(response: 0.46, dampingFraction: 0.90)
    static let musicPlayer = Animation.spring(response: 0.56, dampingFraction: 0.86, blendDuration: 0.0)
    static let lyric = Animation.spring(response: 0.74, dampingFraction: 0.91, blendDuration: 0.14)

    static var pageInsertion: AnyTransition {
        .opacity.combined(with: .scale(scale: 0.995, anchor: .top))
    }

    static var floatingBar: AnyTransition {
        .move(edge: .bottom).combined(with: .opacity)
    }

    static var musicPlayerExpansion: AnyTransition {
        // 整窗覆盖层不能做缩放：即使很小的 scale 也会在标题栏和窗口边缘露出系统白底。
        // 音乐展开的层次变化交给内部面板入场动画，外层只做 opacity，保证第一帧就铺满。
        .asymmetric(
            insertion: .opacity,
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

enum GlassSurfaceRenderMode {
    case material
    case efficient
    /// 最廉价档：单层填充 + 单条渐变描边，零 shadow / 零 material / 零 blendMode。
    /// 用于在列表 / 网格 / 设置分组中大量重复出现的表面，消除每元件 2 个离屏阴影通道。
    case flat
}

/// 表面语义比单个渲染档更重要：重复出现的列表/网格/设置元素必须留在 cheap 档，
/// hover/selected 也不能重新挂 material、大阴影或连续 pointer 采样。
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
}

struct SurfaceBackground: ViewModifier {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    @Environment(\.preferStaticGlassSurfaces) private var preferStaticGlassSurfaces
    @Environment(\.glassPerformanceMode) private var glassPerformanceMode
    var selected = false
    var cornerRadius: CGFloat = 12
    var thickness: Double = 1.18

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
        let radius = min(max(max(globalFrame.width, globalFrame.height) * 0.36, 108), 230)
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
    var selected = false
    var cornerRadius: CGFloat = 12
    var thickness: Double = 1.18
    var respondsToPointer = true
    var renderMode: GlassSurfaceRenderMode = .material

    var body: some View {
        if renderMode == .flat {
            flatSurface
        } else {
            richSurface
        }
    }

    /// P0：列表/网格/设置分组专用的零阴影、零 material、零 blendMode 表面。
    /// 视觉保留白玻璃底色 + 左上柔光渐变 + 冷灰渐变描边，但不产生离屏渲染通道。
    private var flatSurface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.7), 2.1)
        return shape
            .fill(AppColors.cleanPanelFill)
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
                    lineWidth: selected ? 1.05 : 0.85
                )
                .allowsHitTesting(false)
            }
            .overlay {
                // 方向性玻璃染色描边：受光面在左上，右下只留暗边。
                shape.strokeBorder(
                    AppColors.edgeLightStroke(colorScheme, depth: depth, intensity: 0.92),
                    lineWidth: 1.0
                )
            }
            .clipShape(shape)
            .shadow(color: AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.024 : 0.034) * depth), radius: 4 * depth, x: -1, y: -1)
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.16 : 0.060) * depth), radius: 8 * depth, y: 4)
    }

    @ViewBuilder
    private var richSurface: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.7), 2.1)
        let isEfficient = renderMode == .efficient

        // efficient 模式：去掉所有 blendMode(.screen) overlay，用等效直接 opacity 替代。
        // 对于浅色玻璃底色，screen blend 与直接 opacity 视觉效果几乎相同（两者都趋近于1），
        // 但消除 blendMode 可以省去每张卡片 3 个独立的 WindowServer compositing group，
        // 大幅降低海报网格滚动时的 GPU 合成压力。
        let surface = ZStack {
                if isEfficient {
                    shape.fill(AppColors.cleanPanelFill)
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
                if isEfficient {
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
                if !isEfficient {
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
                    lineWidth: 1.0
                )
            }
            .overlay(alignment: .topLeading) {
                if isEfficient {
                    shape
                        .stroke(.white.opacity((colorScheme == .dark ? 0.13 : 0.46) * depth), lineWidth: 0.55)
                } else {
                    shape
                        .stroke(.white.opacity((colorScheme == .dark ? 0.11 : 0.38) * depth), lineWidth: 0.55)
                        .blendMode(.screen)
                }
            }
            .shadow(color: AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.026 : 0.036) * depth), radius: (isEfficient ? 7 : 11) * depth, x: -2, y: -1)
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.10 : 0.026) * depth), radius: (isEfficient ? 7 : 10) * depth, y: isEfficient ? 3 : 5)

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
                                    endRadius: max(proxy.size.width, proxy.size.height) * 0.74
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
                radius: pointerLocation == nil ? 0 : 20,
                x: 0,
                y: 6
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
            content
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
    let onPointerMove: () -> Void

    func makeNSView(context: Context) -> MonitorView {
        let view = MonitorView(frame: .zero)
        view.onScroll = onScroll
        view.onPointerMove = onPointerMove
        return view
    }

    func updateNSView(_ nsView: MonitorView, context: Context) {
        nsView.onScroll = onScroll
        nsView.onPointerMove = onPointerMove
    }

    static func dismantleNSView(_ nsView: MonitorView, coordinator: ()) {
        nsView.stopMonitoring()
    }

    final class MonitorView: NSView {
        var onScroll: (() -> Void)?
        var onPointerMove: (() -> Void)?
        private var scrollMonitor: Any?
        private var pointerMonitor: Any?

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
            if let pointerMonitor {
                NSEvent.removeMonitor(pointerMonitor)
                self.pointerMonitor = nil
            }
        }

        private func startMonitoring() {
            guard scrollMonitor == nil, pointerMonitor == nil else { return }
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
            pointerMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { [weak self] event in
                guard let self,
                      let window,
                      event.window === window else {
                    return event
                }
                let point = convert(event.locationInWindow, from: nil)
                if bounds.contains(point) {
                    onPointerMove?()
                }
                return event
            }
        }

        deinit {
            stopMonitoring()
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

    func body(content: Content) -> some View {
        content
            .environment(\.suppressPointerHoverDuringScroll, isScrolling)
            .background {
                PointerScrollActivityMonitor {
                    markScrolling()
                } onPointerMove: {
                    finishScrollingSoon()
                }
                .allowsHitTesting(false)
            }
            .onDisappear {
                resetTask?.cancel()
                resetTask = nil
            }
    }

    private func markScrolling() {
        if !isScrolling {
            isScrolling = true
        }
        resetTask?.cancel()
        resetTask = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 90_000_000)
            } catch {
                return
            }
            isScrolling = false
            resetTask = nil
        }
    }

    private func finishScrollingSoon() {
        guard isScrolling else { return }
        resetTask?.cancel()
        isScrolling = false
        resetTask = nil
    }
}

struct SidebarGlassBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Rectangle()
                .fill(.ultraThinMaterial)
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
    func surfaceBackground(selected: Bool = false, cornerRadius: CGFloat = 12, thickness: Double = 1.18) -> some View {
        modifier(SurfaceBackground(selected: selected, cornerRadius: cornerRadius, thickness: thickness))
    }

    func staticSurfaceBackground(selected: Bool = false, cornerRadius: CGFloat = 12, thickness: Double = 1.18) -> some View {
        background {
            LiquidGlassSurfaceLayer(selected: selected, cornerRadius: cornerRadius, thickness: thickness, respondsToPointer: false, renderMode: GlassSurfaceRole.repeated.renderMode)
        }
        .contentShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }

    func repeatedSurfaceHover(_ active: Bool, cornerRadius: CGFloat = 12, tint: Color = AppColors.pointerLightTint, intensity: Double = 1) -> some View {
        modifier(RepeatedSurfaceHoverModifier(active: active, cornerRadius: cornerRadius, tint: tint, intensity: intensity))
    }

    func liquidGlass(cornerRadius: CGFloat = 14, selected: Bool = false, thickness: Double = 1.18) -> some View {
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

    func suppressListHighlight() -> some View {
        background(ListHighlightSuppressor())
    }
}

struct LiquidGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = 32
    var prominent = false
    var thickness: Double = 1.18

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.75), 2.0)

        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(prominent ? Color.white.opacity(isEnabled ? 0.99 : 0.86) : Color.primary.opacity(isEnabled ? 0.78 : 0.50))
            .shadow(color: prominent ? .black.opacity(isEnabled ? 0.52 : 0.30) : .clear, radius: 1.6, y: 0.9)
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background {
                ZStack {
                    // 普通页面操作按钮走 cheap 路径：静态白玻璃，不创建 material 模糊层。
                    // 强调按钮数量少且承担主操作视觉重量，保留更厚的系统蓝玻璃高光。
                    if !prominent {
                        // 非强调按钮：暖白半透明底，避免按钮底部露出冷蓝直角色块。
                        shape.fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.40 : 0.66))
                    }
                    shape.fill(
                        LinearGradient(
                            colors: prominent ? [
                                Color(nsColor: NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.98, alpha: 1.0)).opacity(isEnabled ? 1.0 : 0.90),
                                Color(nsColor: NSColor(calibratedRed: 0.00, green: 0.38, blue: 0.86, alpha: 1.0)).opacity(isEnabled ? 1.0 : 0.84),
                                Color(nsColor: NSColor(calibratedRed: 0.00, green: 0.24, blue: 0.68, alpha: 1.0)).opacity(isEnabled ? 1.0 : 0.80)
                            ] : [
                                .white.opacity((colorScheme == .dark ? 0.22 : 0.46) * depth),
                                AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.070 : 0.105) * depth),
                                AppColors.cardAquaWash.opacity(colorScheme == .dark ? 0.12 : 0.14),
                                AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.46 : 0.56)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    if prominent {
                        shape.fill(
                            LinearGradient(
                                colors: [
                                    .white.opacity(isEnabled ? 0.22 : 0.14),
                                    .clear,
                                    Color.black.opacity(isEnabled ? 0.10 : 0.06)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .blendMode(.screen)
                    }
                }
                .clipShape(shape)
            }
            .overlay(alignment: .topLeading) {
                if prominent {
                    shape
                        .strokeBorder(.white.opacity((colorScheme == .dark ? 0.20 : 0.66) * depth), lineWidth: 1.05)
                        .blur(radius: 0.55)
                        .blendMode(.screen)
                } else {
                    shape
                        .strokeBorder(.white.opacity((colorScheme == .dark ? 0.25 : 0.50) * depth), lineWidth: 0.95)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                if prominent {
                    shape
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.18 : 0.045), lineWidth: 0.9)
                        .blur(radius: 0.45)
                } else {
                    shape
                        .strokeBorder(Color.black.opacity(colorScheme == .dark ? 0.17 : 0.070), lineWidth: 0.75)
                }
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? 0.32 : 0.66) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.12 : 0.22) * depth),
                            prominent ? Color(nsColor: NSColor.systemBlue).opacity(colorScheme == .dark ? 0.30 : 0.36) : AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.12 : 0.18) * depth),
                            prominent ? .white.opacity(isEnabled ? 0.48 : 0.30) : Color.black.opacity((colorScheme == .dark ? 0.12 : 0.045) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(
                color: (prominent ? Color(nsColor: NSColor.systemBlue) : AppColors.pointerLightTint)
                    .opacity(prominent ? (colorScheme == .dark ? 0.12 : 0.16) : (colorScheme == .dark ? 0.018 : 0.014)),
                radius: prominent ? 10 : 5,
                y: prominent ? 5 : 2
            )
            .shadow(
                color: .black.opacity((colorScheme == .dark ? (prominent ? 0.18 : 0.068) : (prominent ? 0.074 : 0.034)) * depth),
                radius: prominent ? 14 : 6,
                y: prominent ? 6 : 3
            )
            .pointerLiquidEdge(cornerRadius: cornerRadius, tint: prominent ? .white : AppColors.pointerLightTint, intensity: (prominent ? 1.08 : 0.72) * depth)
            .opacity(configuration.isPressed ? 0.92 : 1)
            .animation(reduceMotion ? nil : AppMotion.fast, value: configuration.isPressed)
    }
}

struct RepeatedGlassButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 12
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = 32
    var thickness: Double = 1.0

    func makeBody(configuration: Configuration) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let depth = min(max(thickness, 0.75), 1.6)
        let pressed = configuration.isPressed

        configuration.label
            .font(.callout.weight(.medium))
            .lineLimit(1)
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.76 : 0.48))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.14 : 0.36) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.060 : 0.085) * depth),
                            AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.40 : 0.54)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
            }
            .overlay {
                shape.strokeBorder(
                    LinearGradient(
                        colors: [
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? 0.24 : 0.56) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.10 : 0.20) * depth),
                            AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.14 : 0.18) * depth),
                            Color.black.opacity((colorScheme == .dark ? 0.11 : 0.038) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 0.9
                )
            }
            .clipShape(shape)
            .contentShape(shape)
            .opacity(pressed ? 0.90 : 1)
            .animation(reduceMotion ? nil : AppMotion.fast, value: pressed)
    }
}

private struct HeaderControlGlassBackground: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat
    var highlighted = false
    var focused = false
    var accent: Color = AppColors.solarEdgeTint
    var enabled = true

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let enabledOpacity = enabled ? 1.0 : 0.58

        content
            .background {
                shape.fill(.thinMaterial)
            }
            .background {
                shape.fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.38 : 0.58))
            }
            .background {
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity(colorScheme == .dark ? 0.12 : 0.34),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.08 : 0.13),
                            AppColors.cardAquaWash.opacity(colorScheme == .dark ? 0.12 : 0.16),
                            .white.opacity(colorScheme == .dark ? 0.030 : 0.105)
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
                            .white.opacity(colorScheme == .dark ? 0.09 : (focused ? 0.26 : 0.18)),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.05 : (focused ? 0.12 : 0.07)),
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
                            .white.opacity(colorScheme == .dark ? 0.28 : 0.66),
                            AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.12 : 0.22),
                            focused ? AppColors.selectedGlassTint.opacity(colorScheme == .dark ? 0.26 : 0.24) : AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.12 : 0.18),
                            Color.black.opacity(colorScheme == .dark ? 0.10 : 0.032)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: focused ? 1.25 : 1.0
                )
            }
            .clipShape(shape)
            .shadow(color: AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.040 : (focused ? 0.060 : 0.040)), radius: highlighted ? 5 : 7, y: highlighted ? 2 : 3)
            .shadow(color: .black.opacity(colorScheme == .dark ? 0.08 : 0.026), radius: 4, y: 2)
            .opacity(enabledOpacity * (highlighted ? 0.92 : 1))
            .contentShape(shape)
    }
}

struct HeaderActionGlassButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var cornerRadius: CGFloat = 13
    var horizontalPadding: CGFloat = 12
    var minHeight: CGFloat = 34

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.callout.weight(.semibold))
            .lineLimit(1)
            .foregroundStyle(Color.primary.opacity(isEnabled ? 0.74 : 0.42))
            .padding(.horizontal, horizontalPadding)
            .frame(minHeight: minHeight)
            .modifier(HeaderControlGlassBackground(
                cornerRadius: cornerRadius,
                highlighted: configuration.isPressed,
                accent: AppColors.solarEdgeTint,
                enabled: isEnabled
            ))
            .animation(reduceMotion ? nil : AppMotion.fast, value: configuration.isPressed)
    }
}

struct GlassCapsuleControl<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isSelected: Bool
    var height: CGFloat = 28
    var horizontalPadding: CGFloat = 12
    var font: Font = .caption.weight(.semibold)
    var tint: Color = .accentColor
    /// 禁用后不挂 onContinuousHover，适用于大量并排出现的筛选胶囊，降低指针事件订阅数量。
    var enablePointerEdge: Bool = true
    @ViewBuilder var content: Content

    init(
        isSelected: Bool,
        height: CGFloat = 28,
        horizontalPadding: CGFloat = 12,
        font: Font = .caption.weight(.semibold),
        tint: Color = .accentColor,
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
        content
            .font(font)
            .lineLimit(1)
            .foregroundStyle(isSelected ? tint : Color.primary.opacity(0.70))
            .padding(.horizontal, horizontalPadding)
            .frame(height: height)
            // 在更深底色上，未选中胶囊白色填充稍加浓，视觉区分度提高。
            .background(
                Capsule()
                    .fill(isSelected ? Color.white.opacity(colorScheme == .dark ? 0.30 : 0.76) : Color.white.opacity(colorScheme == .dark ? 0.17 : 0.58))
            )
            .overlay {
                Capsule()
                    .stroke(
                        LinearGradient(
                            colors: [
                                Color(red: 1.0, green: 0.99, blue: 0.95).opacity(colorScheme == .dark ? 0.32 : 0.82),
                                AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.12 : 0.24),
                                isSelected ? tint.opacity(colorScheme == .dark ? 0.24 : 0.30) : AppColors.solarEdgeTint.opacity(colorScheme == .dark ? 0.14 : 0.18),
                                Color.black.opacity(colorScheme == .dark ? 0.10 : 0.036)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        ),
                        lineWidth: 1
                    )
            }
            .shadow(color: tint.opacity(isSelected ? (colorScheme == .dark ? 0.08 : 0.06) : 0), radius: 8, y: 3)
            .modifier(CapsulePointerEdgeModifier(enabled: enablePointerEdge, cornerRadius: height / 2, tint: tint, isSelected: isSelected))
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
            // P3：开启"降低透明度"时用不透明窗口底色，避免桌面透出；否则用原半透明白玻璃底色。
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            } else {
                AppColors.pageBackground
            }
            // P3：开启"降低透明度"时，省去半透明环境光与两层 screen 混合，只保留实色底，
            // 既尊重无障碍设置，也在该模式下消除两个页面级合成组。
            if includeDirectionalLight && !reduceTransparency {
                // 太阳光从左上柔和射入：降低高光强度、扩大过渡范围，避免左上角出现刺眼亮斑。
                RadialGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.08 : 0.18),
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.12 : 0.18),
                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.06 : 0.10),
                        .white.opacity(colorScheme == .dark ? 0.018 : 0.052),
                        .clear
                    ],
                    center: UnitPoint(x: -0.18, y: -0.24),
                    startRadius: 0,
                    endRadius: 1780
                )
                LinearGradient(
                    colors: [
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.080 : 0.115),
                        AppColors.pointerLightTint.opacity(colorScheme == .dark ? 0.045 : 0.072),
                        .white.opacity(colorScheme == .dark ? 0.012 : 0.042),
                        .clear,
                        .clear
                    ],
                    startPoint: UnitPoint(x: -0.06, y: -0.10),
                    endPoint: UnitPoint(x: 1.02, y: 0.78)
                )
                .blendMode(.screen)
                LinearGradient(
                    colors: [
                        .white.opacity(colorScheme == .dark ? 0.036 : 0.12),
                        AppColors.solarLightTint.opacity(colorScheme == .dark ? 0.050 : 0.080),
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

struct PageHeader<Actions: View>: View {
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
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .transaction { transaction in
            transaction.animation = nil
        }
    }

    private var titleCluster: some View {
        HStack(alignment: .center, spacing: 16) {
            if let systemImage {
                PlayfulSymbolIcon(systemImage: systemImage, size: 42)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(.system(size: 32, weight: .semibold))
                    .lineLimit(1)
                if let subtitle {
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actionsCluster: some View {
        HStack(spacing: 10) {
            actions
        }
        .buttonStyle(HeaderActionGlassButtonStyle(cornerRadius: 13, horizontalPadding: 12, minHeight: 34))
        .fixedSize(horizontal: true, vertical: false)
    }

    private var compactLayout: some View {
        HStack(alignment: .bottom, spacing: 20) {
            titleCluster
                .layoutPriority(1)
            Spacer(minLength: 16)
            actionsCluster
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 62, alignment: .bottom)
    }
}

struct PlayfulSymbolIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let systemImage: String
    var size: CGFloat = 40

    private var visual: MediaIconVisual {
        MediaIconVisual(systemImage: systemImage)
    }

    var body: some View {
        Group {
            if size <= 26 {
                Image(systemName: visual.symbol)
                    .symbolRenderingMode(.hierarchical)
                    .font(.system(size: size * 0.68, weight: .semibold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(nsColor: NSColor.systemBlue),
                                Color(nsColor: NSColor.systemCyan)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: size, height: size, alignment: .center)
            } else {
                ZStack {
                    if let accessory = visual.accessory, size >= 30 {
                        Image(systemName: accessory)
                            .symbolRenderingMode(.hierarchical)
                            .font(.system(size: size * 0.32, weight: .semibold))
                            .foregroundStyle(
                                LinearGradient(
                                    colors: [
                                        Color(nsColor: NSColor.systemCyan).opacity(0.70),
                                        Color(nsColor: NSColor.systemTeal).opacity(0.62)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                            .offset(x: size * 0.20, y: size * 0.20)
                    }
                    Image(systemName: visual.symbol)
                        .symbolRenderingMode(.hierarchical)
                        .font(.system(size: size * 0.62, weight: .semibold))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    Color(nsColor: NSColor.systemBlue),
                                    Color(nsColor: NSColor.systemCyan)
                                ],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            )
                        )
                        .shadow(color: Color(nsColor: NSColor.systemBlue).opacity(colorScheme == .dark ? 0.18 : 0.12), radius: size * 0.08, y: size * 0.03)
                        .offset(visual.symbolOffset)

                    if visual.family == .video {
                        SchemeOneWave()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color(nsColor: NSColor.systemCyan).opacity(0.48),
                                        Color(nsColor: NSColor.systemBlue).opacity(0.18)
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
        switch palette {
        case .video:
            return [Color(nsColor: .systemCyan), Color(nsColor: .systemBlue), Color(nsColor: .systemIndigo)]
        case .music:
            return [Color(nsColor: .systemBlue), Color(nsColor: .systemCyan), Color(nsColor: .systemTeal)]
        case .source:
            return [Color(nsColor: .systemTeal), Color(nsColor: .systemBlue), Color(nsColor: .systemGreen)]
        case .vault:
            return [Color(nsColor: .systemIndigo), Color(nsColor: .systemBlue), Color(nsColor: .systemTeal)]
        case .settings:
            return [Color(nsColor: .systemBlue), Color(nsColor: .systemCyan), Color(nsColor: .systemTeal)]
        case .metadata:
            return [Color(nsColor: .systemCyan), Color(nsColor: .systemTeal), Color(nsColor: .systemMint)]
        case .status:
            return [Color(nsColor: .systemBlue), Color(nsColor: .systemCyan), Color(nsColor: .systemTeal)]
        case .warm:
            return [Color(nsColor: .systemCyan), Color(nsColor: .systemBlue), Color(nsColor: .systemMint)]
        case .gold:
            return [Color(nsColor: .systemCyan), Color(nsColor: .systemTeal), Color(nsColor: .systemBlue)]
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
    @State private var isFocused = false
    let placeholder: String
    @Binding var text: String
    var thickness: Double = 1.28

    var body: some View {
        let depth = min(max(thickness, 0.8), 2.0)
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TransparentSearchTextField(placeholder: placeholder, text: $text, isFocused: $isFocused)
                .frame(height: 20)
            if !text.isEmpty {
                Button {
                    text = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .pointerLiquidEdge(cornerRadius: 9, intensity: 0.62 * depth)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 9)
        .frame(width: 260)
        .modifier(HeaderControlGlassBackground(
            cornerRadius: 18,
            focused: isFocused,
            accent: AppColors.solarEdgeTint,
            enabled: true
        ))
        .pointerLiquidEdge(cornerRadius: 18, intensity: (isFocused ? 1.22 : 1.04) * depth)
        .animation(AppMotion.fast, value: isFocused)
    }
}

private struct GlassFormFieldModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
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
            .frame(minHeight: 32)
            // 表单输入会在设置/弹层里重复出现，用静态玻璃填充保留观感并避免实时采样。
            .background(
                shape.fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.86 : 0.78))
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
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.095 : 0.046) * depth), radius: 5.5, y: 3)
            .pointerLiquidEdge(cornerRadius: cornerRadius, intensity: (isFocused ? 1.16 : 0.86) * depth)
            .animation(AppMotion.fast, value: isFocused)
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
    let title: String
    var width: CGFloat = 150
    var thickness: Double = 1.22
    @ViewBuilder var menuItems: MenuItems

    init(title: String, width: CGFloat = 150, thickness: Double = 1.22, @ViewBuilder menuItems: () -> MenuItems) {
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
            .frame(width: width, height: 32)
            // 菜单按钮会在页头和来源行重复出现，这里避免创建实时 material 层。
            .background(
                shape.fill(AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.86 : 0.78))
            )
            .background(
                shape.fill(
                    LinearGradient(
                        colors: [
                            .white.opacity((colorScheme == .dark ? 0.24 : 0.50) * depth),
                            AppColors.solarLightTint.opacity((colorScheme == .dark ? 0.08 : 0.12) * depth),
                            AppColors.cleanFieldFill.opacity(colorScheme == .dark ? 0.58 : 0.72),
                            .white.opacity((colorScheme == .dark ? 0.07 : 0.24) * depth)
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
                            Color(red: 1.0, green: 0.99, blue: 0.95).opacity((colorScheme == .dark ? 0.32 : 0.88) * depth),
                            .white.opacity((colorScheme == .dark ? 0.14 : 0.30) * depth),
                            AppColors.solarEdgeTint.opacity((colorScheme == .dark ? 0.14 : 0.18) * depth),
                            Color.black.opacity((colorScheme == .dark ? 0.12 : 0.044) * depth)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1
                )
            }
            .clipShape(shape)
            .shadow(color: .black.opacity((colorScheme == .dark ? 0.10 : 0.030) * depth), radius: 6 * depth, y: 3)
            .pointerLiquidEdge(cornerRadius: 9, intensity: 1.04 * depth)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }
}

enum ArtworkImageCache {
    private static let cache = NSCache<NSString, NSImage>()
    private static let remoteStore = ArtworkRemoteImageStore(
        maxConcurrentFetches: 4,
        maxDiskCacheBytes: 256 * 1024 * 1024,
        maxDiskCacheFiles: 1600
    )
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
        // 提高缓存上限，减少滚动时封面被驱逐后重新解码导致的掉帧与闪烁。
        cache.countLimit = 520
        cache.totalCostLimit = 72 * 1024 * 1024
    }

    static func cachedImage(path: String?, targetSize: CGSize? = nil) -> NSImage? {
        configureIfNeeded()
        guard let path else { return nil }
        lock.lock()
        let isMissing = cachedMissingPathIsFresh(path)
        lock.unlock()
        guard !isMissing else { return nil }
        return cache.object(forKey: cacheKey(path: path, targetSize: targetSize))
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
        guard FileManager.default.fileExists(atPath: path),
              let image = downsampledImage(path: path, targetSize: targetSize ?? defaultTargetSize) else {
            lock.lock()
            storeMissingPathLocked(path, isRemote: false)
            lock.unlock()
            return nil
        }
        let pixelCost = image.pixelCost
        cache.setObject(image, forKey: key, cost: pixelCost)
        lock.lock()
        storeAspectRatioLocked(normalizedAspectRatio(for: image), path: path)
        lock.unlock()
        return image
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
        let decoded = await Task.detached(priority: .utility) {
            SendableArtworkImage(downsampledImage(data: data, targetSize: targetSize))
        }.value.image
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
        let scale = NSScreen.main?.backingScaleFactor ?? 2
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

        let scale = NSScreen.main?.backingScaleFactor ?? 2
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

private actor ArtworkRemoteImageStore {
    private let maxConcurrentFetches: Int
    private let maxDiskCacheBytes: Int
    private let maxDiskCacheFiles: Int
    private let cacheDirectory: URL?
    private var activeFetches = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var inFlightRequests: [String: Task<Data?, Never>] = [:]

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
        if let cached = diskData(cacheID: cacheID, maxBytes: maxBytes) {
            return cached
        }

        if let task = inFlightRequests[cacheID] {
            return await task.value
        }

        let task = Task<Data?, Never> {
            await acquire()
            defer { release() }
            if Task.isCancelled { return nil }
            return await fetchAndStore(cacheID: cacheID, url: url, timeout: timeout, maxBytes: maxBytes)
        }
        inFlightRequests[cacheID] = task
        let data = await task.value
        inFlightRequests.removeValue(forKey: cacheID)
        return data
    }

    func remove(cacheID: String) {
        guard let url = cacheFileURL(cacheID: cacheID) else { return }
        try? FileManager.default.removeItem(at: url)
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

    private func diskData(cacheID: String, maxBytes: Int) -> Data? {
        guard let url = cacheFileURL(cacheID: cacheID),
              let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let fileSize = attributes[.size] as? NSNumber,
              fileSize.intValue > 0,
              fileSize.intValue <= maxBytes,
              let data = try? Data(contentsOf: url, options: [.mappedIfSafe]) else {
            return nil
        }
        touch(url)
        return data
    }

    private func fetchAndStore(cacheID: String, url: URL, timeout: TimeInterval, maxBytes: Int) async -> Data? {
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

            if let fileURL = cacheFileURL(cacheID: cacheID) {
                try? data.write(to: fileURL, options: [.atomic])
                touch(fileURL)
                pruneDiskCacheIfNeeded()
            }
            return data
        } catch {
            return nil
        }
    }

    private func cacheFileURL(cacheID: String) -> URL? {
        cacheDirectory?.appendingPathComponent("\(cacheID).img", isDirectory: false)
    }

    private func touch(_ url: URL) {
        try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
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
