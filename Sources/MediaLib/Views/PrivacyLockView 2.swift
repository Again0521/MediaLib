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
        ZStack {
            LinearGradient(
                colors: [
                    Color(red: 26 / 255, green: 34 / 255, blue: 54 / 255),
                    Color(red: 14 / 255, green: 19 / 255, blue: 34 / 255)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            lockPanel
                .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .topLeading) {
            VaultKeyboardCaptureView(onKeyDown: handleKeyDown)
                .frame(width: 1, height: 1)
                .opacity(0.01)
                .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            VaultKeyboardFocusRelay.refocus()
        }
        .onAppear {
            resetEntry(clearSetup: !appState.privacyPINConfigured)
            VaultKeyboardFocusRelay.refocus()
        }
        .onChange(of: appState.privacyPINConfigured) { configured in
            resetEntry(clearSetup: !configured)
            VaultKeyboardFocusRelay.refocus()
        }
    }

    private var lockPanel: some View {
        VStack(alignment: .center, spacing: 0) {
            ZStack {
                RoundedRectangle(cornerRadius: 26, style: .continuous)
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
        .animation(reduceMotion ? nil : .spring(response: 0.24, dampingFraction: 0.76), value: dotCount)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: entry.count)
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

    private func handleKeyDown(_ event: NSEvent) {
        let keyCode = event.keyCode
        switch keyCode {
        case 36, 76:
            handleReturn()
        case 51, 117:
            removeLastDigit()
        case 53:
            resetEntry(clearSetup: false)
        default:
            guard let digit = event.charactersIgnoringModifiers?.first, digit.isNumber else { return }
            appendDigit(String(digit))
        }
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
            if PrivacyLockService.isValidPIN(entry), appState.unlockPrivacyIfPINMatches(entry) {
                resetEntry(clearSetup: false)
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
            guard PrivacyLockService.isValidPIN(entry), appState.unlockPrivacyIfPINMatches(entry) else {
                reportError("密码不正确，请重新输入。")
                return
            }
            resetEntry(clearSetup: false)
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
        if appState.setPrivacyPIN(value) {
            resetEntry(clearSetup: true)
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

private enum VaultKeyboardFocusRelay {
    weak static var current: VaultKeyboardCaptureNSView?

    static func refocus() {
        DispatchQueue.main.async {
            current?.window?.makeFirstResponder(current)
        }
    }
}

private struct VaultKeyboardCaptureView: NSViewRepresentable {
    var onKeyDown: (NSEvent) -> Void

    func makeNSView(context: Context) -> VaultKeyboardCaptureNSView {
        let view = VaultKeyboardCaptureNSView()
        view.onKeyDown = onKeyDown
        VaultKeyboardFocusRelay.current = view
        return view
    }

    func updateNSView(_ nsView: VaultKeyboardCaptureNSView, context: Context) {
        nsView.onKeyDown = onKeyDown
        VaultKeyboardFocusRelay.current = nsView
        VaultKeyboardFocusRelay.refocus()
    }
}

private final class VaultKeyboardCaptureNSView: NSView {
    var onKeyDown: (NSEvent) -> Void = { _ in }

    override var acceptsFirstResponder: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        VaultKeyboardFocusRelay.current = self
        VaultKeyboardFocusRelay.refocus()
    }

    override func keyDown(with event: NSEvent) {
        onKeyDown(event)
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
            .animation(reduceMotion ? nil : AppMotion.fast, value: configuration.isPressed)
    }
}
