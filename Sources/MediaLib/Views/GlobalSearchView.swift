import MediaLibCore
import SwiftUI

/// 全局统一搜索结果：跨视频 / 音乐一框搜（拼音/首字母/模糊，复用 PinyinSearchMatcher），按类别分组展示。
struct GlobalSearchView: View {
    @EnvironmentObject private var appState: AppState
    let query: String
    /// 点击结果：视频→打开详情，音乐→播放（由 ContentView 决定）。
    let onSelect: (MediaItem) -> Void
    @State private var groups: [Group] = []
    @State private var isSearching = false
    @State private var completedQuery = ""

    private struct Group: Identifiable, Sendable {
        let id: String
        let title: String
        let systemImage: String
        let items: [MediaItem]
    }

    private struct SearchCandidate: Sendable {
        let item: MediaItem
        let fields: [String?]
    }

    private var trimmedQuery: String {
        query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var searchTaskID: String {
        [
            trimmedQuery,
            "\(appState.libraryRevision)",
            "\(appState.mediaSearchRevision)",
            "\(appState.canDisplayPrivateItems)"
        ].joined(separator: "|")
    }

    nonisolated private static let groupOrder: [(MediaType, String, String)] = [
        (.movie, "电影", "film"),
        (.tvShow, "电视剧", "tv"),
        (.anime, "动漫", "sparkles.tv"),
        (.documentary, "纪录片", "books.vertical"),
        (.variety, "综艺", "music.mic"),
        (.music, "音乐", "music.note"),
        (.other, "其他", "tray"),
        (.privateCollection, "保险库", "lock.rectangle.stack")
    ]

    private func rebuildGroups() async {
        let q = trimmedQuery
        guard !q.isEmpty else {
            groups = []
            completedQuery = ""
            isSearching = false
            return
        }

        isSearching = true
        completedQuery = q
        groups = []

        let canDisplayPrivateItems = appState.canDisplayPrivateItems
        let candidates = appState.items.compactMap { item -> SearchCandidate? in
            guard item.type != .episode else { return nil }
            if appState.isPrivateItem(item) && !canDisplayPrivateItems { return nil }
            return SearchCandidate(
                item: item,
                fields: appState.mediaSearchFields(for: item)
            )
        }

        let groupedCandidates = Dictionary(grouping: candidates, by: { $0.item.type })
        var completedGroups: [String: Group] = [:]
        await withTaskGroup(of: Group?.self) { taskGroup in
            for (type, _, _) in Self.groupOrder {
                guard let candidates = groupedCandidates[type], !candidates.isEmpty else { continue }
                taskGroup.addTask(priority: .userInitiated) {
                    Self.buildGroup(type: type, query: q, candidates: candidates)
                }
            }

            for await group in taskGroup {
                guard !Task.isCancelled, q == trimmedQuery else {
                    taskGroup.cancelAll()
                    return
                }
                guard let group else { continue }
                completedGroups[group.id] = group
                groups = Self.groupOrder.compactMap { type, _, _ in
                    completedGroups[type.rawValue]
                }
            }
        }

        guard !Task.isCancelled, q == trimmedQuery else { return }
        isSearching = false
    }

    nonisolated private static func buildGroups(query q: String, candidates: [SearchCandidate]) -> [Group] {
        return groupOrder.compactMap { type, title, image in
            buildGroup(type: type, title: title, systemImage: image, query: q, candidates: candidates)
        }
    }

    nonisolated private static func buildGroup(type: MediaType, query q: String, candidates: [SearchCandidate]) -> Group? {
        guard let metadata = groupOrder.first(where: { $0.0 == type }) else { return nil }
        return buildGroup(type: type, title: metadata.1, systemImage: metadata.2, query: q, candidates: candidates)
    }

    nonisolated private static func buildGroup(
        type: MediaType,
        title: String,
        systemImage: String,
        query q: String,
        candidates: [SearchCandidate]
    ) -> Group? {
        let items = candidates.compactMap { candidate -> MediaItem? in
            guard candidate.item.type == type else { return nil }
            return PinyinSearchMatcher.matches(query: q, in: candidate.fields) ? candidate.item : nil
        }
        guard !items.isEmpty else { return nil }
        let sorted = items.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        return Group(id: type.rawValue, title: title, systemImage: systemImage, items: sorted)
    }

    // 内容型组件（无自身页头/滚动/背景），便于嵌入首页搜索框下方。
    var body: some View {
        let total = groups.reduce(0) { $0 + $1.items.count }
        VStack(alignment: .leading, spacing: 16) {
            AppSectionHeading(
                title: isSearching ? "正在搜索“\(completedQuery.isEmpty ? trimmedQuery : completedQuery)”" : (total == 0 ? "未找到“\(trimmedQuery)”" : "搜索“\(trimmedQuery)”"),
                subtitle: total == 0
                    ? "可尝试标题、演员、角色、题材、简介、制作方、年份或剧集名称。"
                    : "已穿透匹配作品资料、演职人员和子集标题，并按媒体类型分组。",
                systemImage: "magnifyingglass",
                badgeText: isSearching ? nil : (total == 0 ? nil : "\(total) 个结果")
            )
            .padding(14)
            .staticSurfaceBackground(cornerRadius: 16, thickness: 0.94)
            .repeatedCardChrome(false, cornerRadius: 16)

            if total == 0, isSearching {
                SearchProgressStatusCard(
                    title: "正在匹配媒体资料",
                    subtitle: "按电影、剧集、音乐等分类并发搜索，命中后会立即显示。",
                    systemImage: "magnifyingglass"
                )
            } else if total == 0 {
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
                if isSearching {
                    SearchProgressStatusCard(
                        title: "继续穿透其他分类",
                        subtitle: "已显示先命中的结果，其余分类和更多字段仍在增量匹配。",
                        systemImage: "magnifyingglass"
                    )
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: searchTaskID) {
            await rebuildGroups()
        }
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
