import SwiftUI

/// 首次启动引导（Phase 4）：分步介绍核心能力，结束后写入 hasCompletedOnboarding 不再弹出。
/// 最后一步可直接「开始使用」或「现在添加媒体源」（跳转到媒体源页）。
struct OnboardingView: View {
    @Environment(\.colorScheme) private var colorScheme
    /// goToSources = true 表示用户希望立即去添加媒体源。
    let onFinish: (_ goToSources: Bool) -> Void

    @State private var step = 0

    private struct Page {
        let systemImage: String
        let title: String
        let subtitle: String
        let bullets: [String]
    }

    private let pages: [Page] = [
        Page(
            systemImage: "play.rectangle.on.rectangle",
            title: "欢迎使用 MediaLIB",
            subtitle: "本地优先的影视与音乐媒体库 + 播放器。",
            bullets: [
                "电影、剧集、动漫与音乐统一管理",
                "内置高性能播放器，原始文件不被修改"
            ]
        ),
        Page(
            systemImage: "externaldrive.badge.plus",
            title: "添加媒体源",
            subtitle: "把你的媒体接入媒体库。",
            bullets: [
                "本地文件夹、移动硬盘、SMB / FTP 网络位置",
                "也可连接 Emby 服务器，按来源拆分一级目录",
                "自动扫描，本地来源优先增量更新"
            ]
        ),
        Page(
            systemImage: "sparkles.rectangle.stack",
            title: "匹配元数据",
            subtitle: "封面、简介、演职人员与歌词一键补全。",
            bullets: [
                "填写 TMDB Key 自动匹配影视，宽容度可调",
                "音乐支持网易云 / QQ / Last.fm / Deezer 等来源",
                "「片库健康」可检查失效路径、重复项与缺口"
            ]
        ),
        Page(
            systemImage: "dot.radiowaves.left.and.right",
            title: "尽情探索",
            subtitle: "还有更多贴心功能等你发现。",
            bullets: [
                "字幕在线搜索、音轨/字幕偏好记忆",
                "艺人电台、相似度连续播放、Last.fm 听歌打卡",
                "批量操作、智能集合与歌单"
            ]
        )
    ]

    private var isLastStep: Bool { step == pages.count - 1 }

    var body: some View {
        VStack(spacing: 0) {
            content
            controls
        }
        .frame(width: 560, height: 520)
        .background(AppPageBackground())
    }

    private var content: some View {
        let page = pages[step]
        return VStack(spacing: 20) {
            PlayfulSymbolIcon(systemImage: page.systemImage, size: 84)
                .padding(.top, 44)

            VStack(spacing: 8) {
                Text(page.title)
                    .font(.system(size: 26, weight: .bold))
                    .multilineTextAlignment(.center)
                Text(page.subtitle)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 32)

            // 每条要点整行居中：图标+文字作为一个整体在页面水平居中，不再用 Spacer 把内容顶到左侧。
            VStack(alignment: .center, spacing: 12) {
                ForEach(page.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppColors.selectedGlassTint)
                            .font(.callout)
                        Text(bullet)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity)
        .animation(AppMotion.standard, value: step)
    }

    private var controls: some View {
        VStack(spacing: 16) {
            HStack(spacing: 8) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? AppColors.selectedGlassTint : Color.primary.opacity(0.18))
                        .frame(width: index == step ? 20 : 7, height: 7)
                        .animation(AppMotion.fast, value: step)
                }
            }

            HStack {
                Button("跳过") { onFinish(false) }
                    .buttonStyle(RepeatedGlassButtonStyle(cornerRadius: 12, horizontalPadding: 14, minHeight: 34, thickness: 0.94))

                Spacer()

                if step > 0 {
                    Button("上一步") {
                        withAnimation(AppMotion.standard) { step -= 1 }
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 16, minHeight: 36))
                }

                if isLastStep {
                    Button("现在添加媒体源") { onFinish(true) }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 16, minHeight: 36))
                    Button("开始使用") { onFinish(false) }
                        .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 18, minHeight: 36, prominent: true))
                        .keyboardShortcut(.defaultAction)
                } else {
                    Button("下一步") {
                        withAnimation(AppMotion.standard) { step += 1 }
                    }
                    .buttonStyle(LiquidGlassButtonStyle(cornerRadius: 12, horizontalPadding: 18, minHeight: 36, prominent: true))
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
    }
}
