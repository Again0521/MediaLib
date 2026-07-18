import AppKit
import SwiftUI

/// 侧栏底板：**浅白实底**（参考 `doc/MediaLIB 系统页面.html`），不再使用 `.sidebar`
/// behind-window 透明毛玻璃 / 桌面壁纸透过。
///
/// - 浅色：`#FBFCFE → #F8FAFD` 纵向浅蓝白渐变（贴近内容区白卡，干净不透明）。
/// - 深色：中性深灰实底渐变。
/// - 右缘一条极淡分隔线（浅色 `#E9EDF4`）与内容区分界。
///
/// 只是一层底板，不承载内容，图标、文字与交互不受影响。`reduceTransparency` 保留在签名里
/// 以兼容调用点，但本实现无论如何都是实底，天然满足 Reduce Transparency。
struct NativeSidebarMaterialBackground: View {
    let reduceTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let isDark = colorScheme == .dark
        let top = isDark
            ? Color(red: 0.114, green: 0.129, blue: 0.157)   // #1D2128
            : Color(red: 0.984, green: 0.988, blue: 0.996)   // #FBFCFE
        let bottom = isDark
            ? Color(red: 0.094, green: 0.106, blue: 0.133)   // #181B22
            : Color(red: 0.961, green: 0.973, blue: 0.992)   // #F5F8FD
        let divider = isDark
            ? Color.white.opacity(0.06)
            : Color(red: 0.914, green: 0.929, blue: 0.957)   // #E9EDF4

        LinearGradient(colors: [top, bottom], startPoint: .top, endPoint: .bottom)
            .overlay(alignment: .trailing) {
                Rectangle()
                    .fill(divider)
                    .frame(width: 1)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }
}
