import AppKit
import SwiftUI

struct PrivacyLockView: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var entry = ""
    @State private var pendingNewPIN: String?
    @State private var errorMessage: String?
    @State private var failedAttempt = 0

    var body: some View {
        // 用滚动容器承载居中面板：与其它详情页（都含 ScrollView）保持一致的顶部安全区/标题栏预留，
        // 这样 NavigationSplitView 不会因为「静态详情页不预留标题栏」而收掉共享顶部安全区、把左侧栏顶上去。
        // 深色渐变背景单独 ignoresSafeArea 铺满（含标题栏后方），但内容仍在安全区内布局。
        GeometryReader { proxy in
            ScrollView(.vertical) {
                VStack(spacing: 0) {
                    Spacer(minLength: 0)
                    lockPanel
                        .padding(.horizontal, 40)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity)
                .frame(minHeight: proxy.size.height)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 26 / 255, green: 34 / 255, blue: 54 / 255),
                        Color(red: 14 / 255, green: 19 / 255, blue: 34 / 255)
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()
            )
        }
        .contentShape(Rectangle())
        .modifier(VaultKeyboardMonitor(onKeyDown: handleKeyDown))
        .onAppear {
            resetEntry(clearSetup: !appState.privacyPINConfigured)
        }
        .onChange(of: appState.privacyPINConfigured) { configured in
            resetEntry(clearSetup: !configured)
        }
    }

    private var lockPanel: some View {
        VStack(alignment: .center, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(AppColors.refProminentGradient)
                    .shadow(color: AppColors.refProminentStart.opacity(0.60), radius: 25, x: 0, y: 14)
                VividIcon(name: "lock", size: 38, lineWidth: 2.2)
                    .foregroundStyle(.white)
            }
            .frame(width: 84, height: 84)
            .padding(.bottom, 26)

            Text(titleText)
                .font(.system(size: 24, weight: .heavy))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text(subtitleText)
                .font(.system(size: 13.5, weight: .medium))
                .foregroundStyle(.white.opacity(0.58))
                .lineSpacing(5)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 12)

            vaultDots
                .padding(.top, 28)
                .modifier(VaultShakeEffect(animatableData: CGFloat(failedAttempt)))

            if let errorMessage {
                Text(errorMessage)
                    .font(.system(size: 12.5, weight: .bold))
                    .foregroundStyle(Color(red: 1.0, green: 0.47, blue: 0.58))
                    .multilineTextAlignment(.center)
                    .padding(.top, 14)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if appState.privacyPINConfigured, appState.privacyBiometricsAvailable {
                helperControls
                    .padding(.top, 24)
            }
        }
        .frame(maxWidth: 410, alignment: .center)
        .animation(reduceMotion ? nil : AppMotion.fast, value: appState.privacyPINConfigured)
        .animation(reduceMotion ? nil : AppMotion.fast, value: errorMessage)
    }

    private var titleText: String {
        if appState.privacyPINConfigured {
            return "\(appState.settings.privacyVaultName)已锁定"
        }
        return pendingNewPIN == nil ? "设置保险库密码" : "再次输入密码"
    }

    private var subtitleText: String {
        if appState.privacyPINConfigured {
            return "直接输入 4-8 位数字密码，正确后会自动解锁；按 Return 可确认当前输入。"
        }
        if let pendingNewPIN {
            return "再次输入刚才的 \(pendingNewPIN.count) 位密码。匹配后会立即完成设置并解锁。"
        }
        return "输入 4-8 位数字密码后按 Return 进入确认。密码验证信息只保存在本机。"
    }

    private var dotCount: Int {
        max(4, entry.count)
    }

    private var vaultDots: some View {
        HStack(spacing: 12) {
            ForEach(0..<dotCount, id: \.self) { index in
                Circle()
                    .fill(index < entry.count ? .white : .clear)
                    .overlay {
                        Circle()
                            .strokeBorder(.white.opacity(index < entry.count ? 0.92 : 0.34), lineWidth: 2)
                    }
                    .frame(width: 14, height: 14)
                    .scaleEffect(index < entry.count ? 1.08 : 0.96)
                    .transition(.scale(scale: 0.72).combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .animation(reduceMotion ? AppMotion.reducedFeedback : AppMotion.fast, value: dotCount)
        .animation(reduceMotion ? AppMotion.reducedFeedback : AppMotion.immediate, value: entry.count)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("密码输入")
        .accessibilityValue("已输入 \(entry.count) 位")
    }

    @ViewBuilder
    private var helperControls: some View {
        Button {
            appState.unlockPrivacyWithBiometrics()
        } label: {
            Label("Touch ID", systemImage: "touchid")
        }
        .buttonStyle(VaultPrimaryButtonStyle())
    }

    /// 返回值表示这一键是否被口令输入消费掉了。
    ///
    /// 没消费的键必须原样放回去：⌘Q、⌘W、⌘H 这些仍然要能用，锁屏不是一个把整个
    /// 应用的键盘吞掉的地方。
    private func handleKeyDown(_ event: NSEvent) -> Bool {
        // 带 Command 的一律放行——它们是应用级快捷键，不是口令。
        guard !event.modifierFlags.contains(.command) else { return false }
        switch event.keyCode {
        case 36, 76:
            handleReturn()
        case 51, 117:
            removeLastDigit()
        case 53:
            resetEntry(clearSetup: false)
        default:
            guard let digit = event.charactersIgnoringModifiers?.first, digit.isNumber else { return false }
            appendDigit(String(digit))
        }
        return true
    }

    private func appendDigit(_ digit: String) {
        guard entry.count < 8 else { return }
        if errorMessage != nil {
            withAnimation(AppMotion.fast) {
                errorMessage = nil
            }
        }
        entry.append(digit)

        if appState.privacyPINConfigured {
            if PrivacyLockService.isValidPIN(entry) {
                unlockPIN(entry, reportFailure: false)
            }
            return
        }

        if let pendingNewPIN, entry == pendingNewPIN, PrivacyLockService.isValidPIN(entry) {
            createPIN(entry)
        }
    }

    private func removeLastDigit() {
        guard !entry.isEmpty else { return }
        entry.removeLast()
        errorMessage = nil
    }

    private func handleReturn() {
        if appState.privacyPINConfigured {
            guard PrivacyLockService.isValidPIN(entry) else {
                reportError("密码不正确，请重新输入。")
                return
            }
            unlockPIN(entry, reportFailure: true)
            return
        }

        if let pendingNewPIN {
            guard entry == pendingNewPIN, PrivacyLockService.isValidPIN(entry) else {
                reportError("两次密码不一致，请重新确认。")
                return
            }
            createPIN(entry)
        } else {
            guard PrivacyLockService.isValidPIN(entry) else {
                reportError("请输入 4 到 8 位数字密码。")
                return
            }
            pendingNewPIN = entry
            withAnimation(AppMotion.fast) {
                entry = ""
                errorMessage = nil
            }
        }
    }

    private func createPIN(_ value: String) {
        Task { @MainActor in
            if await appState.setPrivacyPINAsync(value) {
                resetEntry(clearSetup: true)
            }
        }
    }

    private func unlockPIN(_ value: String, reportFailure: Bool) {
        Task { @MainActor in
            if await appState.unlockPrivacyIfPINMatchesAsync(value) {
                resetEntry(clearSetup: false)
            } else if reportFailure {
                reportError("密码不正确，请重新输入。")
            }
        }
    }

    private func reportError(_ message: String) {
        failedAttempt += 1
        withAnimation(AppMotion.fast) {
            errorMessage = message
            entry = ""
        }
    }

    private func resetEntry(clearSetup: Bool) {
        withAnimation(AppMotion.fast) {
            entry = ""
            errorMessage = nil
            if clearSetup {
                pendingNewPIN = nil
            }
        }
    }
}

/// 保险库口令的键盘输入。
///
/// 这里从前是一个 1×1、不透明度 0.01 的 `NSView` 去抢 first responder，再用
/// `keyDown` 收键，并在点击、出现、状态变化时反复 `makeFirstResponder` 把焦点抢
/// 回来。它收不到键。
///
/// 同一个根因在这个产品里已经出现过一次——视频播放器的快捷键当初也是这么写的。
/// 一个没有尺寸、不在正常响应链上的视图能不能拿到 first responder，取决于窗口有
/// 没有成为 key、SwiftUI 之后有没有把焦点移走，这两件事都不在这段代码的掌控里；
/// 而 `makeFirstResponder` 失败时不抛错、不返回可见信号，于是表现就是"键盘没反应"
/// 且毫无线索。
///
/// 改成窗口级的本地事件监听：谁持有 first responder 都不影响收键，也不再需要那
/// 一串把焦点抢回来的调用。
private struct VaultKeyboardMonitor: ViewModifier {
    let onKeyDown: (NSEvent) -> Bool

    @State private var monitor: Any?

    func body(content: Content) -> some View {
        content
            .onAppear {
                guard monitor == nil else { return }
                monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                    onKeyDown(event) ? nil : event
                }
            }
            .onDisappear {
                if let monitor { NSEvent.removeMonitor(monitor) }
                monitor = nil
            }
    }
}

private struct VaultShakeEffect: GeometryEffect {
    var animatableData: CGFloat

    func effectValue(size: CGSize) -> ProjectionTransform {
        ProjectionTransform(CGAffineTransform(translationX: sin(animatableData * .pi * 4) * 7, y: 0))
    }
}

private struct VaultPrimaryButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 14, weight: .heavy))
            .foregroundStyle(Color(red: 26 / 255, green: 34 / 255, blue: 54 / 255))
            .padding(.horizontal, 22)
            .frame(height: 46)
            .background(.white, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .opacity(isEnabled ? (configuration.isPressed ? 0.82 : 1) : 0.42)
            .scaleEffect(!reduceMotion && configuration.isPressed ? 0.98 : 1)
            .offset(y: !reduceMotion && configuration.isPressed ? 1 : 0)
            .animation(reduceMotion ? AppMotion.reducedFeedback : AppMotion.immediate, value: configuration.isPressed)
    }
}
