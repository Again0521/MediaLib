import Combine
import Foundation
import MediaLibCore

/// 批量多选的状态容器（从 AppState 抽出的第一个领域 Store，R1-ARCH-001 试水）。
///
/// 仅承载**纯选择态**（是否处于多选、已选 ID 集合）与其增删操作；批量动作
/// （标记已看 / 想看 / 评分 / 清理 / 移除）因依赖 repository、Trakt、日志、提示等，
/// 仍留在 AppState，只是改为经此 Store 读取目标集合。
///
/// 行为逐字搬自原 AppState 对应方法，零语义变化。AppState 持有本 Store 并把它的
/// `objectWillChange` 转发到自身，使既有 `@EnvironmentObject appState` 的视图照常刷新，
/// AppState 对外 API（属性与方法）保持不变（视图零改动）。
@MainActor
final class SelectionStore: ObservableObject {
    @Published private(set) var isSelectionModeActive = false
    @Published private(set) var selectedItemIDs: Set<String> = []

    /// 进入/退出多选模式；退出时清空已选。
    func toggleMode() {
        isSelectionModeActive.toggle()
        if !isSelectionModeActive {
            selectedItemIDs.removeAll()
        }
    }

    /// 退出多选并清空（已是退出且无选中时短路）。
    func exit() {
        guard isSelectionModeActive || !selectedItemIDs.isEmpty else { return }
        isSelectionModeActive = false
        selectedItemIDs.removeAll()
    }

    func toggleItem(_ id: String) {
        if selectedItemIDs.contains(id) {
            selectedItemIDs.remove(id)
        } else {
            selectedItemIDs.insert(id)
        }
    }

    /// 在给定 ID 范围内全选 / 取消全选。
    func setSelection(_ ids: [String], selected: Bool) {
        if selected {
            selectedItemIDs.formUnion(ids)
        } else {
            selectedItemIDs.subtract(ids)
        }
    }

    /// 由 ID 集合还原为有序条目（按传入顺序），仅取集合内存在的条目。
    func resolveSelected(orderedBy ordered: [MediaItem]) -> [MediaItem] {
        ordered.filter { selectedItemIDs.contains($0.id) }
    }
}
