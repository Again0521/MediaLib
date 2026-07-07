import Foundation

public enum VideoManualCollectionReorderOperation: Sendable {
    case moveToTop
    case moveUp
    case moveDown
    case moveToBottom
}

public struct VideoManualCollection: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    /// 仅保存 MediaLIB 内部媒体 ID，避免集合操作移动、改名或写入用户媒体文件。
    public var itemIDs: [String]
    public var showOnHome: Bool
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        itemIDs: [String] = [],
        showOnHome: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        self.id = id
        self.name = trimmedName.isEmpty ? "新集合" : trimmedName
        self.itemIDs = itemIDs.filter { !$0.isEmpty }
        self.showOnHome = showOnHome
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case name
        case itemIDs
        case showOnHome
        case createdAt
        case updatedAt
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            id: try container.decodeIfPresent(String.self, forKey: .id) ?? UUID().uuidString,
            name: try container.decodeIfPresent(String.self, forKey: .name) ?? "新集合",
            itemIDs: try container.decodeIfPresent([String].self, forKey: .itemIDs) ?? [],
            showOnHome: try container.decodeIfPresent(Bool.self, forKey: .showOnHome) ?? false,
            createdAt: try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(),
            updatedAt: try container.decodeIfPresent(Date.self, forKey: .updatedAt) ?? Date()
        )
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(name, forKey: .name)
        try container.encode(itemIDs, forKey: .itemIDs)
        try container.encode(showOnHome, forKey: .showOnHome)
        try container.encode(createdAt, forKey: .createdAt)
        try container.encode(updatedAt, forKey: .updatedAt)
    }

    /// 集合排序只重排内部媒体 ID；UI 层和检查用例共用这里，避免右键菜单与持久化逻辑出现不同移动语义。
    public static func reorderedItemIDs(
        _ currentIDs: [String],
        movingItemIDs: [String],
        operation: VideoManualCollectionReorderOperation
    ) -> [String] {
        let movingSet = Set(movingItemIDs.filter { !$0.isEmpty })
        guard currentIDs.contains(where: movingSet.contains) else { return currentIDs }

        switch operation {
        case .moveToTop:
            let moving = currentIDs.filter { movingSet.contains($0) }
            let remaining = currentIDs.filter { !movingSet.contains($0) }
            return moving + remaining
        case .moveToBottom:
            let moving = currentIDs.filter { movingSet.contains($0) }
            let remaining = currentIDs.filter { !movingSet.contains($0) }
            return remaining + moving
        case .moveUp:
            var result = currentIDs
            guard result.count > 1 else { return result }
            var index = 1
            while index < result.count {
                if movingSet.contains(result[index]), !movingSet.contains(result[index - 1]) {
                    result.swapAt(index, index - 1)
                }
                index += 1
            }
            return result
        case .moveDown:
            var result = currentIDs
            guard result.count > 1 else { return result }
            var index = result.count - 2
            while index >= 0 {
                if movingSet.contains(result[index]), !movingSet.contains(result[index + 1]) {
                    result.swapAt(index, index + 1)
                }
                if index == 0 { break }
                index -= 1
            }
            return result
        }
    }
}
