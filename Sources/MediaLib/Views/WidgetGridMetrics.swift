import CoreGraphics
import SwiftUI

enum AppWidgetFraction {
    case quarter
    case third
    case half
    case twoThirds
    case threeQuarters
    case full
}

enum AppWidgetGridMetrics {
    static let dashboardGap: CGFloat = 14
    static let homeGap: CGFloat = 14

    static let dashboardQuarterHeight: CGFloat = 150
    static let homeQuarterHeight: CGFloat = 116

    static func dashboardHeight(_ fraction: AppWidgetFraction) -> CGFloat {
        fractionalHeight(fraction, unit: dashboardQuarterHeight, gap: dashboardGap)
    }

    static func homeHeight(_ fraction: AppWidgetFraction) -> CGFloat {
        fractionalHeight(fraction, unit: homeQuarterHeight, gap: homeGap)
    }

    static func fractionalHeight(_ fraction: AppWidgetFraction, unit: CGFloat, gap: CGFloat) -> CGFloat {
        switch fraction {
        case .quarter:
            return unit
        case .third:
            return unit + (unit + gap) / 3
        case .half:
            return unit * 2 + gap
        case .twoThirds:
            return (unit * 3 + gap * 2) * 2 / 3
        case .threeQuarters:
            return unit * 3 + gap * 2
        case .full:
            return unit * 4 + gap * 3
        }
    }

    static func fractionalMinWidth(_ fraction: AppWidgetFraction) -> CGFloat {
        switch fraction {
        case .quarter:
            return 176
        case .third:
            return 236
        case .half:
            return 330
        case .twoThirds:
            return 450
        case .threeQuarters:
            return 520
        case .full:
            return 680
        }
    }

    static func adaptiveColumns(
        fraction: AppWidgetFraction,
        maximum: CGFloat? = nil,
        spacing: CGFloat
    ) -> [GridItem] {
        [
            GridItem(
                .adaptive(
                    minimum: fractionalMinWidth(fraction),
                    maximum: maximum ?? .infinity
                ),
                spacing: spacing
            )
        ]
    }

    static func columnCount(
        for width: CGFloat,
        preferredColumns: Int,
        minimumColumnWidth: CGFloat,
        spacing: CGFloat
    ) -> Int {
        let safePreferred = max(preferredColumns, 1)
        for count in stride(from: safePreferred, through: 1, by: -1) {
            let required = CGFloat(count) * minimumColumnWidth + CGFloat(max(count - 1, 0)) * spacing
            if width >= required {
                return count
            }
        }
        return 1
    }

    static func equalColumns(count: Int, spacing: CGFloat) -> [GridItem] {
        Array(
            repeating: GridItem(.flexible(), spacing: spacing),
            count: max(count, 1)
        )
    }

    static func gridHeight(
        itemCount: Int,
        columns: Int,
        itemHeight: CGFloat,
        spacing: CGFloat
    ) -> CGFloat {
        let safeColumns = max(columns, 1)
        let rows = max(1, Int(ceil(Double(max(itemCount, 1)) / Double(safeColumns))))
        return CGFloat(rows) * itemHeight + CGFloat(rows - 1) * spacing
    }
}
