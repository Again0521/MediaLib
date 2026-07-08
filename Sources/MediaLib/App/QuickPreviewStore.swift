import Combine
import Foundation
import MediaLibCore

/// 快速预览 sheet 的选中项状态容器。
///
/// 只拥有当前预览条目；条目刷新、隐私过滤、详情页按钮和 sheet 呈现仍由 AppState/Views
/// 通过同名 facade 编排，避免把所有弹层状态合并成宽泛的 presentation god object。
@MainActor
final class QuickPreviewStore: ObservableObject {
    @Published private(set) var item: MediaItem?

    func setItem(_ item: MediaItem?) {
        self.item = item
    }

    func clear() {
        item = nil
    }

    func replaceIfCurrentItemMatches(id: String, with updated: MediaItem) {
        guard item?.id == id else { return }
        item = updated
    }
}
