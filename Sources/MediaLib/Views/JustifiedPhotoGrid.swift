import SwiftUI

/// 保留宽高比的瀑布式（justified rows）相册排版，参考 Google Photos / Immich：
/// 每一行把若干张照片按其原始宽高比横向铺满容器宽度，**同一行统一高度、宽度各异**；
/// 最后一行左对齐、不强行拉伸。竖图不再被裁成正方形，整页边到边、无右侧不规则留白。
///
/// 容器宽度由调用方在根部用一个 GeometryReader 量一次后显式传入（不自测量），
/// 避免 PreferenceKey 回环导致的抖动/重叠。
struct JustifiedPhotoGrid<Item: Identifiable, Cell: View>: View {
    let items: [Item]
    let containerWidth: CGFloat
    /// 每个条目的宽高比（宽/高）；未知时调用方回落到 1.0。
    let aspectRatio: (Item) -> Double
    var targetRowHeight: CGFloat = 168
    var spacing: CGFloat = 3
    @ViewBuilder let cell: (Item, CGSize) -> Cell

    var body: some View {
        let rows = Self.computeRows(
            items: items,
            aspectRatio: aspectRatio,
            containerWidth: containerWidth,
            targetRowHeight: targetRowHeight,
            spacing: spacing
        )
        VStack(alignment: .leading, spacing: spacing) {
            ForEach(rows) { row in
                HStack(spacing: spacing) {
                    ForEach(row.cells) { entry in
                        cell(items[entry.index], entry.size)
                            .frame(width: entry.size.width, height: entry.size.height)
                            .clipped()
                    }
                }
                .frame(height: row.height, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - 行计算

    struct Row: Identifiable {
        let id: Int
        let height: CGFloat
        let cells: [RowCell]
    }

    struct RowCell: Identifiable {
        let id: Int
        let index: Int
        let size: CGSize
    }

    static func computeRows(
        items: [Item],
        aspectRatio: (Item) -> Double,
        containerWidth: CGFloat,
        targetRowHeight: CGFloat,
        spacing: CGFloat
    ) -> [Row] {
        guard containerWidth > 1, !items.isEmpty else { return [] }
        // 仅夹掉真正极端的全景/超长条，避免某行被压得极扁/极高；常见手机比例（0.56~1.78）原样保留。
        let clamp: (Double) -> Double = { min(max($0, 0.4), 3.2) }

        var rows: [Row] = []
        var current: [(index: Int, aspect: Double)] = []
        var aspectSum: Double = 0
        var rowID = 0

        func flush(stretch: Bool) {
            guard !current.isEmpty else { return }
            let totalSpacing = spacing * CGFloat(current.count - 1)
            let availableWidth = max(containerWidth - totalSpacing, 1)
            let rowHeight: CGFloat
            if stretch {
                rowHeight = (availableWidth / CGFloat(aspectSum)).rounded()
            } else {
                // 末行不拉伸到满宽，保持目标行高，左对齐。
                rowHeight = min(targetRowHeight, availableWidth / CGFloat(aspectSum)).rounded()
            }
            // 逐格取整宽度，并让本行最后一格吸收余量，使每行右缘精确对齐（消除逐像素累积误差导致的错位）。
            var widths = current.map { ($0.aspect * rowHeight).rounded() }
            if stretch, !widths.isEmpty {
                let drift = availableWidth - widths.reduce(0, +)
                widths[widths.count - 1] = max(1, widths[widths.count - 1] + drift)
            }
            let cells = current.enumerated().map { offset, entry -> RowCell in
                RowCell(id: entry.index, index: entry.index, size: CGSize(width: max(1, widths[offset]), height: rowHeight))
            }
            rows.append(Row(id: rowID, height: rowHeight, cells: cells))
            rowID += 1
            current = []
            aspectSum = 0
        }

        for index in items.indices {
            let aspect = clamp(aspectRatio(items[index]))
            current.append((index, aspect))
            aspectSum += aspect
            let naturalWidth = CGFloat(aspectSum) * targetRowHeight + spacing * CGFloat(current.count - 1)
            if naturalWidth >= containerWidth {
                flush(stretch: true)
            }
        }
        flush(stretch: false)
        return rows
    }
}
