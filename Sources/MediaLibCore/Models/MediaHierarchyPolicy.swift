public struct MediaHierarchySnapshot: Sendable {
    public var childrenByParentID: [String: [MediaItem]]
    public var privateItemIDs: Set<String>

    public init(childrenByParentID: [String: [MediaItem]], privateItemIDs: Set<String>) {
        self.childrenByParentID = childrenByParentID
        self.privateItemIDs = privateItemIDs
    }
}

public enum MediaHierarchyPolicy {
    public static func sortedChildrenByParentID(
        _ childrenByParentID: [String: [MediaItem]]
    ) -> [String: [MediaItem]] {
        childrenByParentID.mapValues(orderedChildren)
    }

    public static func orderedChildren(_ children: [MediaItem]) -> [MediaItem] {
        children.sorted {
            if ($0.seasonNumber ?? 0) != ($1.seasonNumber ?? 0) {
                return ($0.seasonNumber ?? 0) < ($1.seasonNumber ?? 0)
            }
            if ($0.episodeNumber ?? 0) != ($1.episodeNumber ?? 0) {
                return ($0.episodeNumber ?? 0) < ($1.episodeNumber ?? 0)
            }
            return $0.title.localizedStandardCompare($1.title) == .orderedAscending
        }
    }

    public static func snapshot(for items: [MediaItem]) -> MediaHierarchySnapshot {
        let privateCollectionIDs = Set(items.lazy.filter { $0.type == .privateCollection }.map(\.id))
        var childrenByParentID: [String: [MediaItem]] = [:]
        for item in items {
            if let parentID = item.parentID {
                childrenByParentID[parentID, default: []].append(item)
            }
        }

        var privateItemIDs = privateCollectionIDs
        var privateQueue = Array(privateCollectionIDs)
        var privateQueueIndex = 0
        while privateQueueIndex < privateQueue.count {
            let parentID = privateQueue[privateQueueIndex]
            privateQueueIndex += 1
            for child in childrenByParentID[parentID] ?? [] {
                if privateItemIDs.insert(child.id).inserted {
                    privateQueue.append(child.id)
                }
            }
        }

        return MediaHierarchySnapshot(
            childrenByParentID: childrenByParentID,
            privateItemIDs: privateItemIDs
        )
    }
}
