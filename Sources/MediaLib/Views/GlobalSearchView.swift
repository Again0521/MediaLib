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

    /// 单条记忆化搜索结果：原先每次 body 求值都对全库做拼音匹配过滤（后台扫描频繁发布状态时尤其浪费）。
    /// 结果只取决于 (query, 库内容, 隐私可见性)，故以此为键单条缓存；命中即返回，不改变任何匹配逻辑或展示。
    private enum ResultsCache {
        struct Key: Equatable {
            let query: String
            let revision: Int
            let privacyVisible: Bool
        }
        static var cachedKey: Key?
        static var cachedValue: [Group] = []
    }

    private var groups: [Group] {
        let q = trimmedQuery
        guard !q.isEmpty else { return [] }
        let privacyVisible = appState.privacyPINConfigured && appState.privacyUnlocked
        let key = ResultsCache.Key(query: q, revision: appState.libraryRevision, privacyVisible: privacyVisible)
        if let cachedKey = ResultsCache.cachedKey, cachedKey == key {
            return ResultsCache.cachedValue
        }
        let result = buildGroups(query: q, privacyVisible: privacyVisible)
        ResultsCache.cachedKey = key
        ResultsCache.cachedValue = result
        return result
    }

    private func buildGroups(query q: String, privacyVisible: Bool) -> [Group] {
        let matched = appState.items.filter { item in
            guard item.type != .episode else { return false }
            if appState.isPrivateItem(item) && !privacyVisible { return false }
            return appState.matchesMediaSearch(query: q, item: item)
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
            AppSectionHeading(
                title: total == 0 ? "未找到“\(trimmedQuery)”" : "搜索“\(trimmedQuery)”",
                subtitle: total == 0
                    ? "可尝试标题、演员、角色、题材、简介、制作方、年份或剧集名称。"
                    : "已穿透匹配作品资料、演职人员和子集标题，并按媒体类型分组。",
                systemImage: "magnifyingglass",
                badgeText: total == 0 ? nil : "\(total) 个结果"
            )
            .padding(14)
            .staticSurfaceBackground(cornerRadius: 16, thickness: 0.94)
            .repeatedCardChrome(false, cornerRadius: 16)

            if total == 0 {
                EmptyStateView(
                    title: "无匹配结果",
                    systemImage: "magnifyingglass",
                    message: "支持标题与拼音、演员和角色、题材、简介、电视网、制作公司、年份及具体剧集名称。"
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
        VStack(alignment: .leading, spacing: 12) {
            AppSectionHeading(
                title: group.title,
                subtitle: group.id == MediaType.music.rawValue ? "点击条目立即播放" : "点击条目查看详情",
                systemImage: group.systemImage,
                badgeText: "\(group.items.count) 项"
            )
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
        if let genre = item.genre?.trimmingCharacters(in: .whitespacesAndNewlines), !genre.isEmpty {
            parts.append(genre)
        }
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
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .strokeBorder(.white.opacity(active ? 0.46 : 0.22), lineWidth: 0.75)
                    }

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
            .repeatedCardChrome(active, cornerRadius: 12)
            .repeatedSurfaceHover(active, cornerRadius: 12, intensity: 0.82)
            .brightness(active ? 0.006 : 0)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.title)，\(subtitle)")
        .accessibilityHint(item.type == .music ? "播放此音乐" : "打开媒体详情")
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
