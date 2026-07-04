import AppKit
import SwiftUI
import MediaLibCore

/// 实机验收工具：把所有页面标题图标（真实 SwiftUI `VividPageIcon` 渲染，含发光/裁剪）
/// 离屏渲染成一张 PNG 网格，写到磁盘后退出。用于肉眼检查「色块溢出」等真实渲染问题，
/// 不依赖对比稿。每个单元格带红色边框标出图标标称边界，任何越界色块一目了然。
///
/// 用法：
///   swift build
///   .build/debug/MediaLib --debug-icon-grid            # 输出 /tmp/vivid_icon_grid.png
///   .build/debug/MediaLib --debug-icon-grid --debug-icon-grid-output /path/out.png
@MainActor
enum VividIconGridDebugTool {
    private static let flag = "--debug-icon-grid"
    private static let outputFlag = "--debug-icon-grid-output"
    private static var didRun = false

    static var isRequested: Bool {
        ProcessInfo.processInfo.arguments.contains(flag)
    }

    private static var outputURL: URL {
        let args = ProcessInfo.processInfo.arguments
        if let i = args.firstIndex(of: outputFlag), args.indices.contains(i + 1), !args[i + 1].isEmpty {
            return URL(fileURLWithPath: args[i + 1])
        }
        return URL(fileURLWithPath: "/tmp/vivid_icon_grid.png")
    }

    /// (中文标签, 传入 VividPageIcon 的 systemImage) —— 覆盖全部页面标题图标 + 状态徽标。
    private static let items: [(String, String)] = [
        ("电视剧", "tv.library"), ("动漫", "sparkles.tv"), ("电影", "film"),
        ("综艺", "music.mic"), ("纪录片", "books.vertical"), ("其他视频", "video"),
        ("歌曲", "music.note"), ("专辑", "music.album"), ("艺术家", "person.2"),
        ("歌单", "music.note.list"), ("最近播放", "music.recent"),
        ("照片", "photo"), ("全部相册", "square.grid.2x2"), ("录像", "recording.library"),
        ("媒体源", "externaldrive"), ("设置", "gearshape"),
        ("仪表盘", "dashboard"), ("片库健康", "stethoscope"), ("任务中心", "checklist"),
        ("保险库", "lock.rectangle.stack"),
        ("正在观看", "play.circle"), ("想看", "bookmark"), ("喜欢", "heart"),
        ("未观看", "eye"), ("已观看", "checkmark.circle"), ("未匹配", "questionmark.circle"),
        ("同步", "arrow.triangle.2.circlepath"), ("主题", "paintbrush")
    ]

    static func runAndExitIfRequested() {
        guard isRequested, !didRun else { return }
        didRun = true
        // 延后到 runloop 起来、字体资源就绪后再渲染。
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
            render()
        }
    }

    private static func render() {
        let grid = GridView(items: items)
        if #available(macOS 13.0, *) {
            let renderer = ImageRenderer(content: grid)
            renderer.scale = 2.0
            if let image = renderer.nsImage,
               let tiff = image.tiffRepresentation,
               let rep = NSBitmapImageRep(data: tiff),
               let png = rep.representation(using: .png, properties: [:]) {
                write(png)
                return
            }
        }
        renderViaHosting(AnyView(grid))
    }

    private static func renderViaHosting(_ view: AnyView) {
        let host = NSHostingView(rootView: view)
        host.frame = NSRect(x: 0, y: 0, width: 5 * 128 + 32, height: 6 * 128 + 32)
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else {
            fputs("FAILED: 无法为图标网格创建位图。\n", stderr)
            NSApp.terminate(nil); return
        }
        host.cacheDisplay(in: host.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else {
            fputs("FAILED: 图标网格 PNG 编码失败。\n", stderr)
            NSApp.terminate(nil); return
        }
        write(png)
    }

    private static func write(_ png: Data) {
        do {
            try png.write(to: outputURL, options: .atomic)
            print("VIVID_ICON_GRID=\(outputURL.path)")
        } catch {
            fputs("FAILED: 写入图标网格失败：\(error.localizedDescription)\n", stderr)
        }
        NSApp.terminate(nil)
    }

    private struct GridView: View {
        let items: [(String, String)]
        private let columns = [GridItem](repeating: GridItem(.fixed(128), spacing: 0), count: 5)

        var body: some View {
            LazyVGrid(columns: columns, spacing: 0) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    VStack(spacing: 8) {
                        ZStack {
                            // 红框标出图标标称 56×56 边界；任何溢出该框的色块即为「色块溢出」。
                            RoundedRectangle(cornerRadius: 4)
                                .stroke(Color.red.opacity(0.35), lineWidth: 0.5)
                                .frame(width: 56, height: 56)
                            VividPageIcon(systemImage: item.1)
                        }
                        .frame(width: 88, height: 88)
                        Text(item.0)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(Color(white: 0.35))
                    }
                    .frame(width: 128, height: 128)
                    .background(Color.white)
                    .overlay(Rectangle().stroke(Color(white: 0.85), lineWidth: 0.5))
                }
            }
            .padding(16)
            .frame(width: 5 * 128 + 32)
            .background(Color(red: 0.96, green: 0.97, blue: 0.98))
        }
    }
}
