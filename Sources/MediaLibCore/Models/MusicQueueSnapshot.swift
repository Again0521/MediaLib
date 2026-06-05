import Foundation

public struct MusicQueueSnapshot: Codable, Hashable, Sendable {
    public var itemIDs: [String]
    public var repeatModeRawValue: String
    public var shuffleEnabled: Bool
    public var updatedAt: Date

    public init(
        itemIDs: [String] = [],
        repeatModeRawValue: String = "sequential",
        shuffleEnabled: Bool = false,
        updatedAt: Date = Date()
    ) {
        self.itemIDs = itemIDs
        self.repeatModeRawValue = repeatModeRawValue
        self.shuffleEnabled = shuffleEnabled
        self.updatedAt = updatedAt
    }
}
