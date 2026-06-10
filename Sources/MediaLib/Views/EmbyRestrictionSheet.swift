import AppKit
import SwiftUI

/// 受限远程媒体服务器（白名单拒绝）提示面板。
/// 当服务器对登录 / 拉库 / 取流返回 401/403/451 或白名单类错误时弹出，
/// 提示用户联系管理员，并展示可一键复制的客户端身份信息（Client / Device / DeviceId / Version / User-Agent）。
struct EmbyRestrictionSheet: View {
    let notice: EmbyRestrictionNotice
    let onDismiss: () -> Void

    @State private var copiedAll = false

    private var identityLines: [(label: String, value: String)] {
        [
            ("Client", notice.identity.client),
            ("Device", notice.identity.device),
            ("DeviceId", notice.identity.deviceID),
            ("Version", notice.identity.version),
            ("User-Agent", notice.identity.userAgent)
        ]
    }

    private var combinedText: String {
        identityLines.map { "\($0.label): \($0.value)" }.joined(separator: "\n")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            AppSheetHeader(
                title: "服务器限制第三方客户端",
                subtitle: notice.serverHost,
                systemImage: "lock.shield",
                subtitleLineLimit: 1,
                truncationMode: .middle
            )

            Text("该远程服务器可能限制第三方客户端接入。请联系管理员将 MediaLIB 加入白名单。")
                .font(.callout)
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)

            if let reason = notice.reason, !reason.isEmpty {
                AppInlineNoticeLabel(text: reason, systemImage: "info.circle")
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("客户端信息")
                        .font(.subheadline.weight(.semibold))
                    Spacer()
                    Button {
                        copy(combinedText)
                        copiedAll = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { copiedAll = false }
                    } label: {
                        Label(copiedAll ? "已复制" : "复制全部", systemImage: copiedAll ? "checkmark" : "doc.on.doc")
                            .font(.caption.weight(.medium))
                    }
                    .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 9, horizontalPadding: 8, minHeight: 28, thickness: 0.92))
                }

                VStack(spacing: 0) {
                    ForEach(Array(identityLines.enumerated()), id: \.offset) { index, line in
                        identityRow(label: line.label, value: line.value)
                        if index < identityLines.count - 1 {
                            Divider().opacity(0.5)
                        }
                    }
                }
                .padding(12)
                .staticSurfaceBackground(cornerRadius: 12, thickness: 0.92)
            }

            AppSheetActionFooter {
                Button("关闭", action: onDismiss)
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 32, prominent: true))
                    .keyboardShortcut(.defaultAction)
            }
        }
        .appSheetChrome(width: 440)
    }

    private func identityRow(label: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(label)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
                .frame(width: 84, alignment: .leading)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button {
                copy(value)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.caption2)
            }
            .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 8, horizontalPadding: 6, minHeight: 24, thickness: 0.88))
            .help("复制\(label)")
        }
        .padding(.vertical, 6)
    }

    private func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }
}
