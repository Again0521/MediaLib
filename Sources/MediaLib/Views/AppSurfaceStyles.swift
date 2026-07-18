import SwiftUI

// MARK: - 方向 C 表面两档 + 语义四值
//
// 治「卡片汤」：普通页面表面只允许两档层级——
//   L1 重复表面（appStandardSurface）：描边 + 极轻填充，**无投影**。用于列表行 / 设置行 / 监测行等重复元素。
//   L2 独立卡片（appCardSurface）：填充 + **单档**柔和阴影。仅少量独立卡（统计磁贴 / 媒体源卡 / 仪表盘卡）使用。
// 弹窗 / 菜单 / Toast 的材质投影另属 L2 悬浮物范畴，沿用既有组件。
// 风格感知：`.native` 皮肤下 L2 也退为扁平（`cardShadowOpacity = 0`）。

extension AppColors {
    /// 状态语义四值唯一入口（固定鲜明色，不随主题变灰）。徽章 / 状态点 / 提示统一取用。
    static var semanticGood: Color { AuroraPalette.semanticGood }
    static var semanticWarning: Color { AuroraPalette.semanticWarning }
    static var semanticDanger: Color { AuroraPalette.semanticDanger }
    static var semanticInfo: Color { AuroraPalette.semanticInfo }
}

/// L1 重复表面：描边 + 极轻填充，无投影。
private struct AppStandardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .background {
                shape.fill(AppColors.refCardBg.opacity(colorScheme == .dark ? 0.55 : 0.72))
                    .overlay(shape.fill(Color.primary.opacity(0.04)))
            }
            .overlay {
                shape.strokeBorder(AppColors.refCardBorder, lineWidth: AppGlassMetrics.Stroke.hairline)
            }
            .clipShape(shape)
    }
}

/// L2 独立卡片：填充 + 单档柔和阴影（`.native` 皮肤下退扁平）。
private struct AppCardSurfaceModifier: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.appUIStyle) private var style
    let cornerRadius: CGFloat

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        let shadowOpacity = style.tokens.cardShadowOpacity
        return content
            .background {
                shape.fill(AppColors.refCardBg)
            }
            .overlay {
                shape.strokeBorder(AppColors.refCardBorder, lineWidth: AppGlassMetrics.Stroke.surface)
            }
            .clipShape(shape)
            .shadow(
                color: AppColors.refCardShadow.opacity(shadowOpacity),
                radius: AppGlassMetrics.Shadow.surfaceRadius,
                x: 0,
                y: AppGlassMetrics.Shadow.surfaceY
            )
    }
}

/// 唯一徽章/胶囊规格。此前 AppStatusBadge（渐变+caption2）与 AppSectionHeading 内联徽章（扁平+caption，
/// padding 9/5）两套并存；统一为：Caption(11) semibold + 扁平染色填充 + 发丝描边 + 8/4 内边距。
private struct AppPillBadgeStyle: ViewModifier {
    @Environment(\.colorScheme) private var colorScheme
    let tint: Color

    func body(content: Content) -> some View {
        content
            .font(.appCaption(.semibold))
            .foregroundStyle(tint.opacity(0.95))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(tint.opacity(colorScheme == .dark ? 0.18 : 0.12), in: Capsule(style: .continuous))
            .overlay {
                Capsule(style: .continuous)
                    .strokeBorder(tint.opacity(colorScheme == .dark ? 0.32 : 0.26), lineWidth: AppGlassMetrics.Stroke.hairline)
            }
            .fixedSize()
    }
}

extension View {
    /// 统一徽章外观：染色胶囊 + 发丝描边。传语义四值（AppColors.semanticGood/Warning/Danger/Info）或区块色。
    func appPillBadge(tint: Color) -> some View {
        modifier(AppPillBadgeStyle(tint: tint))
    }

    /// L1 重复表面：描边 + 极轻填充，无投影。用于列表 / 设置 / 监测等重复行，替换旧「白卡 + 投影」。
    func appStandardSurface(cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppStandardSurfaceModifier(cornerRadius: cornerRadius))
    }

    /// L2 独立卡片：填充 + 单档柔和阴影。仅少量独立卡片使用。
    func appCardSurface(cornerRadius: CGFloat = AppRadius.card) -> some View {
        modifier(AppCardSurfaceModifier(cornerRadius: cornerRadius))
    }
}
