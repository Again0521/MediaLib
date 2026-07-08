import Combine
import Foundation

/// 手动视频集合创建 sheet 的请求状态容器。
///
/// 只拥有“用哪些条目创建集合”的临时请求；集合 CRUD、通知、排序和 repository 仍留在
/// 原有集合领域路径，避免把集合业务塞进 presentation request Store。
@MainActor
final class VideoManualCollectionCreationStore: ObservableObject {
    @Published private(set) var request: VideoManualCollectionCreationRequest?

    func setRequest(_ request: VideoManualCollectionCreationRequest?) {
        self.request = request
    }

    func requestCreation(itemIDs: [String]) {
        guard !itemIDs.isEmpty else { return }
        request = VideoManualCollectionCreationRequest(itemIDs: itemIDs)
    }

    func isCurrent(_ request: VideoManualCollectionCreationRequest) -> Bool {
        self.request?.id == request.id
    }

    func clearIfCurrent(_ request: VideoManualCollectionCreationRequest) {
        guard isCurrent(request) else { return }
        self.request = nil
    }

    func clear() {
        request = nil
    }
}
