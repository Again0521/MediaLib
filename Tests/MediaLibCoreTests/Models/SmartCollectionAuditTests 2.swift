import XCTest
import Foundation
@testable import MediaLibCore

/// 【白盒审计补充测试 - P1级智能集合计算与表达式安全专项】
/// 审计目标：验证在大规模数据项（20,000 条）和多重复合条件表达式（AND/OR 交叉、年份、状态过滤）下，
/// `VideoSmartCollection.matches` 批量求值性能是否处于 UI 安全范围，以及无有效年份等特殊数据的容错防崩溃。
/// 对应报告问题 ID：TC-UI-001
final class SmartCollectionAuditTests: XCTestCase {

    private func create20kDiverseMediaItems() -> [MediaItem] {
        var items: [MediaItem] = []
        items.reserveCapacity(20000)

        let years: [Int?] = [nil, 1998, 2010, 2019, 2020, 2023, 2025, 1980]
        let types: [MediaType] = [.movie, .tvShow, .anime, .documentary, .music, .episode, .privateCollection]

        for i in 0..<20000 {
            let type = types[i % types.count]
            let year = years[i % years.count]
            let isFav = (i % 3 == 0)
            let isWatched = (i % 4 == 0)
            let isWatchlist = (i % 5 == 0)
            let progress = isWatched ? 1.0 : (Double(i % 100) / 100.0)

            items.append(MediaItem(
                id: "smart-item-\(i)",
                type: type,
                title: "Movie Title \(i) [HEVC_FLAC]",
                year: year,
                playProgress: progress,
                watched: isWatched,
                favorite: isFav,
                watchlist: isWatchlist
            ))
        }
        return items
    }

    /// 测试在 20,000 条目下全量执行“喜欢且新片(2020年后)”复合条件的过滤耗时
    func testSmartCollectionComplexAllModePerformanceUnder20kItems() {
        let items = create20kDiverseMediaItems()
        let collection = VideoSmartCollection(
            name: "喜爱的新片",
            stateFilter: .favorites,
            rules: VideoSmartCollectionRules(matchMode: .all, year: .since2020)
        )

        let start = CFAbsoluteTimeGetCurrent()
        var matchCount = 0
        for item in items {
            if collection.matches(item, watchedThreshold: 0.9) {
                matchCount += 1
            }
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThan(matchCount, 0, "必须能够匹配到符合条件的喜爱新片")
        XCTAssertLessThan(
            elapsed,
            0.05,
            "20,000 条目全量智能集合表达式求值耗时为 \(String(format: "%.3f", elapsed * 1000))ms。若超过 50ms 会引发界面卡顿，必须做分块计算或增量派生"
        )
    }

    /// 测试在 20,000 条目下全量执行“任一满足(喜爱/已看/新片)”条件求值性能
    func testSmartCollectionComplexAnyModePerformanceUnder20kItems() {
        let items = create20kDiverseMediaItems()
        let collection = VideoSmartCollection(
            name: "随便看看",
            stateFilter: .watched,
            rules: VideoSmartCollectionRules(matchMode: .any, year: .since2020)
        )

        let start = CFAbsoluteTimeGetCurrent()
        let matchedItems = items.filter { collection.matches($0, watchedThreshold: 0.9) }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertFalse(matchedItems.isEmpty)
        XCTAssertLessThan(elapsed, 0.05)
    }

    /// 验证当媒体年份字段包含异常负数或远超现实边界年份时的健壮性
    func testSmartCollectionWithExtremeYearValuesDoesNotCrash() {
        let extremeItem1 = MediaItem(id: "ex-1", type: .movie, title: "Future", year: 99999)
        let extremeItem2 = MediaItem(id: "ex-2", type: .movie, title: "Ancient", year: -5000)
        let extremeItem3 = MediaItem(id: "ex-3", type: .movie, title: "NoYear", year: nil)

        let collection = VideoSmartCollection(name: "2020后", rules: VideoSmartCollectionRules(year: .since2020))

        XCTAssertTrue(collection.matches(extremeItem1, watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(extremeItem2, watchedThreshold: 0.9))
        XCTAssertFalse(collection.matches(extremeItem3, watchedThreshold: 0.9))
    }
}
