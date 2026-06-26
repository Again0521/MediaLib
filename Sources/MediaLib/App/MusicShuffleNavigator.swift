import Foundation
import MediaLibCore

/// 随机播放导航器（从 AppState 抽出，R1-ARCH-001 + R3-PLAY-002）。
///
/// 用「一次性洗牌袋 + 历史栈」取代旧的无状态 `randomElement()`：
/// - **洗牌袋**：每首播完才从袋中移除，整袋放完再重洗 → 保证整轮不重复。
/// - **历史栈**：记录已随机播放的曲目，使「上一首」能真正回到上次随机播放过的曲目。
/// - 队列结构变化（`bagKey` 与当前 queue ID 列表不同）时自动重建。
///
/// 纯逻辑、不依赖 AppState，便于单测（洗牌策略可注入以获得确定性顺序）。
@MainActor
final class MusicShuffleNavigator {
    private var bag: [String] = []
    private var bagKey: [String] = []
    private var history: [String] = []
    /// 洗牌策略；默认 `Array.shuffled()`，测试可注入恒等序以获得确定性。
    private let shuffle: ([String]) -> [String]

    init(shuffle: @escaping ([String]) -> [String] = { $0.shuffled() }) {
        self.shuffle = shuffle
    }

    /// 随机模式下的下一首：从洗牌袋取下一个未播曲目；整袋放完后重洗（循环不停，保证整轮不重复）。
    /// 当前曲目入历史栈，供「上一首」回溯。
    func next(current item: MediaItem, queue: [MediaItem]) -> MediaItem? {
        let queueIDs = queue.map(\.id)
        guard !queueIDs.isEmpty else { return nil }
        rebuildIfNeeded(queueIDs: queueIDs)

        // 把当前曲目压入历史（去抖：避免连续相同），并确保它不会立刻又从袋里被抽到。
        if history.last != item.id {
            history.append(item.id)
        }
        bag.removeAll { $0 == item.id }

        if bag.isEmpty {
            // 整袋放完 → 重洗（排除当前曲目，避免与刚播的同一首相邻）。
            bag = shuffledBag(from: queueIDs, excluding: item.id)
            bagKey = queueIDs
        }
        guard let nextID = bag.first else {
            // 队列只有当前一首：无其他可选，返回自身（与旧 `?? item` 兜底一致）。
            return queue.first { $0.id == item.id } ?? item
        }
        bag.removeFirst()
        return queue.first { $0.id == nextID } ?? item
    }

    /// 随机模式下的上一首：从历史栈回退到上一次随机播放过的曲目；无历史则返回 nil
    /// （调用方落回顺序兜底）。被回退的曲目放回袋首，使其仍会在本轮被播到。
    func previous(current item: MediaItem, queue: [MediaItem]) -> MediaItem? {
        // 丢弃栈顶等于当前曲目的记录（指向自身的占位）。
        while history.last == item.id {
            history.removeLast()
        }
        guard let previousID = history.popLast(),
              let previous = queue.first(where: { $0.id == previousID }) else {
            return nil
        }
        // 当前曲目放回袋首，避免回退后它被本轮跳过。
        if !bag.contains(item.id), queue.contains(where: { $0.id == item.id }) {
            bag.insert(item.id, at: 0)
        }
        return previous
    }

    /// 重置洗牌袋与历史（切换 shuffle 开关时调用）。
    func reset() {
        bag = []
        bagKey = []
        history = []
    }

    private func rebuildIfNeeded(queueIDs: [String]) {
        guard bagKey != queueIDs || bag.isEmpty else { return }
        bag = shuffledBag(from: queueIDs, excluding: nil)
        bagKey = queueIDs
        // 队列结构变化时，历史中已不在队列里的曲目失去意义；保留仍存在的，按原顺序过滤。
        let present = Set(queueIDs)
        history.removeAll { !present.contains($0) }
    }

    private func shuffledBag(from queueIDs: [String], excluding excluded: String?) -> [String] {
        var bag = queueIDs
        if let excluded {
            bag.removeAll { $0 == excluded }
        }
        return shuffle(bag)
    }
}
