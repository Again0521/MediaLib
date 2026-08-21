import Foundation

/// 远程媒体服务器来源路径的解析规则。
///
/// 远程连接器把资料库归属编码进 `source_path`：根是 `emby://<host>/<sourceID>`，
/// 条目写 `<root>/library/<viewID>/type/<collectionType>/name/<百分号编码名称>`。
/// 客户端靠反解这段字符串就能列出每台服务器下的资料库——不联网、不建表。
///
/// 这些函数原本是 `EmbyService` 的静态成员，只有客户端 target 能用，于是服务端
/// 无法按同一口径给网页分组。它们是纯字符串运算、零依赖，因此下沉到 Core 由两端
/// 共用；`EmbyService` 保留同名转发以免调用点大面积改动。
public enum RemoteLibraryPathPolicy {
    /// 已知的远程媒体服务器 scheme。
    public static let mediaServerSchemes = ["emby://", "jellyfin://", "plex://", "mlink://"]

    public static func isMediaServerSourcePath(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return mediaServerSchemes.contains { lowercased.hasPrefix($0) }
    }

    /// Emby 与 Jellyfin 共用同一套播放上报/取流 API，应被同等对待；Plex 另有分支。
    public static func isEmbyCompatibleSourcePath(_ value: String?) -> Bool {
        guard let value else { return false }
        let lowercased = value.lowercased()
        return lowercased.hasPrefix("emby://") || lowercased.hasPrefix("jellyfin://")
    }

    /// 从逐资料库子路径回到该服务器的来源根。不含 `/library/` 时它自己就是根。
    public static func sourceRootPath(from librarySourcePath: String) -> String? {
        guard isMediaServerSourcePath(librarySourcePath) else { return nil }
        guard let range = librarySourcePath.range(of: "/library/", options: .caseInsensitive) else {
            return librarySourcePath
        }
        return String(librarySourcePath[..<range.lowerBound])
    }

    /// 解析逐资料库子路径中的 `(viewID, 名称, collectionType)`。
    ///
    /// 三种历史形态都要认：只有 viewID；`viewID/type/<t>/name/<n>` 的键值形态；
    /// 以及更早的 `<name>/<viewID>` 两段式。少认一种就会让老资料库的分组变成空名。
    public static func libraryInfo(
        from sourcePath: String
    ) -> (id: String, name: String?, collectionType: String?)? {
        guard isMediaServerSourcePath(sourcePath),
              let range = sourcePath.range(of: "/library/", options: .caseInsensitive) else { return nil }
        let remainder = sourcePath[range.upperBound...]
        let parts = remainder.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        if parts.count == 1, !parts[0].isEmpty {
            return (parts[0], nil, nil)
        }
        if !parts.isEmpty, !parts[0].isEmpty {
            var name: String?
            var collectionType: String?
            var index = 1
            while index + 1 < parts.count {
                let key = parts[index]
                let value = parts[index + 1]
                if key == "name" {
                    name = value.removingPercentEncoding ?? value
                } else if key == "type" {
                    collectionType = value.removingPercentEncoding ?? value
                }
                index += 2
            }
            if name != nil || collectionType != nil {
                return (parts[0], name, collectionType)
            }
        }
        guard parts.count >= 2, !parts[0].isEmpty, !parts[1].isEmpty else { return nil }
        let name = parts[0].removingPercentEncoding ?? parts[0]
        return (parts[1], name, nil)
    }

    /// 音乐类资料库在客户端的远程分组里不单独成行——它们由分组内的「音乐」入口
    /// 统一承载，否则同一批远程音乐会被拆成两个没有上下文的入口。
    public static func isMusicLibrary(collectionType: String?) -> Bool {
        collectionType?.lowercased() == "music"
    }
}
