import MediaLibCore
import SwiftUI

struct VideoManualCollectionCoverView: View {
    let items: [MediaItem]
    let title: String
    var size: CGFloat
    var cornerRadius: CGFloat
    var maxTiles: Int = 4
    var selected: Bool = false

    private var visibleItems: [MediaItem] {
        Array(items.prefix(max(maxTiles, 0)))
    }

    private var tileSpacing: CGFloat {
        max(size * 0.035, 1)
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)

        ZStack {
            fallbackBackground
            if visibleItems.isEmpty {
                fallbackSymbol
            } else {
                collage
            }
        }
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay {
            shape.strokeBorder(.white.opacity(selected ? 0.64 : 0.36), lineWidth: selected ? 1.2 : 0.8)
        }
        .overlay(alignment: .topLeading) {
            shape
                .strokeBorder(.white.opacity(0.20), lineWidth: 0.8)
                .blendMode(.plusLighter)
        }
        .shadow(color: .black.opacity(size <= 28 ? 0.06 : 0.10), radius: size <= 28 ? 2 : 8, y: size <= 28 ? 1 : 4)
        .accessibilityLabel(title)
    }

    @ViewBuilder
    private var collage: some View {
        switch visibleItems.count {
        case 1:
            posterTile(visibleItems[0], width: size, height: size)
        case 2:
            HStack(spacing: tileSpacing) {
                posterTile(visibleItems[0], width: (size - tileSpacing) / 2, height: size)
                posterTile(visibleItems[1], width: (size - tileSpacing) / 2, height: size)
            }
        case 3:
            HStack(spacing: tileSpacing) {
                posterTile(visibleItems[0], width: (size - tileSpacing) * 0.58, height: size)
                VStack(spacing: tileSpacing) {
                    posterTile(visibleItems[1], width: (size - tileSpacing) * 0.42, height: (size - tileSpacing) / 2)
                    posterTile(visibleItems[2], width: (size - tileSpacing) * 0.42, height: (size - tileSpacing) / 2)
                }
            }
        default:
            VStack(spacing: tileSpacing) {
                HStack(spacing: tileSpacing) {
                    posterTile(visibleItems[0], width: (size - tileSpacing) / 2, height: (size - tileSpacing) / 2)
                    posterTile(visibleItems[1], width: (size - tileSpacing) / 2, height: (size - tileSpacing) / 2)
                }
                HStack(spacing: tileSpacing) {
                    posterTile(visibleItems[2], width: (size - tileSpacing) / 2, height: (size - tileSpacing) / 2)
                    posterTile(visibleItems[3], width: (size - tileSpacing) / 2, height: (size - tileSpacing) / 2)
                }
            }
        }
    }

    private func posterTile(_ item: MediaItem, width: CGFloat, height: CGFloat) -> some View {
        PosterImage(
            path: item.posterPath,
            title: item.cardTitle,
            mediaType: item.type,
            cacheTargetSize: CGSize(width: max(width * 2, 44), height: max(height * 2, 44))
        )
        .frame(width: width, height: height)
        .clipped()
    }

    private var fallbackBackground: some View {
        ZStack {
            LinearGradient(
                colors: [
                    AppColors.cleanFieldFill.opacity(0.94),
                    AppColors.solarLightTint.opacity(0.62),
                    AppColors.selectedGlassTint.opacity(0.28)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
            LinearGradient(
                colors: [
                    .white.opacity(0.38),
                    .clear,
                    .black.opacity(0.08)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )
        }
    }

    private var fallbackSymbol: some View {
        ZStack {
            RoundedRectangle(cornerRadius: max(cornerRadius * 0.72, 5), style: .continuous)
                .fill(.white.opacity(0.22))
                .padding(size * 0.18)
            PlayfulSymbolIcon(systemImage: "rectangle.stack", size: max(size * 0.64, 16), selected: false)
        }
    }
}

struct VideoManualCollectionPageHeader<Actions: View>: View {
    let title: String
    let subtitle: String
    let previewItems: [MediaItem]
    @ViewBuilder var actions: Actions

    var body: some View {
        HStack(alignment: .bottom, spacing: 20) {
            HStack(alignment: .center, spacing: 16) {
                VideoManualCollectionCoverView(
                    items: previewItems,
                    title: title,
                    size: 76,
                    cornerRadius: 17,
                    maxTiles: 4
                )

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 32, weight: .semibold))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Spacer(minLength: 16)

            HStack(spacing: 10) {
                actions
            }
            .buttonStyle(HeaderActionGlassButtonStyle(cornerRadius: 13, horizontalPadding: 12, minHeight: 34))
            .fixedSize(horizontal: true, vertical: false)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(minHeight: 82, alignment: .bottom)
        .transaction { transaction in
            transaction.animation = nil
        }
    }
}
