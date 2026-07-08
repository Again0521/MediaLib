import Combine
import Foundation

/// 音乐元数据补充的活动状态容器。
///
/// 只拥有补充进行中标志和设置页进度文案；数据源搜索、标签/歌词写回、
/// 健康中心后台任务和提示文案仍由 AppState+MetadataSupplement 编排。
@MainActor
final class MusicMetadataActivityStore: ObservableObject {
    @Published private(set) var isFetching = false
    @Published private(set) var isSupplementing = false
    @Published private(set) var fetchProgress = ""

    func setFetching(_ fetching: Bool) {
        isFetching = fetching
    }

    func beginFetching(progress: String) {
        isFetching = true
        fetchProgress = progress
    }

    func finishFetching() {
        isFetching = false
    }

    func setSupplementing(_ supplementing: Bool) {
        isSupplementing = supplementing
    }

    func beginSupplementing() {
        isSupplementing = true
    }

    func finishSupplementing() {
        isSupplementing = false
    }

    func setFetchProgress(_ progress: String) {
        fetchProgress = progress
    }
}
