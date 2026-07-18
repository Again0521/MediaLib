import Foundation
import MediaLibServerProtocol

/// Authenticated Web navigation shared by every server-rendered page.
///
/// Keeping this markup in one place prevents pages from silently drifting into
/// different link orders, active states, mobile behavior, or management exposure.
enum ServerWebNavigation {
    enum Active: String {
        case home, library, watching, history, search, favorites, watchlist, ratings, watched, unwatched
        case sources, status, administration, account

        var title: String {
            switch self {
            case .home: return "首页"
            case .library: return "浏览资料库"
            case .watching: return "继续观看"
            case .history: return "播放历史"
            case .search: return "全局搜索"
            case .favorites: return "我的收藏"
            case .watchlist: return "想看清单"
            case .ratings: return "我的评分"
            case .watched: return "已看内容"
            case .unwatched: return "未看内容"
            case .sources: return "媒体源"
            case .status: return "仪表盘"
            case .administration: return "服务管理"
            case .account: return "我的账户"
            }
        }
    }

    enum Note: Equatable {
        case library, playback, security, none

        var html: String {
            switch self {
            case .library:
                return "<strong>认证资料库</strong><br>分类、搜索和播放状态只来自当前账号有权访问的服务端索引。"
            case .playback:
                return "<strong>播放边界</strong><br>网页使用同源媒体 ID 获取授权字节流，并由浏览器原生解码；本地路径不会发送到网页。"
            case .security:
                return "<strong>安全边界</strong><br>管理页只显示脱敏数据；路径、连接地址、凭据、Cookie 和令牌不会进入页面。"
            case .none:
                return ""
            }
        }
    }

    private struct Item {
        let active: Active
        let path: String
        let icon: Icon
        let managementOnly: Bool
    }

    private enum Icon {
        case home, library, play, history, search, heart, bookmark, star, check, circle, source, dashboard, users, account

        var paths: String {
            switch self {
            case .home:
                return #"<path d="M3 10.5 12 3l9 7.5"></path><path d="M5.5 9.5V21h13V9.5"></path><path d="M9 21v-7h6v7"></path>"#
            case .library:
                return #"<rect x="3" y="4" width="18" height="16" rx="2"></rect><path d="M7 8h10M7 12h10M7 16h6"></path>"#
            case .play:
                return #"<circle cx="12" cy="12" r="9"></circle><path d="m10 8 6 4-6 4Z"></path>"#
            case .history:
                return #"<path d="M3 12a9 9 0 1 0 3-6.7L3 8"></path><path d="M3 3v5h5M12 7v5l3 2"></path>"#
            case .search:
                return #"<circle cx="11" cy="11" r="7"></circle><path d="m16.5 16.5 4 4"></path>"#
            case .heart:
                return #"<path d="M20.8 4.6a5.5 5.5 0 0 0-7.8 0L12 5.7l-1.1-1.1a5.5 5.5 0 0 0-7.8 7.8L12 21l8.8-8.6a5.5 5.5 0 0 0 0-7.8Z"></path>"#
            case .bookmark:
                return #"<path d="M6 3h12a1 1 0 0 1 1 1v17l-7-4-7 4V4a1 1 0 0 1 1-1Z"></path>"#
            case .star:
                return #"<path d="m12 3 2.8 5.7 6.2.9-4.5 4.4 1.1 6.2-5.6-3-5.6 3 1.1-6.2L3 9.6l6.2-.9Z"></path>"#
            case .check:
                return #"<circle cx="12" cy="12" r="9"></circle><path d="m8 12 2.7 2.7L16.5 9"></path>"#
            case .circle:
                return #"<circle cx="12" cy="12" r="9"></circle>"#
            case .source:
                return #"<rect x="3" y="5" width="18" height="14" rx="3"></rect><path d="M7 15h.01M11 15h6M7 9h10"></path>"#
            case .dashboard:
                return #"<rect x="3" y="3" width="7" height="7" rx="1"></rect><rect x="14" y="3" width="7" height="7" rx="1"></rect><rect x="3" y="14" width="7" height="7" rx="1"></rect><rect x="14" y="14" width="7" height="7" rx="1"></rect>"#
            case .users:
                return #"<circle cx="9" cy="8" r="3"></circle><path d="M3.5 20v-2a5.5 5.5 0 0 1 11 0v2M16 4.5a3 3 0 0 1 0 6M17 13a5 5 0 0 1 3.5 4.8V20"></path>"#
            case .account:
                return #"<circle cx="12" cy="8" r="4"></circle><path d="M4 21a8 8 0 0 1 16 0"></path>"#
            }
        }
    }

    private static let mediaItems: [Item] = [
        Item(active: .home, path: "/", icon: .home, managementOnly: false),
        Item(active: .library, path: "/library", icon: .library, managementOnly: false),
        Item(active: .watching, path: "/watching", icon: .play, managementOnly: false),
        Item(active: .history, path: "/history", icon: .history, managementOnly: false),
        Item(active: .search, path: "/search", icon: .search, managementOnly: false)
    ]

    private static let personalItems: [Item] = [
        Item(active: .favorites, path: "/favorites", icon: .heart, managementOnly: false),
        Item(active: .watchlist, path: "/watchlist", icon: .bookmark, managementOnly: false),
        Item(active: .ratings, path: "/ratings", icon: .star, managementOnly: false),
        Item(active: .watched, path: "/watched", icon: .check, managementOnly: false),
        Item(active: .unwatched, path: "/unwatched", icon: .circle, managementOnly: false)
    ]

    private static let managementItems: [Item] = [
        Item(active: .sources, path: "/sources", icon: .source, managementOnly: true),
        Item(active: .status, path: "/status", icon: .dashboard, managementOnly: false),
        Item(active: .administration, path: "/admin", icon: .users, managementOnly: true),
        Item(active: .account, path: "/account", icon: .account, managementOnly: false)
    ]

    static func render(
        active: Active,
        showAdministration: Bool,
        note: Note,
        categories: [ServerLibraryCategory] = [],
        activeCategoryID: String? = nil
    ) -> String {
        let navigation = navigationMarkup(
            active: active,
            showAdministration: showAdministration,
            categories: categories,
            activeCategoryID: activeCategoryID,
            ariaLabel: "主导航",
            className: "app-nav app-nav-desktop"
        )
        let mobileNavigation = navigationMarkup(
            active: active,
            showAdministration: showAdministration,
            categories: categories,
            activeCategoryID: activeCategoryID,
            ariaLabel: "移动端主导航",
            className: "app-nav app-nav-mobile-links"
        )
        let noteMarkup = note == .none ? "" : "<div class=\"sidebar-note\">\(note.html)</div>"
        return """
        <aside class="app-sidebar">
          <a class="app-brand" href="/" aria-label="MediaLIB 首页"><span class="brand-mark" aria-hidden="true">M</span><span>MediaLIB</span></a>
          \(navigation)
          <details class="app-mobile-nav"><summary>导航 · \(active.title)</summary>\(mobileNavigation)</details>
          \(noteMarkup)
        </aside>
        """
    }

    private static func navigationMarkup(
        active: Active,
        showAdministration: Bool,
        categories: [ServerLibraryCategory],
        activeCategoryID: String?,
        ariaLabel: String,
        className: String
    ) -> String {
        let media = links(
            mediaItems,
            active: active,
            showAdministration: showAdministration,
            suppressLibraryActiveState: activeCategoryID != nil
        )
        let categoryLinks = categoryMarkup(categories, activeCategoryID: activeCategoryID)
        let personal = links(personalItems, active: active, showAdministration: showAdministration)
        let management = links(managementItems, active: active, showAdministration: showAdministration)
        return """
        <nav class="\(className)" aria-label="\(ariaLabel)">
          <span class="nav-group-title">媒体库</span>
          \(media)
          \(categoryLinks)
          <span class="nav-subgroup-title">我的媒体</span>
          \(personal)
          <span class="nav-group-title nav-management-title">管理</span>
          \(management)
        </nav>
        """
    }

    private static func links(
        _ items: [Item],
        active: Active,
        showAdministration: Bool,
        suppressLibraryActiveState: Bool = false
    ) -> String {
        items.compactMap { item in
            guard showAdministration || !item.managementOnly else { return nil }
            let isActive = item.active == active && !(suppressLibraryActiveState && item.active == .library)
            let state = isActive ? " active\" aria-current=\"page" : ""
            return """
            <a class="nav-item\(state)" href="\(item.path)"><svg class="nav-icon" viewBox="0 0 24 24" aria-hidden="true" fill="none" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round">\(item.icon.paths)</svg><span>\(item.active.title)</span></a>
            """
        }.joined(separator: "\n")
    }

    private static func categoryMarkup(
        _ categories: [ServerLibraryCategory],
        activeCategoryID: String?
    ) -> String {
        let links = categories.prefix(32).compactMap { category -> String? in
            guard let encodedID = ServerWebURL.queryValue(category.id) else { return nil }
            let selected = category.id == activeCategoryID ? " active\" aria-current=\"page" : ""
            return "<a class=\"nav-item nav-category\(selected)\" href=\"/library?type=\(encodedID)\"><span class=\"nav-category-dot\" aria-hidden=\"true\"></span><span>\(escape(category.title))</span><small>\(max(category.itemCount, 0))</small></a>"
        }.joined(separator: "\n")
        guard !links.isEmpty else { return "" }
        return "<span class=\"nav-subgroup-title\">服务端分类</span>\n\(links)"
    }

    private static func escape(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "\"", with: "&quot;")
            .replacingOccurrences(of: "'", with: "&#39;")
    }
}
