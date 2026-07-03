import AppKit
import Darwin
import Foundation
import SwiftUI

#if DEBUG
@MainActor
enum TitleIconDebugTool {
    struct Sample: Identifiable {
        let id: String
        let title: String
        let subtitle: String
        let systemImage: String
    }

    private static let samples: [Sample] = [
        Sample(id: "albums", title: "专辑", subtitle: "按专辑浏览歌曲 · 287 张", systemImage: "music.album"),
        Sample(id: "tv", title: "电视剧", subtitle: "浏览、筛选和管理当前内容 · 2 项", systemImage: "tv.library"),
        Sample(id: "artists", title: "艺术家", subtitle: "按艺术家浏览歌曲 · 0 位", systemImage: "person.2"),
        Sample(id: "playlists", title: "歌单", subtitle: "管理手动歌单与智能歌单 · 1 个", systemImage: "music.note.list"),
        Sample(id: "recent", title: "最近播放", subtitle: "查看最近播放的歌曲 · 0 首", systemImage: "music.recent"),
        Sample(id: "video-gallery", title: "录像", subtitle: "相册 · 64 段录像", systemImage: "recording.library"),
        Sample(id: "songs", title: "歌曲", subtitle: "浏览音乐库中的全部歌曲 · 315 首", systemImage: "music.note"),
        Sample(id: "sources", title: "媒体源", subtitle: "管理本地文件夹、移动硬盘、网络挂载、Emby、Jellyfin 和 Plex 媒体库。", systemImage: "externaldrive")
    ]

    static func runAndExitIfRequested() {
        let arguments = ProcessInfo.processInfo.arguments
        guard arguments.contains("--debug-title-icons") else { return }

        let outputDirectory = outputDirectory(from: arguments)
        do {
            try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
            let pngURL = outputDirectory.appendingPathComponent("title-icons-preview.png")
            let guideURL = outputDirectory.appendingPathComponent("title-icons-guides.png")
            let jsonURL = outputDirectory.appendingPathComponent("title-icons-report.json")
            try renderPreview(to: pngURL, showGuides: false)
            try renderPreview(to: guideURL, showGuides: true)
            try writeReport(to: jsonURL)
            print("Title icon visual debug passed")
            print("PREVIEW=\(pngURL.path)")
            print("GUIDES=\(guideURL.path)")
            print("REPORT=\(jsonURL.path)")
            Darwin.exit(0)
        } catch {
            fputs("FAILED: title icon visual debug failed: \(error.localizedDescription)\n", stderr)
            Darwin.exit(1)
        }
    }

    private static func outputDirectory(from arguments: [String]) -> URL {
        if let index = arguments.firstIndex(of: "--debug-title-icons-output"),
           arguments.indices.contains(index + 1) {
            return URL(fileURLWithPath: arguments[index + 1], isDirectory: true)
        }
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("Build/TitleIconDebug", isDirectory: true)
    }

    private static func renderPreview(to url: URL, showGuides: Bool) throws {
        let width: CGFloat = 760
        let rowHeight: CGFloat = 118
        let height = CGFloat(samples.count) * rowHeight + 42
        let content = TitleIconDebugCanvas(samples: samples, rowHeight: rowHeight, showGuides: showGuides)
            .frame(width: width, height: height)
            .environment(\.colorScheme, .light)

        let renderer = ImageRenderer(content: content)
        renderer.scale = 2
        guard let cgImage = renderer.cgImage else {
            throw NSError(domain: "TitleIconDebug", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法渲染标题图标预览。"])
        }
        let bitmap = NSBitmapImageRep(cgImage: cgImage)
        guard let data = bitmap.representation(using: .png, properties: [:]) else {
            throw NSError(domain: "TitleIconDebug", code: 2, userInfo: [NSLocalizedDescriptionKey: "无法编码 PNG 预览。"])
        }
        try data.write(to: url, options: .atomic)
    }

    private static func writeReport(to url: URL) throws {
        let estimatedIconVisualRight = AppSpacing.pageHeaderIconSafeSlot - 8
        let textStart = AppSpacing.pageHeaderIconSafeSlot + AppSpacing.pageHeaderIconToText
        let minimumGap = textStart - estimatedIconVisualRight
        let rows = samples.map { sample in
            [
                "id": sample.id,
                "title": sample.title,
                "systemImage": sample.systemImage,
                "iconSlotWidth": AppSpacing.pageHeaderIconSafeSlot,
                "textStartX": textStart,
                "estimatedIconVisualRightX": estimatedIconVisualRight,
                "minimumGap": minimumGap,
                "overlapRisk": minimumGap < 8
            ] as [String: Any]
        }
        let report: [String: Any] = [
            "generatedAt": ISO8601DateFormatter().string(from: Date()),
            "preview": "title-icons-preview.png",
            "guides": "title-icons-guides.png",
            "samples": rows,
            "passed": minimumGap >= 8
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url, options: .atomic)
        if minimumGap < 8 {
            throw NSError(domain: "TitleIconDebug", code: 3, userInfo: [NSLocalizedDescriptionKey: "页头图标与文字安全间距不足。"])
        }
    }
}

private struct TitleIconDebugCanvas: View {
    let samples: [TitleIconDebugTool.Sample]
    let rowHeight: CGFloat
    let showGuides: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("MediaLIB Title Icon Debug")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.debugTitleIconHex("#0F172A"))
                .padding(.horizontal, 24)
                .padding(.top, 18)
                .padding(.bottom, 10)

            ForEach(samples) { sample in
                ZStack(alignment: .topLeading) {
                    Color.white
                    PageHeader(title: sample.title, subtitle: sample.subtitle, systemImage: sample.systemImage)
                        .padding(.top, 16)
                        .padding(.horizontal, 22)

                    if showGuides {
                        Rectangle()
                            .fill(Color.debugTitleIconHex("#22D3A8").opacity(0.18))
                            .frame(width: AppSpacing.pageHeaderIconSafeSlot, height: rowHeight - 26)
                            .offset(x: 26, y: 12)
                            .allowsHitTesting(false)

                        Rectangle()
                            .fill(Color.debugTitleIconHex("#EF4444").opacity(0.16))
                            .frame(width: 1, height: rowHeight - 24)
                            .offset(x: 26 + AppSpacing.pageHeaderIconSafeSlot + AppSpacing.pageHeaderIconToText, y: 12)
                            .allowsHitTesting(false)
                    }
                }
                .frame(height: rowHeight)
                .overlay(alignment: .bottom) {
                    Rectangle()
                        .fill(Color.debugTitleIconHex("#E2E8F0"))
                        .frame(height: 1)
                }
            }
        }
        .background(Color.debugTitleIconHex("#F8FAFC"))
    }
}

private extension Color {
    static func debugTitleIconHex(_ hex: String) -> Color {
        let value = hex.trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        var int: UInt64 = 0
        Scanner(string: value).scanHexInt64(&int)
        let red = Double((int >> 16) & 0xFF) / 255.0
        let green = Double((int >> 8) & 0xFF) / 255.0
        let blue = Double(int & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}
#endif
