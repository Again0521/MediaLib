import MediaLibCore
import SwiftUI

/// 全局统一搜索结果：跨视频 / 音乐一框搜（拼音/首字母/模糊，复用 PinyinSearchMatcher），按类别分组展示。
struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    let query: String
    /// 点击结果：视频→打开详情，音乐→播放（由 ContentView 决定）。
    let onSelect: (MediaItem) -> Void

    private struct Group: Identifiable {
        let id: String
        let title: String
        let systemImage: String
        let items: [MediaItem]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var groups: [Group] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        let privacyVisible = appState.privacyPINConfigured && appState.privacyUnlocked
        let matched = appState.items.filter { item in
            guard item.type != .episode else { return false }
            if item.type == .privateCollection && !privacyVisible { return false }
            return PinyinSearchMatcher.matches(query: q, in: [item.title, item.originalTitle, item.artist, item.album])
        }

        let order: [(MediaType, String, String)] = [
            (.movie, "电影", "film"),
            (.tvShow, "电视剧", "tv"),
            (.anime, "动漫", "sparkles.tv"),
            (.documentary, "纪录片", "books.vertical"),
            (.variety, "综艺", "music.mic"),
            (.music, "音乐", "music.note"),
            (.other, "其他", "tray"),
            (.privateCollection, "保险库", "lock.rectangle.stack")
        ]
        return order.compactMap { type, title, image in
            let items = matched.filter { $0.type == type }
            guard !items.isEmpty else { return nil }
            let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
            return Group(id: type.rawValue, title: title, systemImage: image, items: sorted)
        }
    }

    // 内容型组件（无自身页头/滚动/背景），便于嵌入首页搜索框下方。
    var body: some View {
        let groups = groups
        let total = groups.reduce(0) { $0 + $1.items.count }
        VStack(alignment: .leading, spacing: 16) {
            Label(
                total == 0
                    ? "未找到“\(trimmedQuery)”"
                    : "搜索“\(trimmedQuery)” · 共 \(total) 个结果",
                systemImage: "magnifyingglass"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)

            if total == 0 {
                EmptyStateView(
                    title: "无匹配结果",
                    systemImage: "magnifyingglass",
                    message: "支持标题、拼音全拼、首字母和艺术家关键词。"
                )
                .staticSurfaceBackground(cornerRadius: 22)
            } else {
                ForEach(groups) { group in
                    groupSection(group)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func groupSection(_ group: Group) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("\(group.title) · \(group.items.count)", systemImage: group.systemImage)
                .font(.headline)
            LazyVStack(spacing: 8) {
                ForEach(group.items) { item in
                    resultRow(item)
                }
            }
        }
    }

    private func resultRow(_ item: MediaItem) -> some View {
        GlobalSearchResultRow(item: item, subtitle: subtitle(for: item), onSelect: onSelect)
            .id(item.id)
    }

    private func subtitle(for item: MediaItem) -> String {
        if item.type == .music {
            return item.artistAlbumLine ?? "未知艺人"
        }
        var parts: [String] = [item.type.displayName]
        if item.year != nil { parts.append(item.displayYear) }
        if let rating = item.rating, rating > 0 { parts.append("★ \(String(format: "%.1f", rating))") }
        return parts.joined(separator: " · ")
    }
}

private struct GlobalSearchResultRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.suppressPointerHoverDuringScroll) private var suppressHoverDuringScroll
    let item: MediaItem
    let subtitle: String
    let onSelect: (MediaItem) -> Void
    @State private var isHovering = false

    var body: some View {
        let active = isHovering && !suppressHoverDuringScroll

        Button {
            onSelect(item)
        } label: {
            HStack(spacing: 12) {
                PosterImage(path: item.posterPath, title: item.title, mediaType: item.type)
                    .aspectRatio(item.type == .music ? 1 : 2.0 / 3.0, contentMode: .fill)
                    .frame(width: item.type == .music ? 46 : 40, height: 60)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))

                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                Image(systemName: item.type == .music ? "play.circle" : "chevron.right")
                    .foregroundStyle(active ? AppColors.selectedGlassTint.opacity(0.86) : Color.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .staticSurfaceBackground(cornerRadius: 12, thickness: 0.9)
            .repeatedSurfaceHover(active, cornerRadius: 12, intensity: 0.82)
            .brightness(active ? 0.006 : 0)
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            isHovering = suppressHoverDuringScroll ? false : hovering
        }
        .onChange(of: suppressHoverDuringScroll) { suppressing in
            if suppressing {
                isHovering = false
            }
        }
        .animation(reduceMotion ? nil : AppMotion.listHover, value: active)
    }
}
