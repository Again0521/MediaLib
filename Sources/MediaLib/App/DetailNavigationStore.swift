import Combine
import Foundation
import MediaLibCore

struct DetailReturnContext: Equatable, Sendable {
    let destinationID: String
    let anchorID: String
    let searchText: String?
}

private enum DetailNavigationNode: Equatable, Sendable {
    case media(String)
    case person(String)
}

/// 详情页导航状态容器。
///
/// 只拥有当前媒体详情、人物详情、返回锚点和详情内跳转历史；媒体库查询、视图呈现、
/// repository 更新和其他副作用仍留在 AppState/Views。AppState 暂时保留同名 facade，
/// 让现有 `@EnvironmentObject appState` 读取路径和刷新语义保持不变。
@MainActor
final class DetailNavigationStore: ObservableObject {
    @Published private(set) var selectedItem: MediaItem?
    @Published private(set) var selectedPersonID: String?
    @Published private(set) var detailReturnContext: DetailReturnContext?

    private var navigationHistory: [DetailNavigationNode] = []

    func setSelectedItem(_ item: MediaItem?) {
        selectedItem = item
    }

    func setSelectedPersonID(_ personID: String?) {
        selectedPersonID = personID
    }

    func presentDetail(
        _ item: MediaItem,
        from destinationID: String,
        anchorID: String,
        searchText: String? = nil
    ) {
        let normalizedSearchText = searchText?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        navigationHistory.removeAll()
        selectedPersonID = nil
        selectedItem = item
        detailReturnContext = DetailReturnContext(
            destinationID: destinationID,
            anchorID: anchorID,
            searchText: normalizedSearchText?.isEmpty == false ? normalizedSearchText : nil
        )
    }

    func presentRelatedDetail(_ item: MediaItem) {
        if let selectedItem, selectedItem.id != item.id {
            navigationHistory.append(.media(selectedItem.id))
        } else if let selectedPersonID {
            navigationHistory.append(.person(selectedPersonID))
        }
        selectedPersonID = nil
        selectedItem = item
    }

    func presentPersonDetail(_ personID: String) {
        if let selectedItem {
            navigationHistory.append(.media(selectedItem.id))
        } else if let selectedPersonID, selectedPersonID != personID {
            navigationHistory.append(.person(selectedPersonID))
        }
        selectedItem = nil
        selectedPersonID = personID
    }

    func dismissDetail(resolveMediaItem: (String) -> MediaItem?) {
        guard let previous = navigationHistory.popLast() else {
            selectedItem = nil
            selectedPersonID = nil
            return
        }
        switch previous {
        case .media(let id):
            selectedPersonID = nil
            selectedItem = resolveMediaItem(id)
        case .person(let id):
            selectedItem = nil
            selectedPersonID = id
        }
    }

    func consumeReturnContext(destinationID: String, anchorID: String) {
        guard detailReturnContext?.destinationID == destinationID,
              detailReturnContext?.anchorID == anchorID else { return }
        detailReturnContext = nil
    }

    func clear() {
        navigationHistory.removeAll()
        detailReturnContext = nil
        selectedItem = nil
        selectedPersonID = nil
    }
}
