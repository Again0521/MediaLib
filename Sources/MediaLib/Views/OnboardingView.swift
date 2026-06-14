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
            title: "你好，欢迎使用 MediaLIB",
            subtitle: "你的电影、剧集、动漫和音乐，从此有一个家。",
            bullets: [
                "一切都在你的设备上：我们不会上传你的任何内容",
                "只读你的文件、绝不移动或修改它们，随时可以放心卸载",
                "海报墙、播放进度、收藏歌单——都围绕你的收藏展开"
            ]
        ),
        Page(
            systemImage: "externaldrive.badge.plus",
            title: "先把收藏接进来",
            subtitle: "本地硬盘、NAS、流媒体服务器，都可以。",
            bullets: [
                "本地文件夹、移动硬盘和 SMB 网络位置直接扫描",
                "有 Emby / Jellyfin / Plex 服务器？登录就能在这里看",
                "之后新增的文件会自动增量更新，不用再手动整理"
            ]
        ),
        Page(
            systemImage: "sparkles.rectangle.stack",
            title: "让海报墙好看起来",
            subtitle: "封面、简介、评分和歌词，一键帮你补全。",
            bullets: [
                "在设置里填一个免费的 TMDB Key，影视信息自动匹配",
                "音乐标签和歌词支持网易云 / QQ / Last.fm 等来源",
                "拿不准哪里出了问题？「片库健康」帮你查失效和重复"
            ]
        ),
        Page(
            systemImage: "film.stack",
            title: "想怎么看，就怎么看",
            subtitle: "内置播放器很能打，不输你熟悉的桌面播放器。",
            bullets: [
                "字幕在线搜索、双字幕对照、音轨和倍速都记得你的偏好",
                "剧集自动续播下一集，迷你悬浮窗让你边看边做别的",
                "远程视频可以离线缓存下来，出门没网也能接着看"
            ]
        ),
        Page(
            systemImage: "music.note.list",
            title: "音乐也能认真收藏",
            subtitle: "封面、歌词、队列和歌单，会跟着你的音乐一起整理好。",
            bullets: [
                "歌曲会按专辑、艺人和歌单归档，查找起来更顺手",
                "本地 LRC 和在线歌词都能同步显示，播放时自动对齐",
                "随机播放、循环模式和下一首队列都能在底栏快速控制"
            ]
        ),
        Page(
            systemImage: "checkmark.seal",
            title: "可以开始了",
            subtitle: "先把媒体源加上，其它的慢慢来。",
            bullets: [
                "喜欢的话，可在设置中把 MediaLIB 设为系统默认播放器",
                "按 ⌘⇧O 还能直接打开网络串流链接",
                "所有选项都在「设置」里，随时回来调整"
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

            // 要点块：对勾位于每行开头，文字左对齐（首字竖向对齐）；
            // 块宽收缩到最长一行（fixedSize），整块居中后左右留白自然相等，
            // 同时避免短句被拉得太开。
            VStack(alignment: .leading, spacing: 12) {
                ForEach(page.bullets, id: \.self) { bullet in
                    HStack(alignment: .firstTextBaseline, spacing: 14) {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundStyle(AppColors.selectedGlassTint)
                            .font(.callout)
                        Text(bullet)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
            .fixedSize(horizontal: true, vertical: false)
            .frame(maxWidth: 440)
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
