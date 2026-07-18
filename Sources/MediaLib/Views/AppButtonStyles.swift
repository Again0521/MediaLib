import SwiftUI

// MARK: - 方向 C 统一按钮三件套
//
// 全 app（音乐展开页 / 视频播放器窗口除外）只允许这三种按钮：
//   · AppPrimaryButtonStyle   —— 每屏最多一个强调动作（立即播放 / 添加媒体源 / 保存）。
//   · AppStandardButtonStyle  —— 常规动作（扫描 / 选择 / 外部打开 / 弹窗次要键）。
//   · AppPlainIconButtonStyle —— 无底图标钮（行内动作 / 工具栏图标）。
//
// 它们是「唯一入口」：此前散落的 LiquidGlassButtonStyle / RepeatedGlassButtonStyle /
// AppSheetPrimary·Secondary / HeaderAction·Prominent / HomeHero·Vault·Carousel 等在 C-R2 逐页迁移到这三种后删除。
// 风格感知：读 `@Environment(\.appUIStyle)`——`.vivid` 走当前玻璃 / 品牌渐变观感（零漂移）；
// `.native` 分支在实现原生皮肤时补齐（当前暂同 vivid，保证可编译且不改观感）。

/// 强调主按钮。品牌渐变实心（vivid）。
struct AppPrimaryButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = AppRadius.control
    var horizontalPadding: CGFloat = 20
    var minHeight: CGFloat = AppControlMetrics.prominentButtonHeight
    @Environment(\.appUIStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        // native 皮肤未落地前与 vivid 同渲染，避免类型分叉；实现原生时在此按 style.tokens.primaryUsesBrandGradient 分流。
        LiquidGlassButtonStyle(
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight,
            prominent: true
        )
        .makeBody(configuration: configuration)
    }
}

/// 常规按钮。玻璃胶囊（vivid）。
struct AppStandardButtonStyle: ButtonStyle {
    var cornerRadius: CGFloat = AppRadius.control
    var horizontalPadding: CGFloat = 18
    var minHeight: CGFloat = AppControlMetrics.defaultButtonHeight
    /// 弹窗次要键等需要白底描边强调「次」层级时置 true。
    var outlined: Bool = false
    @Environment(\.appUIStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        LiquidGlassButtonStyle(
            cornerRadius: cornerRadius,
            horizontalPadding: horizontalPadding,
            minHeight: minHeight,
            prominent: false,
            outlined: outlined
        )
        .makeBody(configuration: configuration)
    }
}

/// 无底图标钮。hover 轻提亮，无布局位移。
struct AppPlainIconButtonStyle: ButtonStyle {
    var minSize: CGFloat = 28
    @Environment(\.appUIStyle) private var style

    func makeBody(configuration: Configuration) -> some View {
        SubtleIconButtonStyle(minSize: minSize)
            .makeBody(configuration: configuration)
    }
}

extension ButtonStyle where Self == AppPrimaryButtonStyle {
    /// 便捷取值：`.buttonStyle(.appPrimary)`。
    static var appPrimary: AppPrimaryButtonStyle { AppPrimaryButtonStyle() }
}

extension ButtonStyle where Self == AppStandardButtonStyle {
    static var appStandard: AppStandardButtonStyle { AppStandardButtonStyle() }
    /// 弹窗次要键：白底描边的「次」层级。
    static var appStandardOutlined: AppStandardButtonStyle { AppStandardButtonStyle(outlined: true) }
}

extension ButtonStyle where Self == AppPlainIconButtonStyle {
    static var appPlainIcon: AppPlainIconButtonStyle { AppPlainIconButtonStyle() }
}
