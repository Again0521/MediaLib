import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计测试 - P0级风险专项】
/// 审计目标：验证在持有 50,000 个 `MediaItem` 实体的大规模片库下，
/// 主线性遍历计算树型层级及过滤分类的耗时是否超过 UI 帧间阈值 (16.6ms / 50ms)。
/// 对应报告问题 ID：P0-3 (RISK-03)
final class AppStatePerformanceAuditTests: XCTestCase {

    /// 构建 50,000 条模拟媒体数据（含剧集父子层级与私密标识）
    private func create50kMockMediaItems() -> [MediaItem] {
        var items: [MediaItem] = []
        items.reserveCapacity(50000)
        
        // 100 个私密系列与 400 个公开系列
        for s in 0..<500 {
            let seriesID = "series-\(s)"
            let isPrivate = s < 100
            let seriesItem = MediaItem(
                id: seriesID,
                type: isPrivate ? .privateCollection : .movie,
                title: "Mock Series \(s)",
                fileSize: 0
            )
            items.append(seriesItem)
            
            // 每个系列下挂 80 集
            for e in 0..<80 {
                let ep = MediaItem(
                    id: "\(seriesID)-ep-\(e)",
                    type: .movie,
                    title: "Episode \(e)",
                    parentID: seriesID,
                    fileSize: 1024 * 1024 * 500
                )
                items.append(ep)
            }
        }
        
        // 剩余填充独立音乐和电影
        while items.count < 50000 {
            let idx = items.count
            items.append(MediaItem(
                id: "item-\(idx)",
                type: idx % 2 == 0 ? .music : .movie,
                title: "Standalone Track \(idx)",
                fileSize: 1024 * 1024 * 10
            ))
        }
        return items
    }

    /// 审计测试 50,000 条数据下纯内存遍历与父子树形私密传播的同步消耗时间
    func testRebuildDerivedCachesAlgorithmLatencyUnder50kItems() {
        let items = create50kMockMediaItems()
        XCTAssertEqual(items.count, 50000)
        
        let startTime = CFAbsoluteTimeGetCurrent()
        
        // 模拟 AppState.rebuildDerivedItemCaches 的 Pass 1：私密树向子级传播。
        // 这里只需要子级 id 做 BFS，不需要整份 MediaItem（50 个字段的大 struct），
        // 存 id 而非整个 item 能显著减少 40,000 条剧集在 dictionary 里的拷贝开销。
        let privateCollectionIDs = Set(items.lazy.filter { $0.type == .privateCollection }.map(\.id))
        var childIDsByParentID: [String: [String]] = [:]
        for item in items {
            if let parentID = item.parentID {
                childIDsByParentID[parentID, default: []].append(item.id)
            }
        }

        var privateItemIDs = privateCollectionIDs
        privateItemIDs.reserveCapacity(items.count)
        var privateQueue = Array(privateCollectionIDs)
        privateQueue.reserveCapacity(items.count)
        var privateQueueIndex = 0
        while privateQueueIndex < privateQueue.count {
            let parentID = privateQueue[privateQueueIndex]
            privateQueueIndex += 1
            for childID in childIDsByParentID[parentID] ?? [] {
                if privateItemIDs.insert(childID).inserted {
                    privateQueue.append(childID)
                }
            }
        }
        
        // 模拟 Pass 2：单次分拣各类型数组
        var musicTracksRaw: [MediaItem] = []
        var watchingRaw: [MediaItem] = []
        var privateWatchingRaw: [MediaItem] = []
        
        for item in items {
            let isPrivate = privateItemIDs.contains(item.id)
            if item.type == .music {
                musicTracksRaw.append(item)
            } else if item.playPosition > 0 {
                if isPrivate {
                    privateWatchingRaw.append(item)
                } else {
                    watchingRaw.append(item)
                }
            }
        }
        
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        
        XCTAssertFalse(privateItemIDs.isEmpty, "应该能够成功推导出所有私密剧集的子单集 ID")
        XCTAssertLessThan(
            elapsed,
            0.05,
            "50,000 条目下的线性重筛查耗费了 \(String(format: "%.3f", elapsed * 1000))ms。若大于 50ms 将导致 UI 产生可见掉帧。必须尽量采用异步后台计算或局部增量策略。"
        )
    }
}
