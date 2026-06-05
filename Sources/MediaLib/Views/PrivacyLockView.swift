import SwiftUI

struct PrivacyLockView: View {
    @EnvironmentObject private var appState: AppState
    @State private var pin = ""
    @State private var confirmPIN = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                PageHeader(
                    title: appState.settings.privacyVaultName,
                    subtitle: subtitle,
                    systemImage: "lock.rectangle.stack"
                )

                HStack {
                    Spacer(minLength: 0)
                    lockPanel
                    Spacer(minLength: 0)
                }
            }
            .pageContainer()
        }
        .background(AppPageBackground())
    }

    private var subtitle: String {
        appState.privacyPINConfigured ? "使用 Touch ID 或密码解锁。" : "创建 4 到 8 位数字密码。"
    }

    private var lockPanel: some View {
        VStack(alignment: .center, spacing: 18) {
            VStack(spacing: 14) {
                PlayfulSymbolIcon(systemImage: appState.privacyPINConfigured ? "lock.rectangle.stack" : "lock.badge.clock", size: 58)

                Text(appState.privacyPINConfigured ? "\(appState.settings.privacyVaultName)已锁定" : "设置保险库密码")
                    .font(.title3.weight(.semibold))
                    .multilineTextAlignment(.center)
                Text(appState.privacyPINConfigured ? "锁定时隐藏路径、文件名和内容。" : "设置完成后会解锁保险库，密码可在设置中管理。")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            if appState.privacyPINConfigured {
                unlockControls
            } else {
                createPINControls
            }
        }
        .padding(22)
        .frame(maxWidth: 560, alignment: .center)
        .surfaceBackground(cornerRadius: 18)
    }

    private var unlockControls: some View {
        VStack(alignment: .center, spacing: 12) {
            HStack(spacing: 5) {
                SecureField("4-8 位数字", text: $pin)
                    .glassFormField()
                    .multilineTextAlignment(.center)
                    .frame(width: 158)
                    .onChange(of: pin) { newValue in
                        pin = String(newValue.filter(\.isNumber).prefix(8))
                    }
                    .onSubmit(unlockWithPIN)

                Button("解锁") {
                    unlockWithPIN()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .frame(width: 74)
                .disabled(!PrivacyLockService.isValidPIN(pin))

                if appState.privacyBiometricsAvailable {
                    Button {
                        appState.unlockPrivacyWithBiometrics()
                    } label: {
                        Label("Touch ID", systemImage: "touchid")
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32))
                    .frame(width: 118)
                }
            }

            Text("解锁前隐藏保险库内容与媒体源路径。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var createPINControls: some View {
        VStack(alignment: .center, spacing: 12) {
            HStack(spacing: 10) {
                SecureField("4-8 位数字", text: $pin)
                    .glassFormField()
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .onChange(of: pin) { newValue in
                        pin = String(newValue.filter(\.isNumber).prefix(8))
                    }

                SecureField("再次输入", text: $confirmPIN)
                    .glassFormField()
                    .multilineTextAlignment(.center)
                    .frame(width: 180)
                    .onChange(of: confirmPIN) { newValue in
                        confirmPIN = String(newValue.filter(\.isNumber).prefix(8))
                    }

                Button("设置并解锁") {
                    createPIN()
                }
                .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                .disabled(!canCreatePIN)
            }

            Text("密码验证信息只保存在本机，不使用系统钥匙串。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var canCreatePIN: Bool {
        PrivacyLockService.isValidPIN(pin) && pin == confirmPIN
    }

    private func createPIN() {
        guard canCreatePIN else {
            appState.alert = AppAlert(title: "密码无效", message: "请输入一致的 4 到 8 位数字密码。")
            return
        }
        if appState.setPrivacyPIN(pin) {
            pin = ""
            confirmPIN = ""
        }
    }

    private func unlockWithPIN() {
        if appState.verifyPrivacyPIN(pin) {
            pin = ""
        }
    }
}
