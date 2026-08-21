import Foundation
import MediaLibCore

/// 把"这个账号被授权了哪些媒体来源"翻译成"允许出现在服务端查询里的具体
/// `source_path` 集合"。
///
/// 存在的理由：本地来源的条目 `source_path` 恰好等于来源自身的 `path`，而远程
/// 连接器只为**整台服务器**建一行 `MediaSource`（`emby://host/<sourceID>`），条目
/// 却写逐资料库子路径（`<root>/library/<viewID>/type/<type>/name/<name>`）。
/// 服务端所有查询都用精确相等连接授权表，于是远程内容一条也进不来——侧栏分类
/// 为空、资料库为空。这里在 Swift 侧把授权根展开成该根下真实存在的具体路径，
/// SQL 侧继续用等值连接。
///
/// 为什么不把 SQL 的连接条件改成前缀匹配：`media_items` 上有多条以 `source_path`
/// 打头的复合索引（`(source_path, type, parent_id, <排序键>)`），等值连接能从授权
/// 临时表的主键驱动并 seek；换成 `substr()`/`GLOB` 都不可 sarg，十几处服务端查询
/// 会集体退化成全表扫描。展开法把前缀判断收敛到每请求一次的小集合运算里。
enum ServerSourceAuthorizationResolver {
    /// 只有这些 scheme 的来源根会被展开。
    ///
    /// 本地来源的条目本来就写着与来源 `path` 逐字相同的 `source_path`，因此把展开
    /// 限制在远程 scheme 上，对本地行为是**可证明的 no-op**——没有任何本地条目会
    /// 因此变得可见或不可见。这也顺带避开了"保险库目录嵌套在公开目录之下"这类
    /// 本地布局带来的归属歧义。
    /// 与 `RemoteLibraryPathPolicy.mediaServerSchemes` 是同一份，不再手抄：抄出来的
    /// 副本迟早会和它漂移，而漂移的后果是某个 scheme 的内容悄悄整台消失或整台越权。
    static let expandableSchemes = RemoteLibraryPathPolicy.mediaServerSchemes

    /// 解析授权路径集合。
    ///
    /// - Parameters:
    ///   - sources: **全部**来源，包含保险库。归属判定必须看到全部来源，否则
    ///     嵌套在公开来源之下的私密来源会被公开来源"顺手"授权。
    ///   - concreteSourcePaths: 资料库里真实出现过的 distinct `source_path`。
    ///   - isAuthorized: 逐来源的授权判定（权限 + 逐库授予）。
    static func authorizedSourcePaths(
        sources: [MediaSource],
        concreteSourcePaths: [String],
        isAuthorized: (MediaSource) -> Bool
    ) -> Set<String> {
        let roots = sources.filter { !$0.path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var authorized: Set<String> = []

        // 1. 既有语义原样保留：授权的非私密来源，其自身路径始终在集合内。
        for source in roots where source.mediaType != .privateCollection && isAuthorized(source) {
            authorized.insert(source.path)
        }

        let expandableRoots = roots.filter { isExpandableRoot($0.path) }
        guard !expandableRoots.isEmpty else { return authorized }

        // 2. 展开：把每个具体路径归属到**最长**的包含它的来源根。
        for concrete in concreteSourcePaths {
            let trimmed = concrete.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !authorized.contains(trimmed) else { continue }
            // 最长匹配，而不是"命中任一授权根"。后者会让 `/Volumes/Media` 顺带
            // 授权 `/Volumes/Media/Vault`——那是现有精确相等实现天然免疫、而展开
            // 会引入的提权。
            guard let owner = roots
                .filter({ SourcePathPolicy.isSourcePath(trimmed, inside: $0.path) })
                .max(by: { $0.path.count < $1.path.count })
            else { continue }
            guard isExpandableRoot(owner.path),
                  owner.mediaType != .privateCollection,
                  isAuthorized(owner)
            else { continue }
            authorized.insert(trimmed)
        }
        return authorized
    }

    /// 判断一个来源根是否可以安全展开。
    ///
    /// 除 scheme 白名单外还要求 scheme 之后至少有一个非空路径分量：`emby://` 这样
    /// 的裸 scheme 会把该协议下的一切都收进来。这些根由 `connectRemoteMediaServer`
    /// 机器生成（`emby://<host>/<sourceID>`、`mlink://<sourceID>`），不是用户手输，
    /// 因此一个分量的下限既足够又不会误伤没有主机名的 Mlink。
    static func isExpandableRoot(_ path: String) -> Bool {
        let normalized = SourcePathPolicy.normalizedSourceRoot(
            path.trimmingCharacters(in: .whitespacesAndNewlines)
        )
        // 根为 `/` 时 `SourcePathPolicy.isSourcePath` 对任何绝对路径都返回 true，
        // 展开它等于授权整个资料库。scheme 白名单已经排除了它，这里再挡一道，
        // 免得将来放宽 scheme 列表时把这个后果一起放宽。
        guard normalized != "/" else { return false }
        let lowercased = normalized.lowercased()
        guard let scheme = expandableSchemes.first(where: { lowercased.hasPrefix($0) }) else {
            return false
        }
        let remainder = normalized.dropFirst(scheme.count)
        return remainder.split(separator: "/", omittingEmptySubsequences: true).isEmpty == false
    }
}
