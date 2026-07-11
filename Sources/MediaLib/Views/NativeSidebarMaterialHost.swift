import AppKit
import SwiftUI

/// 侧栏的唯一底板：原生 `.sidebar` 材质 + 极轻冷中性纱层。作为侧栏内容的 background 使用，
/// 配合 `.ignoresSafeArea()` 连同隐藏标题栏那条安全区一起铺满，整列材质完全一致。
/// 只是一层底板，不承载内容，图标、文字与交互不受影响。
///
/// `.sidebar` 在部分蓝色桌面上会把采样色推向青绿；这里不用混合模式或通道乘法与系统
/// vibrancy 对抗，而是在材质上加一层低不透明度的冷中性纱，维持墙纸透过与高斯模糊，
/// 同时将综合色相拉回蓝灰。其余侧栏样式不参与这层校正。
struct NativeSidebarMaterialBackground: View {
    let reduceTransparency: Bool
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            SidebarVisualEffectView(reduceTransparency: reduceTransparency)
            // 分成提亮底与极轻蓝灰校正：单独冷色纱会在浅色页面旁显灰；白底先恢复原生
            // sidebar 的明度，再用极小的蓝灰量抵消蓝色壁纸被材质推向青绿的偏移。
            // 两层都在材质之上，底层仍负责实时高斯模糊与壁纸透过。
            if !reduceTransparency {
                if colorScheme == .dark {
                    Color.black.opacity(0.08)
                } else {
                    // 保留足够亮度以贴近纯白内容区，同时让 `.behindWindow` 的壁纸模糊仍可读。
                    Color.white.opacity(0.42)
                    Color(red: 0.93, green: 0.96, blue: 1.0).opacity(0.02)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

private struct SidebarVisualEffectView: NSViewRepresentable {
    let reduceTransparency: Bool

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
    }

    private func configure(_ materialView: NSVisualEffectView) {
        materialView.material = .sidebar
        materialView.blendingMode = reduceTransparency ? .withinWindow : .behindWindow
        materialView.state = .active
        materialView.isEmphasized = false
        // 必须保持 1.0：NSVisualEffectView（或其祖先）alphaValue < 1 会让系统放弃
        // 高斯模糊采样，底板退化成一层不模糊的透色——正是曾经"只有标题栏那条有模糊"的根因。
        materialView.alphaValue = 1
    }
}
