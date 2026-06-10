import MediaLibCore
import SwiftUI

struct VideoManualCollectionMenuItems: View {
    @EnvironmentObject private var appState: AppState
    let items: [MediaItem]
    var currentCollectionID: String?

    var body: some View {
        let validItems = items.filter(appState.canUseInVideoManualCollection)
        if !validItems.isEmpty {
            if let currentCollectionID,
               appState.videoManualCollection(id: currentCollectionID) != nil {
                Menu {
                    Button {
                        appState.reorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveToTop)
                    } label: {
                        Label("移到顶部", systemImage: "arrow.up.to.line")
                    }
                    .disabled(!appState.canReorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveToTop))

                    Button {
                        appState.reorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveUp)
                    } label: {
                        Label("上移", systemImage: "arrow.up")
                    }
                    .disabled(!appState.canReorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveUp))

                    Button {
                        appState.reorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveDown)
                    } label: {
                        Label("下移", systemImage: "arrow.down")
                    }
                    .disabled(!appState.canReorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveDown))

                    Button {
                        appState.reorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveToBottom)
                    } label: {
                        Label("移到底部", systemImage: "arrow.down.to.line")
                    }
                    .disabled(!appState.canReorderVideoManualCollection(validItems, collectionID: currentCollectionID, operation: .moveToBottom))
                } label: {
                    Label("调整集合顺序", systemImage: "arrow.up.arrow.down")
                }

                Button {
                    appState.removeFromVideoManualCollection(validItems, collectionID: currentCollectionID)
                } label: {
                    Label("从集合移除", systemImage: "minus.circle")
                }
            }

            Menu {
                Button {
                    appState.requestVideoManualCollectionCreation(items: validItems)
                } label: {
                    Label("新建集合并加入", systemImage: "rectangle.stack.badge.plus")
                }

                if !appState.videoManualCollections.isEmpty {
                    Divider()
                    ForEach(appState.videoManualCollections) { collection in
                        let alreadyContainsAll = validItems.allSatisfy { collection.itemIDs.contains($0.id) }
                        Button {
                            appState.addToVideoManualCollection(validItems, collectionID: collection.id)
                        } label: {
                            Label(collection.name, systemImage: alreadyContainsAll ? "checkmark" : "rectangle.stack")
                        }
                        .disabled(alreadyContainsAll)
                    }
                }
            } label: {
                Label("加入集合", systemImage: "rectangle.stack.badge.plus")
            }
        }
    }
}
