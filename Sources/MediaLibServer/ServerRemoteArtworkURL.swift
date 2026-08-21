import Foundation
import MediaLibCore

/// 远程封面地址的尺寸改写与稳定身份。
///
/// 规则本身住在 `MediaLibCore.RemoteArtworkURLPolicy`：客户端的封面缓存需要**同一套**
/// 判据（缓存键里不能带会轮换的 `api_key`，取图尺寸要跟着解码尺寸走），而它们是纯
/// URL 运算、零依赖。这里保留同名转发，服务端的调用点与测试不必改动。
enum ServerRemoteArtworkURL {
    static func sized(_ url: URL, maximumPixel: Int) -> URL {
        RemoteArtworkURLPolicy.sized(url, maximumPixel: maximumPixel)
    }

    static func stableIdentity(for url: URL) -> String {
        RemoteArtworkURLPolicy.stableIdentity(for: url)
    }
}
