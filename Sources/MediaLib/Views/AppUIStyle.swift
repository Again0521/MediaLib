import SwiftUI

/// 全 app 非音乐界面的「形态语言」皮肤轴。
///
/// 与另外两条既有轴**正交**：
/// - 配色主题 `AppThemePreset`（暮山紫 / 珊瑚 / …）——只换颜色，不换形态；
/// - 音乐皮肤 `MusicThemeConfig`（琉璃 / 无界 / 湖光）——只作用于音乐展开页。
///
/// 本轴决定普通页面的**形态**：图标是彩色渐变芯片还是 SF Symbols 单色、按钮是玻璃/品牌渐变还是系统 bordered、
/// 重复表面是否投影、页头图标体量等。方向 C（品牌沉浸）默认 `.vivid`；后续可实现 `.native`（原生克制，方向 A 骨架），
/// 用户在设置里一键切换即整套换形态，而配色主题与音乐皮肤保持不变。
///
/// 落地策略：所有普通页面组件从 `AppStyleTokens` 读取形态决策（下方 flag），不再在各处散落 if；
/// 目前两种风格都能编译，`.vivid` 一切等于当前观感（零视觉漂移），`.native` 分支逐轮补齐。
/// ⚠ 音乐展开页 / 视频播放器窗口不读本轴，天然隔离。
enum AppUIStyle: String, CaseIterable, Codable, Sendable {
    /// 当前活力多彩品牌风（方向 C 默认）。
    case vivid
    /// 预留：向系统原生克制靠拢（方向 A 骨架，后续逐轮实现）。
    case native

    var displayName: String {
        switch self {
        case .vivid: return "活力"
        case .native: return "原生"
        }
    }

    /// 全局生效风格；由 AppState 在启动 / 设置变更时写入，供非 View 代码（如 AppColors 派生）读取。
    /// 默认 `.vivid`。View 树内优先用 `@Environment(\.appUIStyle)`，两者在 C-R0 一致。
    static var active: AppUIStyle = .vivid

    /// 已解析的形态 token。普通页面组件只读这里，不各自判断 `self`。
    var tokens: AppStyleTokens {
        switch self {
        case .vivid:
            return AppStyleTokens(
                kind: .vivid,
                usesColoredIconChips: true,
                primaryUsesBrandGradient: true,
                standardUsesGlass: true,
                repeatedSurfaceElevated: false,   // C 决策：重复行去投影改描边（治「卡片汤」），活力风也遵守
                cardShadowOpacity: 1.0,
                pageHeaderIconSize: 44,
                sidebarIconSize: 20
            )
        case .native:
            return AppStyleTokens(
                kind: .native,
                usesColoredIconChips: false,
                primaryUsesBrandGradient: false,
                standardUsesGlass: false,
                repeatedSurfaceElevated: false,
                cardShadowOpacity: 0.0,
                pageHeaderIconSize: 22,
                sidebarIconSize: 16
            )
        }
    }
}

/// 已解析的形态决策。数值/布尔皮肤参数集中在此，普通页面组件按需读取。
struct AppStyleTokens: Equatable, Sendable {
    var kind: AppUIStyle
    /// 图标语言：true = 彩色渐变芯片（活力），false = SF Symbols 单色（原生）。
    var usesColoredIconChips: Bool
    /// Primary 按钮填充：true = 品牌渐变，false = 系统 accent 实心。
    var primaryUsesBrandGradient: Bool
    /// Standard 按钮外观：true = 玻璃，false = 系统 bordered。
    var standardUsesGlass: Bool
    /// 重复表面（列表行 / 设置行 / 监测行）是否抬升带投影：C 恒 false（描边 + 极轻填充）。
    var repeatedSurfaceElevated: Bool
    /// 独立卡片阴影强度系数（0 = 扁平，1 = 单档标准阴影）。
    var cardShadowOpacity: Double
    /// 页头主图标边长。
    var pageHeaderIconSize: CGFloat
    /// 侧栏项图标边长。
    var sidebarIconSize: CGFloat
}

private struct AppUIStyleKey: EnvironmentKey {
    static let defaultValue: AppUIStyle = .vivid
}

extension EnvironmentValues {
    var appUIStyle: AppUIStyle {
        get { self[AppUIStyleKey.self] }
        set { self[AppUIStyleKey.self] = newValue }
    }
}

extension View {
    /// 覆盖子树的形态风格（设置预览 / 分屏对照用）。全局默认由 `AppUIStyle.active` 决定。
    func appUIStyle(_ style: AppUIStyle) -> some View {
        environment(\.appUIStyle, style)
    }
}
