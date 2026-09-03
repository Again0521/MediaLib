import Foundation
import MediaLibCore

/// 管理读接口共用的严格查询契约。
///
/// 路由只负责认证、权限和 HTTP 映射；键白名单、重复键、百分号解码、控制字符、
/// 页边界与枚举值域集中在这里，避免每新增一个管理列表就复制一份略有差异的解析器。
enum ServerAdministrationQueryParser {
    static let maximumOffset = 1_000_000
    static let maximumLimit = 100
    static let maximumSearchLength = 128

    struct Sessions: Equatable {
        let offset: Int
        let limit: Int
        let searchText: String?
    }

    struct Page: Equatable {
        let offset: Int
        let limit: Int
    }

    struct SecurityEvents: Equatable {
        let offset: Int
        let limit: Int
        let category: ServerSecurityEventCategory?
        let outcome: ServerSecurityEventOutcome?
        let searchText: String?
    }

    struct Jobs: Equatable {
        let offset: Int
        let limit: Int
        let state: ServerJobState?
        let kind: String?
        let scope: String?
        let searchText: String?
    }

    struct PlaybackSessions: Equatable {
        let offset: Int
        let limit: Int
        let state: ServerHLSPlaybackSessionState?
        let searchText: String?
    }

    struct Backups: Equatable {
        let offset: Int
        let limit: Int
        let kind: ServerBackupKind?
    }

    struct Sources: Equatable {
        let offset: Int
        let limit: Int
        let searchText: String?
    }

    static func users(from target: String) -> Page? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/users",
            allowedKeys: ["offset", "limit"]
        ), let page = page(values, defaultLimit: 24)
        else { return nil }
        return Page(offset: page.offset, limit: page.limit)
    }

    static func libraries(from target: String) -> Bool {
        values(from: target, path: "/api/v1/admin/libraries", allowedKeys: []) != nil
    }

    static func dashboard(from target: String) -> Bool {
        values(from: target, path: "/api/v1/admin/dashboard", allowedKeys: []) != nil
    }

    static func settings(from target: String) -> Bool {
        values(from: target, path: "/api/v1/admin/settings", allowedKeys: []) != nil
    }

    static func diagnostics(from target: String) -> Bool {
        values(from: target, path: "/api/v1/admin/diagnostics", allowedKeys: []) != nil
    }

    static func backupDownload(from target: String, path: String) -> Bool {
        values(from: target, path: path, allowedKeys: []) != nil
    }

    static func sessions(from target: String) -> Sessions? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/sessions",
            allowedKeys: ["offset", "limit", "q"]
        ), let page = page(values, defaultLimit: 50), let searchText = search(values["q"])
        else { return nil }
        return Sessions(offset: page.offset, limit: page.limit, searchText: searchText)
    }

    static func securityEvents(from target: String, path: String) -> SecurityEvents? {
        guard ["/api/v1/admin/security-events", "/api/v1/admin/logs"].contains(path),
              let values = values(
                from: target,
                path: path,
                allowedKeys: ["offset", "limit", "category", "outcome", "q"]
              ),
              let page = page(values, defaultLimit: 50),
              let searchText = search(values["q"])
        else { return nil }
        let category = values["category"].flatMap(ServerSecurityEventCategory.init(rawValue:))
        let outcome = values["outcome"].flatMap(ServerSecurityEventOutcome.init(rawValue:))
        guard values["category"] == nil || category != nil,
              values["outcome"] == nil || outcome != nil
        else { return nil }
        return SecurityEvents(
            offset: page.offset,
            limit: page.limit,
            category: category,
            outcome: outcome,
            searchText: searchText
        )
    }

    static func jobs(from target: String) -> Jobs? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/jobs",
            allowedKeys: ["offset", "limit", "state", "kind", "scope", "q"]
        ), let page = page(values, defaultLimit: 50), let searchText = search(values["q"])
        else { return nil }
        let state = values["state"].flatMap(ServerJobState.init(rawValue:))
        let knownKinds: Set<String> = [
            "library.scan", "library.reindex", "metadata.refresh",
            "database.backup", "database.restore", "transcode-cache.clear"
        ]
        let kind = values["kind"]
        let scope = values["scope"]
        guard values["state"] == nil || state != nil,
              kind.map(knownKinds.contains) ?? true,
              scope.map({ ["library", "server"].contains($0) }) ?? true
        else { return nil }
        return Jobs(
            offset: page.offset,
            limit: page.limit,
            state: state,
            kind: kind,
            scope: scope,
            searchText: searchText
        )
    }

    static func playbackSessions(from target: String) -> PlaybackSessions? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/playback-sessions",
            allowedKeys: ["offset", "limit", "state", "q"]
        ), let page = page(values, defaultLimit: 50), let searchText = search(values["q"])
        else { return nil }
        let state = values["state"].flatMap(ServerHLSPlaybackSessionState.init(rawValue:))
        guard values["state"] == nil || state != nil else { return nil }
        return PlaybackSessions(
            offset: page.offset,
            limit: page.limit,
            state: state,
            searchText: searchText
        )
    }

    static func backups(from target: String) -> Backups? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/backups",
            allowedKeys: ["offset", "limit", "kind"]
        ), let page = page(values, defaultLimit: 100)
        else { return nil }
        let kind = values["kind"].flatMap(ServerBackupKind.init(rawValue:))
        guard values["kind"] == nil || kind != nil else { return nil }
        return Backups(offset: page.offset, limit: page.limit, kind: kind)
    }

    static func sources(from target: String) -> Sources? {
        guard let values = values(
            from: target,
            path: "/api/v1/admin/sources",
            allowedKeys: ["offset", "limit", "q"]
        ), let page = page(values, defaultLimit: 50), let searchText = search(values["q"])
        else { return nil }
        return Sources(offset: page.offset, limit: page.limit, searchText: searchText)
    }

    private static func values(
        from target: String,
        path expectedPath: String,
        allowedKeys: Set<String>
    ) -> [String: String]? {
        let pieces = target.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        guard pieces.count <= 2, pieces.first.map(String.init) == expectedPath else { return nil }
        guard pieces.count == 2 else { return [:] }
        guard !pieces[1].isEmpty else { return nil }
        var result: [String: String] = [:]
        for pair in pieces[1].split(separator: "&", omittingEmptySubsequences: false) {
            guard !pair.isEmpty else { return nil }
            let keyValue = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard keyValue.count == 2,
                  let key = decode(String(keyValue[0])),
                  let value = decode(String(keyValue[1])),
                  allowedKeys.contains(key),
                  result[key] == nil,
                  value.utf8.count <= 512,
                  !containsControlCharacter(value)
            else { return nil }
            result[key] = value
        }
        return result
    }

    private static func page(
        _ values: [String: String],
        defaultLimit: Int
    ) -> (offset: Int, limit: Int)? {
        guard let offset = strictNonnegativeInteger(values["offset"] ?? "0"),
              offset <= maximumOffset,
              let limit = strictNonnegativeInteger(values["limit"] ?? String(defaultLimit)),
              (1...maximumLimit).contains(limit)
        else { return nil }
        return (offset, limit)
    }

    /// `nil` 输入表示没有搜索键；非 nil 的空白输入是合法的“清除筛选”，因此用
    /// 双层 Optional 区分“合法且无搜索词”和“输入非法”。
    private static func search(_ raw: String?) -> String?? {
        guard let raw else { return .some(nil) }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.utf8.count <= maximumSearchLength,
              !containsControlCharacter(trimmed)
        else { return nil }
        return .some(trimmed.isEmpty ? nil : trimmed)
    }

    private static func decode(_ value: String) -> String? {
        value.replacingOccurrences(of: "+", with: " ").removingPercentEncoding
    }

    private static func containsControlCharacter(_ value: String) -> Bool {
        value.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f }
    }

    private static func strictNonnegativeInteger(_ value: String) -> Int? {
        guard !value.isEmpty, value.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(value)
    }
}

struct ServerAdminPlaybackSessionsPage: Equatable {
    let totalCount: Int
    let offset: Int
    let sessions: [ServerAdminHLSPlaybackSession]

    var isTruncated: Bool { offset + sessions.count < totalCount }
}

/// 内存 HLS 状态的管理投影。状态机拥有资源生命周期；此目录只做无副作用的
/// 搜索、稳定排序和分页，HTTP 路由不再承担列表算法。
enum ServerAdminPlaybackSessionCatalog {
    static func page(
        _ sessions: [ServerAdminHLSPlaybackSession],
        query: ServerAdministrationQueryParser.PlaybackSessions
    ) -> ServerAdminPlaybackSessionsPage {
        let filtered = sessions.filter { session in
            guard query.state.map({ session.state == $0 }) ?? true else { return false }
            guard let searchText = query.searchText else { return true }
            return [session.sessionID, session.userID, session.mode, session.state.rawValue]
                .contains { $0.localizedCaseInsensitiveContains(searchText) }
        }.sorted {
            if $0.startedAt != $1.startedAt { return $0.startedAt > $1.startedAt }
            return $0.sessionID < $1.sessionID
        }
        let selected = query.offset < filtered.count
            ? Array(filtered.dropFirst(query.offset).prefix(query.limit))
            : []
        return ServerAdminPlaybackSessionsPage(
            totalCount: filtered.count,
            offset: query.offset,
            sessions: selected
        )
    }
}
