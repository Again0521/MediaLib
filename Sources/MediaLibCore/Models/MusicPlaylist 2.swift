import Foundation

public struct MusicPlaylist: Identifiable, Codable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var itemIDs: [String]
    public var createdAt: Date
    public var updatedAt: Date

    public init(
        id: String = UUID().uuidString,
        name: String,
        itemIDs: [String] = [],
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "新歌单" : name
        self.itemIDs = itemIDs
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}
