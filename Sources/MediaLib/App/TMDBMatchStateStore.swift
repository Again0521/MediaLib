import Combine
import Foundation

/// 剧集 / 动漫 TMDB 批量匹配的进行中状态容器。
///
/// 只拥有“是否正在匹配”的并发闸门和按钮进度态；候选筛选、API Key 校验、TMDB 搜索、
/// 封面落盘、元数据写回、提示文案和自动任务调度仍由 AppState 现有流程编排。
@MainActor
final class TMDBMatchStateStore: ObservableObject {
    @Published private(set) var isMatching = false

    func setMatching(_ matching: Bool) {
        isMatching = matching
    }

    func begin() {
        isMatching = true
    }

    func finish() {
        isMatching = false
    }
}
