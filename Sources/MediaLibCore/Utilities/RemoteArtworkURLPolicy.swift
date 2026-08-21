import CryptoKit
import Foundation

/// 远程封面地址的两个处理规则：向上游索取合适的尺寸，以及给它一个与凭据无关的
/// 稳定身份。
///
/// 这两条规则原本只有 HTTP 服务端有（`ServerRemoteArtworkURL`），而客户端的封面
/// 缓存正好踩着它们解决过的两个坑：缓存键里带着会轮换的 `api_key`，以及固定按
/// `maxWidth=700` 取图却只解码到更小的尺寸。纯字符串／URL 运算、零依赖，因此下沉到
/// Core 由两端共用；`ServerRemoteArtworkURL` 保留同名转发以免调用点大面积改动。
public enum RemoteArtworkURLPolicy {
    /// 上游可以按需改写的尺寸参数。
    ///
    /// Emby/Jellyfin 用 `maxWidth`/`maxHeight`；Plex 的图片路由（`/photo/:/transcode`）
    /// 用 `width`/`height`。只认前一对时，Plex 的海报一直在下原图。
    static let resizableQueryKeys: Set<String> = ["maxwidth", "maxheight", "width", "height"]

    /// 会随会话变化、因而绝不能进入缓存键的参数。
    static let volatileQueryKeys: Set<String> = [
        "api_key", "apikey", "x-emby-token", "x-plex-token", "plextoken",
        "token", "access_token", "quality"
    ]

    /// 同步阶段写下的 Emby/Jellyfin 封面地址固定带 `maxWidth=700`。真正要的往往是
    /// 160/320/512/640/1024 这几个桶，其中海报墙用得最多的是 320——于是每张卡片都在
    /// 下载一张四倍面积的图，只为把它缩小后丢掉。这里按需要的桶改写尺寸。
    ///
    /// 只改写**已经存在**的尺寸参数：没有该参数的上游保持原样，避免给不认识该参数的
    /// 服务端发出会被拒的请求。凭据参数一律不动。
    public static func sized(_ url: URL, maximumPixel: Int) -> URL {
        guard maximumPixel > 0,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let queryItems = components.queryItems,
              !queryItems.isEmpty
        else { return url }
        guard queryItems.contains(where: { resizableQueryKeys.contains($0.name.lowercased()) }) else {
            return url
        }
        components.queryItems = queryItems.map { item in
            guard resizableQueryKeys.contains(item.name.lowercased()) else { return item }
            // 上游给的是"不超过"语义，因此请求的桶值直接作为上限；比桶更小的原图
            // 不会被放大，仍然按原尺寸返回。
            guard let existing = item.value.flatMap(Int.init), existing > maximumPixel else { return item }
            return URLQueryItem(name: item.name, value: String(maximumPixel))
        }
        return components.url ?? url
    }

    /// 与凭据无关的稳定身份，用作封面缓存键。
    ///
    /// 直接用整个 URL 做键是不行的：`api_key` 会轮换，轮换一次整个缓存全部失效——
    /// 客户端每重新同步一次 Emby，`posterPath` 就换成新 token 的地址，几百 MB 的
    /// 磁盘封面缓存一次性全部落空，所有海报重下重解。剥掉已知的凭据参数后，同一张
    /// 封面在 token 变化前后得到同一个键。尺寸参数也一并剥掉，因为桶值由调用方
    /// 单独带进键里。
    public static func stableIdentity(for url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        let stripped = volatileQueryKeys.union(resizableQueryKeys)
        let retained = components?.queryItems?
            .filter { !stripped.contains($0.name.lowercased()) }
            .sorted { $0.name < $1.name }
        components?.queryItems = (retained?.isEmpty == false) ? retained : nil
        let canonical = components?.url?.absoluteString ?? url.absoluteString
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// 字符串形态的便利入口：客户端的封面路径存在数据库里，取出来就是字符串，
    /// 而且可能是本地文件路径（那时没有可剥的凭据，原样返回）。
    public static func stableIdentity(forPath path: String) -> String {
        guard let url = URL(string: path), url.scheme?.hasPrefix("http") == true else {
            return SHA256.hash(data: Data(path.utf8)).map { String(format: "%02x", $0) }.joined()
        }
        return stableIdentity(for: url)
    }
}
