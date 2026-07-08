import Combine
import Foundation
import MediaLibCore

/// 视频集合状态容器。
///
/// 只拥有智能集合/手动集合数组、repository CRUD 与内存排序。通知、library revision、
/// 媒体可见性过滤、首页展示数据和右键菜单仍留在 AppState/Views，避免集合 Store
/// 扩张成视频库协调器。
@MainActor
final class VideoCollectionStore: ObservableObject {
    @Published private(set) var smartCollections: [VideoSmartCollection] = []
    @Published private(set) var manualCollections: [VideoManualCollection] = []

    private let smartRepository: VideoSmartCollectionRepository?
    private let manualRepository: VideoManualCollectionRepository?

    init(
        smartRepository: VideoSmartCollectionRepository?,
        manualRepository: VideoManualCollectionRepository?
    ) {
        self.smartRepository = smartRepository
        self.manualRepository = manualRepository
    }

    func replaceLoaded(
        smartCollections: [VideoSmartCollection],
        manualCollections: [VideoManualCollection]
    ) {
        self.smartCollections = smartCollections
        self.manualCollections = manualCollections
    }

    func smartCollection(id: String) -> VideoSmartCollection? {
        smartCollections.first { $0.id == id }
    }

    @discardableResult
    func saveSmart(_ collection: VideoSmartCollection) throws -> (saved: VideoSmartCollection, isNew: Bool)? {
        guard let smartRepository else { return nil }
        let isNew = !smartCollections.contains { $0.id == collection.id }
        let saved = try smartRepository.save(collection)
        upsertSmartInMemory(saved)
        return (saved, isNew)
    }

    @discardableResult
    func deleteSmart(id: String) throws -> Bool {
        guard let smartRepository else { return false }
        try smartRepository.delete(id: id)
        smartCollections.removeAll { $0.id == id }
        return true
    }

    func manualCollection(id: String) -> VideoManualCollection? {
        manualCollections.first { $0.id == id }
    }

    @discardableResult
    func saveManual(_ collection: VideoManualCollection) throws -> (saved: VideoManualCollection, isNew: Bool)? {
        guard let manualRepository else { return nil }
        let isNew = !manualCollections.contains { $0.id == collection.id }
        let saved = try manualRepository.save(collection)
        upsertManualInMemory(saved)
        return (saved, isNew)
    }

    @discardableResult
    func createManual(name: String, itemIDs: [String]) throws -> VideoManualCollection? {
        guard let manualRepository else { return nil }
        let collection = try manualRepository.create(name: name, itemIDs: itemIDs)
        upsertManualInMemory(collection)
        return collection
    }

    @discardableResult
    func deleteManual(id: String) throws -> Bool {
        guard let manualRepository else { return false }
        try manualRepository.delete(id: id)
        manualCollections.removeAll { $0.id == id }
        return true
    }

    @discardableResult
    func addManual(itemIDs: [String], toCollectionID collectionID: String) throws -> VideoManualCollection? {
        guard let manualRepository else { return nil }
        guard let updated = try manualRepository.add(itemIDs: itemIDs, toCollectionID: collectionID) else { return nil }
        upsertManualInMemory(updated)
        return updated
    }

    @discardableResult
    func removeManual(itemIDs: [String], fromCollectionID collectionID: String) throws -> VideoManualCollection? {
        guard let manualRepository else { return nil }
        guard let updated = try manualRepository.remove(itemIDs: itemIDs, fromCollectionID: collectionID) else { return nil }
        upsertManualInMemory(updated)
        return updated
    }

    func canReorderManual(
        itemIDs: [String],
        collectionID: String,
        operation: VideoManualCollectionReorderOperation
    ) -> Bool {
        guard let collection = manualCollection(id: collectionID) else { return false }
        return reorderedManualItemIDs(
            collection.itemIDs,
            movingItemIDs: itemIDs,
            operation: operation
        ) != collection.itemIDs
    }

    @discardableResult
    func reorderManual(
        itemIDs: [String],
        collectionID: String,
        operation: VideoManualCollectionReorderOperation
    ) throws -> VideoManualCollection? {
        guard let manualRepository else { return nil }
        guard var collection = try manualRepository.fetch(id: collectionID) else { return nil }
        let reordered = reorderedManualItemIDs(
            collection.itemIDs,
            movingItemIDs: itemIDs,
            operation: operation
        )
        guard reordered != collection.itemIDs else { return nil }
        collection.itemIDs = reordered
        let saved = try manualRepository.save(collection)
        upsertManualInMemory(saved)
        return saved
    }

    func manualCollections(containing itemID: String) -> [VideoManualCollection] {
        manualCollections.filter { $0.itemIDs.contains(itemID) }
    }

    private func upsertSmartInMemory(_ collection: VideoSmartCollection) {
        if let index = smartCollections.firstIndex(where: { $0.id == collection.id }) {
            smartCollections[index] = collection
        } else {
            smartCollections.insert(collection, at: 0)
        }
        smartCollections.sort { $0.updatedAt > $1.updatedAt }
    }

    private func upsertManualInMemory(_ collection: VideoManualCollection) {
        if let index = manualCollections.firstIndex(where: { $0.id == collection.id }) {
            manualCollections[index] = collection
        } else {
            manualCollections.insert(collection, at: 0)
        }
        manualCollections.sort { lhs, rhs in
            if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }

    private func reorderedManualItemIDs(
        _ currentIDs: [String],
        movingItemIDs: [String],
        operation: VideoManualCollectionReorderOperation
    ) -> [String] {
        VideoManualCollection.reorderedItemIDs(
            currentIDs,
            movingItemIDs: movingItemIDs,
            operation: operation
        )
    }
}
