import Foundation

/// Where "back" goes on a detail page.
///
/// Detail pages used to hardcode 返回资料库 no matter how the reader arrived, so
/// opening an episode from the queue, a collection, a person's credits or the
/// home shelves and pressing back dropped you on `/library` — a page you had
/// never visited. The origin is instead derived from the request's `Referer`,
/// matched against an allowlist of this product's own routes.
///
/// Security notes:
/// * Only paths that match a known in-app route are ever emitted, so a foreign
///   or crafted referrer cannot turn the control into an open redirect; anything
///   unrecognised falls back to the page's own default.
/// * Identifier-bearing routes (`/series/{id}`, `/collections/{id}`,
///   `/people/{id}`) are rebuilt from a re-encoded segment rather than echoed,
///   so the referrer's bytes never reach the markup verbatim.
/// * Authenticated HTML is `no-store`, so varying the control by `Referer` can
///   not be cached across readers.
enum ServerWebBackNavigation {
    struct Target: Equatable {
        let label: String
        let href: String
    }

    /// Routes with no identifier. Longest-prefix concerns do not arise because
    /// the referrer path is matched whole.
    private static let fixedRoutes: [String: String] = [
        "/": "首页",
        "/search": "搜索",
        "/watching": "继续观看",
        "/history": "播放历史",
        "/favorites": "我的收藏",
        "/watchlist": "想看清单",
        "/ratings": "我的评分",
        "/watched": "已看内容",
        "/unwatched": "未看内容",
        "/queue": "播放队列",
        "/photos": "照片",
        "/people": "人物",
        "/collections": "合集",
        "/music/songs": "歌曲",
        "/music/albums": "专辑",
        "/music/artists": "艺术家",
        "/music/playlists": "歌单",
        "/music/recent": "最近播放",
        // 侧栏能到达的每一个页面都必须在这里，否则从它进入详情页再返回，读者会
        // 被扔回首页。相册、保险库和管理区此前全部缺席。
        "/albums": "相册",
        "/vault": "保险库",
        "/sources": "媒体源",
        "/status": "仪表盘",
        "/admin": "服务管理",
        "/account": "设置"
    ]

    /// Routes shaped `/{prefix}/{id}`, rebuilt rather than echoed.
    private static let identifierRoutes: [(prefix: String, label: String)] = [
        ("/category", "资料库"),
        ("/collections", "合集"),
        ("/people", "人物"),
        // 智能集合、智能歌单和远程来源分组也是侧栏条目，从它们点进一部作品再
        // 返回，同样该回到那一行，而不是首页。
        ("/smart-collections", "集合"),
        ("/music/playlists", "歌单"),
        ("/remote", "媒体源"),
        // 详情页之间也会互相跳：从一部作品点进演员，再从演员的作品点回另一部。
        // 那条路径上的每一跳都有真实的来处。
        ("/item", "详情")
    ]

    /// - Parameters:
    ///   - requestHead: The raw request head; only `Referer` is read from it.
    ///   - fallback: Used when there is no referrer, it is cross-origin, or it
    ///     names a route this product does not serve.
    static func target(requestHead: String, fallback: Target) -> Target {
        guard let referer = headerValue("referer", in: requestHead),
              let parsed = sameOriginLocation(from: referer)
        else { return fallback }
        return resolve(path: parsed.path, query: parsed.query) ?? fallback
    }

    /// The view-state keys the library family carries in its URL.
    ///
    /// A browse page's search term, sort and page live in its URL, so dropping
    /// them returns the reader to the right category but the wrong view. Only
    /// these keys survive, each re-encoded, so the referrer cannot append
    /// arbitrary parameters.
    private static let preservedQueryKeys = ["type", "group", "sort", "q", "offset", "limit"]

    static func resolve(path: String, query: [(name: String, value: String)] = []) -> Target? {
        if let label = fixedRoutes[path] {
            return Target(label: "返回\(label)", href: path + encodedQuery(query))
        }
        for route in identifierRoutes where path.hasPrefix(route.prefix + "/") {
            let rawIdentifier = String(path.dropFirst(route.prefix.count + 1))
            guard !rawIdentifier.isEmpty,
                  !rawIdentifier.contains("/"),
                  let identifier = ServerWebURL.pathSegment(decodePathSegment(rawIdentifier))
            else { continue }
            return Target(label: "返回\(route.label)", href: "\(route.prefix)/\(identifier)" + encodedQuery(query))
        }
        return nil
    }

    // MARK: - Parsing

    /// The referrer's path, but only when it points at this same origin.
    ///
    /// Cross-origin referrers are dropped rather than "cleaned": there is no
    /// reason for another site's path to steer navigation inside this product.
    /// Rebuilds the surviving query from scratch: known keys only, each value
    /// bounded and re-encoded, so no byte of the referrer reaches the markup as
    /// written.
    private static func encodedQuery(_ query: [(name: String, value: String)]) -> String {
        let pairs = preservedQueryKeys.compactMap { key -> String? in
            guard let raw = query.first(where: { $0.name == key })?.value,
                  let encoded = ServerWebURL.queryValue(raw)
            else { return nil }
            return "\(key)=\(encoded)"
        }
        // A plain `&` here: the target is HTML-escaped where it is emitted, so
        // pre-escaping it would ship `&amp;amp;` in the href.
        return pairs.isEmpty ? "" : "?" + pairs.joined(separator: "&")
    }

    private static func sameOriginLocation(from referer: String) -> (path: String, query: [(name: String, value: String)])? {
        guard let components = URLComponents(string: referer),
              let path = components.path.nilIfEmptyPath
        else { return nil }
        let query = (components.queryItems ?? []).compactMap { item -> (name: String, value: String)? in
            guard let value = item.value, !value.isEmpty else { return nil }
            return (item.name, value)
        }
        // Same-origin is decided by the router's own Host/Origin checks before
        // the page renders; here the referrer only survives if it is a relative
        // or loopback URL, never an arbitrary external host.
        if let host = components.host {
            guard host == "127.0.0.1" || host == "localhost" || host == "[::1]" || host == "::1" else { return nil }
        }
        guard path.hasPrefix("/"), path.utf8.count <= 512, !path.contains("//") else { return nil }
        guard !path.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) else { return nil }
        return (path, query)
    }

    private static func decodePathSegment(_ value: String) -> String {
        value.removingPercentEncoding ?? value
    }

    private static func headerValue(_ name: String, in requestHead: String) -> String? {
        guard let headerEnd = requestHead.range(of: "\r\n\r\n") else { return nil }
        let head = requestHead[..<headerEnd.lowerBound]
        for line in head.components(separatedBy: "\r\n").dropFirst() {
            guard let colon = line.firstIndex(of: ":"),
                  line[..<colon].lowercased() == name
            else { continue }
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }
}

private extension String {
    var nilIfEmptyPath: String? { isEmpty ? nil : self }
}
