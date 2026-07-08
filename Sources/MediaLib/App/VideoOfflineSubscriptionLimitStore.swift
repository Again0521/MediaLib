import Combine
import Foundation

/// 离线订阅自定义剧集数 sheet 的请求状态容器。
///
/// 只拥有当前上限输入请求；系列查找、可缓存判断、订阅保存、错误提示和下载副作用仍留在
/// 原有离线缓存领域路径，避免把离线缓存业务塞进 presentation request Store。
@MainActor
final class VideoOfflineSubscriptionLimitStore: ObservableObject {
    @Published private(set) var request: VideoOfflineSubscriptionLimitRequest?

    func setRequest(_ request: VideoOfflineSubscriptionLimitRequest?) {
        self.request = request
    }

    func presentRequest(
        itemID: String,
        seriesTitle: String,
        qualityID: String?,
        initialEpisodeLimit: Int,
        hidesDetail: Bool
    ) {
        request = VideoOfflineSubscriptionLimitRequest(
            itemID: itemID,
            seriesTitle: seriesTitle,
            qualityID: qualityID,
            initialEpisodeLimit: initialEpisodeLimit,
            hidesDetail: hidesDetail
        )
    }

    func isCurrent(_ request: VideoOfflineSubscriptionLimitRequest) -> Bool {
        self.request?.id == request.id
    }

    func clearIfCurrent(_ request: VideoOfflineSubscriptionLimitRequest) {
        guard isCurrent(request) else { return }
        self.request = nil
    }

    func clear() {
        request = nil
    }
}
